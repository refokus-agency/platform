---
issue_number: 94
issue_title: "feat: report agent run telemetry in code-review comment"
repo: "refokus-agency/platform"
labels: [enhancement]
plan_level: "full"
depth: "medium"
branch_name: "beogip/feat-report-agent-run-telemetry-in-code-review-c"
created_at: "2026-09-14T19:56:34Z"
---

# Implementation Plan: #94 — feat: report agent run telemetry in code-review comment

Add a step to `.github/workflows/code-review.yml` that reads the `execution_file`
output of `anthropics/claude-code-action@v1` and posts a separate telemetry comment
on the pull request: aggregate run cost, per-agent context consumed, per-agent model,
with the orchestrator visually distinguished from its subagents.

## Files

| # | Action | Path | Purpose |
|---|---|---|---|
| 1 | create | `.github/scripts/report-run-telemetry.sh` | Parse `execution_file`, render the comment body, post it with `gh pr comment`. Never exits non-zero. |
| 2 | modify | `.github/workflows/code-review.yml` | New step after `Verify review outcome`, gated `if: always() && steps.pr.outputs.eligible == 'true'`. |
| 3 | modify | `docs/architecture.md` | Document the telemetry step; correct the sparse-checkout rationale (it now serves two consumers, not one). |
| 4 | modify | `CLAUDE.md` | Same correction — the `.platform` checkout is no longer "for the guard script, and for nothing else". |
| 5 | modify | `docs/troubleshooting.md` | Entry for "no telemetry comment appeared". |

## Codebase Context

- **`.github/scripts/review-guard.sh` is the house style to mirror**: `#!/usr/bin/env bash`,
  `set -euo pipefail`, a header comment block documenting every environment variable,
  pure functions separated from `main()`, `::notice::` / `::error::` workflow annotations,
  and the executed-not-sourced seam at the bottom
  (`if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then main "$@"; fi`).

- **Deliberate divergence from that precedent**: `review-guard.sh` is *allowed* to `exit 1` —
  that advisory-red behaviour is its feature. The telemetry script must never do this.
  The closer precedent is `.github/scripts/record-github-deployment.cjs`, which wraps its
  work in try/catch, emits a warning on failure, and returns normally so the step it runs
  in never goes red.

- **No new checkout step is needed.** The existing `Checkout platform repo (for the guard
  script)` step sparse-checks out the whole `.github/scripts` directory, not a single file.

- **`steps.review.outputs.execution_file` is already plumbed** as the `EXECUTION_FILE` env
  var on the `Verify review outcome` step. Reuse that exact pattern.

- **`jq` is the established JSON tool** for parsing action output in this repo's workflow
  steps. No `python3` or `node` is used for transcript parsing anywhere (`actions/github-script`
  + a `.cjs` module in `deploy.yml` is a different mechanism, for GitHub API calls).

- **No permission or allowlist change.** The job already carries `pull-requests: write` and
  already allows `Bash(gh pr comment:*)`.

- **This repo has no test framework.** The `BASH_SOURCE` seam in `review-guard.sh` exists for
  a follow-up test issue that has not landed yet. See Test Strategy for what "tested" means here.

### `execution_file` format — confirmed findings

Confirmed against `anthropics/claude-code-action` `main` and
`@anthropic-ai/claude-agent-sdk@0.3.270` (the version that action pins).

- The file is a **single pretty-printed JSON array** of `SDKMessage` — *not* newline-delimited
  stream-json. Written by `base-action/src/execution-file.ts` to
  `$RUNNER_TEMP/claude-execution-output.json`. Every message from the SDK's `query()` stream is
  pushed unfiltered; the log sanitisation in `run-claude-sdk.ts` does not touch the array.
- **`result` message**: `total_cost_usd` (cumulative — read the last one, do not sum),
  `num_turns`, `duration_ms`, `subtype`, `is_error`. Its `usage` field is documented as
  *main-agent-loop only*; its `modelUsage` is per-model aggregate across all agents. Neither
  is per-agent.
