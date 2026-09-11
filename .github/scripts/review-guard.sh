#!/usr/bin/env bash
#
# Verifies that a code review run actually reviewed something, and says so on the pull request
# when it did not.
#
# The action runs with show_full_output false by default, so Claude's own output never reaches
# the run log: a deliberate decline, a crash that swallowed its error, and a review whose
# subagents never launched are all the same thing from the outside — a green check and silence.
# This script reads the transcript the action leaves behind, turns it into three booleans, and
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

# Is the transcript there and parseable? Nothing else — the three detectors below assume it.
read_transcript() {
  [ -n "${EXECUTION_FILE:-}" ] || return 1
  [ -s "$EXECUTION_FILE" ] || return 1
  jq empty <"$EXECUTION_FILE" >/dev/null 2>&1
}

# Any tool_use anywhere in the transcript carrying one of the given names. The recursive descent
# is deliberate: tool_use blocks are nested inside assistant messages today, and this survives
# upstream moving them.
#
# Know what this proves and what it does not. The plugin command's step 1 launches a subagent
# UNCONDITIONALLY, before it evaluates any stop condition, so this goes true the moment the
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
has_comment_signal() {
  jq -e '
    [.. | objects | select(.type? == "tool_use")] as $used
    | any($used[];
        .name == "mcp__github_inline_comment__create_inline_comment"
        or (.name == "Bash"
            and ((.input.command? // "")
                 | tostring
                 | test("(^|[;&|]|&&|\\|\\|)[[:space:]]*gh[[:space:]]+pr[[:space:]]+comment\\b"))))
  ' <"$EXECUTION_FILE" >/dev/null 2>&1
}

# --- decision ----------------------------------------------------------------------------------

# Pure: takes the five signals, prints the action on the first line and the comment body on the
# rest. No I/O, no `gh`, no environment — so the decision table can be tested on its own.
#
#   conclusion / step | fan-out ran | commented | action
#   ------------------+-------------+-----------+------------------------------------------
#   cancelled         | *           | *         | pass  — somebody stopped it on purpose
#   failed            | *           | *         | fail  — post a failure notice, red job
#   unreadable        | *           | *         | fail  — post "could not verify", red job
#   success           | yes         | yes       | pass  — post nothing, green job
#   success           | yes         | no        | post  — "ran, ended without a word", green job
#   success           | no          | yes       | pass  — a deliberate decline, green job
#   success           | no          | no        | fail  — post "did not run", red job
decide() {
  local step_outcome="$1" conclusion="$2" transcript_readable="$3" fanout_ran="$4" comment_posted="$5"

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

  if [ "$comment_posted" = true ]; then
    # Includes the fan-out-less case on purpose: the review spoke, and a decline stated out loud
    # is a valid outcome. Only silence is a bug.
    printf 'pass\n'
    return
  fi

  if [ "$fanout_ran" = true ]; then
    printf 'post\n'
    printf '**Code review ran and ended without posting anything.**\n\n'
    printf 'The review started and launched subagents, then finished without saying a word on this pull request — most often because it found nothing to report, but possibly because it stopped early instead. This note stands in for the comment it owed you either way: an empty review and a review that quietly gave up are indistinguishable in silence.\n'
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
  local transcript_readable=false fanout_ran=false comment_posted=false

  if read_transcript; then
    transcript_readable=true
    has_tool_use "${FANOUT_TOOLS[@]}" && fanout_ran=true
    has_comment_signal && comment_posted=true
  fi

  echo "::notice::[code-review] guard: step=${REVIEW_OUTCOME:-unknown} conclusion=${REVIEW_CONCLUSION:-unknown} transcript_readable=${transcript_readable} fanout_ran=${fanout_ran} comment_posted=${comment_posted}"

  local decision action body
  decision=$(decide "${REVIEW_OUTCOME:-}" "${REVIEW_CONCLUSION:-}" "$transcript_readable" "$fanout_ran" "$comment_posted")
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
# side effects in `main`. This is the seam the follow-up test issue hangs off.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  main "$@"
fi
