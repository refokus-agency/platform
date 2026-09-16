#!/usr/bin/env bash
#
# Verifies that every third-party action referenced under .github/ is pinned to a
# full-length commit SHA whose trailing version comment tells the truth.
#
# Why this exists as our own script rather than an off-the-shelf action: the gate
# enforces a policy about not trusting third-party code, so running it *through*
# third-party code is the wrong shape. A SHA pin stops an upstream tag from moving; it
# does not stop the code at that SHA from running in the job. pinact (the CLI) is still
# how pins are generated locally — see docs/contributing.md. Only the gate is ours.
#
# What it checks, per third-party `uses:`:
#   1. the ref is `owner/repo[/subpath]@<40-hex>` — a tag, a branch or a short SHA fails
#   2. a trailing comment exists and names a version, rather than restating the SHA
#   3. that version actually resolves to the pinned commit
#
# Step 3 is the half that is easy to skip and expensive to lose. Without it a pin can be
# made to *look* like v7.0.1 while pointing somewhere else entirely, and a SHA is not
# something a reviewer reads — the comment is. Verification fails CLOSED: if the API
# cannot be reached, the check fails rather than passing unverified.
#
# Runs in CI (.github/workflows/pin-check.yml) and locally:
#
#   ./.github/scripts/check-action-pins.sh              # full check
#   ./.github/scripts/check-action-pins.sh --no-api     # offline: skip step 3 only
#   ./.github/scripts/check-action-pins.sh --self-test  # prove the gate rejects bad pins
#
# Exit codes: 0 everything pinned and verified; 1 findings; 2 the check could not run.

set -euo pipefail

# Resolve the repo root from this script's own location, so it behaves the same whether
# CI runs it from the workspace root or a dev runs it from a subdirectory.
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

WORKFLOWS_DIR=".github/workflows"
ACTIONS_DIR=".github/actions"
FIXTURES_DIR=".github/scripts/fixtures/pin-check"

NO_API=0
SELF_TEST=0

# A full-length commit SHA. The `/subpath` group covers `owner/repo/path/to/action@sha`.
PINNED_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(/[^@]+)?@[0-9a-f]{40}$'

usage() {
  cat >&2 <<EOF
usage: $0 [--no-api] [--self-test]

  --no-api     Skip the GitHub API verification (step 3). Shape and comment presence
               are still enforced. For local runs without gh or without auth.
  --self-test  Run the script against ${FIXTURES_DIR}/ and assert it accepts what it
               should accept and rejects what it should reject.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-api) NO_API=1 ;;
    --self-test) SELF_TEST=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

# GitHub-Actions annotations when running in CI, plain text when running locally.
err() {
  local file="$1" line="$2" message="$3"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    if [[ -n "$line" ]]; then
      echo "::error file=${file},line=${line}::${message}"
    else
      echo "::error file=${file}::${message}"
    fi
  else
    echo "error: ${file}${line:+:${line}}: ${message}" >&2
  fi
}

if ! command -v yq >/dev/null 2>&1; then
  echo "error: yq is not installed. Install it with: brew install yq" >&2
  exit 2
fi

if [[ $NO_API -eq 0 ]] && ! command -v gh >/dev/null 2>&1; then
  echo "error: gh is not installed, so version comments cannot be verified." >&2
  echo "       Install it, or re-run with --no-api to check shape only." >&2
  exit 2
fi

# Cache of resolved `owner/repo@version` -> commit SHA. actions/checkout alone appears
# eight times at the same version; without this the gate would make eight identical API
# calls. A file rather than an associative array, because macOS still ships bash 3.2.
CACHE_FILE="$(mktemp)"

# One file's worth of extracted refs. It exists so that extract_refs is *not* consumed
# through a process substitution — see the note in check_file.
REFS_FILE="$(mktemp)"

trap 'rm -f "$CACHE_FILE" "$REFS_FILE"' EXIT