- **`assistant` message**: `parent_tool_use_id` (`null` for the orchestrator, set for messages
  produced inside a Task subagent), `subagent_type`, `task_description`, `message.model`,
  `message.usage`.
- **`system` / `init` message**: top-level `model` — the orchestrator's resolved model.
- **Per-subagent itemisation is CONFIRMED PRESENT**, via two corroborating mechanisms:
  the `parent_tool_use_id` / `subagent_type` fields on assistant messages, and the
  `task_started` / `task_progress` / `task_notification` system messages.
- **Per-agent cost in USD is NOT a field read anywhere.** It would have to be estimated from
  `modelUsage` rates. The issue explicitly says aggregate cost suffices, so this is moot —
  but it is why AC-1 asks only for the total.
- **Caveat**: the research was against `main`, not a pinned `v1.0.x` tag, and the SDK's own doc
  comments repeatedly note fields may be "absent from older producers". Treat every per-agent
  field as optional. This is precisely the contingency AC-8 and AC-9 exist for.

### Context measurement — the load-bearing decision

Two candidate sources exist for "context consumed". They are not interchangeable:

- `task_notification.usage.total_tokens` — **cumulative across the agent's turns**.
- The final assistant message's `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`
  — **the context window occupied**, matching how Claude Code's own `/context` reports it.

Measured empirically on real local transcripts:

```
MAIN agent:      71k -> 90k   (sum across all its messages: 2,241k)
SUBAGENT:        66k -> 120k  (sum across all its messages: 3,230k)
```

The per-message figure is monotonically increasing, so the **last** message is the maximum and
is the right number. Summing reports roughly **25x** the real context — catastrophic against the
200k yardstick the reader is meant to apply. AC-4 pins this down.

## Steps

1. **Build fixtures** (scratchpad only, not committed): a happy-path `execution_file` with a
   `system/init`, orchestrator `assistant` messages with rising `usage`, two Task subagents
   carrying `parent_tool_use_id` + `subagent_type` + their own rising `usage`, and a final `result`.
   **Done when:** `jq type` on the fixture prints `"array"` and the fixture contains at least one
   message each of `system`, `assistant` (main), `assistant` (subagent), and `result`.

2. **Write `format_k` and `extract_run_summary`.**
   **Done when:** sourcing the script and running `extract_run_summary < fixture` prints exactly one
   TSV line with 6 fields, and `format_k 142400` prints `142k`.

3. **Write `extract_agent_rows`** using the last-message context formula (depends on step 2).
   **Done when:** `extract_agent_rows < fixture` prints exactly 3 lines (1 main + 2 subagents), the
   main line has `is_main=1`, and each row's `context_tokens` equals that agent's **final** message
   sum — not the sum across its messages.

4. **Write `has_unitemised_subagents` and the omission gate** (depends on step 3).
   **Done when:** against a second fixture where `parent_tool_use_id` is stripped from every message
   while `Task` tool_use blocks remain, `render_comment` output contains no table and no agent rows.

5. **Write `render_comment` and `main`**, with the never-fail wrapper and the `BASH_SOURCE` seam
   (depends on steps 2–4).
   **Done when:** `EXECUTION_FILE=/nonexistent ./report-run-telemetry.sh; echo $?` prints `0` and emits
   a `::notice::`; the same holds for a fixture containing `{}` and for one containing invalid JSON.

6. **Wire the workflow step** into `code-review.yml` after `Verify review outcome` (depends on step 5).
   Gated `if: always() && steps.pr.outputs.eligible == 'true'`, carrying `continue-on-error: true`,
   env `EXECUTION_FILE` / `GH_TOKEN` / `PR_NUMBER`, and an `if [ -x ... ]` guard that emits a notice
   and skips rather than erroring.
   **Done when:** `actionlint` parses `code-review.yml` clean and the new step carries both
   `continue-on-error: true` and `if: always()`.

