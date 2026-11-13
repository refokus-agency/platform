#!/usr/bin/env bash
#
# Tests for code-review.yml's "Resolve preview site" step: resolve-preview-site.sh, which finds the
# preview deployment of the reviewed commit, waits for it, and either hands the review a site or
# stops it with a comment on the pull request.
#
# Black box: the script runs against the stub `gh` in fixtures/review-context/, which answers from
# per-test fixture files and logs its calls, and against a stub `sleep` that only logs, so the
# wait costs no real time and its polls can be counted. Nothing here talks to the network.
#
# Usage:
#   ./.github/scripts/test-resolve-preview-site.sh                 # every case
#   ./.github/scripts/test-resolve-preview-site.sh ac1 ac3         # just these
#
# Needs bash, jq, yq and node (node only for `node --check` on the init script; all preinstalled on
# ubuntu-latest). Exit 0 all passed, 1 otherwise.

# The case_* functions are called by name from the runner at the bottom; single-quoted backticks
# are the Markdown the comments are expected to carry.
# shellcheck disable=SC2329,SC2016

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2
ROOT=$(pwd)
SCRIPT="$ROOT/.github/scripts/resolve-preview-site.sh"
VITALS="$ROOT/.github/scripts/site-vitals.js"
STUB_BIN="$ROOT/.github/scripts/fixtures/review-context"
WF="$ROOT/.github/workflows/code-review.yml"

for tool in jq yq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is not installed." >&2; exit 2; }
done

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

SHA=0123456789abcdef0123456789abcdef01234567
PREVIEW=https://app-git-abc123-acme.vercel.app
RUN_URL=https://github.com/acme/app/actions/runs/777

# --- harness ---------------------------------------------------------------------------------

setup() {
  T=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  export STUB_DIR="$T/fx"
  mkdir -p "$STUB_DIR" "$T/bin" "$T/runner"
  : >"$STUB_DIR/calls.log"
  : >"$T/sleep.log"
  # A stub sleep: logs its argument and returns at once.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$T/sleep.log" >"$T/bin/sleep"
  chmod +x "$T/bin/sleep"
  export GH_TOKEN=x GITHUB_REPOSITORY=acme/app GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=777 \
    HEAD_SHA=$SHA PR_NUMBER=50 TRIGGER_PHRASE='@claude review' RUNNER_TEMP="$T/runner" \
    SITE_URL_TEMPLATE='https://stage.example.com/?preview={preview_url}'
  export GITHUB_OUTPUT="$T/out"
  : >"$GITHUB_OUTPUT"
}
fx() { printf '%s' "$2" >"$STUB_DIR/$1.out"; }
fxn() { printf '%s' "$3" >"$STUB_DIR/$1.$2.out"; }  # name, n-th call, body
fxrc() { printf '%s' "$2" >"$STUB_DIR/$1.rc"; }
fxnrc() { printf '%s' "$3" >"$STUB_DIR/$1.$2.rc"; }  # name, n-th call, exit code
fxerr() { printf '%s\n' "$2" >"$STUB_DIR/$1.err"; }
deployment() { fx deployments "[{\"id\":$1,\"sha\":\"$SHA\",\"environment\":\"preview\"}]"; }
status() { # state [environment_url] [log_url]
  jq -cn --arg s "$1" --arg u "${2:-}" --arg l "${3:-https://github.com/acme/app/actions/runs/42}" \
    '[{state:$s, environment_url:$u, log_url:$l}]'
}

# Runs the script. ERR: its stdout and stderr, RC: exit code.
run_script() {
  PATH="$T/bin:$STUB_BIN:$PATH" "$SCRIPT" >"$T/err" 2>&1
  RC=$?
  ERR=$(cat "$T/err")
}
# One step output by name (single-line values only, which is all this step writes).
outv() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n 1; }
has_out() { grep -q "^$1=" "$GITHUB_OUTPUT"; }
comments() { grep -c '^pr comment' "$STUB_DIR/calls.log"; }
body() { cat "$STUB_DIR/pr_comment.body" 2>/dev/null; }
sleeps() { grep -c . "$T/sleep.log"; }
api_calls() { grep -c '^api' "$STUB_DIR/calls.log"; }

