---
issue_number: 79
issue_title: "fix(code-review): v1.10.1 still ends the run silently, and the caller cannot see where it stopped"
repo: "refokus-agency/platform"
labels: [bug]
plan_level: "standard"
depth: "medium"
branch_name: "beogip/fix-code-review-v1.10.1-still-ends-the-run-silen"
created_at: "2026-09-11T00:00:00Z"
---

# Implementation Plan: #79 — fix(code-review): v1.10.1 still ends the run silently, and the caller cannot see where it stopped

## Files

| # | Action | Path | Purpose |
|---|---|---|---|
| 1 | create | `.github/scripts/review-guard.sh` | Reads the transcript, derives the three signals, decides the action. All the logic lives here, not in the YAML |
| 2 | modify | `.github/workflows/code-review.yml` | New `show-full-output` input; `id: review` on the action step; new guard step with `if: always()`. The step-6 prompt override is deliberately NOT added |
| 3 | modify | `docs/architecture.md` | Minimum only: an entry for the new input plus one sentence in §"Two input defaults that look redundant and are not" noting that the guarantee now lives on the runner. No new section |
| 4 | modify | `docs/troubleshooting.md` | Minimum only: replace the diagnosis in §"Code review finishes green but posts no comment" — the guard now says it on the pull request. No restructuring |

`examples/comment-code-review.yml` is intentionally unchanged.

## Codebase Context

- `steps.<id>.outputs.<x>` via `$GITHUB_OUTPUT` — the pattern is already used three times in this same file (`auth.ready`, `actor.eligible`, `pr.head-sha`).
- `normalize()` in the "Resolve actor" step — lowercase via `tr` plus `[bot]` suffix strip.
- The tool-name-pair convention (`Task`/`Agent`, `Skill`/`SlashCommand`) is documented in the `allowed-tools` description: the CLI has spelled each both ways across versions, and an entry matching no tool is inert.
- All four existing gates skip green with `::notice::[code-review] ...`. Reuse that prefix and tone for the new messages.
- `docs/architecture.md` §"On versioning": fixing a default that never worked ships as `fix:` on the v1 line with no major bump.
- Upstream facts verified against `anthropics/claude-code-action@v1`:
  - `show_full_output` exists (`required: false`, default `"false"`, string).
  - Outputs available: `conclusion`, `execution_file`, `branch_name`, `github_token`, `structured_output`, `session_id`.
  - `base-action/src/execution-file.ts` writes the **unsanitized** `SDKMessage[]` to `$RUNNER_TEMP/claude-execution-output.json` on every run and exposes the path as `execution_file`.
  - `sanitizeSdkOutput(message, showFullOutput)` only controls what is printed to the log; the execution file is complete regardless of `show_full_output`.
  - `conclusion` is `success` only when `subtype === "success" && !is_error`.
  - On a thrown error the action calls `core.setFailed` + `process.exit(1)` (the step goes red and later steps skip unless `if: always()`); on the non-throwing path `conclusion` can be `"failure"` while the step stays green.

## Steps

1. Add the `show-full-output` input (`required: false`, `type: boolean`, `default: false`) with a description naming the secret-exposure risk on public logs → `code-review.yml`
   **Done when:** `yq '.on.workflow_call.inputs.show-full-output.default'` returns `false` and `required` is `false`.

2. Forward it as `show_full_output: ${{ inputs.show-full-output }}` on the action step → `code-review.yml`
   **Done when:** the `Code review` step's `with:` contains `show_full_output` and no other input changed.

3. Add `id: review` to the `Code review` step → `code-review.yml`
   **Done when:** `steps.review.outputs.execution_file` and `.conclusion` are referenceable from a later step.

4. Write `read_transcript`, `has_tool_use` and `has_comment_signal` → `review-guard.sh`
   **Done when:** against a transcript containing an `Agent` tool_use it returns `fanout_ran=true`; against one with neither name, `false`; against a missing file, `transcript_readable=false`.

5. Write `decide` implementing the five-row decision table → `review-guard.sh`
   **Done when:** all five combinations return the table's action, and `conclusion=failure` wins over every other signal.

6. Write `main`: post via `gh pr comment` and exit 1 on the fail paths → `review-guard.sh`
   **Done when:** the file is `chmod +x` and `bash -n` passes with no error.

