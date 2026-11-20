#!/usr/bin/env bash
#
# Tests for code-review.yml's "Resolve actor" step: who may request a review by commenting the
# trigger phrase. The step's own `run:` is extracted with yq and run the way the runner does,
# against the stub `gh` in fixtures/resolve-actor/. Nothing here talks to the network.
#
# The write-access half must agree with claude-code-action's own check: the collaborator
# permission API, `admin` or `write` in the legacy `permission` field.
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
STUB_BIN="$ROOT/.github/scripts/fixtures/resolve-actor"
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
  # The association says nothing about permission level: every case must be decided by the
  # permission lookup alone, whatever this says.
  export AUTHOR_ASSOCIATION=COLLABORATOR
  fx user User
}
fx() { printf '%s' "$2" >"$STUB_DIR/$1.out"; }
fxrc() { printf '%s' "$2" >"$STUB_DIR/$1.rc"; }

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
  # `$?` is saved first: the command substitution in check's message would otherwise reset it.
  grep -qxF "api repos/acme/app/collaborators/${1}/permission --jq .permission" "$STUB_DIR/calls.log"
  local rc=$?
  check "looked up ${1}'s permission on acme/app (calls: $(tr '\n' ';' <"$STUB_DIR/calls.log"))" "$rc"
}
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
  fx permission read; run_step; expect_ok; expect_eligible false
  says "whose permission on this repository is read"; says "requires write access"
}
case_none() { fx permission none; run_step; expect_ok; expect_eligible false; says "is none"; }
case_empty() {
  fx permission ''; run_step; expect_ok; expect_eligible false
  says "could not look up alice's permission"; says "Retry the trigger phrase"
}
case_lookup_fails() {
  fxrc permission 1; run_step; expect_ok; expect_eligible false
  says "could not look up alice's permission"; says "Retry the trigger phrase"
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
case_unconfirmed_wildcard() {
  export ALLOWED_BOTS='*'
  fxrc user 1; run_step; expect_ok; expect_eligible false; never_asked_permission; says "unconfirmed"
}

# --- runner ----------------------------------------------------------------------------------

ALL=(admin write read none empty lookup_fails allowed_bot unlisted_bot self_trigger unconfirmed_wildcard)
[ $# -gt 0 ] && ALL=("$@")

failed=()
n=0
for c in "${ALL[@]}"; do
  n=$((n + 1))
  setup
  CASE_FAIL=0
  "case_$c"
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