7. **Docs and invariant correction** (independent of steps 2–6).
   **Done when:** `rg -n "for the guard script, and for nothing else"` returns zero hits across
   `CLAUDE.md` and `docs/`.

## Interfaces

Bash has no type system, so these are the explicit contracts between functions. Each is a
tab-separated record; no function passes an untyped blob.

- **`RunSummary`** — exactly one TSV line:
  `total_cost_usd`, `num_turns`, `duration_ms`, `subtype`, `is_error`, `orchestrator_model`.
  Any field that cannot be derived is the empty string; the renderer omits what is empty.

- **`AgentRow`** — one TSV line per agent:
  `is_main` (`1` | `0`), `label` (`main` for the orchestrator, otherwise the `subagent_type`),
  `context_tokens` (integer), `model` (string, empty when not obtainable).

- **`ExecutionFile`** — the input, produced by the action. A top-level JSON array of `SDKMessage`.
  Fields consumed: `system`/`init` → `.model`; `assistant` → `.parent_tool_use_id`,
  `.subagent_type`, `.message.model`, `.message.usage.{input_tokens, cache_read_input_tokens,
  cache_creation_input_tokens}`; `result` → `.total_cost_usd`, `.num_turns`, `.duration_ms`,
  `.subtype`, `.is_error`.

## Function Design

`.github/scripts/report-run-telemetry.sh`:

| Function | Single concern |
|---|---|
| `extract_run_summary` | execution JSON on stdin → one `RunSummary` line. Aggregate figures only. |
| `extract_agent_rows` | execution JSON on stdin → zero or more `AgentRow` lines. Per-agent figures only. |
| `has_unitemised_subagents` | Detect `Task` tool_use blocks that have no correlating itemised usage. Returns a boolean. |
| `format_k` | Integer token count → `142k`. Pure formatting, no I/O. |
| `render_comment` | `RunSummary` + `AgentRow` lines → markdown body. No I/O, no network. |
| `main` | Orchestration **and** the never-fail lifecycle wrapper. |

**Flagged:** `main` deliberately combines orchestration with failure suppression. That coupling is
the requirement (AC-10), not an accident — but it is why `main` is the one function the
`BASH_SOURCE` seam cannot meaningfully unit-test. Every function above it is pure and sourceable.

### Proposed comment shape

```markdown
### Run telemetry

**Cost** $0.8421 · **Turns** 42 · **Duration** 3m 12s

| Agent | Context | Model |
|---|---|---|
| **⬥ main** (orchestrator) | **90k** | claude-opus-5 |
| ↳ code-reviewer | 120k | claude-sonnet-5 |
| ↳ code-reviewer | 88k | claude-sonnet-5 |

<sub>Context = window occupied on each agent's final turn. — [run log](…)</sub>
```

The orchestrator is distinguished three ways at once — bold, a distinct glyph, and the explicit
`(orchestrator)` label — against the `↳` indent marker on subagents (AC-7).

## Acceptance Criteria (EARS)

- **AC-1.** The telemetry comment shall report the run's aggregate cost in USD, read from the last
  `result` message's `total_cost_usd`.
- **AC-2.** The telemetry comment shall report, for every agent whose usage is itemised, the context
  that agent consumed.
- **AC-3.** Context shall be rendered as the raw token count in thousands with a `k` suffix
  (e.g. `142k`); the workflow shall not compute a smart-zone verdict, threshold, colour, or comparison.
- **AC-4.** Context per agent shall be computed as
  `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` on that agent's **last**
  assistant message, and shall never be a sum across that agent's messages.
- **AC-5.** Per agent, the comment shall report context and model only; it shall not describe what
  the agent reviewed.
- **AC-6.** When an agent's model is obtainable from the transcript, the comment shall report it;
  if it is not obtainable, the model cell shall render `—`.
