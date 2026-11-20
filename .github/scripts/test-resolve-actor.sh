#!/usr/bin/env bash
#
# Tests for code-review.yml's "Resolve actor" step: who may request a review by commenting the
# trigger phrase. The step's own `run:` is extracted with yq and run the way the runner does,
# against the stub `gh` in fixtures/review-context/. Nothing here talks to the network.
#
# The write-access half must agree with claude-code-action's own check: the collaborator
# permission API, `admin` or `write` in the legacy `permission` field. Both lookups (account type
# and permission) share one helper: a 5xx or 429 is retried (3 attempts, LOOKUP_RETRY_SECONDS
# apart, 0 here); any other 4xx and either rate limit, primary or secondary, stop at once.
#
# Usage:
#   ./.github/scripts/test-resolve-actor.sh                 # every case
#   ./.github/scripts/test-resolve-actor.sh admin read      # just these
#
# Needs bash and yq (preinstalled on ubuntu-latest). Exit 0 all passed, 1 otherwise.

# The case_* functions are called by name from the runner at the bottom.
# shellcheck disable=SC2329

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2
ROOT=$(pwd)
STUB_BIN="$ROOT/.github/scripts/fixtures/review-context"
WF="$ROOT/.github/workflows/code-review.yml"

command -v yq >/dev/null 2>&1 || { echo "error: yq is not installed." >&2; exit 2; }

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- harness ---------------------------------------------------------------------------------

setup() {
  T=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  export STUB_DIR="$T/fx"
  mkdir -p "$STUB_DIR"
  : >"$STUB_DIR/calls.log"
  export GITHUB_REPOSITORY=acme/app GH_TOKEN=x GITHUB_ACTOR=alice ALLOWED_BOTS=''
  # The step retries a failed lookup; no case should wait for it.
  export LOOKUP_RETRY_SECONDS=0
  fx user User
}
fx() { printf '%s' "$2" >"$STUB_DIR/$1.out"; }
fxrc() { printf '%s' "$2" >"$STUB_DIR/$1.rc"; }
fxerr() { printf '%s\n' "$2" >"$STUB_DIR/$1.err"; }

# Runs the step's `run:`. ELIGIBLE: the `eligible` output it wrote, ERR: its stdout and stderr,
# RC: exit code.
run_step() {
  yq '.jobs[].steps[] | select(.name == "Resolve actor") | .run' "$WF" >"$T/step.sh"
  export GITHUB_OUTPUT="$T/out"
  : >"$GITHUB_OUTPUT"
  (cd "$T" && PATH="$STUB_BIN:$PATH" bash --noprofile --norc -eo pipefail "$T/step.sh") >"$T/err" 2>&1
  RC=$?
  ERR=$(cat "$T/err")
  ELIGIBLE=$(sed -n 's/^eligible=//p' "$GITHUB_OUTPUT")
}

check() { # description, status (0 = pass)
  if [ "$2" -ne 0 ]; then
    echo "    FAIL: $1"
    CASE_FAIL=1
  fi
}
expect_ok() { [ "$RC" -eq 0 ]; check "exit 0 (rc=$RC, output: $ERR)" $?; }
expect_eligible() {
  [ "$ELIGIBLE" = "$1" ]
  check "eligible=$1 (got '${ELIGIBLE}', output: $ERR)" $?
}
says() { printf '%s' "$ERR" | grep -qF -- "$1"; check "output contains: $1 (got: $ERR)" $?; }
asked_permission() {
  grep -qxF "api repos/acme/app/collaborators/${1}/permission --jq .permission" "$STUB_DIR/calls.log"
  # Saved first: the command substitution in check's message would reset $? before it is read.
  local rc=$?
  check "looked up ${1}'s permission on acme/app (calls: $(tr '\n' ';' <"$STUB_DIR/calls.log"))" "$rc"
}
permission_calls() { # expected number of permission lookups
  local got
  got=$(grep -c '/permission' "$STUB_DIR/calls.log")
  [ "$got" -eq "$1" ]
  check "looked up the permission $1 time(s) (got $got)" $?
}
user_calls() { # expected number of account-type lookups
  local got
  got=$(grep -c '^api users/' "$STUB_DIR/calls.log")
  [ "$got" -eq "$1" ]
  check "looked up the account type $1 time(s) (got $got)" $?
}
never_says() { ! printf '%s' "$ERR" | grep -qF -- "$1"; check "output does not contain: $1 (got: $ERR)" $?; }
never_asked_permission() {
  ! grep -q '/permission' "$STUB_DIR/calls.log"
  local rc=$?
  check "never looked up a permission (calls: $(tr '\n' ';' <"$STUB_DIR/calls.log"))" "$rc"
}

