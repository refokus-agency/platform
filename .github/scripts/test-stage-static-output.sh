#!/usr/bin/env bash
#
# Tests for deploy-static.yml: stage-static-output.sh, which decides what gets published, and the
# workflow steps that run around it. Steps are extracted with yq and run the way the runner does,
# with a stub `npx` standing in for the Vercel CLI. Nothing here talks to the network.
#
# Usage:
#   ./.github/scripts/test-stage-static-output.sh                    # every case
#   ./.github/scripts/test-stage-static-output.sh symlinks dotfiles  # just these
#
# Needs bash and yq (preinstalled on ubuntu-latest). Exit 0 all passed, 1 otherwise.

# The case_* functions are called by name from the runner at the bottom.
# shellcheck disable=SC2329
# Literal ${{ }} and $(...) in single quotes are what these cases look for, not shell to expand.
# shellcheck disable=SC2016

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2
ROOT=$(pwd)
SCRIPT="$ROOT/.github/scripts/stage-static-output.sh"
WF="$ROOT/.github/workflows/deploy-static.yml"

command -v yq >/dev/null 2>&1 || { echo "error: yq is not installed." >&2; exit 2; }

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- harness ---------------------------------------------------------------------------------

setup() {
  T=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  REPO="$T/repo"
  OUT="$REPO/.vercel/output"
  mkdir -p "$REPO"
  # Confidential content every case starts with: none of it may ever be staged.
  put "docs/adr/0001-use-webflow-cms.md" decision
  put "brand-strategy/positioning.md" strategy
  put "call-summaries/kickoff.md" call
  put "README.md" readme
  put "DESIGN.md" design
}
put() { mkdir -p "$(dirname "$REPO/$1")"; printf '%s' "$2" >"$REPO/$1"; }

# Runs the staging script. RC: exit code, ERR: stdout and stderr together.
stage() {
  (cd "$REPO" && bash "$SCRIPT" "$@") >"$T/err" 2>&1
  RC=$?
  ERR=$(cat "$T/err")
}

# Every file under $OUT/static, as sorted relative paths, one per line.
staged() { (cd "$OUT/static" 2>/dev/null && find . -type f -o -type l | sed 's|^\./||' | LC_ALL=C sort); }

check() { # description, status (0 = pass)
  if [ "$2" -ne 0 ]; then
    echo "    FAIL: $1"
    CASE_FAIL=1
  fi
}
expect_rc() { [ "$RC" -eq "$1" ]; check "exit $1 (rc=$RC, output: $ERR)" $?; }
says() { printf '%s' "$ERR" | grep -qF -- "$1"; check "output contains: $1 (got: $ERR)" $?; }
never_says() { ! printf '%s' "$ERR" | grep -qF -- "$1"; check "output does not contain: $1 (got: $ERR)" $?; }
expect_staged() { # expected files, one per argument
  local want got rc
  want=$(printf '%s\n' "$@" | sed '/^$/d' | LC_ALL=C sort)
  got=$(staged)
  [ "$want" = "$got" ]
  # Saved first: the command substitutions in check's message would reset $? before it is read.
  rc=$?
  check "staged exactly [$(echo "$want" | tr '\n' ' ')] (got: [$(echo "$got" | tr '\n' ' ')])" "$rc"
}
expect_valid_output() {
  [ "$(cat "$OUT/config.json" 2>/dev/null)" = '{"version":3}' ]
  check "config.json is {\"version\":3}" $?
  [ -d "$OUT/static" ]; check "static/ exists" $?
}
expect_untouched_output() { # a usage error must not wipe or write anything
  [ "$(cat "$OUT/sentinel" 2>/dev/null)" = keep ]; check "out dir left untouched" $?
}