# The status comes first: it is expanded before the description, whose command substitutions
# would otherwise reset $? to 0 and pass every check.
check() { # status (0 = pass), description
  if [ "$1" -ne 0 ]; then
    echo "    FAIL: $2"
    CASE_FAIL=1
  fi
}
expect_rc() { [ "$RC" -eq "$1" ]; check $? "exit $1 (rc=$RC, output: $ERR)"; }
expect_out() { [ "$(outv "$1")" = "$2" ]; check $? "output $1 is '$2' (got '$(outv "$1")')"; }
expect_no_out() { ! has_out "$1"; check $? "no $1 output (got '$(outv "$1")')"; }
body_has() { body | tr '\n' ' ' | tr -s ' ' | grep -qF -- "$1"; check $? "comment contains: $1 (got: $(body))"; }
# A stopped review: status stop, the reason, one comment linking the run, exit 1, nothing ready.
expect_stop() { # stop-reason
  expect_rc 1
  expect_out status stop
  expect_out stop-reason "$1"
  [ "$(comments)" -eq 1 ]; check $? "exactly one pr comment (got $(comments))"
  grep -q '^pr comment 50 --repo acme/app --body' "$STUB_DIR/calls.log"; check $? "the comment goes to pull request 50 of acme/app"
  body_has 'Code review not run'
  body_has "$RUN_URL"
  expect_no_out site-url
  expect_no_out mcp-config
  expect_no_out browser-tools
  expect_no_out vitals-tag
  printf '%s' "$ERR" | grep -q "::error::\[code-review\] preview site: $1"; check $? "::error:: names the reason"
}

# --- cases -----------------------------------------------------------------------------------

case_ac1() { # no template: no site, no API call, no comment, no wait
  SITE_URL_TEMPLATE=''
  run_script; expect_rc 0
  expect_out status none
  expect_no_out site-url
  expect_no_out mcp-config
  expect_no_out browser-tools
  expect_no_out stop-reason
  [ ! -s "$STUB_DIR/calls.log" ]; check $? "no gh call (got: $(cat "$STUB_DIR/calls.log"))"
  [ "$(sleeps)" -eq 0 ]; check $? "no wait"
}

case_blank_template() { # a whitespace-only template is no template: no site, no stop
  local v
  for v in ' ' $'\n' $' \t\n '; do
    setup
    SITE_URL_TEMPLATE=$v
    run_script; expect_rc 0
    expect_out status none
    [ "$(comments)" -eq 0 ]; check $? "no comment for a blank template"
    setup
    SITE_URL_TEMPLATE=$v
    run_step; expect_rc 0
    expect_out status none
  done
  # Surrounding whitespace on a real template is dropped, not a reason to stop.
  setup
  SITE_URL_TEMPLATE=$' https://stage.example.com/?preview={preview_url}\n'
  deployment 101
  fx statuses "$(status success "$PREVIEW")"
  run_script; expect_rc 0
  expect_out site-url "https://stage.example.com/?preview=$PREVIEW"
}

case_none_template() { # `none` opts out (of an org-level variable): no site, no call, no stop
  local v
  for v in none ' none' $'none\n'; do
    setup
    SITE_URL_TEMPLATE=$v
    run_script; expect_rc 0
    expect_out status none
    expect_no_out stop-reason
    [ ! -s "$STUB_DIR/calls.log" ]; check $? "no gh call for '$v' (got: $(cat "$STUB_DIR/calls.log"))"
    setup
    SITE_URL_TEMPLATE=$v
    run_step; expect_rc 0
    expect_out status none
    [ ! -s "$STUB_DIR/calls.log" ]; check $? "the step makes no gh call for '$v'"
  done
  # The stop comment for a missing deployment names the opt-out, through the variable or the
  # caller's input, since a caller can pass the template either way.
  setup
  run_script
  expect_stop missing
  body_has 'to `none`'
  body_has '`SITE_URL_TEMPLATE` variable'
  body_has '`site-url-template` input'
}

case_jq_status() { # a jq that exits 2 or 3 is an unreadable answer (error), never a refusal
  local c
  for c in 2 3; do
    setup
    deployment 101
    printf '#!/bin/sh\nexit %s\n' "$c" >"$T/bin/jq"
    chmod +x "$T/bin/jq"
    run_script
    expect_stop error
    ! body | grep -qF 'deployments: read'; check $? "jq exit $c is not reported as a missing permission"
  done
}

