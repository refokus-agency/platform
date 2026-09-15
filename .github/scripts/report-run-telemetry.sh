#!/usr/bin/env bash
#
# Reports what a code review run cost and how much context each of its agents consumed, as its
# own comment on the pull request.
#
# The action hides Claude's output from the run log, so the only trace a finished review leaves
# behind is the transcript it writes to disk. That transcript already carries the run's cost and
# every agent's token usage; without this step nobody ever sees either. This reads it, renders
# the numbers, and posts them.
#
# It reports figures and nothing else. There is no verdict here: no threshold, no colour, no
# pass or fail derived from context. The reader compares the numbers against whatever yardstick
# they care about — that judgement is theirs, not this script's.
#
# Environment:
#   EXECUTION_FILE     path to claude-code-action's `execution_file` output — the raw
#                      SDKMessage[] transcript in $RUNNER_TEMP
#   PR_NUMBER          pull request to comment on
#   GH_TOKEN           token with pull-requests: write
#   GITHUB_REPOSITORY, GITHUB_SERVER_URL, GITHUB_RUN_ID — supplied by the runner
#
# THIS SCRIPT MUST NEVER EXIT NON-ZERO. That is the one hard rule, and it is the deliberate
# divergence from its sibling `review-guard.sh`, which is allowed to go red because an
# unverified review is a result the caller has to see. Telemetry is not a verdict — it is
# additive information — and `@v1` is force-moved onto every consumer repo in the org, so a
# telemetry bug must never be able to redden a CI check anywhere. The closer precedent is
# `record-github-deployment.cjs`: catch, warn, return normally. Every failure path below emits
# a `::notice::` and returns 0, and the workflow step carries `continue-on-error: true` on top.
#
# The transcript is UNSANITIZED tool output and this job runs on public repositories, so no part
# of it is ever printed or included in a comment. Only numbers, model names and subagent type
# names leave here — never prompt text, tool input, tool output or file contents.

set -euo pipefail

notice() {
  echo "::notice::[code-review] telemetry: $1"
}

# --- pure formatting ----------------------------------------------------------------------------

# `read` with a whitespace IFS collapses runs of tabs, which would silently shift every field
# after an empty one — and empty is a legal value for most fields in both records below. So the
# split is done by hand: an empty field stays an empty field.
tsv_field() {
  local line="$1" index="$2" i=1
  while [ "$i" -lt "$index" ]; do
    case "$line" in
      *$'\t'*) line="${line#*$'\t'}" ;;
      *) return 0 ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "${line%%$'\t'*}"
}

# Token count -> `142k`. Truncating, not rounding: this is a magnitude for a human to eyeball
# against a context window, and a number that reads slightly low is the safer error.
format_k() {
  local tokens="${1:-}"
  case "$tokens" in
    '' | *[!0-9]*) printf '—'; return 0 ;;
  esac
  if [ "$tokens" -lt 1000 ]; then
    printf '<1k'
  else
    printf '%sk' "$((tokens / 1000))"
  fi
}

# Milliseconds -> `3m 12s`. Empty output for anything unparseable, which the renderer drops.
format_duration() {
  local ms="${1:-}"
  case "$ms" in
    '' | *[!0-9]*) return 0 ;;
  esac
  local total=$((ms / 1000)) hours minutes seconds
  hours=$((total / 3600))
  minutes=$(((total % 3600) / 60))
  seconds=$((total % 60))
  if [ "$hours" -gt 0 ]; then
    printf '%dh %dm' "$hours" "$minutes"
  elif [ "$minutes" -gt 0 ]; then
    printf '%dm %ds' "$minutes" "$seconds"
  else
    printf '%ds' "$seconds"
  fi
}

# --- extraction ---------------------------------------------------------------------------------

# Transcript on stdin -> exactly one RunSummary line:
#   total_cost_usd \t num_turns \t duration_ms \t subtype \t is_error \t orchestrator_model
#
# Any field that cannot be derived is the empty string and the renderer omits it. `total_cost_usd`
# is CUMULATIVE across the run, so the last `result` message is the whole answer — summing them
# double-counts.
extract_run_summary() {
  jq -r '
    def s($v): if $v == null then "" else ($v | tostring) end;
    . as $root
    | ([$root[]? | select(type == "object" and .type? == "result")] | last) as $result
    | ([$root[]? | select(type == "object" and .type? == "system") | .model? | select(. != null)] | first) as $init_model
    | [ s($result.total_cost_usd),
        s($result.num_turns),
        s($result.duration_ms),
        s($result.subtype),
        s($result.is_error),
        s($init_model) ]
    | @tsv
  '
}

