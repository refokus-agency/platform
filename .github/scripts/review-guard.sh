#!/usr/bin/env bash
#
# Verifies that a code review run actually reviewed something, and says so on the pull request
# when it did not.
#
# The action runs with show_full_output false by default, so Claude's own output never reaches
# the run log: a deliberate decline, a crash that swallowed its error, and a review whose
# subagents never launched are all the same thing from the outside — a green check and silence.
# This script reads the transcript the action leaves behind, turns it into four booleans, and
# makes each of those outcomes visible on the pull request.
#
# It runs AFTER the review and never gates it. The worst case is a red advisory job carrying an
# explanation, never a review that did not happen because the guard broke.
#
# Environment:
#   EXECUTION_FILE     path to claude-code-action's `execution_file` output — the raw
#                      SDKMessage[] transcript in $RUNNER_TEMP
#   REVIEW_CONCLUSION  the action's `conclusion` output: success | failure
#   REVIEW_OUTCOME     the `Code review` step's own outcome: success | failure | cancelled
#   PR_NUMBER          pull request to comment on
#   GH_TOKEN           token with pull-requests: write
#   GITHUB_REPOSITORY, GITHUB_SERVER_URL, GITHUB_RUN_ID — supplied by the runner
#
# The transcript is the UNSANITIZED tool output and this job runs on public repositories, so no
# part of it is ever printed to the log or included in a comment. Only the booleans leave here.

set -euo pipefail

# Both spellings of the fan-out tool, exactly as the `allowed-tools` default lists them: the CLI
# has named it `Task` and `Agent` across versions, and claude-code-action@v1 pins its own moving
# CLI version. A name matching no tool is inert, so checking both costs nothing and stops a CLI
# bump from turning a healthy review into a false "did not run".
FANOUT_TOOLS=(Task Agent)

TROUBLESHOOTING='https://github.com/refokus-agency/platform/blob/main/docs/troubleshooting.md#code-review-finishes-green-but-posts-no-comment'

# --- signals -----------------------------------------------------------------------------------

# Is the transcript there and parseable? Nothing else — the detectors below assume it.
read_transcript() {
  [ -n "${EXECUTION_FILE:-}" ] || return 1
  [ -s "$EXECUTION_FILE" ] || return 1
  jq empty <"$EXECUTION_FILE" >/dev/null 2>&1
}

# Any tool_use anywhere in the transcript carrying one of the given names. The recursive descent
# is deliberate: tool_use blocks are nested inside assistant messages today, and this survives
# upstream moving them.
#
# Know what this proves and what it does not. The plugin command's eligibility check launches a
# subagent UNCONDITIONALLY, before it evaluates any stop condition, so this goes true the moment the
# command starts executing at all. That makes it a reliable detector of the failure it was
# written for — an `allowed-tools` allowlist missing `Skill` or `Task`, where the orchestrator
# improvises a review and never fans out — and NOT a proof that the review reached the diff.
# The comment text on that path is worded to claim only what this actually establishes.
has_tool_use() {
  jq -e --args '
    [.. | objects | select(.type? == "tool_use") | .name] as $used
    | any($used[]; . as $name | $ARGS.positional | index($name) != null)
  ' "$@" <"$EXECUTION_FILE" >/dev/null 2>&1
}