case_ac2() { # newest deployment succeeded with a URL: the site, the MCP and the browser tools
  deployment 101
  fx statuses "$(status success "$PREVIEW")"
  run_script; expect_rc 0
  expect_out status ready
  expect_out site-url "https://stage.example.com/?preview=$PREVIEW"
  expect_no_out stop-reason
  [ "$(comments)" -eq 0 ]; check $? "no comment"
  [ "$(sleeps)" -eq 0 ]; check $? "no wait"
  grep -q "^api repos/acme/app/deployments?environment=preview&sha=$SHA&per_page=1$" "$STUB_DIR/calls.log"
  check $? "newest preview deployment of the head SHA is read"
  grep -q '^api repos/acme/app/deployments/101/statuses?per_page=1$' "$STUB_DIR/calls.log"
  check $? "its newest status is read"
  local cfg want
  cfg=$(outv mcp-config)
  want=$(jq -cn --arg t "$RUNNER_TEMP" '{mcpServers:{playwright:{command:"/bin/sh",
    args:["-c","mkdir -p \"$0\" && cd \"$0\" && exec \"$@\"","\($t)/playwright-mcp",
          "\($t)/pwmcp/node_modules/.bin/playwright-mcp",
          "--headless","--isolated","--ignore-roots","--browser","chrome","--output-dir","\($t)/playwright-mcp",
          "--init-script","\($t)/code-review/site-vitals.js",
          "--blocked-origins","localhost;http://localhost:*;https://localhost:*;localhost.;http://localhost.:*;https://localhost.:*;127.0.0.1;http://127.0.0.1:*;https://127.0.0.1:*;0.0.0.0;http://0.0.0.0:*;https://0.0.0.0:*;169.254.169.254;http://169.254.169.254:*;https://169.254.169.254:*;169.254.170.2;http://169.254.170.2:*;https://169.254.170.2:*;168.63.129.16;http://168.63.129.16:*;https://168.63.129.16:*;[::1];[::1]:*"]}}}')
  [ "$(printf '%s' "$cfg" | jq -c . 2>/dev/null)" = "$want" ]; check $? "mcp-config is exactly $want (got $cfg)"
  local tag
  tag=$(outv vitals-tag)
  [[ "$tag" =~ ^[0-9a-f]{16}$ ]]; check $? "vitals-tag is 16 hex characters (got '$tag')"
  sed "s/^  const PREFIX = '\[cwv\]';\$/  const PREFIX = '[cwv:$tag]';/" "$VITALS" | cmp -s - "$RUNNER_TEMP/code-review/site-vitals.js"
  check $? "the init script is copied where the config points, with only its prefix tagged"
  grep -qxF "  const PREFIX = '[cwv:$tag]';" "$RUNNER_TEMP/code-review/site-vitals.js"; check $? "the copy carries the tag"
  setup; deployment 101; fx statuses "$(status success "$PREVIEW")"; run_script
  [ "$(outv vitals-tag)" != "$tag" ]; check $? "the tag differs per run"
  outv browser-tools | grep -q '^mcp__playwright__browser_navigate,'; check $? "browser tools start with navigate, no leading comma (got $(outv browser-tools))"
  outv browser-tools | grep -qv ',$'; check $? "browser tools have no trailing comma"
}

case_ac3() { # pending, queued, in_progress, no status yet, then success: four 15 s polls, then ready
  deployment 101
  fxn statuses 1 "$(status pending)"
  fxn statuses 2 "$(status queued)"
  fxn statuses 3 "$(status in_progress)"
  fxn statuses 4 '[]'
  fx statuses "$(status success "$PREVIEW")"
  run_script; expect_rc 0
  expect_out status ready
  expect_out site-url "https://stage.example.com/?preview=$PREVIEW"
  [ "$(sleeps)" -eq 4 ]; check $? "four polls (got $(sleeps))"
  ! grep -qvx 15 "$T/sleep.log"; check $? "every poll waits 15 s (got $(tr '\n' ' ' <"$T/sleep.log"))"
  [ "$(comments)" -eq 0 ]; check $? "no comment"
  local i s
  i=0
  for s in pending queued in_progress none; do
    i=$((i + 1))
    printf '%s\n' "$ERR" | grep -qE "^::notice::\[code-review\] waiting for the preview deployment $i/20 \(state $s, [0-2][0-9]:[0-5][0-9]:[0-5][0-9]\)$"
    check $? "poll $i logged as $i/20 with state $s and a timestamp (output: $ERR)"
  done
  ! printf '%s\n' "$ERR" | grep -q 'waiting for the preview deployment 5/20'; check $? "no fifth poll"
}

case_ac4() { # still in_progress after 300 s: twenty polls, then one comment and a stop
  deployment 101
  fx statuses "$(status in_progress)"
  run_script
  expect_stop pending-timeout
  [ "$(sleeps)" -eq 20 ]; check $? "twenty polls of 15 s (got $(sleeps))"
  printf '%s\n' "$ERR" | grep -q 'waiting for the preview deployment 20/20 (state in_progress'; check $? "last poll logged as 20/20"
  body_has 'the preview is still deploying'
  body_has 'still `in_progress` after 5 minutes'
  body_has 'Comment `@claude review` again once it finishes'
}

case_ac5() { # no preview deployment for the head commit: stop at once, naming the three causes
  fx deployments '[]'
  run_script
  expect_stop missing
  [ "$(sleeps)" -eq 0 ]; check $? "no wait (got $(sleeps))"
  ! grep -q statuses "$STUB_DIR/calls.log"; check $? "no status read"
  body_has 'no preview deployment for this commit'
  body_has 'the deploy has not started yet'
  body_has 'deploys only after CI passes, so a pull request whose CI is still running or failed has none'
  body_has '`pr-preview` skipped this pull request (for example a Dependabot one)'
  body_has 'the repository has no preview deploy'
}

