#!/usr/bin/env bash
#
# Resolves the preview site for code-review.yml's "Resolve preview site" step.
#
# With no SITE_URL_TEMPLATE, or the value `none`, the review runs without a site (status=none).
# `none` is how a repository opts out of an organization-level variable: a repository variable
# named the same overrides the organization's, and GitHub does not accept an empty one. With a
# template, it finds the
# newest `preview` GitHub deployment that deploy.yml recorded for the reviewed commit, waits while
# it is still deploying, and either hands the review a site (status=ready) or stops it
# (status=stop): one comment on the pull request saying why, then exit 1, so the job fails and the
# review does not run. A site that is configured and not usable is never silently dropped.
#
# Outputs (written to $GITHUB_OUTPUT):
#   status         none | ready | stop
#   site-url       the template with {preview_url} replaced; ready only
#   mcp-config     inline JSON for claude_args' --mcp-config; ready only
#   browser-tools  the browser tools to add to --allowedTools, comma-separated; ready only
#   vitals-tag     16 hex characters, random per run, that site-vitals.js puts in its console
#                  prefix ([cwv:<tag>]), so the page cannot forge the platform's lines; ready only
#   stop-reason    pending-timeout | missing | failed | unreadable | invalid-template |
#                  invalid-url | error; stop only
#
# Environment (every value is read from the environment, never interpolated into a script):
#   SITE_URL_TEMPLATE  the caller's `site-url-template` input; empty or `none` means no site
#   HEAD_SHA           the reviewed commit
#   PR_NUMBER          the reviewed pull request
#   TRIGGER_PHRASE     the caller's `trigger-phrase` input, quoted in the pending comment
#   GH_TOKEN           token able to read deployments and comment on the pull request
#   GITHUB_REPOSITORY, GITHUB_SERVER_URL, GITHUB_RUN_ID, RUNNER_TEMP, GITHUB_OUTPUT
#
# Tests: .github/scripts/test-resolve-preview-site.sh, run in CI by
# .github/workflows/script-tests.yml.

# The single-quoted backticks are Markdown for the comment, never shell.
# shellcheck disable=SC2016

set -euo pipefail

