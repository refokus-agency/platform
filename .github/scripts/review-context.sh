#!/usr/bin/env bash
#
# Composes the prompt for code-review.yml's "Code review" step: the caller's prompt followed by
# the context blocks, printed to stdout. Warnings go to stderr, so that they reach the run log
# and never the prompt.
#
# Blocks are appended AFTER the caller's prompt, never before it: line 1 has to stay the bare
# slash command, or the command is not recognised as one. Each block is optional and present
# only when its data is, so an overridden `prompt` still gets them.
#
# The workflow runs this BEFORE the review, out of a platform checkout that it deletes again
# before the pull request head is checked out, and falls back to the caller's prompt plus a
# fixed `Context not read:` block when this script is missing or exits non-zero. So a failure
# here costs the review its context, never the review itself — keep it that way: a block that
# cannot get its data warns, it does not exit. A block whose source fails also emits a
# `Context not read:` block of its own, the only shape the default prompt accepts as a report
# of unread context (#118): its header and its "Left unchecked" list come from a fixed
# vocabulary here, never from fetched text, and it carries its own instruction to be named in
# the summary, for callers that override `prompt`.
#
# Environment (every value is caller- or author-controlled text and is only ever read from the
# environment, never interpolated into a script):
#   PROMPT             the caller's `prompt` input
#   HEAD_SHA           the reviewed commit, from "Resolve pull request"
#   PR_NUMBER          the reviewed pull request
#   BASE_REF           its base branch
#   DEFAULT_BRANCH     the repository's default branch
#   GH_TOKEN           token able to read pull requests
#   GITHUB_REPOSITORY  supplied by the runner
#
# Tests: .github/scripts/test-review-context.sh, run in CI by .github/workflows/script-tests.yml.

set -euo pipefail

PROMPT=${PROMPT:-}
HEAD_SHA=${HEAD_SHA:-}
PR_NUMBER=${PR_NUMBER:-}
BASE_REF=${BASE_REF:-}
DEFAULT_BRANCH=${DEFAULT_BRANCH:-}

# One function per block, each printing its block or nothing. A new block adds one
# function here and one quoted `"$(block_x)"` entry to `blocks` in `compose`, and fetches
# its own data.
block_commit() {
  # Validated, not trusted: anything but a full lowercase SHA is dropped, not quoted.
  if [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'Reviewed commit: %s\n' "$HEAD_SHA"
    printf 'This is the commit checked out for this review. Name it in the summary as the commit that was checked.'
  fi
}

# The related-PRs lookups. Each prints one `<number>\t<relation>\t<status>` line per pull
# request it finds. On failure it prints a `failed\t<lookup>` line instead, which
# block_related turns into a `Context not read:` block, and a `::warning::` to stderr,
# which reaches the run log and never the prompt. Only the number, a fixed relation and a
# status derived from `state` and `merged_at` are read: titles, bodies and branch names are
# author text, and an error response is never read at all.
related_lines() {
  # $1: the relation; $2: the jq path to the pull request objects in the JSON on stdin.
  # Only `open` and `closed` are mapped. Anything else — a missing state, a new value, a
  # change of case — becomes `unknown`, which block_related drops with a warning, rather
  # than defaulting to "closed without merging", which the prompt reads as "fixes nothing".
  jq -r --arg rel "$1" "$2"' | [.number, $rel,
    (if .state == "open" then "open"
     elif .state == "closed" and .merged_at != null then "merged"
     elif .state == "closed" then "closed without merging"
     else "unknown" end)] | @tsv'
}

related_failed() {
  # $1: the lookup's fixed name, one of `stack`, `siblings` or `base chain`.
  echo "::warning::[code-review] related pull requests lookup failed: $1. The review runs without its entries and is asked to report it as context not read in the summary; see docs/troubleshooting.md." >&2
  printf 'failed\t%s\n' "$1"
}

related_stack() {
  local out lines
  if ! out=$(gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
      "repos/${GITHUB_REPOSITORY}/stacks?pull_request=${PR_NUMBER}") \
    || ! lines=$(printf '%s' "$out" | related_lines stack '.[] | (.pull_requests // [])[]'); then
    related_failed stack
    return 0
  fi
  printf '%s\n' "$lines"
}

related_siblings() {
  local base out lines
  # On the default branch every open pull request is a "sibling", which says nothing.
  if [ -z "$BASE_REF" ] || [ "$BASE_REF" = "$DEFAULT_BRANCH" ]; then
    return 0
  fi
  # The branch name goes into a query string, so it is encoded, never pasted.
  base=$(jq -rn --arg b "$BASE_REF" '$b | @uri')
  # --paginate prints one JSON array per page; jq reads them as a stream.
  if ! out=$(gh api --paginate \
      "repos/${GITHUB_REPOSITORY}/pulls?state=open&base=${base}&per_page=100") \
    || ! lines=$(printf '%s' "$out" | related_lines sibling '.[]'); then
    related_failed siblings
    return 0
  fi
  printf '%s\n' "$lines"
}