case_ac6() { # failure, error, inactive, and success with no URL: the deploy failed, with its log
  local s log=https://github.com/acme/app/actions/runs/42
  for s in failure error inactive success; do
    setup
    deployment 101
    fx statuses "$(status "$s" '' "$log")"
    run_script
    expect_stop failed
    body_has 'the preview deploy failed'
    body_has "ended \`$s\`"
    body_has "Deploy log: $log"
  done
  setup  # the deploy failed after a wait: still reported as failed, not as pending
  deployment 101
  fxn statuses 1 "$(status in_progress)"
  fx statuses "$(status failure '' "$log")"
  run_script
  expect_stop failed
  [ "$(sleeps)" -eq 1 ]; check $? "one poll before the failure (got $(sleeps))"
}

case_ac7() { # 403 or 404 on the list, or 403 on the statuses: the caller must grant the permission
  local rc
  for rc in 403 404; do
    setup
    fxrc deployments "$rc"
    run_script
    expect_stop unreadable
    body_has 'the deployments could not be read'
    body_has 'grant `deployments: read`'
    [ "$(sleeps)" -eq 0 ]; check $? "a refusal is not retried (got $(sleeps))"
  done
  setup
  deployment 101
  fxrc statuses 403
  run_script
  expect_stop unreadable
  setup  # 404 on the statuses of a listed deployment: deleted in the meantime, not a permission
  deployment 101
  fxrc statuses 404
  run_script
  expect_stop missing
  setup  # the same during the wait
  deployment 101
  fxn statuses 1 "$(status in_progress)"
  fxnrc statuses 2 404
  run_script
  expect_stop missing
  setup  # a rate limit answers 403 too: retried, then the generic error, never the permission advice
  fxrc deployments 403
  fxerr deployments 'gh: API rate limit exceeded for installation ID 1. (HTTP 403)'
  run_script
  expect_stop error
  [ "$(api_calls)" -eq 3 ]; check $? "three tries (got $(api_calls))"
  ! body | grep -qF 'deployments: read'; check $? "no permission advice for a rate limit"
  # The documented caller grants it.
  [ "$(yq '.permissions.deployments' "$ROOT/examples/comment-code-review.yml")" = read ]
  check $? "examples/comment-code-review.yml grants deployments: read"
}

case_ac8() { # an invalid template stops before any lookup; a non-Vercel deployment URL stops too
  local t u
  for t in 'https://stage.example.com/' 'http://stage.example.com/?preview={preview_url}' \
    "https://stage.example.com/?preview={preview_url}'" 'https://stage.example.com/ ?preview={preview_url}' \
    'https://stage.example.com/?preview={preview_url}`id`' 'https://stage.example.com/?preview="{preview_url}"' \
    'https://stage.example.com/?preview={preview_url}
x' 'https://{preview_url}' 'https://{preview_url}/x' 'https://u@{preview_url}/' 'https://stage{preview_url}/' \
    'https://stage.example.com{preview_url}'; do
    setup
    SITE_URL_TEMPLATE=$t
    run_script
    expect_stop invalid-template
    ! grep -q '^api' "$STUB_DIR/calls.log"; check $? "no lookup with an invalid template: $t"
    body_has '`SITE_URL_TEMPLATE` is invalid'
    body_has 'start with `https://` and a host, contain `{preview_url}` after the host'
  done
  for t in 'https://stage.example.com/{preview_url}' 'https://stage.example.com:8443/?p={preview_url}' \
    'https://stage.example.com#{preview_url}'; do
    setup
    deployment 101
    fx statuses "$(status success "$PREVIEW")"
    SITE_URL_TEMPLATE=$t
    run_script; expect_rc 0
    expect_out status ready; check $? "a placeholder after the host is valid: $t"
  done
  for u in https://evil.example.com http://app.vercel.app https://app.vercel.app/x https://App.vercel.app \
    'https://app.vercel.app.evil.com' 'https://a_b.vercel.app'; do
    setup
    deployment 101
    fx statuses "$(status success "$u")"
    run_script
    expect_stop invalid-url
    body_has 'the preview deployment URL is not a Vercel URL'
    ! body | grep -qF "$u"; check $? "the rejected URL is not quoted: $u"
  done
}