SITE_URL_TEMPLATE=${SITE_URL_TEMPLATE:-}
# Leading and trailing whitespace dropped, so a blank variable (a stray space or a pasted newline)
# means no site, like an empty one, instead of an invalid template that stops every review. The
# workflow step's own emptiness check ignores whitespace the same way.
SITE_URL_TEMPLATE=${SITE_URL_TEMPLATE#"${SITE_URL_TEMPLATE%%[![:space:]]*}"}
SITE_URL_TEMPLATE=${SITE_URL_TEMPLATE%"${SITE_URL_TEMPLATE##*[![:space:]]}"}

# How long a review waits for a preview that is still deploying. Being tuned: 5 minutes is a first
# guess (the sandbox's preview deploys took 1.5-3 minutes), revisited with the #122 measurement.
# Every minute of it is Actions minutes on a private repository.
SITE_WAIT_SECONDS=300
POLL_SECONDS=15

# The browser tools the review may use, appended to --allowedTools. See
# docs/architecture.md#the-preview-site-and-the-performance-note before adding one.
BROWSER_TOOLS=(browser_navigate browser_snapshot browser_take_screenshot browser_console_messages
  browser_network_requests browser_network_request browser_wait_for browser_click browser_hover
  browser_press_key browser_resize)

# Origins the browser may never request: the runner itself (localhost, with and without the
# trailing dot, 127.0.0.1, [::1], 0.0.0.0) and the cloud metadata and wire-server addresses
# (169.254.169.254, 169.254.170.2, and Azure's 168.63.129.16, where GitHub-hosted runners live). A
# bare host blocks it on its default port under any scheme; `scheme://host:*` blocks every port.
# IPv6 is the exception: Playwright's `scheme://host:*` form does not accept the colons in `[::1]`
# (it becomes a glob that matches nothing), so `[::1]:*` (any scheme, any port) is used instead.
# Playwright matches these as literal globs, with no address ranges: the rest of 127.0.0.0/8 and
# 169.254.0.0/16, and the private ranges, are NOT blocked. Defense in depth, not a boundary:
# Playwright does not apply it to redirects either, and a page can still ask the agent to open an
# outside URL. See docs/architecture.md#the-preview-site-and-the-performance-note.
BLOCKED_HOSTS=(localhost localhost. 127.0.0.1 0.0.0.0 169.254.169.254 169.254.170.2 168.63.129.16)
BLOCKED_ORIGINS=()
for h in "${BLOCKED_HOSTS[@]}"; do
  BLOCKED_ORIGINS+=("$h" "http://$h:*" "https://$h:*")
done
unset h
BLOCKED_ORIGINS+=('[::1]' '[::1]:*')

# A read that fails for another reason than a refusal (a GitHub 5xx, a rate limit, the network) is
# tried API_TRIES times, API_RETRY_SECONDS apart, so one blip in the wait does not stop a review.
API_TRIES=3
API_RETRY_SECONDS=5

# Shape check of the template only: https, a literal host, the placeholder after it (in the path,
# query or fragment: the value is a whole `https://...` URL, so `https://{preview_url}` would yield
# `https://https://...`), and URL characters (no space, quote, backtick or newline), so that it can
# reach a prompt and a comment unquoted.
TEMPLATE_CHARS='^[A-Za-z0-9._~:/?#@!$&()*+,;=%{}-]+$'
TEMPLATE_SHAPE='^https://[A-Za-z0-9.-]+(:[0-9]+)?[/?#].*[{]preview_url[}]'
validate_template() {
  [[ "$1" =~ $TEMPLATE_SHAPE ]] && [[ "$1" =~ $TEMPLATE_CHARS ]]
}

# The deployment's URL, as deploy.yml records it: a bare Vercel deployment origin.
validate_site_url() {
  [[ "$1" =~ ^https://[a-z0-9-]+\.vercel\.app$ ]]
}

out() { printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; }

# One GET. Prints the response; on failure prints gh's error to stderr (it reaches the run log) and
# returns 2 for a 403 (a rate limit excepted), 3 for a 404 — what a token without
# `deployments: read` gets — or 1 for anything else, once the retries are spent.
#
# Codes 2 and 3 mean a refusal to read_failed, so nothing else may return them: the jq that parses
# an answer returns JQ_FAILED whatever its own status is (jq 1.6 exits 2 on malformed JSON).
JQ_FAILED=4
api() {
  local body rc err try=1
  err=$(mktemp)
  while :; do
    rc=0
    body=$(gh api "$1" 2>"$err") || rc=$?
    [ "$rc" -eq 0 ] && break
    cat "$err" >&2
    if grep -qi 'rate limit' "$err"; then rc=1
    elif grep -qE 'HTTP 403([^0-9]|$)' "$err"; then rc=2
    elif grep -qE 'HTTP 404([^0-9]|$)' "$err"; then rc=3
    else rc=1
    fi
    if [ "$rc" -ne 1 ] || [ "$try" -ge "$API_TRIES" ]; then break; fi
    echo "::warning::[code-review] reading the preview deployment failed; retry $try/$((API_TRIES - 1)) in ${API_RETRY_SECONDS} s." >&2
    try=$((try + 1))
    sleep "$API_RETRY_SECONDS"
  done
  rm -f "$err"
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$body"
}

# Prints the id of the newest preview deployment of the head commit, or nothing when there is
# none. The API lists deployments newest first.
latest_deployment() {
  local json
  json=$(api "repos/${GITHUB_REPOSITORY}/deployments?environment=preview&sha=${HEAD_SHA}&per_page=1") || return
  # Numeric or nothing: the id goes into the next API path.
  printf '%s' "$json" | jq -r '.[0].id // empty | if type == "number" then . else error("not an id") end' \
    || return "$JQ_FAILED"
}

# Prints the deployment's newest status as three tab-separated fields: state, environment_url and
# log_url (each `-` when absent). State `none` when the deployment has no status yet.
deployment_state() {
  local json
  json=$(api "repos/${GITHUB_REPOSITORY}/deployments/$1/statuses?per_page=1") || return
  printf '%s' "$json" | jq -r '(.[0] // {state: "none"}) | [.state, (.environment_url // "" | if . == "" then "-" else . end),
        (.log_url // "" | if . == "" then "-" else . end)] | @tsv' || return "$JQ_FAILED"
}

# Still deploying: no status yet, or one that is not final.
pending() { [[ "$1" =~ ^(none|queued|pending|in_progress)$ ]]; }

# The polling loop only: re-reads the deployment every POLL_SECONDS while it is pending, for up to
# SITE_WAIT_SECONDS, and prints the last state it read (still pending when the wait ran out).
wait_for_deployment() {
  local id=$1 line=$2 polls=$((SITE_WAIT_SECONDS / POLL_SECONDS)) i=0 state
  state=${line%%$'\t'*}
  while pending "$state" && [ "$i" -lt "$polls" ]; do
    i=$((i + 1))
    echo "::notice::[code-review] waiting for the preview deployment $i/$polls (state $state, $(date -u +%H:%M:%S))" >&2
    sleep "$POLL_SECONDS"
    line=$(deployment_state "$id") || return
    state=${line%%$'\t'*}
  done
  printf '%s\n' "$line"
}

# Stops the review: writes the outputs, posts one comment saying why (fixed wording, plus the
# run's log), and exits 1 so the job fails. $1: the stop reason; $2: the deployment state, for the
# reasons that name one. Only fixed text, validated values and the caller's own trigger phrase
# reach the comment.
stop_with_comment() {
  local reason=$1 detail=${2:-} log_url=${3:-} run_url title text
  run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  case "$reason" in
    pending-timeout)
      title='the preview is still deploying'
      text="The newest preview deployment of ${HEAD_SHA} was still \`${detail}\` after $((SITE_WAIT_SECONDS / 60)) minutes. Comment \`${TRIGGER_PHRASE}\` again once it finishes."
      ;;
    missing)
      title='no preview deployment for this commit'
      text="There is no preview deployment of ${HEAD_SHA}. Either the deploy has not started yet (\`pr-preview\` deploys only after CI passes, so a pull request whose CI is still running or failed has none), the deployment was deleted, \`pr-preview\` skipped this pull request (for example a Dependabot one), or the repository has no preview deploy. Comment \`${TRIGGER_PHRASE}\` again once the preview is deployed, or, if this repository has no site to check, set the \`SITE_URL_TEMPLATE\` variable or the caller's \`site-url-template\` input to \`none\`."
      ;;
    failed)
      title='the preview deploy failed'
      text="The newest preview deployment of ${HEAD_SHA} ended \`${detail}\`"
      if [ "$detail" = success ]; then
        text+=' without a URL'
      fi
      text+='. '
      # The log link is the deploy run's URL, recorded by deploy.yml; anything else is left out.
      if [[ "$log_url" =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~/-]+$ ]]; then
        text+="Deploy log: ${log_url}. "
      fi
      text+="Fix the deploy, push, and comment \`${TRIGGER_PHRASE}\` again."
      ;;
    unreadable)
      title='the deployments could not be read'
      text="Reading the preview deployment of ${HEAD_SHA} was refused (403 or 404). The calling workflow has to grant \`deployments: read\` in its \`permissions:\` block, as in \`examples/comment-code-review.yml\` of refokus-agency/platform."
      ;;
    invalid-template)
      title='`SITE_URL_TEMPLATE` is invalid'
      text="The template has to start with \`https://\` and a host, contain \`{preview_url}\` after the host (in the path, query or fragment), and use only URL characters: no space, quote or backtick. Fix it where it is set (the \`SITE_URL_TEMPLATE\` variable or the caller's \`site-url-template\` input) and comment \`${TRIGGER_PHRASE}\` again."
      ;;
    invalid-url)
      title='the preview deployment URL is not a Vercel URL'
      text="The newest preview deployment of ${HEAD_SHA} reports a URL that is not \`https://<name>.vercel.app\`, so it is not opened. Check what records \`preview\` deployments in this repository."
      ;;
    *)
      reason=error
      title='the preview site could not be resolved'
      text="An unexpected error stopped the step that finds the preview deployment of ${HEAD_SHA}; its error is in the run log. Comment \`${TRIGGER_PHRASE}\` again, and report it if it happens again."
      ;;
  esac
  STOPPED=1
  out status stop
  out stop-reason "$reason"
  echo "::error::[code-review] preview site: ${reason}. The review did not run; the pull request was told why. See docs/troubleshooting.md." >&2
  gh pr comment "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --body "$(printf '**Code review not run: %s.**\n\nThis repository sets `SITE_URL_TEMPLATE`, so the review checks the preview site of the pull request, and it could not here. %s\n\nRun log: %s' "$title" "$text" "$run_url")" \
    || echo "::error::[code-review] could not comment on pull request #${PR_NUMBER} (pull-requests: write not granted?)." >&2
  exit 1
}

