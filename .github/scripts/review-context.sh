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
# before the pull request head is checked out, and falls back to the caller's prompt alone when
# this script is missing or exits non-zero. So a failure here costs the review its context,
# never the review itself — keep it that way: a block that cannot get its data prints nothing
# and warns, it does not exit.
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
# request it finds, and on failure a `::warning::` to stderr, so that the warning reaches
# the run log and never the prompt. Only the number, a fixed relation and a status derived
# from `state` and `merged_at` are read: titles, bodies and branch names are author text.
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
  echo "::warning::[code-review] related pull requests lookup failed: $1. The review runs without its entries; see docs/troubleshooting.md." >&2
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
  # one does (an ambiguous chain: all of them are listed, none is followed).
  local branch=$BASE_REF seen=" $PR_NUMBER " head out lines next
  while [ -n "$branch" ] && [ "$branch" != "$DEFAULT_BRANCH" ]; do
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
  local lines
  # Re-validated here whatever the lookup printed: a line that is not exactly a number, a
  # known relation and a known status is dropped. Each number is kept once, under the
  # first lookup that found it, and the reviewed pull request is never listed. A dropped
  # line does not mark its number as seen, so it never hides a valid line from a later
  # lookup. A pull request whose status is `unknown` is named in a warning on stderr.
  lines=$({ related_chain; related_stack; related_siblings; } | awk -F '\t' -v self="$PR_NUMBER" '
    NF == 3 && $1 ~ /^[1-9][0-9]*$/ && $1 != self && $3 == "unknown" {
      print "::warning::[code-review] related pull request #" $1 " has an unrecognised status and is not listed." > "/dev/stderr"
      next
    }
    NF == 3 && $1 ~ /^[1-9][0-9]*$/ && $1 != self &&
    $2 ~ /^(base|stack|sibling)$/ && $3 ~ /^(open|merged|closed without merging)$/ &&
    !seen[$1]++ {
      printf "- #%s (%s, %s)\n", $1, $2, $3
    }')
  if [ -n "$lines" ]; then
    printf 'Related pull requests:\n%s\n' "$lines"
    printf 'Only numbers, relations and statuses are listed here. Inspect any of them with gh pr view and gh pr diff.'
  fi
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
  # sits after exactly one blank line, however the prompt ends.
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