case_error() { # edge case 14: anything unexpected still stops with one generic comment
  fxrc deployments 500                                   # a GitHub error other than 403/404, every try
  run_script
  expect_stop error
  body_has 'the preview site could not be resolved'
  [ "$(api_calls)" -eq 3 ]; check $? "three tries (got $(api_calls))"
  [ "$(tr '\n' ' ' <"$T/sleep.log")" = '5 5 ' ]; check $? "two 5 s pauses between tries (got $(tr '\n' ' ' <"$T/sleep.log"))"
  setup
  fx deployments 'not json'                              # an answer the script cannot read
  run_script
  expect_stop error
  setup
  fx deployments '[{"id":"101/../../x"}]'                 # an id that is not a number
  run_script
  expect_stop error
  ! grep -q statuses "$STUB_DIR/calls.log"; check $? "a forged id never reaches an API path"
  setup
  deployment 101
  fx statuses "$(status bogus)"                          # a state GitHub does not document
  run_script
  expect_stop error
  setup
  deployment 101
  fxn statuses 1 "$(status in_progress)"
  fxnrc statuses 2 502                                   # a failure during the wait, every try
  fxnrc statuses 3 502
  fxnrc statuses 4 502
  run_script
  expect_stop error
}

case_retry() { # one failed read, on the list or during the wait, is retried and the review goes on
  fxnrc deployments 1 502
  deployment 101
  fx statuses "$(status success "$PREVIEW")"
  run_script; expect_rc 0
  expect_out status ready
  [ "$(comments)" -eq 0 ]; check $? "no comment"
  printf '%s\n' "$ERR" | grep -q '::warning::\[code-review\] reading the preview deployment failed; retry 1/2 in 5 s.'
  check $? "the retry is logged (output: $ERR)"
  setup
  deployment 101
  fxn statuses 1 "$(status in_progress)"
  fxnrc statuses 2 502
  fx statuses "$(status success "$PREVIEW")"
  run_script; expect_rc 0
  expect_out status ready
  [ "$(tr '\n' ' ' <"$T/sleep.log")" = '15 5 ' ]; check $? "one poll, then one retry pause (got $(tr '\n' ' ' <"$T/sleep.log"))"
}

case_vitals() { # site-vitals.js: [cwv] lines, once per distinct value, never throwing
  command -v node >/dev/null 2>&1 || { check 1 "node is installed"; return; }
  node --check "$VITALS"; check $? "node --check site-vitals.js"
  local got
  got=$(node - "$VITALS" <<'JS'
const vm = require('vm');
const src = require('fs').readFileSync(process.argv[2], 'utf8');
const run = (withObserver, throwOnObserve, inFrame = false) => {
  const logs = [];
  const observers = {};
  class PO {
    constructor(cb) { this.cb = cb; }
    observe(o) { if (throwOnObserve) throw new Error('unsupported'); observers[o.type] = { cb: this.cb, o }; }
  }
  const ctx = { console: { log: (...a) => logs.push(a.join(' ')) } };
  if (withObserver) ctx.PerformanceObserver = PO;
  ctx.window = {};
  ctx.window.top = inFrame ? {} : ctx.window;
  vm.runInNewContext(src, ctx);
  const fire = (t, entries) => observers[t].cb({ getEntries: () => entries });
  return { logs, observers, fire };
};
const r = run(true, false);
const buffered = ['largest-contentful-paint', 'layout-shift', 'event'].every((t) => r.observers[t] && r.observers[t].o.buffered === true);
const inpThreshold = r.observers.event && r.observers.event.o.durationThreshold === 16;
r.fire('largest-contentful-paint', [{ startTime: 1200.4 }]);
r.fire('largest-contentful-paint', [{ startTime: 1200.4 }]);
r.fire('largest-contentful-paint', [{ startTime: 1500.6 }]);
r.fire('layout-shift', [{ value: 0.05, hadRecentInput: false, startTime: 100 }, { value: 0.3, hadRecentInput: true, startTime: 150 }]);
r.fire('layout-shift', [{ value: 0, hadRecentInput: false, startTime: 200 }]);
r.fire('layout-shift', [{ value: 0.02, hadRecentInput: false, startTime: 300 }]);
r.fire('event', [{ interactionId: 0, duration: 300 }, { interactionId: 5, duration: 80 }]);
r.fire('event', [{ interactionId: 6, duration: 40 }]);
let threw = false;
try { run(false, false); run(true, true); } catch (e) { threw = true; }
// CLS is the largest session window: a gap of 1 s or more, or a window reaching 5 s, starts a new one.
const w = run(true, false);
w.fire('layout-shift', [{ value: 0.05, startTime: 0 }, { value: 0.05, startTime: 500 }]); // window 1: 0.1
w.fire('layout-shift', [{ value: 0.04, startTime: 2000 }]); // 1.5 s gap: window 2, 0.04
w.fire('layout-shift', [{ value: 0.04, startTime: 2900 }, { value: 0.04, startTime: 3800 }]); // window 2: 0.12
const cap = [];
for (let t = 10000; t <= 16300; t += 900) cap.push({ value: 0.02, startTime: t }); // 8 shifts 0.9 s apart
w.fire('layout-shift', cap); // a 5 s cap: 6 in the first window (0.12), 2 in the next; uncapped it would read 0.16
const clsWindows = w.logs.join('|');
const frame = run(true, false, true);
const frameSilent = Object.keys(frame.observers).length === 0 && frame.logs.length === 0;
console.log(JSON.stringify({ logs: r.logs, buffered, inpThreshold, threw, frameSilent, clsWindows }));
JS
)
  [ "$got" = '{"logs":["[cwv] LCP_ms=1200","[cwv] LCP_ms=1501","[cwv] CLS=0.05","[cwv] CLS=0.07","[cwv] INP_ms=80"],"buffered":true,"inpThreshold":true,"threw":false,"frameSilent":true,"clsWindows":"[cwv] CLS=0.1|[cwv] CLS=0.12"}' ]
  check $? "site-vitals.js logs each metric once per distinct value, CLS as the largest session window, top frame only (got $got)"
}

