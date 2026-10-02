#!/usr/bin/env bash
#
# Decides which `version:` the setup composite hands to pnpm/action-setup.
#
# Why this exists: pnpm/action-setup compares an explicit `version:` against the
# caller's `package.json` `packageManager` with an EXACT string compare and throws
# "Multiple versions of pnpm specified" on any difference ('10' vs 'pnpm@10.12.1'
# included). A hard-coded default therefore breaks every caller that pins
# `packageManager`. So the default is resolved here instead:
#
#   1. an explicit `pnpm-version` input wins, passed through unchanged; this
#      script never overrides it. pnpm/action-setup checks it only against
#      `packageManager` (conflict error on mismatch); against a pnpm declared
#      only in `devEngines.packageManager`, the explicit input wins silently.
#   2. `package.json` declares pnpm (`devEngines.packageManager` object with
#      `name: pnpm` and a `version`, or `packageManager: pnpm@<version>`):
#      output '' so pnpm/action-setup reads the version itself.
#   3. otherwise (no `package.json`, no field, another package manager, invalid
#      JSON or not a JSON object): output the fallback DEFAULT_PNPM_VERSION.
#
# The rules mirror pnpm/action-setup's own lookup (src/install-pnpm/run.ts).
#
# Usage:
#
#   PNPM_VERSION_INPUT=<maybe-empty> resolve-pnpm-version.sh [path/to/package.json]
#   resolve-pnpm-version.sh --self-test
#
# The package.json path defaults to $GITHUB_WORKSPACE/package.json, the same file
# pnpm/action-setup reads. Writes `version=<value>` to $GITHUB_OUTPUT and logs the
# source that decided it: input | devEngines | packageManager | fallback.

set -euo pipefail

DEFAULT_PNPM_VERSION=10

# GitHub-Actions annotations when running in CI, plain text when running locally.
warn() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning::$1" >&2
  else
    echo "warning: $1" >&2
  fi
}

die() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error::$1" >&2
  else
    echo "error: $1" >&2
  fi
  exit 1
}

require_jq() {
  command -v jq > /dev/null 2>&1 \
    || die "jq is required to resolve the pnpm version from package.json but is not installed on this runner. Install jq, or pass pnpm-version explicitly."
}

# A line break in the input would inject extra `key=value` lines into $GITHUB_OUTPUT.
validate_input() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

# Pure decision: prints "<value> <source>". <value> may be empty.
resolve_version() {
  local input="$1" pkg_json="$2"

  if [[ -n "$input" ]]; then
    echo "$input input"
    return
  fi

  if [[ ! -f "$pkg_json" ]]; then
    echo "$DEFAULT_PNPM_VERSION fallback"
    return
  fi

  # A top-level array, string or number is valid JSON but has no fields to read.
  if ! jq -e 'type == "object"' "$pkg_json" > /dev/null 2>&1; then
    warn "${pkg_json} is not a valid JSON object; using pnpm ${DEFAULT_PNPM_VERSION}. pnpm/action-setup will likely fail parsing it too."
    echo "$DEFAULT_PNPM_VERSION fallback"
    return
  fi

  # Same precedence as pnpm/action-setup: devEngines (object only, non-empty
  # version) first, then `packageManager: pnpm@<version>[+<integrity>]`.
  # Stricter than upstream on purpose: upstream accepts any truthy devEngines
  # version, but a non-string one is malformed per spec, so it falls through.
  local source
  source="$(jq -r '
    if (.devEngines | type) == "object"
       and (.devEngines.packageManager | type) == "object"
       and .devEngines.packageManager.name == "pnpm"
       and ((.devEngines.packageManager.version // "") | type) == "string"
       and (.devEngines.packageManager.version // "") != ""
    then "devEngines"
    elif (.packageManager | type) == "string"
       and (.packageManager | test("^pnpm@[^+]"))
    then "packageManager"
    else "fallback"
    end
  ' "$pkg_json")"

  if [[ "$source" == "fallback" ]]; then
    echo "$DEFAULT_PNPM_VERSION fallback"
  else
    echo " $source"
  fi
}

main() {
  require_jq

  local pkg_json="${1:-${GITHUB_WORKSPACE:-.}/package.json}"
  local out value source
  validate_input "${PNPM_VERSION_INPUT:-}" \
    || die "pnpm-version must be a single line; got a value containing a line break."
  out="$(resolve_version "${PNPM_VERSION_INPUT:-}" "$pkg_json")"
  value="${out% *}"
  source="${out##* }"

  case "$source" in
    input) echo "pnpm version: '${value}' (source: input)" ;;
    fallback) echo "pnpm version: '${value}' (source: fallback, no pnpm declared in ${pkg_json})" ;;
    *) echo "pnpm version: read by pnpm/action-setup (source: ${source} in ${pkg_json})" ;;
  esac

  echo "version=${value}" >> "${GITHUB_OUTPUT:-/dev/stdout}"
}