# The prefix line in site-vitals.js that emit_ready gives a per-run tag.
VITALS_PREFIX_LINE="  const PREFIX = '[cwv]';"

# Hands the review its site: the URL, the inline MCP config, the browser tools and the vitals tag.
emit_ready() {
  local site_url=$1 tools blocked tag src dst
  src=$(dirname "${BASH_SOURCE[0]}")/site-vitals.js
  dst=$RUNNER_TEMP/code-review/site-vitals.js
  mkdir -p "$RUNNER_TEMP/code-review"
  # A tag the page cannot know: the page's own scripts can log `[cwv] ...` too, and the review
  # would read those as the platform's numbers.
  tag=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  [[ "$tag" =~ ^[0-9a-f]{16}$ ]] || { echo "::error::[code-review] could not generate the vitals tag." >&2; exit 1; }
  grep -qxF "$VITALS_PREFIX_LINE" "$src" || { echo "::error::[code-review] site-vitals.js has no prefix line to tag." >&2; exit 1; }
  sed "s/^  const PREFIX = '\[cwv\]';\$/  const PREFIX = '[cwv:${tag}]';/" "$src" >"$dst"
  grep -qxF "  const PREFIX = '[cwv:${tag}]';" "$dst" || { echo "::error::[code-review] could not tag site-vitals.js." >&2; exit 1; }
  # The MCP's manifest and lockfile, for the `Install Playwright MCP` step's `npm ci`: the
  # platform checkout is gone by the time anything else could read them.
  mkdir -p "$RUNNER_TEMP/pwmcp"
  cp "$(dirname "${BASH_SOURCE[0]}")/playwright-mcp/package.json" \
    "$(dirname "${BASH_SOURCE[0]}")/playwright-mcp/package-lock.json" "$RUNNER_TEMP/pwmcp/"
  tools=$(printf 'mcp__playwright__%s,' "${BROWSER_TOOLS[@]}")
  blocked=$(printf '%s;' "${BLOCKED_ORIGINS[@]}")
  out status ready
  out site-url "$site_url"
  # Started from inside its output directory, with --ignore-roots. The MCP lets a tool's
  # `filename` argument write anywhere under its output directory or its workspace, and the
  # workspace is the client's first root, else its own cwd: both the pull request checkout
  # otherwise. This way the two are the same directory under $RUNNER_TEMP.
  out mcp-config "$(jq -cn --arg t "$RUNNER_TEMP" --arg b "${blocked%;}" '{mcpServers: {playwright: {
    command: "/bin/sh",
    args: ["-c", "mkdir -p \"$0\" && cd \"$0\" && exec \"$@\"", "\($t)/playwright-mcp",
      "\($t)/pwmcp/node_modules/.bin/playwright-mcp",
      "--headless", "--isolated", "--ignore-roots", "--browser", "chrome", "--output-dir", "\($t)/playwright-mcp",
      "--init-script", "\($t)/code-review/site-vitals.js", "--blocked-origins", $b]}}}')"
  out browser-tools "${tools%,}"
  out vitals-tag "$tag"
}