case_cancel() { # a cancelled run during the wait exits quietly: no comment, no stop
  # Two shapes: the signal reaches only the wait's children (the sleep dies, the script sees it
  # fail), or the whole tree, the script included.
  local mode pid i
  kill_tree() { local c; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; kill -TERM "$1" 2>/dev/null; }
  kill_children() { local c; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; }
  for mode in children tree; do
    setup
    deployment 101
    fx statuses "$(status pending)"
    # A real, short sleep, so that the signal lands during the wait.
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexec /bin/sleep 3\n' "$T/sleep.log" >"$T/bin/sleep"
    PATH="$T/bin:$STUB_BIN:$PATH" "$SCRIPT" >"$T/err" 2>&1 &
    pid=$! i=0
    while [ "$(sleeps)" -eq 0 ] && [ "$i" -lt 100 ]; do i=$((i + 1)); /bin/sleep 0.1; done
    /bin/sleep 0.2
    [ "$(sleeps)" -gt 0 ]; check $? "$mode: the script reached the wait"
    if [ "$mode" = children ]; then kill_children "$pid"; else kill_tree "$pid"; fi
    wait "$pid" 2>/dev/null; RC=$?
    ERR=$(cat "$T/err")
    expect_rc 143
    [ "$(comments)" -eq 0 ]; check $? "$mode: no comment on a cancel (got $(comments): $(body))"
    expect_no_out status
  done
}

# --- the workflow (code-review.yml) ---------------------------------------------------------

steps() { yq -r '.jobs.review.steps[].name' "$WF"; }
step() { yq -r ".jobs.review.steps[] | select(.name == \"$1\") | $2" "$WF"; }
claude_args() { step 'Code review' '.with.claude_args'; }
position() { steps | grep -nxF "$1" | cut -d: -f1; }

case_ac12() { # exactly the eleven browser tools, appended to --allowedTools only with a site
  deployment 101
  fx statuses "$(status success "$PREVIEW")"
  run_script; expect_rc 0
  local want t
  want='mcp__playwright__browser_navigate,mcp__playwright__browser_snapshot,mcp__playwright__browser_take_screenshot,mcp__playwright__browser_console_messages,mcp__playwright__browser_network_requests,mcp__playwright__browser_network_request,mcp__playwright__browser_wait_for,mcp__playwright__browser_click,mcp__playwright__browser_hover,mcp__playwright__browser_press_key,mcp__playwright__browser_resize'
  expect_out browser-tools "$want"
  for t in browser_evaluate browser_run_code_unsafe browser_file_upload; do
    ! grep -q "$t" "$SCRIPT"; check $? "$t is never named in the resolver"
    ! grep -q "$t" "$WF"; check $? "$t is never named in the workflow"
  done
  # The workflow appends that output, and only that output, inside --allowedTools, also when the
  # caller's allowed-tools is empty: a started browser server must not have every tool denied.
  # Gated on the prompt naming the site (site-checked from the context step), never on the site
  # status alone: a resolved site whose block is missing gets no browser.
  claude_args | grep -qF "(inputs.allowed-tools != '' || steps.context.outputs.site-checked == 'true') && format('--allowedTools \"{0}{1}{2}\"', inputs.allowed-tools, (inputs.allowed-tools != '' && steps.context.outputs.site-checked == 'true') && ',' || '', steps.context.outputs.site-checked == 'true' && steps.site.outputs.browser-tools || '') || ''"
  check $? "claude_args joins allowed-tools and the browser tools in --allowedTools only with site-checked (got: $(claude_args))"
  ! yq -r '.on.workflow_call.inputs.allowed-tools.default' "$WF" | grep -q playwright
  check $? "the allowed-tools default names no browser tool"
}