self_test() {
  require_jq

  # Global, not local: the EXIT trap runs after this function has returned.
  SELF_TEST_TMP="$(mktemp -d)"
  trap 'rm -rf "$SELF_TEST_TMP"' EXIT
  local tmp="$SELF_TEST_TMP" failures=0

  # name | input | package.json content (MISSING = no file) | expected value | expected source
  local cases=(
    "explicit input wins|9.15.0|MISSING|9.15.0|input"
    "explicit input is not overridden by package.json|11|{\"packageManager\":\"pnpm@11.17.0\"}|11|input"
    "packageManager exact version||{\"packageManager\":\"pnpm@10.12.1\"}||packageManager"
    "packageManager with integrity hash||{\"packageManager\":\"pnpm@11.17.0+sha512.abc\"}||packageManager"
    "devEngines object with pnpm and version||{\"devEngines\":{\"packageManager\":{\"name\":\"pnpm\",\"version\":\"^11.0.0\"}}}||devEngines"
    "devEngines wins over packageManager||{\"devEngines\":{\"packageManager\":{\"name\":\"pnpm\",\"version\":\"11.1.0\"}},\"packageManager\":\"pnpm@11.1.0\"}||devEngines"
    "devEngines array falls through to packageManager||{\"devEngines\":{\"packageManager\":[{\"name\":\"pnpm\",\"version\":\"11.1.0\"}]},\"packageManager\":\"pnpm@11.1.0\"}||packageManager"
    "devEngines pnpm without version falls back||{\"devEngines\":{\"packageManager\":{\"name\":\"pnpm\"}}}|${DEFAULT_PNPM_VERSION}|fallback"
    "devEngines for another manager falls back||{\"devEngines\":{\"packageManager\":{\"name\":\"yarn\",\"version\":\"4.0.0\"}}}|${DEFAULT_PNPM_VERSION}|fallback"
    "packageManager for another manager falls back||{\"packageManager\":\"yarn@4.1.0\"}|${DEFAULT_PNPM_VERSION}|fallback"
    "packageManager pnpm without version falls back||{\"packageManager\":\"pnpm@\"}|${DEFAULT_PNPM_VERSION}|fallback"
    "no field falls back||{\"name\":\"x\"}|${DEFAULT_PNPM_VERSION}|fallback"
    "missing package.json falls back||MISSING|${DEFAULT_PNPM_VERSION}|fallback"
    "invalid JSON falls back||{not json|${DEFAULT_PNPM_VERSION}|fallback"
    "top-level array falls back||[]|${DEFAULT_PNPM_VERSION}|fallback"
    "top-level number falls back||42|${DEFAULT_PNPM_VERSION}|fallback"
    "non-object devEngines falls through to packageManager||{\"devEngines\":[],\"packageManager\":\"pnpm@11.1.0\"}||packageManager"
  )

  local entry name input content want_value want_source pkg out got_value got_source i=0
  for entry in "${cases[@]}"; do
    IFS='|' read -r name input content want_value want_source <<< "$entry"
    i=$((i + 1))
    pkg="$tmp/$i/package.json"
    mkdir -p "$tmp/$i"
    [[ "$content" != "MISSING" ]] && printf '%s' "$content" > "$pkg"

    out="$(resolve_version "$input" "$pkg" 2> /dev/null)"
    got_value="${out% *}"
    got_source="${out##* }"

    if [[ "$got_value" == "$want_value" && "$got_source" == "$want_source" ]]; then
      echo "ok   - $name"
    else
      echo "FAIL - $name: want '${want_value}' (${want_source}), got '${got_value}' (${got_source})"
      failures=$((failures + 1))
    fi
  done

  # Inputs main() must reject before writing $GITHUB_OUTPUT. Kept out of the table
  # above because its `|`/newline-delimited format cannot carry a newline.
  local rejects=($'10\nextra=1' $'10\r') bad
  for bad in "${rejects[@]}"; do
    if validate_input "$bad" 2> /dev/null; then
      echo "FAIL - input with a line break is rejected: accepted $(printf '%q' "$bad")"
      failures=$((failures + 1))
    else
      echo "ok   - input with a line break is rejected: $(printf '%q' "$bad")"
    fi
  done
  if validate_input "11.17.0" 2> /dev/null; then
    echo "ok   - input without a line break is accepted"
  else
    echo "FAIL - input without a line break is accepted: rejected '11.17.0'"
    failures=$((failures + 1))
  fi
  local total=$((${#cases[@]} + ${#rejects[@]} + 1))

  if ((failures > 0)); then
    echo "self-test: ${failures} of ${total} cases failed" >&2
    exit 1
  fi
  echo "self-test: all ${total} cases passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
else
  main "$@"
fi