# Unexpected exits (set -e, an unreadable answer, a bug) still stop the review out loud. Every
# deliberate exit goes through stop_with_comment, which sets STOPPED first. A cancelled run (a
# manual cancel, or the job timeout during the wait, where this step spends its time) is not an
# error: the runner signals the step, and the pull request gets no comment for it.
STOPPED=0
CANCELLED=0
on_signal() { CANCELLED=1; exit "$1"; }
on_exit() {
  local rc=$?
  # 130 and 143 also cover a signal that reached only a child (the wait runs in a subshell).
  if [ "$rc" -ne 0 ] && [ "$STOPPED" -eq 0 ] && [ "$CANCELLED" -eq 0 ] && [ "$rc" -ne 130 ] && [ "$rc" -ne 143 ]; then
    trap - EXIT
    stop_with_comment error
  fi
}

# A failed read: refused (403 or 404) is the missing permission; anything else ends the script.
# $2 `statuses`: the deployment list was already readable, so a 404 on its statuses is a
# deployment deleted in the meantime, not a permission.
read_failed() {
  if [ "$1" -eq 3 ] && [ "${2:-}" = statuses ]; then
    stop_with_comment missing
  fi
  if [ "$1" -eq 2 ] || [ "$1" -eq 3 ]; then
    stop_with_comment unreadable
  fi
  exit "$1"
}