# --- cases -----------------------------------------------------------------------------------

case_admin() { fx permission admin; run_step; expect_ok; expect_eligible true; asked_permission alice; }
# maintain arrives as `write` in the legacy field, so this case covers it too.
case_write() { fx permission write; run_step; expect_ok; expect_eligible true; asked_permission alice; }
case_read() {
  fx permission read; run_step; expect_ok; expect_eligible false; asked_permission alice
  says "whose permission on this repository is read"; says "requires write access"
}
case_none() { fx permission none; run_step; expect_ok; expect_eligible false; asked_permission alice; says "is none"; }
# Exit 0 with nothing printed: retried, and the log says what gh returned instead of pointing at
# an error that is not there.
case_empty() {
  fx permission ''; run_step; expect_ok; expect_eligible false; asked_permission alice
  permission_calls 3; says "[code-review] gh returned an empty or null permission on this repository for alice."
  says "could not look up alice's permission"; says "Retry the trigger phrase"
}
# A 200 without the field: --jq prints `null`, which must not pass as a permission named "null".
case_null() {
  fx permission null; run_step; expect_ok; expect_eligible false; asked_permission alice
  permission_calls 3; says "gh returned an empty or null permission on this repository for alice."
  never_says "is null"; says "could not look up alice's permission"
}
# A transient failure gets 3 attempts in all, and gh's error reaches the log under one prefix.
case_lookup_fails() {
  fxrc permission 1; fxerr permission 'gh: Bad Gateway (HTTP 502)'
  run_step; expect_ok; expect_eligible false; asked_permission alice; permission_calls 3
  says "retry 1/2"; says "retry 2/2"; says "[code-review] gh: Bad Gateway (HTTP 502)"; never_says "gh: gh:"
  says "could not look up alice's permission"; says "Retry the trigger phrase"
}
# Two 502s, then an exit 0 with nothing printed: the 502 is what the log shows, not lost to the
# last try's empty stderr, and the log also says the last try came back empty.
case_error_then_empty() {
  fxrc permission.1 1; fxerr permission.1 'gh: Bad Gateway (HTTP 502)'
  fxrc permission.2 1; fxerr permission.2 'gh: Bad Gateway (HTTP 502)'
  fx permission.3 ''
  run_step; expect_ok; expect_eligible false; permission_calls 3
  says "[code-review] gh: Bad Gateway (HTTP 502)"
  says "gh returned an empty or null permission on this repository for alice."
  says "could not look up alice's permission"
}
# An error the account-type lookup recovered from is not shown for the permission lookup after it.
case_error_not_carried_over() {
  fxrc user.1 1; fxerr user.1 'gh: Bad Gateway (HTTP 502)'
  fx permission ''
  run_step; expect_ok; expect_eligible false; user_calls 2; permission_calls 3
  never_says "Bad Gateway"; says "gh returned an empty or null permission on this repository for alice."
}
# A non-numeric delay must not reach `sleep` and fail the step red: it falls back to 5 s. Also
# checks the EXIT trap removes the step's scratch files.
case_bad_retry_seconds() {
  export LOOKUP_RETRY_SECONDS=x TMPDIR="$T/tmp"
  mkdir -p "$TMPDIR"
  fxrc permission.1 1; fxerr permission.1 'gh: Bad Gateway (HTTP 502)'; fx permission write
  run_step; expect_ok; expect_eligible true; permission_calls 2; says "retry 1/2 in 5 s"
  local left
  left=$(find "$TMPDIR" -mindepth 1 | tr '\n' ' ')
  [ -z "$left" ]; check "scratch files removed (left: $left)" $?
}
# One blip, then an answer: the review runs.
case_lookup_recovers() {
  fxrc permission.1 1; fx permission write
  run_step; expect_ok; expect_eligible true; asked_permission alice; permission_calls 2; says "retry 1/2"
}
# The primary quota only clears at its hourly reset: no retry, and no advice to retry now.
case_rate_limited() {
  fxrc permission 1; fxerr permission 'gh: API rate limit exceeded for installation ID 1. (HTTP 403)'
  run_step; expect_ok; expect_eligible false; permission_calls 1; never_says "retry 1/2"
  says "rate limit of this repository's token is exhausted"; says "resets within the hour"
  never_says "Retry the trigger phrase"
}
# When /rate_limit answers with a reset time ahead, the notice gives it.
case_rate_limited_reset() {
  fxrc permission 1; fxerr permission 'gh: API rate limit exceeded for installation ID 1. (HTTP 403)'
  fx rate_limit "$(( $(date +%s) + 600 ))"
  run_step; expect_ok; expect_eligible false; permission_calls 1; says "resets in about 10 min"
}
# GitHub asks a client hitting a secondary rate limit to wait at least a minute, longer than the
# retries would: no retry, and advice to try again in a few minutes. A later call would pass, so
# this also proves the step did not make one.
case_secondary_rate_limited() {
  fxrc permission.1 1; fxerr permission.1 'gh: You have exceeded a secondary rate limit. (HTTP 403)'
  fx permission write
  run_step; expect_ok; expect_eligible false; permission_calls 1; never_says "retry 1/2"
  says "[code-review] gh: You have exceeded a secondary rate limit. (HTTP 403)"
  says "secondary rate limit refused to look up alice's permission"; says "in a few minutes"
  never_says "will not change that"
}
# The account-type lookup stops on it the same way.
case_user_secondary_rate_limited() {
  fxrc user 1; fxerr user 'gh: You have exceeded a secondary rate limit. (HTTP 429)'
  run_step; expect_ok; expect_eligible false; user_calls 1; never_asked_permission
  says "secondary rate limit refused to look up alice's account type"; says "in a few minutes"
}
case_too_many_requests() {
  fxrc permission 1; fxerr permission 'gh: Too Many Requests (HTTP 429)'
  run_step; expect_ok; expect_eligible false; permission_calls 3; says "retry 2/2"
  says "Retry the trigger phrase"
}
# A refusal will not change on retry: one call, the error, and no advice to retry.
case_lookup_refused() {
  fxrc permission 1; fxerr permission 'gh: Not Found (HTTP 404)'
  run_step; expect_ok; expect_eligible false; asked_permission alice; permission_calls 1
  says "[code-review] gh: Not Found (HTTP 404)"; never_says "gh: gh:"; says "will not change that"
  never_says "Retry the trigger phrase"
}
# Every 4xx but 429 is final, not just 403 and 404.
case_unauthorized() {
  fxrc permission 1; fxerr permission 'gh: Bad credentials (HTTP 401)'
  run_step; expect_ok; expect_eligible false; permission_calls 1; never_says "retry 1/2"
  says "[code-review] gh: Bad credentials (HTTP 401)"; says "will not change that"
  never_says "Retry the trigger phrase"
}