case_wiring() { # the step's place, its inputs, and what a stop skips
  [ "$(yq -r '.on.workflow_call.inputs.site-url-template.default' "$WF")" = '${{ vars.SITE_URL_TEMPLATE }}' ]
  check $? "site-url-template defaults to the SITE_URL_TEMPLATE variable"
  [ "$(yq -r '.on.workflow_call.inputs.site-url-template.required' "$WF")" = false ]; check $? "site-url-template is optional"
  [ "$(step 'Resolve preview site' '.id')" = site ]; check $? "the step has id site"
  [ "$(position 'Acknowledge request')" -lt "$(position 'Resolve preview site')" ]; check $? "the eyes reaction comes before the wait"
  [ "$(position 'Checkout platform repo (for the context script)')" -lt "$(position 'Resolve preview site')" ]
  check $? "after the platform checkout"
  [ "$(position 'Resolve preview site')" -lt "$(position 'Resolve review context')" ]; check $? "before the context step, which deletes .platform"
  ! step 'Resolve preview site' '.run' | grep -q '\${{'; check $? "no expression inside its run:"
  [ "$(step 'Resolve preview site' '.env.SITE_URL_TEMPLATE')" = '${{ inputs.site-url-template }}' ]; check $? "the template arrives through env"
  [ "$(step 'Resolve review context' '.env.SITE_STATUS')" = '${{ steps.site.outputs.status }}' ]; check $? "SITE_STATUS reaches the context step"
  [ "$(step 'Resolve review context' '.env.SITE_URL')" = '${{ steps.site.outputs.site-url }}' ]; check $? "SITE_URL reaches the context step"
  [ "$(step 'Resolve review context' '.env.SITE_VITALS_TAG')" = '${{ steps.site.outputs.vitals-tag }}' ]; check $? "SITE_VITALS_TAG reaches the context step"
  local s
  for s in 'Resolve review context' 'Checkout pull request head' 'Code review' 'Checkout platform repo (for the guard script)' \
    'Verify review outcome' 'Report run telemetry'; do
    step "$s" '.if' | grep -qF "steps.site.outputs.status != 'stop'"; check $? "$s is skipped after a stop"
  done
  # The always() steps run only when the site step succeeded: one that failed without writing a
  # status, or was cancelled during the wait for the preview, must not reach the guard as a review
  # that ended `skipped`.
  for s in 'Checkout platform repo (for the guard script)' 'Verify review outcome' 'Report run telemetry'; do
    step "$s" '.if' | grep -qF "steps.site.outcome == 'success'"; check $? "$s is skipped unless the site step succeeded"
    ! step "$s" '.if' | grep -qF "steps.site.outcome != 'failure'"; check $? "$s does not let a cancelled site step through"
    # A failed (or cancelled) browser install stopped the review with its own comment: the guard
    # must not report it again as a review that ended `skipped`.
    step "$s" '.if' | grep -qF "(steps.pwmcp.outcome == 'success' || steps.pwmcp.outcome == 'skipped')"
    check $? "$s is skipped unless the browser install succeeded or had no site to install for"
  done
}

# Runs the workflow step's own `run:` in an empty workspace (no .platform), the way the runner does.
run_step() {
  mkdir -p "$T/ws"
  step 'Resolve preview site' '.run' >"$T/step.sh"
  (cd "$T/ws" && PATH="$T/bin:$STUB_BIN:$PATH" bash --noprofile --norc -eo pipefail "$T/step.sh") >"$T/err" 2>&1
  RC=$?
  ERR=$(cat "$T/err")
}
case_step_no_script() { # no template: none without the script; a template without it: a stop
  SITE_URL_TEMPLATE=''
  run_step; expect_rc 0
  expect_out status none
  [ ! -s "$STUB_DIR/calls.log" ]; check $? "no gh call"
  setup
  export CHECKOUT_OUTCOME=failure
  run_step
  expect_stop error
  body_has 'the preview site could not be resolved'
  ! body | grep -q '^ '; check $? "the comment body is not indented (got: $(body))"
  unset CHECKOUT_OUTCOME
}

# Runs the `Install Playwright MCP` step's own `run:` with a stub npm that exits with $1.
run_install_step() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit %s\n' "$T/npm.log" "$1" >"$T/bin/npm"
  chmod +x "$T/bin/npm"
  mkdir -p "$T/ws"
  step 'Install Playwright MCP' '.run' >"$T/install.sh"
  (cd "$T/ws" && PATH="$T/bin:$STUB_BIN:$PATH" bash --noprofile --norc -eo pipefail "$T/install.sh") >"$T/err" 2>&1
  RC=$?
  ERR=$(cat "$T/err")
}
case_step_install() { # a failed install stops the review with a comment; a good one is silent
  run_install_step 0; expect_rc 0
  [ ! -s "$STUB_DIR/calls.log" ]; check $? "no gh call when the install succeeds"
  grep -qxF "ci --ignore-scripts --no-audit --no-fund --prefix $RUNNER_TEMP/pwmcp" "$T/npm.log"
  check $? "npm ci runs with --ignore-scripts under RUNNER_TEMP (got: $(cat "$T/npm.log"))"
  setup
  run_install_step 1; expect_rc 1
  [ "$(comments)" -eq 1 ]; check $? "one comment on the pull request (got $(comments))"
  grep -q '^pr comment 50 --repo acme/app --body' "$STUB_DIR/calls.log"; check $? "the comment goes to pull request 50 of acme/app"
  body_has 'Code review not run: the browser for the preview site could not be installed.'
  body_has "$RUN_URL"
  ! body | grep -q '^ '; check $? "the comment body is not indented (got: $(body))"
  printf '%s' "$ERR" | grep -qF '::error::[code-review] preview site: the Playwright MCP could not be installed'
  check $? "the step logs the stop (got: $ERR)"
  [ "$(step 'Install Playwright MCP' '.env.PR_NUMBER')" = '${{ github.event.issue.number }}' ]; check $? "PR_NUMBER arrives through env"
  ! step 'Install Playwright MCP' '.run' | grep -q '\${{'; check $? "no expression inside its run:"
}