main() {
  local id line state url log
  if [ -z "$SITE_URL_TEMPLATE" ] || [ "$SITE_URL_TEMPLATE" = none ]; then
    out status none
    return 0
  fi
  if ! [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::error::[code-review] the head commit is not a full SHA: ${HEAD_SHA:-empty}." >&2
    exit 1
  fi
  if ! validate_template "$SITE_URL_TEMPLATE"; then
    stop_with_comment invalid-template
  fi
  id=$(latest_deployment) || read_failed $?
  if [ -z "$id" ]; then
    stop_with_comment missing
  fi
  # Through variables, not `< <(...)`: a failing read has to stop the script, and a process
  # substitution hides its exit code.
  line=$(deployment_state "$id") || read_failed $? statuses
  line=$(wait_for_deployment "$id" "$line") || read_failed $? statuses
  IFS=$'\t' read -r state url log <<<"$line"
  if pending "$state"; then
    stop_with_comment pending-timeout "$state"
  fi
  if [[ "$state" =~ ^(failure|error|inactive)$ ]] || { [ "$state" = success ] && [ "$url" = - ]; }; then
    stop_with_comment failed "$state" "$log"
  fi
  if [ "$state" = success ] && ! validate_site_url "$url"; then
    stop_with_comment invalid-url
  fi
  if [ "$state" != success ]; then
    echo "::error::[code-review] the preview deployment reports an unknown state." >&2
    exit 1
  fi
  # A literal replacement: bash 5.2 would otherwise read `&` in the URL as the matched text, and
  # quoting the replacement to stop it is kept literally by older versions.
  shopt -u patsub_replacement 2>/dev/null || true
  emit_ready "${SITE_URL_TEMPLATE//\{preview_url\}/$url}"
}

trap on_exit EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
main