related_chain() {
  # Walks down a manual chain: the open pull request whose head is this one's base, then
  # the one whose head is that one's base, and so on. Stops at the default branch, when no
  # open pull request heads the branch, when a number repeats (a loop), or when more than
  # one does (an ambiguous chain: all of them are listed, none is followed). It also stops
  # after 20 lookups, with a warning: the repeat check already ends a loop, and the cap keeps
  # a regression in it from hanging the step until the job times out.
  local branch=$BASE_REF seen=" $PR_NUMBER " head out lines next hops=0
  while [ -n "$branch" ] && [ "$branch" != "$DEFAULT_BRANCH" ]; do
    if [ "$hops" -ge 20 ]; then
      echo "::warning::[code-review] base chain longer than 20 pull requests; the review lists the first 20." >&2
      return 0
    fi
    hops=$((hops + 1))
    head=$(jq -rn --arg h "${GITHUB_REPOSITORY%%/*}:${branch}" '$h | @uri')
    if ! out=$(gh api "repos/${GITHUB_REPOSITORY}/pulls?state=open&head=${head}&per_page=100") \
      || ! lines=$(printf '%s' "$out" | related_lines base '.[]') \
      || ! next=$(printf '%s' "$out" | jq -r 'if length == 1 then "\(.[0].number) \(.[0].base.ref)" else "" end'); then
      related_failed 'base chain'
      return 0
    fi
    if [ -n "$lines" ]; then
      printf '%s\n' "$lines"
    fi
    if [ -z "$next" ] || [[ "$seen" == *" ${next%% *} "* ]]; then
      return 0
    fi
    seen+="${next%% *} "
    branch=${next#* }
  done
}

block_related() {
  # Re-validated here whatever the lookup printed: a line that is not exactly a number, a
  # known relation and a known status is dropped. Each number is kept once, under the
  # first lookup that found it, and the reviewed pull request is never listed. A dropped
  # line does not mark its number as seen, so it never hides a valid line from a later
  # lookup. A pull request whose status is `unknown` is named in a warning on stderr.
  #
  # A failed lookup is reported in a `Context not read:` block of its own, after the related
  # block, naming every failed lookup and what each left unchecked from a closed vocabulary:
  # otherwise the agent cannot tell "this lookup failed" from "nothing is related". The default
  # prompt counts only a block that starts with `Context not read:` as that report, so the
  # failure never goes inside the related block. A lookup that answered but returned a pull
  # request without a usable number (a changed response shape, e.g. the stacks preview renaming
  # `number`) failed too: it may have missed a related pull request just the same.
  { related_chain; related_stack; related_siblings; } | awk -F '\t' -v self="$PR_NUMBER" '
    function fail(lookup) {
      if (!failseen[lookup]++) failed[++nfailed] = lookup
    }
    NF == 2 && $1 == "failed" && $2 ~ /^(stack|siblings|base chain)$/ {
      fail($2)
      next
    }
    NF == 3 && $1 !~ /^[1-9][0-9]*$/ && $2 ~ /^(base|stack|sibling)$/ {
      lookup = ($2 == "base" ? "base chain" : ($2 == "sibling" ? "siblings" : $2))
      if (!warned[lookup]++) {
        print "::warning::[code-review] related pull requests lookup returned a pull request without a usable number: " lookup ". It is not listed, and the review is asked to report the lookup as context not read in the summary; see docs/troubleshooting.md." > "/dev/stderr"
      }
      fail(lookup)
      next
    }
    NF == 3 && $1 ~ /^[1-9][0-9]*$/ && $1 != self && $3 == "unknown" {
      print "::warning::[code-review] related pull request #" $1 " has an unrecognised status and is not listed." > "/dev/stderr"
      next
    }
    NF == 3 && $1 ~ /^[1-9][0-9]*$/ && $1 != self &&
    $2 ~ /^(base|stack|sibling)$/ && $3 ~ /^(open|merged|closed without merging)$/ &&
    !seen[$1]++ {
      if (!entries++) print "Related pull requests:"
      printf "- #%s (%s, %s)\n", $1, $2, $3
    }
    END {
      if (entries) {
        print "Only numbers, relations and statuses are listed here. Inspect any of them with gh pr view and gh pr diff."
      }
      if (!nfailed) exit
      name["stack"] = "the stack lookup"
      name["siblings"] = "the sibling lookup"
      name["base chain"] = "the base chain lookup"
      left["stack"] = "the rest of the stack this pull request belongs to"
      left["siblings"] = "the open pull requests on its base"
      left["base chain"] = "the pull requests this one is based on"
      if (entries) print ""
      names = name[failed[1]]
      lefts = left[failed[1]]
      for (i = 2; i <= nfailed; i++) {
        names = names ", " name[failed[i]]
        lefts = lefts (i == nfailed ? " and " : ", ") left[failed[i]]
      }
      print "Context not read: " names "."
      print "Left unchecked: " lefts ", any of which may already fix or contradict a finding."
      print "Name this in the summary, with what it left unchecked."
    }'
}

compose() {
  local block trimmed
  local -a blocks
  # A blank prompt passes through untouched: blocks with no slash command in front of
  # them would turn a misconfigured caller into an instruction-less run of the agent.
  if [[ -z "${PROMPT//[[:space:]]/}" ]]; then
    printf '%s' "$PROMPT"
    return
  fi
  # Trailing newlines are dropped (command substitution strips them) so that every block
  # sits after exactly one blank line, however the prompt ends. The fallback in
  # code-review.yml's "Resolve review context" step repeats this check and this trim for its
  # fixed sentence, because it runs exactly when this script is not available: change both.
  trimmed=$(printf '%s' "$PROMPT")
  printf '%s' "$trimmed"
  blocks=("$(block_commit)" "$(block_related)")
  for block in "${blocks[@]}"; do
    if [ -n "$block" ]; then
      printf '\n\n%s' "$block"
    fi
  done
}

compose
