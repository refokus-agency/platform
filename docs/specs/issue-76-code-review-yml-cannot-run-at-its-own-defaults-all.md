---
issue_number: 76
issue_title: "code-review.yml cannot run at its own defaults: allowed-tools denies the tool that executes the prompt"
repo: "refokus-agency/platform"
labels: [bug]
plan_level: "standard"
depth: "focused"
branch_name: "fix/code-review-allowlist-slash-command-and-trivial-stop"
created_at: "2026-09-11T00:00:00Z"
---

# Implementation Plan: #76 — code-review.yml cannot run at its own defaults

Port the three fixes proven as caller-side overrides in a downstream consumer repository into this
repository's reusable input defaults, so every consumer inherits them without a caller change.

Scope decision on record: only the reusable's defaults are ported. That consumer's caller file also
carries three changes it labels explicitly as *deviations from platform's example* — an actor allowlist, an
explicit `secrets:` map in place of `inherit`, and a `drift-check` job. All three are
external-consumer concerns and are out of scope here. See **Out of Scope**.

## Files

| File | Change |
|---|---|
| `.github/workflows/code-review.yml` | `allowed-tools` default `+= Task,Agent,TodoWrite,Skill,SlashCommand`; `prompt` default override widened from two stop conditions to three, plus a comment-before-stopping requirement; both `description:` blocks rewritten |
| `docs/architecture.md` | "Two input defaults that look redundant and are not" — both paragraphs rewritten with the new evidence; note in "On versioning" recording the `fix:`-on-v1 call |
| `docs/troubleshooting.md` | New section: the review run finishes green and posts nothing |
| `examples/comment-code-review.yml` | **unchanged** — the fix is in the defaults |
| `.github/workflows/comment-code-review.yml` | **unchanged** — same reason |

## Codebase Context

- **Two-tier docs convention (established, respect it).** `docs/architecture.md` is the single
  canonical home for the full argument behind a decision. YAML `description:` blocks and comments
  carry only the operational facts a config-time reader needs, plus a terse pointer to the doc.
  Do not relocate the long rationale into the workflow file.
- **Verified: no caller overrides either input.** `examples/comment-code-review.yml` and
  `.github/workflows/comment-code-review.yml` both consist of triggers, permissions, concurrency,
  `uses:` and `secrets: inherit`. Nothing else. Both inherit the fixed defaults for free.
- **Read-only posture is load-bearing.** `claude-code-action` treats the checked-out pull request
  head as untrusted and restores `.claude`, `CLAUDE.md`, `.mcp.json` and friends from the base
  branch for that reason. All five additions preserve it: a subagent inherits this same allowlist,
  so `Task` grants no reach the orchestrator does not already have; `TodoWrite` writes to the
  session's todo state, never to the checked-out worktree; `Skill` executes the command that is
  already this input's sibling default.
- **Tool-name pairs are deliberate, not redundancy.** `Task`/`Agent` and `Skill`/`SlashCommand`
  have each been named both ways across Claude Code versions, and the action pins its own moving
  CLI version. An allowlist entry that matches no tool is inert, so naming both costs nothing and
  stops a CLI bump from silently reinstating this exact failure. A tidy-minded maintainer will want
  to delete one of each pair — the `description:` must say why not.
- **Reference implementation:** one downstream consumer already carries these values as caller-side
  overrides in its own `comment-code-review.yml`, with the investigation written up inline. That
  repository is the verification target in **Test Strategy**.

## Steps

1. **`allowed-tools`: default and description.**
   Append `,Task,Agent,TodoWrite,Skill,SlashCommand` to the default string. Extend the
   `description:` with the half it is missing: today it explains only why the *reading* tools are
   needed (`Read,Glob,Grep`); it needs the *execution* half — `Skill` executes the slash command
   that is this workflow's `prompt` default, `Task` launches the subagents the command is built
   from, `TodoWrite` is named in the command's own notes. Include the read-only argument and the
   tool-name-pair argument.
   **Done when:** the default contains all five new entries and the `description:` names `Skill`
   as the tool that executes the slash command.

2. **`prompt`: default and description.**
   Widen the step 1 override to a third stop condition (`trivial`) and add the requirement that
   the command post a comment naming any stop condition that does fire, before ending the run.
   The `description:` currently reads "lifts exactly two of step 1's stop conditions" and "Closed,
   trivial and automated still stop the review" — both become false and must be rewritten.
   **Done when:** the block scalar `|` is intact, the first line is still the bare slash command,
   and the `description:` reflects three conditions plus the comment requirement.