- **AC-7.** The main/orchestrator agent's row shall be visually distinguished from subagent rows.
- **AC-8.** If no per-agent usage is itemised in the execution file, then the comment shall omit the
  per-agent block entirely and report only the aggregate figures.
- **AC-9.** If `Task` subagents are detectable in the transcript but their usage is not itemised,
  then the per-agent block shall be omitted entirely rather than rendered with the main agent alone.
- **AC-10.** If the telemetry script encounters any failure — missing file, empty file, malformed
  JSON, missing field, or a failing `gh pr comment` — then it shall emit a `::notice::` annotation
  and exit `0`, and the job shall not go red.
- **AC-11.** When the review action is skipped by any eligibility gate, the telemetry step shall post
  no comment at all.
- **AC-12.** When the review action runs and then fails mid-run, the telemetry comment shall still be
  posted.
- **AC-13.** Each run shall post its own telemetry comment; the workflow shall not upsert, edit, or
  delete a previous one.
- **AC-14.** The comment shall contain no transcript content — no prompt text, tool inputs, tool
  outputs, or file contents — only numeric figures, model names, and subagent type names.
- **AC-15.** The change shall add no required input and no required secret to `code-review.yml`'s
  `workflow_call` interface.

## Out of Scope

- **Per-agent cost in USD.** Not a field read anywhere in `execution_file`; it would have to be
  estimated from `modelUsage` rates. The issue states aggregate cost suffices.
- **Any change to the `prompt` input** or to the `/code-review:code-review` command. The review
  comment is written by the marketplace plugin, not by this repo — telemetry goes in its own comment
  precisely so it does not depend on the plugin's cooperation.
- **Any change to the other reusables**, or to `review-guard.sh`'s existing behaviour.
- **Upserting a single telemetry comment** by hidden marker. Rejected during scoping: the history of
  how spend evolves across runs is worth more than a tidy thread.
- **Any smart-zone verdict, 200k threshold, or pass/fail signal** derived from context. The reader
  makes that comparison themselves.
- **An opt-out input** (`report-telemetry: true`). Offered at the approval gate and declined for this
  change. It remains additive and v1-safe if it is wanted later — see Risk 3.

## Edge Cases + Error Handling

| # | Scenario | Source | Handling |
|---|---|---|---|
| 1 | Any of the four green gates skips the action | [from issue] | `eligible != 'true'` → the step never runs. No comment at all. |
| 2 | The review fails mid-run; money has already been spent | [from issue] | `if: always()` → the comment is still posted, with the cost. |
| 3 | Repeated `@claude review` on the same pull request | [from issue] | One telemetry comment per run, by design. No upsert. |
| 4 | `execution_file` output is empty (action skipped but step ran) | [inferred] | Empty `EXECUTION_FILE` → `::notice::`, exit 0, no comment. |
| 5 | The file exists but is malformed JSON | [inferred] | `jq` failure is caught → `::notice::`, exit 0, no comment. |
| 6 | Upstream drops `parent_tool_use_id` / `subagent_type` | [from issue] | The per-agent block is omitted entirely (AC-8, AC-9). Aggregate figures are still posted. |
| 7 | No `result` message (run killed or timed out) | [inferred] | Cost is unobtainable → omit the cost line; still post the per-agent block if derivable. If neither is derivable, post nothing. |
| 8 | `gh pr comment` fails (caller lacks `pull-requests: write`) | [inferred] | `::notice::` naming the missing permission, exit 0. Unlike the guard, this is **not** escalated to `::error::` — telemetry is additive information, not a verdict. |
| 9 | The sparse checkout failed and the script is not on disk | [inferred] | `if [ -x ... ]` guard → `::notice::`, skip. Never `exit 1` the way the guard does. |
| 10 | A subagent ran zero assistant turns | [inferred] | No usage to read → that row is omitted; the remaining rows still render. |

## Done Criteria per Feature