# Every `uses:` in a file, as `ref<TAB>trailing-comment`, one per line.
#
# Three shapes are covered: workflow steps, job-level reusable-workflow calls, and
# composite-action steps. All three are collected in one pass so no caller has to know
# which kind of file it is holding.
#
# Two details are load-bearing and were both learned the hard way:
#   - The `[ ... ] | .[]` wrapper and the per-item string concat are required. yq's `,`
#     binds looser than `|`, so `... | .uses, (.uses | line_comment)` emits every ref
#     first and then every comment, silently destroying the pairing.
#   - `select(has("uses"))` must be on every branch. Without it yq emits whole step
#     mappings and the caller then validates nonsense with complete confidence.
#
# Using yq rather than grep is what makes the prose in code-review.yml that contains the
# literal text `uses:` a non-event: it is a comment, so it is not a ref.
extract_refs() {
  yq -r '
    [ (.jobs[]?.steps[]? | select(has("uses"))),
      (.jobs[]?          | select(has("uses"))),
      (.runs.steps[]?    | select(has("uses"))) ]
    | .[] | .uses + "\t" + (.uses | line_comment)
  ' "$1"
}

# Read one key out of the cache. The match must be on the *whole* first field: a
# substring match (grep -F, even with the tab) also matches a key it is a suffix of, so
# a ref for an attacker-owned `xactions/checkout` cached earlier in the run would answer
# the lookup for `actions/checkout` — handing step 3 a SHA it never asked GitHub about,
# which is exactly the lying-comment case the gate exists to catch.
cache_lookup() {
  awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$CACHE_FILE" 2>/dev/null || true
}

# Resolve a version to the commit it points at. One call handles both lightweight and
# annotated tags, because the commits endpoint dereferences the tag object for us.
# (Do not reach for `git ls-remote` instead: it returns the tag *object* for an annotated
# tag — four of our pins use one — so a naive comparison red-fails a correct pin.)
#
# Echoes the SHA and returns 0 on success. Otherwise the caller needs to know *which*
# kind of failure it hit, because they mean opposite things:
#   2 — GitHub answered, and the answer is that this version does not exist. The pin or
#       its comment is wrong. Retrying cannot change that.
#   1 — we could not get an answer. Says nothing about the pin.
resolve_version() {
  local repo="$1" version="$2" key cached sha output status
  key="${repo}@${version}"

  cached="$(cache_lookup "$key")"
  if [[ -n "$cached" ]]; then
    printf '%s' "$cached"
    return 0
  fi

  local attempt
  for attempt in 1 2; do
    status=0
    output="$(gh api "repos/${repo}/commits/${version}" --jq '.sha' 2>&1)" || status=$?

    if [[ $status -eq 0 && -n "$output" ]]; then
      printf '%s\t%s\n' "$key" "$output" >>"$CACHE_FILE"
      printf '%s' "$output"
      return 0
    fi

    # A missing tag on an existing repo is 422; a missing repo is 404. Both are verdicts,
    # not outages — return immediately rather than sleeping and asking again.
    case "$output" in
      *'(HTTP 404)'* | *'(HTTP 422)'*) return 2 ;;
    esac

    [[ $attempt -eq 1 ]] && sleep 2
  done

  return 1
}

# Best-effort line number for the annotation. yq has a `line` operator, but it reports
# the wrong line for job-level `uses:` keys, so the ref string is looked up directly.
line_of() {
  grep -n -F -m1 "$1" "$2" 2>/dev/null | cut -d: -f1 || true
}

