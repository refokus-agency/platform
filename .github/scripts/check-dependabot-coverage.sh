#!/usr/bin/env bash
#
# Verifies that every composite action under .github/actions/ has its own entry in
# .github/dependabot.yml.
#
# Why this exists: Dependabot's `github-actions` ecosystem does NOT recurse into
# .github/actions/**. The `directory: "/"` entry covers .github/workflows/ and the
# root action.yml, and stops there. A composite action without its own entry keeps
# its SHA pins forever — they stay pinned, so `pinact --check` is happy, but they
# stop receiving security updates. The upstream request for recursion is closed as
# not planned (dependabot-core#7495), so nothing but this check will catch it.
#
# The failure mode without this script is silent by construction: the only signal is
# the *absence* of Dependabot PRs for that directory. That is why a red check exists.
#
# Runs in CI (.github/workflows/pin-check.yml) and locally:
#
#   ./.github/scripts/check-dependabot-coverage.sh
#
# Exit codes: 0 every composite action is covered; 1 one or more are not.

set -euo pipefail

# Resolve the repo root from this script's own location, so it behaves the same whether
# CI runs it from the workspace root or a dev runs it from a subdirectory.
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

CONFIG=".github/dependabot.yml"
ACTIONS_DIR=".github/actions"

# GitHub-Actions annotations when running in CI, plain text when running locally.
err() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error file=${CONFIG}::$1"
  else
    echo "error: $1" >&2
  fi
}

if ! command -v yq >/dev/null 2>&1; then
  err "yq is not installed. Install it with: brew install yq"
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  err "${CONFIG} not found. Every repo shipping composite actions needs one."
  exit 1
fi

# No composite actions at all is a valid state — nothing to cover.
if [[ ! -d "$ACTIONS_DIR" ]]; then
  echo "No ${ACTIONS_DIR}/ directory — nothing to check."
  exit 0
fi

# Directories Dependabot is told to watch, across both spellings of the option:
# `directory: "/x"` (string) and `directories: ["/x", "/y"]` (list).
declared="$(
  yq -r '
    [ .updates[]
      | select(."package-ecosystem" == "github-actions")
      | (.directory // "", (.directories // [])[])
    ] | .[] | select(. != "")
  ' "$CONFIG"
)"

# Normalize to a leading slash and no trailing slash, so "/x/" and "x" both match "/x".
normalize() { sed -E 's#/+$##; s#^/*#/#'; }
declared_normalized="$(printf '%s\n' "$declared" | normalize)"

# Found at any depth, not just .github/actions/<name>/. A grouped layout such as
# .github/actions/vercel/deploy/action.yml is just as real, and a one-level glob would
# report "all covered" while that action's pins froze forever — the exact silent
# failure this script exists to catch, one directory deeper than it looks.
missing=()
while IFS= read -r action_file; do
  [[ -n "$action_file" ]] || continue
  expected="/$(dirname "$action_file")"
  if ! printf '%s\n' "$declared_normalized" | grep -qxF "$expected"; then
    missing+=("$expected")
  fi
done < <(find "$ACTIONS_DIR" -type f \( -name 'action.yml' -o -name 'action.yaml' \) | sort)

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "All composite actions under ${ACTIONS_DIR}/ are covered by ${CONFIG}."
  exit 0
fi

for dir in "${missing[@]}"; do
  err "Composite action ${dir#/} has no Dependabot entry — its SHA pins will never be updated."
done

cat >&2 <<EOF

Add this to ${CONFIG} under 'updates:' — one block per directory listed above:
EOF

for dir in "${missing[@]}"; do
  cat >&2 <<EOF

  - package-ecosystem: "github-actions"
    directory: "${dir}"
    schedule:
      interval: "weekly"
    groups:
      actions:
        patterns: ["*"]
EOF
done

cat >&2 <<EOF

Background: docs/dependabot.md -> "Action pins in this repo"
EOF

exit 1