case_ac13() { # the MCP config goes inline, so the action keeps its inline-comment server
  deployment 101
  fx statuses "$(status success "$PREVIEW")"
  run_script; expect_rc 0
  [ "$(outv mcp-config | jq -r '.mcpServers | keys | join(",")')" = playwright ]
  check $? "the config defines the playwright server only, never the action's own"
  ! outv mcp-config | grep -q "'"; check $? "the config has no single quote (it is single-quoted in claude_args)"
  claude_args | grep -qF "steps.context.outputs.site-checked == 'true' && format(' --mcp-config ''{0}''', steps.site.outputs.mcp-config) || ''"
  check $? "claude_args passes the config inline, only when the prompt names the site (got: $(claude_args))"
  ! claude_args | grep -qF "steps.site.outputs.status == 'ready'"; check $? "claude_args never gates the browser on the site status alone"
  yq -r '.on.workflow_call.inputs.allowed-tools.default' "$WF" | tr ',' '\n' | grep -qx mcp__github_inline_comment__create_inline_comment
  check $? "the inline-comment tool stays allowed"
  [ "$(step 'Install Playwright MCP' '.if')" = "steps.site.outputs.status == 'ready'" ]; check $? "the MCP is installed only with a site"
  [ "$(step 'Install Playwright MCP' '.continue-on-error')" = null ]; check $? "a failed install fails the step (no continue-on-error)"
  [ "$(step 'Install Playwright MCP' '.id')" = pwmcp ]; check $? "the install step has id pwmcp"
  step 'Install Playwright MCP' '.run' | grep -qxF 'if npm ci --ignore-scripts --no-audit --no-fund --prefix "$RUNNER_TEMP/pwmcp"; then'
  check $? "installed with npm ci and --ignore-scripts, where the config points"
  cmp -s "$ROOT/.github/scripts/playwright-mcp/package-lock.json" "$RUNNER_TEMP/pwmcp/package-lock.json" \
    && cmp -s "$ROOT/.github/scripts/playwright-mcp/package.json" "$RUNNER_TEMP/pwmcp/package.json"
  check $? "the manifest and the lockfile are copied where npm ci runs"
  local lock=$ROOT/.github/scripts/playwright-mcp/package-lock.json
  jq -e '.packages | to_entries | map(select(.key != "")) | length > 0 and all(.[].value;
      (.version | test("^[0-9]")) and (.resolved | startswith("https://registry.npmjs.org/"))
      and (.integrity | startswith("sha512-")) and (.hasInstallScript | not))' "$lock" >/dev/null
  check $? "every locked package has an exact version, the npm registry, a sha512 integrity and no install script"
  [ "$(jq -r '.dependencies["@playwright/mcp"]' "$ROOT/.github/scripts/playwright-mcp/package.json")" = \
    "$(jq -r '.packages["node_modules/@playwright/mcp"].version' "$lock")" ]
  check $? "the manifest pins the exact version the lockfile holds"
  outv mcp-config | jq -e '.mcpServers.playwright.args | index("--ignore-roots") != null' >/dev/null
  check $? "the MCP ignores the client's roots, so its workspace is not the checkout"
  [ "$(position 'Resolve preview site')" -lt "$(position 'Install Playwright MCP')" ] && [ "$(position 'Install Playwright MCP')" -lt "$(position 'Code review')" ]
  check $? "installed between the site step and the review"
}

# --- runner ----------------------------------------------------------------------------------

ALL=(ac1 blank_template none_template jq_status ac2 ac3 ac4 ac5 ac6 ac7 ac8 error retry cancel vitals ac12 wiring step_no_script step_install ac13)
[ $# -gt 0 ] && ALL=("$@")

failed=()
n=0
for c in "${ALL[@]}"; do
  n=$((n + 1))
  setup
  CASE_FAIL=0
  if declare -F "case_$c" >/dev/null; then
    "case_$c"
  else
    check 1 "no such case: $c"
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