# Transcript on stdin -> zero or more AgentRow lines:
#   is_main (1|0) \t label \t context_tokens \t model
#
# CONTEXT IS THE LAST MESSAGE, NEVER A SUM. Each assistant message reports the window the agent
# was holding at that turn, and that figure only grows, so the final message already IS the
# maximum. Adding them up reports roughly 25x the truth — measured on real transcripts, a main
# agent that went 71k -> 90k sums to 2,241k and a subagent that went 66k -> 120k sums to 3,230k.
# A number that wrong is worse than no number at all, because it is plausible.
#
# Agents are separated by `parent_tool_use_id`: null is the orchestrator, any value is one Task
# subagent invocation. Subagent order is order of first appearance — `group_by` would sort them
# by a random tool-use id instead.
extract_agent_rows() {
  jq -r '
    def ctx: (.message.usage // {})
      | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0));
    # The comment body is a markdown table, so a pipe or a newline reaching a cell would break
    # the rendering of every row after it.
    def clean: (. // "") | tostring | gsub("[|\\n\\r]"; " ") | gsub("^\\s+|\\s+$"; "");

    . as $root
    | [$root[]? | select(type == "object" and .type? == "assistant")] as $agents
    | [$agents[] | select(.parent_tool_use_id == null)] as $main
    | [$agents[] | select(.parent_tool_use_id != null)] as $subs
    | (reduce $subs[] as $m ([];
        if index($m.parent_tool_use_id) then . else . + [$m.parent_tool_use_id] end)) as $ids
    | (
        (if ($main | length) > 0
         then ["1", "main",
               ($main[-1] | ctx | tostring),
               ([$main[] | .message.model? | select(. != null)] | last // "" | clean)]
         else empty end),
        ($ids[] as $id
         | [$subs[] | select(.parent_tool_use_id == $id)] as $group
         | ["0",
            ([$group[] | .subagent_type? | select(. != null)] | first // "subagent" | clean),
            ($group[-1] | ctx | tostring),
            ([$group[] | .message.model? | select(. != null)] | last // "" | clean)])
      )
    | @tsv
  '
}

# True when the transcript shows the review fanned out but carries no itemised usage for any of
# the agents it fanned out to.
#
# This is the upstream-drift contingency. If `claude-code-action` stops emitting
# `parent_tool_use_id`, every subagent message becomes indistinguishable from an orchestrator
# one and the main row would silently absorb all of them — a single plausible, wrong number. In
# that state the per-agent block is dropped entirely rather than rendered with the main agent
# standing alone. Both spellings of the fan-out tool are checked, for the reason `review-guard.sh`
# gives at its own FANOUT_TOOLS.
has_unitemised_subagents() {
  jq -e '
    . as $root
    | ([$root | .. | objects
        | select(.type? == "tool_use" and (.name? == "Task" or .name? == "Agent"))] | length > 0)
      and ([$root[]? | select(type == "object" and .type? == "assistant" and .parent_tool_use_id != null)] | length == 0)
  ' >/dev/null 2>&1
}

# --- rendering ----------------------------------------------------------------------------------

# RunSummary line + AgentRow lines + run log URL -> the comment body. Pure: no I/O, no network,
# no environment. Every part is optional, so a transcript that yields only half the figures still
# produces a sensible comment.
render_comment() {
  local summary="$1" rows="${2:-}" run_log="${3:-}"
  local cost turns duration_ms init_model
  cost=$(tsv_field "$summary" 1)
  turns=$(tsv_field "$summary" 2)
  duration_ms=$(tsv_field "$summary" 3)
  init_model=$(tsv_field "$summary" 6)

  local -a facts=()
  case "$cost" in
    '' | *[!0-9.]*) ;;
    *) facts+=("**Cost** \$$(LC_NUMERIC=C printf '%.4f' "$cost")") ;;
  esac
  case "$turns" in
    '' | *[!0-9]*) ;;
    *) facts+=("**Turns** $turns") ;;
  esac
  local duration
  duration=$(format_duration "$duration_ms")
  [ -n "$duration" ] && facts+=("**Duration** $duration")

  printf '### Run telemetry\n'

  if [ "${#facts[@]}" -gt 0 ]; then
    local joined="${facts[0]}" i
    for ((i = 1; i < ${#facts[@]}; i++)); do
      joined+=" · ${facts[i]}"
    done
    printf '\n%s\n' "$joined"
  fi

  if [ -n "$rows" ]; then
    printf '\n| Agent | Context | Model |\n|---|---|---|\n'
    local row is_main label context model
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      is_main=$(tsv_field "$row" 1)
      label=$(tsv_field "$row" 2)
      context=$(tsv_field "$row" 3)
      model=$(tsv_field "$row" 4)
      # The orchestrator is marked three ways at once — a glyph, bold, and the word itself —
      # because the one thing a reader must not do is mistake a subagent's context for the
      # run's own.
      if [ "$is_main" = '1' ]; then
        [ -n "$model" ] || model="$init_model"
        printf '| **⬥ %s** (orchestrator) | **%s** | %s |\n' \
          "$label" "$(format_k "$context")" "${model:-—}"
      else
        printf '| ↳ %s | %s | %s |\n' \
          "$label" "$(format_k "$context")" "${model:-—}"
      fi
    done <<<"$rows"
  fi

  printf '\n<sub>Context is the window each agent was holding on its final turn, not a sum across its turns.'
  if [ -n "$run_log" ]; then
    printf ' — [run log](%s)' "$run_log"
  fi
  printf '</sub>\n'
}

# --- orchestration --------------------------------------------------------------------------------

# Everything with a side effect. Returns 0 on every path it knows about; `main` catches the ones
# it does not.
run() {
  local file="${EXECUTION_FILE:-}"

  if [ -z "$file" ] || [ ! -s "$file" ]; then
    notice "no run transcript to report on. Nothing posted."
    return 0
  fi

  if ! jq empty <"$file" >/dev/null 2>&1; then
    notice "the run transcript is not valid JSON. Nothing posted."
    return 0
  fi

  local summary rows=''
  if ! summary=$(extract_run_summary <"$file"); then
    notice "could not read the run summary from the transcript. Nothing posted."
    return 0
  fi

  if has_unitemised_subagents <"$file"; then
    notice "the review fanned out but this transcript itemises no per-agent usage — reporting the aggregate figures only."
  elif ! rows=$(extract_agent_rows <"$file"); then
    notice "could not read per-agent usage from the transcript — reporting the aggregate figures only."
    rows=''
  fi

  # A run killed before it produced a `result` and before any agent spoke leaves nothing worth a
  # comment. Post no comment rather than an empty one.
  if [ -z "$rows" ] \
    && [ -z "$(tsv_field "$summary" 1)" ] \
    && [ -z "$(tsv_field "$summary" 2)" ] \
    && [ -z "$(tsv_field "$summary" 3)" ]; then
    notice "the transcript carries neither aggregate figures nor per-agent usage. Nothing posted."
    return 0
  fi

  if [ -z "${PR_NUMBER:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
    notice "no pull request to comment on (PR_NUMBER or GITHUB_REPOSITORY is unset). Nothing posted."
    return 0
  fi

  local run_log=''
  if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    run_log="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  fi

  local body
  if ! body=$(render_comment "$summary" "$rows" "$run_log"); then
    notice "could not render the telemetry comment. Nothing posted."
    return 0
  fi

  # Unlike the guard, a failure to post is NOT escalated to `::error::`. The guard's comment is a
  # verdict the caller has to see; this one is information they are welcome to miss.
  if ! gh pr comment "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --body "$body"; then
    notice "could not comment on pull request #${PR_NUMBER} — the caller may not have granted \`pull-requests: write\`. The review itself is unaffected."
    return 0
  fi

  return 0
}

# The never-fail lifecycle wrapper, and nothing else — `run` above holds the orchestration.
#
# The split is what makes the wrapper work rather than mere tidiness. Calling `run` as an `if`
# CONDITION suspends `errexit` for its whole dynamic extent, so no failure anywhere inside it
# can kill the script, and whatever it returns lands here to be swallowed. Inline the two and
# that suspension has nowhere to attach: the first unguarded non-zero exit under `set -e` takes
# the script down and the job with it.
#
# The same suspension is why every fallible command inside `run` carries its own explicit
# handler. With `errexit` off, a failing command does not abort — execution simply continues to
# the next line, holding whatever empty value the failure left behind. This is the last resort,
# not the safety net.
main() {
  if ! run; then
    notice "an unexpected failure stopped the report. The review itself is unaffected."
  fi
  return 0
}

# Executed, not sourced — so a test can source this file and call the pure functions above
# without the side effects in `main`. Same seam as `review-guard.sh`.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  main "$@"
fi