# The account-type lookup goes through the same helper.
case_user_lookup_recovers() {
  fxrc user.1 1; fxerr user.1 'gh: Bad Gateway (HTTP 502)'; fx permission write
  run_step; expect_ok; expect_eligible true; user_calls 2; says "looking up alice's account type failed; retry 1/2"
  asked_permission alice
}
# A human is never classified a bot because the lookup failed: the run skips with the reason.
case_user_lookup_fails() {
  fxrc user 1; fxerr user 'gh: Bad Gateway (HTTP 502)'
  run_step; expect_ok; expect_eligible false; user_calls 3; never_asked_permission
  says "[code-review] gh: Bad Gateway (HTTP 502)"; says "could not look up alice's account type after 3 tries"
  says "Retry the trigger phrase"; never_says "not a human"
}
case_user_lookup_refused() {
  fxrc user 1; fxerr user 'gh: Bad credentials (HTTP 401)'
  run_step; expect_ok; expect_eligible false; user_calls 1; never_asked_permission
  says "refused to look up alice's account type"; never_says "not a human"
}

# The bot branch is unchanged by the permission lookup: an allowed bot is exempt, like in the
# action, and every other non-human is skipped before any permission is asked for.
case_allowed_bot() {
  export GITHUB_ACTOR='renovate[bot]' ALLOWED_BOTS='dependabot, renovate'
  fx user Bot; run_step; expect_ok; expect_eligible true; never_asked_permission
}
case_unlisted_bot() {
  export GITHUB_ACTOR='renovate[bot]' ALLOWED_BOTS='dependabot'
  fx user Bot; run_step; expect_ok; expect_eligible false; never_asked_permission; says "not a human"
}
case_self_trigger() {
  export GITHUB_ACTOR='claude[bot]' ALLOWED_BOTS='*'
  fx user Bot; run_step; expect_ok; expect_eligible false; never_asked_permission; says "its own review"
}
# A 404 is a GitHub App with no user account: a bot, but unconfirmed, so '*' does not cover it
# while a list naming it does.
case_unconfirmed_wildcard() {
  export GITHUB_ACTOR='some-app[bot]' ALLOWED_BOTS='*'
  fxrc user 1; fxerr user 'gh: Not Found (HTTP 404)'
  run_step; expect_ok; expect_eligible false; user_calls 1; never_asked_permission; says "unconfirmed"
  says "not a human"
}
case_unconfirmed_listed() {
  export GITHUB_ACTOR='some-app[bot]' ALLOWED_BOTS='some-app'
  fxrc user 1; fxerr user 'gh: Not Found (HTTP 404)'
  run_step; expect_ok; expect_eligible true; never_asked_permission
}
# A 404 for a login without `[bot]` is a deleted or renamed account, not an app: it skips with
# gh's error, and the notice neither calls it a bot nor points at allowed-bots. Even a list that
# names the login does not admit it.
case_user_not_found() {
  export ALLOWED_BOTS='alice'
  fxrc user 1; fxerr user 'gh: Not Found (HTTP 404)'
  run_step; expect_ok; expect_eligible false; user_calls 1; never_asked_permission
  says "[code-review] gh: Not Found (HTTP 404)"; says "GitHub has no account named alice"
  says "deleted or renamed"; never_says "refused to look up"; never_says "not a human"; never_says "unconfirmed"; never_says "GitHub App"; never_says "allowed-bots"
}