| Feature | Done when all pass |
|---|---|
| Aggregate reporting | AC-1, AC-15 |
| Per-agent context | AC-2, AC-3, AC-4, AC-5 |
| Per-agent model | AC-6 |
| Main-agent distinction | AC-7 |
| Graceful degradation | AC-8, AC-9, AC-10, AC-11, AC-12 |
| Hygiene | AC-13, AC-14 |

## Risks

1. **Summing usage across messages instead of taking the last one** → reports roughly 25x the real
   context, silently and plausibly.
   *Mitigation:* AC-4 states the formula explicitly, step 3's Done-when asserts it, and the figure was
   measured on real transcripts (main `71k→90k` against a sum of `2,241k`; subagent `66k→120k` against
   a sum of `3,230k`).

2. **A red telemetry step breaks CI across every Refokus repo at once** — `@v1` is force-moved to every
   release on the v1.x line.
   *Mitigation:* two independent guards — a defensive script that cannot exit non-zero, plus
   `continue-on-error: true` on the step itself. Belt and braces, deliberately.

3. **Comment spam on every review in every consumer repo, with no way out.**
   *Mitigation:* an optional `report-telemetry` input (default `true`) would give consumers an escape
   hatch. Declined for this change; additive and v1-safe if it is wanted later.

4. **Upstream `claude-code-action@v1` changes the `execution_file` shape.** The workflow pins the
   floating `@v1`, and the research was against `main` and SDK `0.3.270`, not a tagged release.
   *Mitigation:* every per-agent field is treated as absent-tolerant; AC-8 is exactly this contingency.
   The aggregate `total_cost_usd` carries no such caveat and degrades independently.

5. **Fixture JSON accidentally committed.**
   *Mitigation:* fixtures are built in the session scratchpad only. If a committed fixture later becomes
   necessary, its directory goes into `.gitignore` with a `.gitkeep` to preserve the path.

6. **A stale invariant in `CLAUDE.md` and `docs/architecture.md`.** Both currently state the `.platform`
   checkout exists for the guard script "and for nothing else" — false the moment this ships.
   *Mitigation:* step 7, with an `rg` assertion as its Done-when.

## Test Strategy

This repo has no test framework. The `BASH_SOURCE` seam in `review-guard.sh` was added for a follow-up
test issue that has not landed. So "tested" here means the following, and nothing is claimed beyond it:

1. **Fixture-driven, black-box through the script's CLI.** Three fixtures: happy path (main + two
   subagents), degraded (`parent_tool_use_id` stripped, `Task` blocks still present), and broken
   (malformed JSON, and a variant missing the `result` message). Drive the script with
   `EXECUTION_FILE=<fixture>` and a stub `gh` earlier on `PATH` that echoes its arguments instead of
   posting. Assert on the rendered body and on `$?` being `0` in every case.

2. **Assertions are behavioural, not structural.** "The main row renders `90k` and the subagent renders
   `120k`" — not "the output has three lines".

3. **Mirror the `BASH_SOURCE` seam** so the pure functions are sourceable, and so the follow-up test
   issue can cover this script alongside the guard.

4. **Static checks:** `shellcheck` on the new script, `actionlint` on the modified workflow.

5. **Live verification — this is what actually closes the issue's "verify against a real
   `execution_file`" requirement.** Push the branch, point a low-stakes caller repo at
   `refokus-agency/platform/.github/workflows/code-review.yml@beogip/feat-report-agent-run-telemetry-in-code-review-c`,
   comment `@claude review`, and check the resulting telemetry comment against the real transcript. The
   format research is strong, but it is research — it is not a live run, and a reusable workflow cannot
   be exercised from inside this repo.

**Note on Strict TDD Mode:** it is enabled for this session, but this repo has no test runner. Steps 2–5
are written test-first against fixtures, which is the closest honest approximation available. No
red-green-refactor cycle is claimed, because the repo cannot run one.