# Check one file. Sets FILE_FINDINGS; never exits, so callers can total up.
#
# The count comes back in a global rather than on stdout deliberately. In CI err() emits
# `::error` annotations on stdout, so capturing this function with $(...) would swallow
# every annotation into the count string instead of showing it to the reviewer.
FILE_FINDINGS=0
check_file() {
  local file="$1"
  local ref comment version lower_version repo sha actual line resolved
  FILE_FINDINGS=0

  # Extract into a file and check the status, rather than reading from `< <(extract_refs)`.
  # The shell never checks a process substitution's exit code and `set -e` does not reach
  # inside one, so a file yq cannot parse would simply yield zero lines: zero findings,
  # and a green run over a file whose refs were never looked at. That is the same
  # fail-open the API path already refuses — a gate that silently skips what it cannot
  # read is not a gate — and it is not theoretical: yq rejects a tab in indentation, and
  # a single stray tab was enough to walk an unpinned ref straight past the check.
  if ! extract_refs "$file" >"$REFS_FILE"; then
    err "$file" 1 "could not be parsed, so its action references were never checked. Fix the YAML (yq's error is above); the gate will not pass a file it cannot read."
    FILE_FINDINGS=1
    return 0
  fi

  while IFS=$'\t' read -r ref comment; do
    [[ -n "$ref" ]] || continue

    # Local `./` refs and docker:// images are not pinnable to a commit by definition.
    case "$ref" in
      ./* | docker://*) continue ;;
    esac

    line="$(line_of "$ref" "$file")"

    if ! [[ "$ref" =~ $PINNED_RE ]]; then
      err "$file" "$line" "'${ref}' is not pinned to a full-length commit SHA. Run 'pinact run' to pin it."
      FILE_FINDINGS=$((FILE_FINDINGS + 1))
      continue
    fi

    # A comment may carry more than the version ("# v7.0.1 (pinned by pinact)"), so the
    # first token is the version and the rest is prose.
    version="${comment%% *}"
    if [[ -z "$version" ]]; then
      err "$file" "$line" "'${ref}' has no trailing version comment, so nobody can review what it pins. Run 'pinact run'."
      FILE_FINDINGS=$((FILE_FINDINGS + 1))
      continue
    fi
    if ! [[ "$version" =~ ^v?[0-9] ]]; then
      err "$file" "$line" "'${ref}' has the trailing comment '${comment}', which does not name a version."
      FILE_FINDINGS=$((FILE_FINDINGS + 1))
      continue
    fi

    sha="${ref##*@}"

    # The commits endpoint takes a SHA as its ref and echoes it back, so a comment that
    # restates the pin verifies itself against any commit at all, tagged or not. `^v?[0-9]`
    # does not catch it: a SHA starting with a digit matches as readily as `7.0.1`.
    #
    # Hence any prefix rather than the whole SHA — the API resolves abbreviations from 5
    # characters — with the floor at git's minimum of 4 so the rule does not rest on where
    # GitHub draws that line today. The leading `v` goes because `# v3d3c42e` is the same
    # restatement, and having only the API reject it left it passing under --no-api.
    lower_version="$(printf '%s' "${version#v}" | tr '[:upper:]' '[:lower:]')"
    if [[ ${#lower_version} -ge 4 && "$sha" == "$lower_version"* ]]; then
      err "$file" "$line" "'${ref}' has the trailing comment '${comment}', which restates the pinned SHA instead of naming a version. Comparing a SHA to itself verifies nothing — name the tag the pin came from."
      FILE_FINDINGS=$((FILE_FINDINGS + 1))
      continue
    fi

    [[ $NO_API -eq 1 ]] && continue

    repo="$(printf '%s' "${ref%@*}" | cut -d/ -f1,2)"

    resolved=0
    actual="$(resolve_version "$repo" "$version")" || resolved=$?

    case $resolved in
      0)
        if [[ "$actual" != "$sha" ]]; then
          err "$file" "$line" "${repo} is pinned to ${sha} but its comment says ${version}, which is ${actual}. The comment is wrong, or the pin is."
          FILE_FINDINGS=$((FILE_FINDINGS + 1))
        fi
        ;;
      2)
        err "$file" "$line" "${repo} has no version ${version}, but that is what its comment claims. The comment is wrong."
        FILE_FINDINGS=$((FILE_FINDINGS + 1))
        ;;
      *)
        # Fail closed. A gate that goes green when its own verification broke is not a gate.
        err "$file" "$line" "could not reach the GitHub API to verify ${repo}@${version}. Refusing to pass it unverified."
        FILE_FINDINGS=$((FILE_FINDINGS + 1))
        ;;
    esac
  done <"$REFS_FILE"
}

# The files the gate is responsible for. Composite actions are found at any depth: a
# grouped layout like .github/actions/vercel/deploy/action.yml is just as real as the
# flat one, and a check that silently misses it is worse than no check.
scan_targets() {
  local f
  for f in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
    [[ -e "$f" ]] && printf '%s\n' "$f"
  done
  if [[ -d "$ACTIONS_DIR" ]]; then
    find "$ACTIONS_DIR" -type f \( -name 'action.yml' -o -name 'action.yaml' \) | sort
  fi
  return 0
}

# The cache is the one place where a lookup can answer step 3 without the API, so a
# wrong answer here is invisible: the run stays green and never makes the call it
# skipped. Exercised offline, so it guards the suffix-collision regression on every run.
self_test_cache_lookup() {
  local failures=0 got

  printf 'xactions/checkout@v7.0.1\tDECOYSHA\n' >"$CACHE_FILE"
  printf 'actions/setup-node@v4\tREALSHA\n' >>"$CACHE_FILE"

  got="$(cache_lookup 'actions/checkout@v7.0.1')"
  if [[ -n "$got" ]]; then
    echo "  FAIL cache lookup: 'actions/checkout@v7.0.1' matched an unrelated key (got '${got}')."
    failures=$((failures + 1))
  else
    echo "  PASS cache lookup rejects a suffix-colliding key"
  fi

  got="$(cache_lookup 'actions/setup-node@v4')"
  if [[ "$got" == "REALSHA" ]]; then
    echo "  PASS cache lookup returns an exact key"
  else
    echo "  FAIL cache lookup: exact key returned '${got}', expected 'REALSHA'."
    failures=$((failures + 1))
  fi

  : >"$CACHE_FILE"
  return $failures
}

run_self_test() {
  local file name expected actual failures=0 skipped=0

  if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo "error: ${FIXTURES_DIR}/ not found — the self-test has no inputs." >&2
    exit 2
  fi

  echo "Self-test: ${FIXTURES_DIR}/"

  for file in "$FIXTURES_DIR"/*.yml "$FIXTURES_DIR"/*.yaml; do
    [[ -e "$file" ]] || continue
    name="$(basename "$file")"

    # Only the cases about what a version *resolves to* need the network. Every other
    # case is decidable offline.
    if [[ "$name" == bad-lying-comment.yml || "$name" == bad-nonexistent-version.yml ]] && [[ $NO_API -eq 1 ]]; then
      echo "  SKIP ${name} (needs the API; running with --no-api)"
      skipped=$((skipped + 1))
      continue
    fi

    case "$name" in
      good-*) expected=0 ;;
      bad-*) expected=1 ;;
      *)
        echo "error: fixture '${name}' must be named good-* or bad-*." >&2
        exit 2
        ;;
    esac

    # Findings are expected here, so the annotations are noise — keep them off the log.
    check_file "$file" >/dev/null 2>&1
    actual="$FILE_FINDINGS"

    if [[ "$actual" == "$expected" ]]; then
      echo "  PASS ${name} (${actual} findings)"
    else
      echo "  FAIL ${name}: expected ${expected} findings, got ${actual}"
      failures=$((failures + 1))
    fi
  done

  local cache_failures=0
  self_test_cache_lookup || cache_failures=$?
  failures=$((failures + cache_failures))

  if [[ $failures -gt 0 ]]; then
    echo
    echo "${failures} self-test case(s) failed. The gate does not do what it claims." >&2
    exit 1
  fi

  if [[ $skipped -gt 0 ]]; then
    echo "Self-test passed (${skipped} skipped)."
  else
    echo "Self-test passed."
  fi
}

main() {
  if [[ $SELF_TEST -eq 1 ]]; then
    run_self_test
    exit 0
  fi

  local file total=0 checked=0

  while read -r file; do
    [[ -n "$file" ]] || continue
    checked=$((checked + 1))
    check_file "$file"
    total=$((total + FILE_FINDINGS))
  done < <(scan_targets)

  if [[ $checked -eq 0 ]]; then
    echo "error: no workflow or composite-action files found. Is the repo root right?" >&2
    exit 2
  fi

  if [[ $total -gt 0 ]]; then
    echo >&2
    echo "${total} unpinned or unverifiable action reference(s) across ${checked} file(s)." >&2
    echo "Fix them with 'pinact run', then commit the result." >&2
    echo "Background: docs/architecture.md -> \"Why are third-party actions pinned by SHA?\"" >&2
    exit 1
  fi

  if [[ $NO_API -eq 1 ]]; then
    echo "All third-party actions across ${checked} file(s) are SHA-pinned (comments not verified: --no-api)."
  else
    echo "All third-party actions across ${checked} file(s) are SHA-pinned and their version comments verified."
  fi
}

main