# --- runner ----------------------------------------------------------------------------------

ALL=(admin write read none empty null lookup_fails error_then_empty error_not_carried_over
  bad_retry_seconds lookup_recovers rate_limited rate_limited_reset
  secondary_rate_limited user_secondary_rate_limited too_many_requests lookup_refused unauthorized
  user_lookup_recovers user_lookup_fails user_lookup_refused allowed_bot unlisted_bot self_trigger
  unconfirmed_wildcard unconfirmed_listed user_not_found)
[ $# -gt 0 ] && ALL=("$@")

failed=()
n=0
for c in "${ALL[@]}"; do
  n=$((n + 1))
  setup
  CASE_FAIL=0
  # A mistyped name must fail, not pass by running nothing.
  if declare -F "case_$c" >/dev/null; then
    "case_$c"
  else
    echo "    FAIL: no such case: $c"
    CASE_FAIL=1
  fi
  if [ "$CASE_FAIL" -eq 0 ]; then
    echo "PASS ${n}/${#ALL[@]} $c"
  else
    echo "FAIL ${n}/${#ALL[@]} $c"
    failed+=("$c")
  fi
done

if [ "${#failed[@]}" -eq 0 ]; then
  echo "All ${#ALL[@]} cases passed."
  exit 0
fi
echo "Failed: ${failed[*]}"
exit 1