7. Add the `Verify review outcome` step with `if: always() && steps.pr.outputs.eligible == 'true'`, passing `execution_file`, `conclusion`, `steps.review.outcome`, `GH_TOKEN` and the pull request number as env → `code-review.yml`
   **Done when:** the step runs even when `Code review` is red, and does not run when the pull request was not eligible.

8. Document with the strict minimum in `architecture.md` and `troubleshooting.md`; open the tech-debt issue → `docs/`
   **Done when:** the `docs/` diff adds no more than ~25 lines in total, no section is created, and the follow-up issue exists.

## Interfaces

- **`ReviewStepOutputs`** — what the action leaves behind: `conclusion: "success" | "failure"`, `execution_file: string` (path to `$RUNNER_TEMP/claude-execution-output.json`), `session_id: string`.
- **`GuardSignals`** — what the script derives: `step_ok: bool` (the action step did not die), `conclusion: "success" | "failure"`, `fanout_ran: bool`, `comment_posted: bool`, `transcript_readable: bool`.
- **`FANOUT_TOOLS`** — the set `{ "Task", "Agent" }`.
- **`COMMENT_SIGNALS`** — `{ tool_use.name == "mcp__github_inline_comment__create_inline_comment" }` ∪ `{ tool_use.name == "Bash" ∧ input.command matches "gh pr comment" }`.

## Function Design

All in `.github/scripts/review-guard.sh`:

- `read_transcript` — validates the file exists and parses as JSON. Single concern: readability.
- `has_tool_use <name...>` — is there any `tool_use` with one of those names? Read-only.
- `has_comment_signal` — the `Bash` + `gh pr comment` case cannot be resolved by tool name alone; it has to inspect `input.command`. Separate for that reason.
- `decide` — takes the signals, returns `{action, message}`. **Pure**: no I/O, no `gh`. This is the function the tech-debt issue will add tests to.
- `main` — orchestrates: gather signals → `decide` → post/fail. The only place with side effects.

## Acceptance Criteria (EARS)

- **AC-1.** The reusable shall expose a `show-full-output` input with `required: false`, `type: boolean` and default `false`.
- **AC-2.** The reusable shall forward `show-full-output` to `claude-code-action`'s `show_full_output` input unchanged.
- **AC-3.** When `show-full-output` is left at its default, the run log shall contain no more output than it does today.
- **AC-4.** When the `Code review` step finishes, the workflow shall run the guard step regardless of that step's outcome, provided the pull request was eligible.
- **AC-5.** When the guard step runs, it shall derive `fanout_ran` from the presence of a `tool_use` named `Task` or `Agent` in the transcript at `execution_file`.
- **AC-6.** When the guard step runs, it shall derive `comment_posted` from the presence of a `tool_use` named `mcp__github_inline_comment__create_inline_comment`, or of a `Bash` tool_use whose command contains `gh pr comment`.
- **AC-7.** If the `Code review` step did not succeed, or `conclusion` is `failure`, then the guard shall post a pull request comment reporting the failed run and shall fail the job, irrespective of `fanout_ran` and `comment_posted`.
- **AC-8.** When `conclusion` is `success`, `fanout_ran` is true and `comment_posted` is true, the guard shall post nothing and leave the job green.
- **AC-9.** When `conclusion` is `success`, `fanout_ran` is true and `comment_posted` is false, the guard shall post a pull request comment stating that the review ran and found nothing to report, and shall leave the job green.
- **AC-10.** When `conclusion` is `success`, `fanout_ran` is false and `comment_posted` is true, the guard shall post nothing and leave the job green.
- **AC-11.** If `conclusion` is `success`, `fanout_ran` is false and `comment_posted` is false, then the guard shall post a pull request comment reporting that the review did not run, and shall fail the job.
- **AC-12.** If the transcript is missing, empty or not parseable as JSON, then the guard shall post a comment reporting that the outcome could not be verified, and shall fail the job.
- **AC-13.** The guard shall never include transcript content in a comment or in the run log.
- **AC-14.** The workflow's existing input names, types and `required` flags shall remain unchanged, and `examples/comment-code-review.yml` shall remain unchanged.
- **AC-15.** Documentation changes shall be limited to describing the new input and the guard step's decision table; no section shall be created, renamed or restructured, and no existing passage shall be rewritten beyond the sentences that this change makes factually wrong.

## Out of Scope