# Extracts a step's `run:` from the workflow into $T/step.sh.
step_script() {
  yq ".jobs.deploy.steps[] | select(.name == \"$1\") | .run" "$WF" >"$T/step.sh"
  [ -s "$T/step.sh" ]; check "step '$1' has a run script" $?
}
# Runs $T/step.sh in $REPO the way the runner does. RC, ERR as above; OUTPUTS: $GITHUB_OUTPUT.
run_step() {
  export GITHUB_OUTPUT="$T/gh_out" GITHUB_STEP_SUMMARY="$T/summary"
  : >"$GITHUB_OUTPUT"
  (cd "$REPO" && PATH="$T/bin:$PATH" bash --noprofile --norc -eo pipefail "$T/step.sh") >"$T/err" 2>&1
  RC=$?
  ERR=$(cat "$T/err")
  OUTPUTS=$(cat "$GITHUB_OUTPUT")
}
# A stub `npx` that logs its arguments and prints $NPX_STDOUT, as `vercel deploy` prints the URL.
stub_npx() {
  mkdir -p "$T/bin"
  cat >"$T/bin/npx" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NPX_LOG"
echo "Vercel CLI progress goes to stderr" >&2
printf '%s\n' "$NPX_STDOUT"
EOF
  chmod +x "$T/bin/npx"
  export NPX_LOG="$T/npx.log" NPX_STDOUT="$1"
  : >"$NPX_LOG"
}

# --- staging rules ---------------------------------------------------------------------------

# Rule 2: only the listed folders, at the same relative paths, byte for byte.
case_allowlist() {
  put "wireframes/home.html" '<img src="assets/hero.png">'
  put "artifacts/forms/tech-call.html" "<form></form>"
  printf '\x89PNG\x00\xff' >"$T/hero.png"
  mkdir -p "$REPO/wireframes/assets"
  cp "$T/hero.png" "$REPO/wireframes/assets/hero.png"
  stage . .vercel/output wireframes artifacts
  expect_rc 0
  expect_valid_output
  expect_staged artifacts/forms/tech-call.html wireframes/assets/hero.png wireframes/home.html
  cmp -s "$T/hero.png" "$OUT/static/wireframes/assets/hero.png"; check "binary copied byte for byte" $?
  says "published: wireframes/home.html"
  says "Staged 3 file(s) from: wireframes artifacts."
}

# The folder list is an argument, not a hardcoded pair.
case_any_folders() {
  put "wireframes/home.html" home
  put "site/index.html" index
  put "site/deep/nested/dir/page.html" page
  stage . .vercel/output site
  expect_rc 0
  expect_staged site/deep/nested/dir/page.html site/index.html
}

# Rule 3: dotfiles and dot-folders at any depth; a dot-folder is not descended into.
case_dotfiles() {
  put "wireframes/home.html" home
  put "wireframes/.DS_Store" junk
  put "wireframes/.gitkeep" ""
  put "wireframes/.drafts/old.html" draft
  put "wireframes/a/b/.env" secret
  put "wireframes/a/b/page.html" page
  stage . .vercel/output wireframes
  expect_rc 0
  expect_staged wireframes/a/b/page.html wireframes/home.html
  says "excluded (dotfile): wireframes/.drafts"
  says "excluded (dotfile): wireframes/a/b/.env"
  never_says "wireframes/.drafts/old.html"
  says "4 dotfile(s)"  # .DS_Store, .gitkeep, .drafts, a/b/.env
}

# Rule 4: symlinks to files and folders, inside or outside the repo, are never followed.
case_symlinks() {
  put "wireframes/home.html" home
  put "artifacts/tool/index.html" tool
  printf 'outside' >"$T/outside.txt"
  ln -s "$REPO/brand-strategy/positioning.md" "$REPO/wireframes/strategy.md"
  ln -s "$REPO/docs/adr" "$REPO/artifacts/adr"
  ln -s "$T/outside.txt" "$REPO/artifacts/tool/outside.txt"
  ln -s ../../brand-strategy "$REPO/artifacts/tool/rel"
  stage . .vercel/output wireframes artifacts
  expect_rc 0
  expect_staged artifacts/tool/index.html wireframes/home.html
  says "excluded (symlink): wireframes/strategy.md"
  says "excluded (symlink): artifacts/adr"
  says "4 symlink(s)"
}