# Did the review actually say something on the pull request? Two shapes, and the second cannot be
# resolved by tool name alone — `Bash` is also how the review reads the diff — so this one has to
# look at the command itself.
#
# The match is ANCHORED, not a substring search. `gh pr comment` appearing anywhere in a command
# is not evidence that a comment was posted: `grep -rn "gh pr comment" .github/` contains it and
# posts nothing. A false "it commented" is the same class of bug this whole script exists to
# remove, so the phrase has to be what the command actually invokes — allowing for a leading
# `cd ... &&`, a pipeline segment or a `;` sequence in front of it.
#
# And a call is an attempt, not a comment. The allowlist matches `gh pr comment` by prefix and
# denies a command carrying a shell construct, and a denied or failed call still leaves its
# tool_use behind. So a call only counts when its own tool_result came back without `is_error`.
# A call with no result at all — the run ended under it — does not count either. Both ids must be
# present: without that, a tool_use with no `id` would pair with any result lacking `tool_use_id`
# (null == null), and a drift in the transcript shape would read as "it commented".
#
# The two shapes are told apart because they are not the same comment: `summary` is a
# `gh pr comment`, the one the `prompt` default requires on every review; `inline` is a finding
# posted on a line. A review that posted findings and lost its summary has still said something,
# but not what it owed.
has_comment_signal() {
  local kind="$1"
  jq -e --arg kind "$kind" '
    [.. | objects | select(.type? == "tool_result" and .is_error? != true and .tool_use_id? != null) | .tool_use_id] as $ok
    | [.. | objects | select(.type? == "tool_use")] as $used
    | any($used[];
        (.id? != null and (.id as $id | any($ok[]; . == $id)))
        and (if $kind == "inline" then
               .name == "mcp__github_inline_comment__create_inline_comment"
             else
               .name == "Bash"
               and ((.input.command? // "")
                    | tostring
                    | test("(^|[;&|]|&&|\\|\\|)[[:space:]]*gh[[:space:]]+pr[[:space:]]+comment\\b"))
             end))
  ' <"$EXECUTION_FILE" >/dev/null 2>&1
}

# --- decision ----------------------------------------------------------------------------------

# Pure: takes the six signals, prints the action on the first line and the comment body on the
# rest. No I/O, no `gh`, no environment — so the decision table can be tested on its own.
#
#   conclusion / step | fan-out ran | summary | inline | action
#   ------------------+-------------+---------+--------+-------------------------------------------
#   cancelled         | *           | *       | *      | pass  — somebody stopped it on purpose
#   failed            | *           | *       | *      | fail  — post a failure notice, red job
#   unreadable        | *           | *       | *      | fail  — post "could not verify", red job
#   success           | yes         | yes     | *      | pass  — post nothing, green job
#   success           | yes         | no      | yes    | post  — "findings, but no summary", green job
#   success           | yes         | no      | no     | post  — "ran, ended without a word", green job
#   success           | no          | yes     | *      | pass  — a deliberate decline, green job
#   success           | no          | no      | yes    | pass  — a deliberate decline, green job
#   success           | no          | no      | no     | fail  — post "did not run", red job
decide() {
  local step_outcome="$1" conclusion="$2" transcript_readable="$3" fanout_ran="$4" summary_posted="$5" inline_posted="$6"

  # A cancelled run is not a broken one. Somebody pressed the button, they know the review did not
  # finish, and "treat this pull request as unreviewed" on a deliberate cancellation is noise.
  if [ "$step_outcome" = cancelled ]; then
    printf 'pass\n'
    return
  fi

  # Precedence, not convenience: a broken run must never be reported as "found nothing", so the
  # outcome of the step and the action's own conclusion are read before any transcript signal.
  if [ "$step_outcome" != success ] || [ "$conclusion" = failure ]; then
    printf 'fail\n'
    printf '**Code review did not complete.**\n\n'
    printf 'The review step ended as `%s` and the action reported `conclusion: %s`. Whatever the review found — if it reached the diff at all — went down with the run, so treat this pull request as unreviewed.\n\n' \
      "${step_outcome:-unknown}" "${conclusion:-unknown}"
    printf 'Comment the trigger phrase again to retry. If it keeps failing, see [troubleshooting](%s).\n' "$TROUBLESHOOTING"
    return
  fi

  # The step finished clean but left nothing to check. That is not a pass: it is the one state
  # where this guard cannot tell a real review from a run that stopped early.
  if [ "$transcript_readable" != true ]; then
    printf 'fail\n'
    printf '**Code review outcome could not be verified.**\n\n'
    printf 'The review step finished green, but the run transcript it should have left behind is missing or unreadable — so nothing here can distinguish a completed review from one that stopped early. Treat this pull request as unreviewed and comment the trigger phrase again.\n'
    return
  fi

  if [ "$summary_posted" = true ]; then
    printf 'pass\n'
    return
  fi

  if [ "$fanout_ran" != true ] && [ "$inline_posted" = true ]; then
    # The fan-out-less decline, said out loud: a valid outcome. Only silence is a bug.
    printf 'pass\n'
    return
  fi

  if [ "$fanout_ran" = true ] && [ "$inline_posted" = true ]; then
    # Green, not red: the findings are on the pull request and nothing about them is wrong. What
    # is missing is the overview beside them, most often because its `gh pr comment` was refused.
    # A caller that overrides `prompt` drops the summary-on-every-review rule, and upstream then
    # posts findings with no summary by design — this note fires on every such review, which is
    # why it names that case instead of calling it a failure.
    printf 'post\n'
    printf '**Code review posted its findings but no summary.**\n\n'
    printf 'The inline findings above are the output of the review and stand on their own. The summary comment that should sit beside them — what was checked and how many findings per verdict — did not go up, most often because the call that posted it was refused. Read the findings as they are; comment the trigger phrase again if you want the overview.\n\n'
    printf 'If your caller workflow overrides `prompt`, this is expected: the summary-on-every-review rule lives in the `prompt` default. See [troubleshooting](%s).\n' "$TROUBLESHOOTING"
    return
  fi

  if [ "$fanout_ran" = true ]; then
    printf 'post\n'
    printf '**Code review ran and ended without posting anything.**\n\n'
    printf 'The review started and launched subagents, then finished without saying a word on this pull request — most often because it found nothing to report, but possibly because it stopped early instead, or because the comment it tried to post was refused. This note stands in for the comment it owed you either way: an empty review and a review that quietly gave up are indistinguishable in silence.\n'
    return
  fi

  printf 'fail\n'
  printf '**Code review did not actually run.**\n\n'
  printf 'The step finished green, but the transcript shows no subagent fan-out and no comment: the review never reached the diff. The usual cause is a caller overriding `allowed-tools` or `prompt` with a value that drops the tools the plugin command needs to execute.\n\n'
  printf 'See [troubleshooting](%s).\n' "$TROUBLESHOOTING"
}

# --- orchestration -----------------------------------------------------------------------------

# The only function with side effects: gather the signals, hand them to `decide`, act on what it
# says.
main() {
  local transcript_readable=false fanout_ran=false summary_posted=false inline_posted=false

  if read_transcript; then
    transcript_readable=true
    has_tool_use "${FANOUT_TOOLS[@]}" && fanout_ran=true
    has_comment_signal summary && summary_posted=true
    has_comment_signal inline && inline_posted=true
  fi

  echo "::notice::[code-review] guard: step=${REVIEW_OUTCOME:-unknown} conclusion=${REVIEW_CONCLUSION:-unknown} transcript_readable=${transcript_readable} fanout_ran=${fanout_ran} summary_posted=${summary_posted} inline_posted=${inline_posted}"

  local decision action body
  decision=$(decide "${REVIEW_OUTCOME:-}" "${REVIEW_CONCLUSION:-}" "$transcript_readable" "$fanout_ran" "$summary_posted" "$inline_posted")
  action=$(printf '%s' "$decision" | head -n 1)
  body=$(printf '%s' "$decision" | tail -n +2)

  if [ "$action" = pass ]; then
    echo "::notice::[code-review] nothing to report: the review either spoke for itself or was cancelled."
    return 0
  fi

  body="${body}"$'\n\n'"— [run log](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})"

  # A failure to post is itself the silence this change exists to remove, so it is never
  # swallowed. The usual cause is a caller that did not grant `pull-requests: write`.
  if ! gh pr comment "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --body "$body"; then
    echo "::error::[code-review] the guard could not comment on pull request #${PR_NUMBER}. Grant the caller workflow \`pull-requests: write\`."
    return 1
  fi

  if [ "$action" = fail ]; then
    echo "::error::[code-review] the review did not produce a usable result — see the comment on pull request #${PR_NUMBER}."
    return 1
  fi

  return 0
}

# Executed, not sourced — so a test can source this file and call `decide` directly without the
# side effects in `main`. This is the seam the self-test of #123 hangs off.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  main "$@"
fi