3. **`docs/architecture.md`, section "Two input defaults that look redundant and are not".**
   Rewrite both halves so the section carries the *mechanism*, not the incident log. The
   `allowed-tools` half becomes one bullet per tool group naming what each is load-bearing for:
   `Read,Glob,Grep` (the subagents read files), `Skill,SlashCommand` (`prompt` defaults to a slash
   command and these execute it), `Task,Agent` (the command is a fan-out of subagents),
   `TodoWrite` (named in the command's own notes). The `prompt` half gains `trivial` — this
   workflow has no automatic trigger, so a run exists only because a person asked for it, and the
   gate re-decides that from the diff alone — plus the silent-stop argument
   (`show_full_output: false` makes a deliberate decline and a swallowed crash identical from the
   outside). Run IDs, costs, turn counts and consumer-repo names stay in this plan and in the
   issue; they do not belong in a permanent public doc. Link to the troubleshooting section rather
   than repeating the diagnosis. Add one sentence to "On versioning" stating the rule behind the
   `fix:`-on-v1 call: fixing a default that never worked leaves no behaviour for a consumer to
   depend on.
   **Done when:** no statement in the doc contradicts the shipped defaults.

4. **`docs/troubleshooting.md`: new section.**
   Symptom-first, matching the file's existing style: the check is green, the run took minutes and
   cost real money, and no review comment appeared. Cause: `allowed-tools` overridden with a value
   predating this fix, denying `Skill`. Link to the architecture section.
   **Done when:** the section exists and links to `architecture.md`.

5. **Verification.**
   Parse the workflow as YAML and confirm the `prompt` default survives as a multi-paragraph
   string with its newlines. Run `actionlint` if available.
   **Done when:** the file parses clean and the `prompt` value still contains its paragraph breaks.

## Interfaces

Two `workflow_call` input defaults change. The input *names*, *types* and *required* flags are
untouched, so the `workflow_call` interface itself is unchanged — only the behaviour of two
defaults.

```yaml
allowed-tools:
  # before
  default: mcp__github_inline_comment__create_inline_comment,Bash(gh pr diff:*),Bash(gh pr view:*),Bash(gh pr comment:*),Bash(gh pr list:*),Bash(gh issue view:*),Bash(gh issue list:*),Bash(gh search:*),Read,Glob,Grep
  # after
  default: mcp__github_inline_comment__create_inline_comment,Bash(gh pr diff:*),Bash(gh pr view:*),Bash(gh pr comment:*),Bash(gh pr list:*),Bash(gh issue view:*),Bash(gh issue list:*),Bash(gh search:*),Read,Glob,Grep,Task,Agent,TodoWrite,Skill,SlashCommand
```

```yaml
prompt:
  # after — structure only; first line unchanged, block scalar preserved
  default: |
    /code-review:code-review --comment ${{ github.repository }}/pull/${{ github.event.issue.number }}

    <paragraph 1: three stop conditions lifted — already-commented, draft, trivial>

    <paragraph 2: whatever you decide, say it on the pull request before stopping>

    Review the current head.
```

## Function Design

Not applicable — this change is entirely declarative YAML and prose. No shell logic is added or
modified; the four gate steps in `code-review.yml` are untouched.

## Acceptance Criteria (EARS)

- **AC-1.** The `allowed-tools` default shall include `Skill` and `SlashCommand`.
- **AC-2.** The `allowed-tools` default shall include `Task`, `Agent` and `TodoWrite`.
- **AC-3.** The `allowed-tools` default shall contain no tool capable of writing to the checked-out
  worktree — no `Write`, no `Edit`, no bare `Bash(...)` entry.
- **AC-4.** When the review encounters a trivial diff, the reusable's `prompt` default shall not
  stop the review on that ground.
- **AC-5.** When any remaining stop condition fires, the `prompt` default shall require a pull
  request comment naming that condition before the run ends.
- **AC-6.** The `prompt` default shall remain a block scalar whose first line is the bare slash
  command.
- **AC-7.** No file under `examples/` shall change.
- **AC-8.** Every claim in `docs/architecture.md` about either default shall match the shipped
  default.
- **AC-9.** The `workflow_call` input names, types and `required` flags shall be unchanged.

## Out of Scope

Three changes present in that consumer's caller file are deliberately not ported. It labels each
one in-file as a *deviation from platform's example*, and each answers a constraint that does not hold
inside `refokus-agency`.

- **Actor allowlist** (`github.event.comment.user.login == 'beogip'`). Answers the Anthropic
  Consumer Terms binding a personal credential to one individual. This org uses workload identity
  federation, and the reusable's `Resolve actor` gate already requires write access. Adding an
  `allowed-actors` input was offered and declined.
- **Explicit `secrets:` map in place of `inherit`.** Least-privilege when handing secrets to a
  workflow owned by *another* organisation pinned to a moving tag. Inside this org it contradicts
  the documented `secrets: inherit` invariant in `CLAUDE.md` and `docs/architecture.md`.
- **`drift-check` job.** An alarm for `@v1` moving underneath an external consumer. Inside this
  org the reusable and the caller are maintained together.

Also out of scope: bumping `anthropics/claude-code-action@v1`.

## Edge Cases + Error Handling

| # | Scenario | Source | Handling |
|---|---|---|---|
| 1 | The pinned CLI names `Task` but not `Agent` | [from the verification repo] | The unmatched entry is inert and costs nothing — this is why both are named |
| 2 | The pinned CLI names `SlashCommand` but not `Skill` | [inferred] | Same mechanism; both are named for the same reason |
| 3 | A caller overrides `prompt` with the bare slash command | [from architecture.md] | Already documented in the `description:`; the rewrite preserves that warning |
| 4 | The diff is documentation only | [from the verification repo] | Now in scope — a standard that agents follow is reviewable material, and "no code changed" is not "nothing to review" |
| 5 | The pull request is closed, or automated | [from the verification repo] | Still stops the review, but must post a comment naming the condition first |
| 6 | A caller pins `allowed-tools` to the pre-fix value | [inferred] | That caller breaks for itself; the `description:` and the new troubleshooting section name the symptom |
| 7 | Editing the block scalar breaks `${{ }}` interpolation | [inferred] | Step 5 parses the YAML and asserts the paragraph breaks survive |
| 8 | `Task` is read as a privilege escalation in review | [from the verification repo] | A subagent inherits the same allowlist, so it grants no reach the orchestrator lacks — state this in the `description:` so the next reviewer does not have to rediscover it |

## Done Criteria per Feature

| Feature | Must all pass |
|---|---|
| `allowed-tools` executes the command | AC-1, AC-2, AC-3 |
| `prompt` reviews and reports honestly | AC-4, AC-5, AC-6 |
| Caller contract untouched | AC-7, AC-9 |
| Docs tell the truth | AC-8 |

## Risks

| Risk | Mitigation |
|---|---|
| Editing the multi-paragraph block scalar breaks the `${{ }}` interpolation or collapses the newlines | Keep the `\|` scalar and the bare first line; step 5 parses the YAML and asserts the paragraph breaks survive |
| **Semver.** `CLAUDE.md` classifies "changing an input default's behaviour" as breaking (`feat!:`) | Ship as `fix:` on the v1 line, and argue it in the PR: these defaults never worked, so no consumer can be relying on the behaviour of a review that reviews nothing. Same shape as the bounded exception already recorded in `docs/architecture.md` -> "On versioning". Flag it explicitly for the second maintainer rather than deciding it quietly |
| The three fixes were validated together downstream, never in isolation | Accepted. All three ship together here, which is the configuration that was actually proved end-to-end |
| A future reviewer deletes `Agent` or `SlashCommand` as redundant | The `description:` must carry the argument, not just the entries |
| The verification repo overrides `allowed-tools` itself, so pointing it at the branch tests the override, not the default | Temporarily drop that override for the verification run, so the branch's default is what executes |

## Test Strategy

There is no way to run a reusable workflow locally, and `act` does not reliably exercise secrets or
composite actions. The in-repo dogfood caller is also useless here: GitHub runs an `issue_comment`
workflow from the **default branch, always**, so commenting on a pull request in this repo
exercises `code-review.yml` as it exists on `main`, not on the branch under review. See
`docs/architecture.md` -> "Testing a change to `code-review.yml`".

1. **Local.** Parse `.github/workflows/code-review.yml` as YAML; assert the `prompt` default is a
   multi-paragraph string whose first line is the bare slash command, and that `allowed-tools`
   contains all five new entries and none of `Write`, `Edit` or a bare `Bash(...)`. Run
   `actionlint` if available. This is the only remaining genuinely open risk — the *values* are
   already proven, the syntax is not.
2. **Against a real repo** (`docs/contributing.md` -> Option A). Point the verification repo at
   `refokus-agency/platform/.github/workflows/code-review.yml@fix/code-review-allowlist-slash-command-and-trivial-stop`,
   temporarily remove its own `allowed-tools` override so the branch's default is what runs, and
   comment the trigger phrase. Expect: a `Task` dispatch in the run, a `modelUsage` carrying more
   than one model entry, and a posted review comment.
3. **Post-release.** Comment `@claude review` on the next pull request in this repo and confirm the
   run dispatches subagents and posts a comment — the first end-to-end exercise of the comment
   trigger in `platform`, which has never run here (every `Code Review` run in this repo to date
   fired on `pull_request`, before the trigger change).