# Rule 4 for the listed folder itself: a symlinked folder publishes nothing.
case_symlinked_folder() {
  ln -s "$REPO/brand-strategy" "$REPO/wireframes"
  stage . .vercel/output wireframes
  expect_rc 0
  expect_valid_output
  expect_staged
  says "'wireframes' is a symlink"
}

# Rule 5: each folder's own README, whatever its case; a deeper README is content.
case_readmes() {
  put "wireframes/README.md" doc
  put "artifacts/Readme.MD" doc
  put "site/readme.md" doc
  put "artifacts/tool/README.md" "a tool's own readme"
  put "wireframes/home.html" home
  stage . .vercel/output wireframes artifacts site
  expect_rc 0
  expect_staged artifacts/tool/README.md wireframes/home.html
  says "3 folder README(s)"
}

case_keep_readmes() {
  put "wireframes/README.md" doc
  put "wireframes/home.html" home
  stage --keep-readmes . .vercel/output wireframes
  expect_rc 0
  expect_staged wireframes/README.md wireframes/home.html
}

# Names with spaces and other shell-hostile characters survive intact.
case_spaces() {
  put "wireframes/my page.html" spaced
  put "wireframes/sub dir/it's \$here & *.html" odd
  put "wireframes/sub dir/.hidden file" hidden
  stage . .vercel/output wireframes
  expect_rc 0
  expect_staged "wireframes/my page.html" "wireframes/sub dir/it's \$here & *.html"
  [ "$(cat "$OUT/static/wireframes/sub dir/it's \$here & *.html")" = odd ]; check "odd name copied" $?
}

# Rule 1: anything but a plain top-level name is refused before anything is wiped.
case_invalid_folders() {
  local bad
  for bad in .. ../x /etc . .git a/b wire/../docs -rf "" "two words" '*'; do
    put ".vercel/output/sentinel" keep
    stage . .vercel/output wireframes "$bad"
    expect_rc 2
    says "is not a plain top-level folder name"
    expect_untouched_output
  done
}

case_no_folders() {
  put ".vercel/output/sentinel" keep
  stage . .vercel/output
  expect_rc 2
  says "no folders to publish"
  expect_untouched_output
}

# A missing folder (or a file with that name) publishes nothing, with a warning, not an error.
case_missing_folder() {
  put "wireframes/home.html" home
  put "artifacts" "a file, not a folder"
  stage . .vercel/output wireframes artifacts typo
  expect_rc 0
  expect_staged wireframes/home.html
  says "::warning::'typo' is not a folder"
  says "::warning::'artifacts' is not a folder"
}

# Folders with only a README and a .gitkeep stage a valid, empty output (a fresh template).
case_empty_output() {
  put "wireframes/README.md" doc
  put "artifacts/.gitkeep" ""
  mkdir -p "$REPO/wireframes/empty"
  stage . .vercel/output wireframes artifacts
  expect_rc 0
  expect_valid_output
  expect_staged
}

# Deleted or renamed files must disappear on the next deploy.
case_wipes_previous() {
  put "wireframes/new.html" new
  put ".vercel/output/static/wireframes/old.html" old
  put ".vercel/output/static/brand-strategy/positioning.md" leaked
  stage . .vercel/output wireframes
  expect_rc 0
  expect_staged wireframes/new.html
}

case_duplicate_folder() {
  put "wireframes/home.html" home
  stage . .vercel/output wireframes wireframes
  expect_rc 0
  expect_staged wireframes/home.html
  says "Staged 1 file(s) from: wireframes."
}

case_out_dir_is_root() {
  put "wireframes/home.html" home
  stage . . wireframes
  expect_rc 2
  says "must not be the repository root"
  [ -f "$REPO/DESIGN.md" ]; check "repo not wiped" $?
}

case_usage() {
  stage
  expect_rc 2
  says "usage:"
}

# --- workflow --------------------------------------------------------------------------------

# Every ${{ }} reaches a script through env:, never pasted into the shell source.
case_no_inline_expressions() {
  local inline
  inline=$(yq '.jobs.deploy.steps[] | select(has("run")) | .run' "$WF" | grep -F '${{' || true)
  [ -z "$inline" ]; check "no \${{ }} inside run: (found: $inline)" $?
  inline=$(yq '.jobs.deploy.steps[] | select(has("with")) | .with.script // ""' "$WF" | grep -F '${{' || true)
  [ -z "$inline" ]; check "no \${{ }} inside github-script (found: $inline)" $?
}

# The checkout is never uploaded: one CLI call, `deploy --prebuilt`, nothing that builds or pulls.
case_only_prebuilt_deploy() {
  local runs
  runs=$(yq '.jobs.deploy.steps[] | .run // ""' "$WF")
  [ "$(printf '%s' "$runs" | grep -o 'vercel@' | wc -l | tr -d ' ')" -eq 1 ]; check "exactly one vercel invocation" $?
  printf '%s' "$runs" | grep -qE '"vercel@\$\{VERCEL_VERSION\}" deploy --prebuilt '; check "it is deploy --prebuilt" $?
  ! printf '%s' "$runs" | grep -qE 'vercel(@[^ ]+)?"? (build|pull)\b'; check "no vercel build/pull" $?
  local stage deploy
  stage=$(yq '.jobs.deploy.steps | to_entries | .[] | select(.value.name == "Stage allowlisted folders") | .key' "$WF")
  deploy=$(yq '.jobs.deploy.steps | to_entries | .[] | select(.value.name == "Vercel deploy") | .key' "$WF")
  [ -n "$stage" ] && [ -n "$deploy" ] && [ "$stage" -lt "$deploy" ]; check "staging runs before the deploy" $?
}

case_contract() {
  local v
  for v in VERCEL_TOKEN VERCEL_ORG_ID VERCEL_PROJECT_ID; do
    [ "$(yq ".on.workflow_call.secrets.$v.required" "$WF")" = false ]; check "$v is required: false" $?
  done
  [ "$(yq '.on.workflow_call.secrets | keys | length' "$WF")" -eq 3 ]; check "exactly three secrets declared" $?
  [ "$(yq '[.on.workflow_call.inputs[] | select(.required != false)] | length' "$WF")" -eq 0 ]; check "every input is required: false" $?
  [ "$(yq '.on.workflow_call.inputs.vercel-version.default' "$WF")" = 65.7.0 ]; check "CLI pinned to 65.7.0" $?
  [ "$(yq '.on.workflow_call.inputs.exclude-readmes.default' "$WF")" = true ]; check "exclude-readmes defaults to true" $?
  [ "$(yq '.jobs.deploy | has("permissions")' "$WF")" = false ]; check "no job-level permissions block" $?
  [ "$(yq '.on.workflow_call.outputs.url.value' "$WF")" = '${{ jobs.deploy.outputs.url }}' ]; check "url output wired" $?
  yq '.jobs.deploy.steps[] | select(.name == "Finish GitHub deployment") | .if' "$WF" | grep -qF 'always()'
  check "finish step runs under always()" $?
  [ "$(yq '.jobs.deploy.steps[-1].name' "$WF")" = "Finish GitHub deployment" ]; check "finish is the last step" $?
  yq '.jobs.deploy.steps[] | select(.name == "Comment deploy URL on PR") | .with.script' "$WF" |
    grep -qF "c.user.login === 'github-actions[bot]'"
  check "PR comment only edits the bot's own comment" $?
}

check_env() { # ENVIRONMENT FOLDERS VERCEL_VERSION, then the secret names that are set
  export ENVIRONMENT=$1 FOLDERS=$2 VERCEL_VERSION=$3
  shift 3
  export VERCEL_TOKEN='' VERCEL_ORG_ID='' VERCEL_PROJECT_ID=''
  local name
  for name in "$@"; do export "$name=value"; done
}

case_check_ok() {
  step_script "Check inputs and Vercel secrets"
  check_env production "wireframes artifacts" 65.7.0 VERCEL_TOKEN VERCEL_ORG_ID VERCEL_PROJECT_ID
  run_step
  expect_rc 0
  never_says "::error::"
}

case_check_missing_secrets() {
  step_script "Check inputs and Vercel secrets"
  check_env preview wireframes 65.7.0 VERCEL_TOKEN
  run_step
  expect_rc 1
  says "::error::Missing secret(s): VERCEL_ORG_ID VERCEL_PROJECT_ID."
}

case_check_bad_inputs() {
  step_script "Check inputs and Vercel secrets"
  check_env stage "  " latest VERCEL_TOKEN VERCEL_ORG_ID VERCEL_PROJECT_ID
  run_step
  expect_rc 1
  says "environment must be preview or production (got: 'stage')"
  says "vercel-version must be an exact version"
  says "folders is empty"
  check_env "" wireframes 65.7.0 VERCEL_TOKEN VERCEL_ORG_ID VERCEL_PROJECT_ID
  run_step
  expect_rc 1
  says "environment must be preview or production (got: '')"
}

# The step splits `folders` and forwards exclude-readmes as --keep-readmes.
case_stage_step() {
  mkdir -p "$REPO/.platform/.github/scripts"
  cp "$SCRIPT" "$REPO/.platform/.github/scripts/"
  put "wireframes/README.md" doc
  put "wireframes/home.html" home
  put "artifacts/x.html" x
  step_script "Stage allowlisted folders"
  export FOLDERS=" wireframes   artifacts " EXCLUDE_READMES=true PLATFORM_REF=main
  run_step
  expect_rc 0
  expect_staged artifacts/x.html wireframes/home.html
  export EXCLUDE_READMES=false
  run_step
  expect_rc 0
  expect_staged artifacts/x.html wireframes/README.md wireframes/home.html
  export FOLDERS="wireframes ../docs"
  run_step
  expect_rc 2
  says "'../docs' is not a plain top-level folder name"
}

case_stage_step_old_platform_ref() {
  step_script "Stage allowlisted folders"
  export FOLDERS=wireframes EXCLUDE_READMES=true PLATFORM_REF=v2.1.0
  run_step
  expect_rc 1
  says "is missing at platform-ref 'v2.1.0'"
}

deploy_env() { export ENVIRONMENT=$1 VERCEL_VERSION=65.7.0 VERCEL_TOKEN=tok VERCEL_ORG_ID=org VERCEL_PROJECT_ID=prj; }

case_deploy_preview() {
  step_script "Vercel deploy"
  stub_npx "https://brand-brain-abc123.vercel.app"
  deploy_env preview
  run_step
  expect_rc 0
  local calls
  calls=$(cat "$NPX_LOG")
  [ "$calls" = "--yes vercel@65.7.0 deploy --prebuilt --token tok" ]; check "preview: no --prod (got: $calls)" $?
  [ "$OUTPUTS" = "url=https://brand-brain-abc123.vercel.app" ]; check "url output (got: $OUTPUTS)" $?
}

case_deploy_production() {
  step_script "Vercel deploy"
  stub_npx "https://brand-brain-abc123.vercel.app"
  deploy_env production
  run_step
  expect_rc 0
  local calls
  calls=$(cat "$NPX_LOG")
  [ "$calls" = "--yes vercel@65.7.0 deploy --prebuilt --prod --token tok" ]; check "production: --prod (got: $calls)" $?
}

# Anything but a bare https URL on the last stdout line fails the step and writes no output.
case_deploy_bad_url() {
  step_script "Vercel deploy"
  deploy_env preview
  local bad
  for bad in "" "Error: something" "http://x.vercel.app" "https://x.vercel.app/path" 'https://x.vercel.app$(id)'; do
    stub_npx "$bad"
    run_step
    expect_rc 1
    says "did not print a deployment URL"
    [ -z "$OUTPUTS" ]; check "no url output for '$bad' (got: $OUTPUTS)" $?
  done
}

# --- runner ----------------------------------------------------------------------------------

ALL=(allowlist any_folders dotfiles symlinks symlinked_folder readmes keep_readmes spaces
  invalid_folders no_folders missing_folder empty_output wipes_previous duplicate_folder
  out_dir_is_root usage no_inline_expressions only_prebuilt_deploy contract check_ok
  check_missing_secrets check_bad_inputs stage_step stage_step_old_platform_ref deploy_preview
  deploy_production deploy_bad_url)
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