- Fixing the root cause inside `/code-review:code-review` — it belongs to the upstream plugin. This change detects, it does not fix.
- Retrying or re-launching the review automatically.
- Extending the prompt override to step 6 of the command — **deliberately dropped** in favour of the runner-side guard. The existing step-1 override stays untouched.
- Touching `model`, `opus-model` or `allowed-tools`.
- Uploading the transcript as a run artifact.
- Tests for the script — recorded as tech debt, separate issue.
- Rewriting, reordering or expanding any `docs/` passage that this change does not make incorrect.

## Edge Cases + Error Handling

| # | Scenario | Source | Handling |
|---|---|---|---|
| 1 | The CLI renames `Agent` to something else | [from issue] | Both names are checked, exactly as the allowlist does. A name matching no tool is inert |
| 2 | The action throws and the step goes red | [inferred] | `if: always()` on the guard; `steps.review.outcome` is read as a signal |
| 3 | `conclusion: failure` while the step is green | [inferred] | `conclusion` is read separately from `outcome`; AC-7 |
| 4 | `execution_file` empty (the action died before writing it) | [inferred] | AC-12: fail plus comment, never "found nothing" |
| 5 | A human comments while the review is running | [inferred] | The signal comes from the transcript, not from a GitHub API diff. Immune |
| 6 | A review that only left inline comments | [from issue] | `COMMENT_SIGNALS` includes the inline MCP tool, not just `gh pr comment` |
| 7 | The guard's own comment re-triggers the workflow | [inferred] | It does not contain the `trigger-phrase`; and the actor gate rejects bots unless explicitly allowlisted |
| 8 | The caller did not grant `pull-requests: write` | [inferred] | `gh pr comment` fails → the guard fails loudly with `::error::`, it does not mask it |
| 9 | The pull request was not eligible (fork, closed, no credential) | [inferred] | The guard is conditioned on `steps.pr.outputs.eligible == 'true'`; the existing gates keep skipping green |

## Done Criteria per Feature

| Feature | Done when |
|---|---|
| `show-full-output` input | AC-1, AC-2, AC-3, AC-14 |
| Signal detection | AC-4, AC-5, AC-6, AC-12 |
| Decision table | AC-7, AC-8, AC-9, AC-10, AC-11 |
| Safety and contract | AC-13, AC-14, AC-15 |

### Decision table (normative)

| `conclusion` / step | fan-out ran | commented | Action |
|---|---|---|---|
| failure | * | * | post a failure notice + fail the job |
| success | yes | yes | nothing |
| success | yes | no | post "the review ran and found nothing to report" |
| success | no | yes | nothing — deliberate decline |
| success | no | no | post a notice + fail the job |

## Risks

- **False "did not run" from a tool rename** → both names are checked; document the pair in the script the way `allowed-tools` already does.
- **False "found nothing" over a broken run** → `conclusion`/`outcome` take precedence (AC-7) and an unreadable transcript fails (AC-12).
- **Secret leakage**: `show-full-output: true` dumps tool results into a public log → default `false` plus an explicit warning in the input description.
- **Comment noise**: every finding-free review now comments → that is the declared goal, but it changes observable behaviour for every caller on `@v1`.
- **Blast radius**: a bug in the guard affects code review across every agency repo → the guard never blocks the action, it only runs after it; the worst case is a red job with a comment, not a lost review.
- **No tests**: the five-row table is validated by hand → partially mitigated by keeping `decide` pure and isolated; debt recorded in a follow-up issue.
- **Runtime files**: the transcript lives in `$RUNNER_TEMP`, outside the repo. Nothing to add to `.gitignore`.

## Test Strategy

This repo has no test suite and no CI of its own (explicit decision during planning). Verification for this change is manual:

1. Push the branch; point `refokus-agency/time-to-refokus-ai-v2` at `.../code-review.yml@fix/79-guard-silent-code-review-runs`.
2. `@claude review` on a real pull request with a diff → expected: fan-out plus comment, the guard posts nothing, job green (AC-8).
3. `@claude review` on a trivial pull request (docs only, one line) → expected: the silent path reproduces and the guard covers it — a guard comment, not silence (AC-9 or AC-11).
4. Run once with `show-full-output: true` from a test caller to confirm the transcript reaches the log (AC-2, and AC-3 by contrast).

`decide` is written as a pure function with no I/O precisely so the tech-debt issue can add tests without a refactor.

**Debt recorded:** follow-up issue "add unit tests + CI for review-guard.sh".
