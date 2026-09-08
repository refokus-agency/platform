---
issue_number: draft
issue_title: "Add reusable code-review workflow backed by claude-code-action"
repo: "refokus-agency/platform"
labels: [enhancement, ci]
plan_level: "full"
depth: "medium"
branch_name: "feat/code-review-reusable-workflow"
created_at: "2026-09-08T00:00:00Z"
---

# Implementation Plan: draft — Add reusable code-review workflow backed by claude-code-action

> No GitHub issue exists for this change. The issue body was synthesized from a session
> discovery conversation and classified by `issue-analyzer.py` at `full` / depth `medium`
> (score 11/13). If an issue is opened later, rename this file to match its number.

## Files

| # | Action | Path | Purpose |
|---|---|---|---|
| 1 | create | `.github/workflows/code-review.yml` | Reusable `workflow_call`: auth guard + `claude-code-action` |
| 2 | create | `examples/pr-code-review.yml` | Atomic caller example for consumer repos |
| 3 | create | `.github/workflows/pr-code-review.yml` | Dogfood the reusable on this repo's own PRs (new precedent) |
| 4 | modify | `docs/architecture.md` | Building-block subsection + design decision for the absent `.platform/` checkout |
| 5 | modify | `docs/secrets.md` | `ANTHROPIC_API_KEY` table row + configuration subsection |
| 6 | modify | `docs/dependabot.md` | Code-review note alongside the existing Vercel note |
| 7 | modify | `README.md` | Table row + two lines in the repo tree |

## Codebase Context

Collected via context-collector against the live repo.

- **`ci.yml` and `deploy.yml` deliberately declare no job-level `permissions:` block.** Verbatim
  comment in `deploy.yml`: *"No explicit permissions block on purpose: the job inherits the
  caller's granted permissions. Declaring a scope here (e.g. `deployments: write`) would force
  EVERY caller to grant it or the run fails at startup."* `code-review.yml` follows this.
- **Every secret in this repo is `required: false`**, even ones that are logically necessary, for
  the same startup-failure reason. `deploy.yml` makes `VERCEL_TOKEN`, `VERCEL_ORG_ID` and
  `VERCEL_PROJECT_ID` all optional and gates the steps instead.
- **Skip pattern to reuse** — `deploy.yml`'s `transferred` input:
  ```yaml
  - name: Transferred repo — skip deploy
    if: ${{ inputs.transferred }}
    run: |
      echo "[deploy] skipped: repo marked as transferred"
    shell: bash
  ```
  followed by every subsequent step gated `if: ${{ !inputs.transferred }}`. The auth guard is the
  same shape.
- **Input declaration style** — fixed key order `description` → `required` → `type` → `default`:
  ```yaml
  node-version:
    description: Node version.
    required: false
    type: string
    default: '24'
  ```
- **Step naming** — short imperative Title Case: `Checkout caller repo`, `Setup`, `Lint`.
- **Caller template** (`examples/pr-ci.yml`) — two-line header comment (`# <what it does>.` then
  `# Copy to .github/workflows/<file>.yml in your repo.`), `name: Pull Request`, bare
  `pull_request:` trigger, `concurrency.group: ${{ github.workflow }}-${{ github.event.pull_request.number }}`
  with `cancel-in-progress: true`, and `secrets: inherit` on each job.
- **`.platform/` secondary checkout is NOT needed here.** The invariant exists solely to reach the
  local composite `setup` action. `claude-code-action` ships its own runtime, and `platform` has no
  `package.json` for `setup` to detect a package manager from (`setup` hard-errors with
  `::error::No lockfile found`). This is a documented exception, not an oversight.
- **This repo does not currently dogfood its own reusables.** Its four workflows are `ci.yml`,
  `deploy.yml`, `release.yml` (all `workflow_call` only) and `release-please.yml`
  (`push` to `main`). No workflow triggers on `pull_request`. File 3 establishes that precedent.
- **`docs/architecture.md` insertion point** — `### Reusable workflow: code-review.yml` goes under
  `## The building blocks`, after `### Reusable workflow: release.yml` and before `### Callers`.
  The re-checkout exception goes under `## Key design decisions`, near the existing
  `### Why does each reusable re-checkout the platform repo?`.
- **Fixed separately on `fix/stale-gh-pat-token-and-atl-gitignore`** — `CLAUDE.md` claimed
  `GH_PAT_TOKEN` was an always-required secret and that the `VERCEL_*` secrets were `required: true`.
  Neither was true: `GH_PAT_TOKEN` appears in no workflow, and all 8 secret declarations across the
  three reusables are `required: false`. That branch also adds `.atl/` to `.gitignore`.

### Verified upstream facts

Checked against `anthropics/claude-code-action@v1/action.yml` and
`anthropics/claude-code` at `main`:

- `plugins` (line 160) and `plugin_marketplaces` (line 164) exist. Both are **newline-separated**,
  not comma-separated.
- `id-token: write` is mandatory, not optional. `docs/setup.md`: *"The default GitHub App
  authentication path already requires this permission."* The action exchanges the GitHub OIDC
  token for a GitHub App token, exported as `GITHUB_TOKEN` to the CLI.
- Official `examples/pr-review-comprehensive.yml` uses
  `permissions: contents: read, pull-requests: write, id-token: write`.
- `actions/checkout` latest is `v7.0.1`; this repo already standardizes `@v7` everywhere. The
  circulating snippet's `@v6` is stale here.
- Marketplace manifest `.claude-plugin/marketplace.json` declares `name: "claude-code-plugins"`
  and a plugin `name: "code-review"`, so `code-review@claude-code-plugins` from
  `https://github.com/anthropics/claude-code.git` is correct.
- `plugins/code-review/commands/code-review.md` declares in its frontmatter:
  `allowed-tools: Bash(gh issue view:*), Bash(gh search:*), Bash(gh issue list:*), Bash(gh pr comment:*), Bash(gh pr diff:*), Bash(gh pr view:*), Bash(gh pr list:*), mcp__github_inline_comment__create_inline_comment`.
  A `--allowedTools` value restricted to the inline-comment MCP tool alone silently starves the
  review: it cannot read the diff or post the summary comment. The default must be the union.
- That command has **no `$ARGUMENTS` placeholder and no `argument-hint`**. It parses `--comment`
  from prose and describes "the given pull request". Passing `owner/repo/pull/N` works as free-text
  context, not as a formal parameter.

### Secret ownership (resolved)

A reusable workflow executes in the **caller's** context: caller runners, caller `GITHUB_TOKEN`,
caller secrets. GitHub docs on `jobs.<job_id>.secrets.inherit`: *"Use the `inherit` keyword to pass
all the calling workflow's secrets to the called workflow."*

Therefore an external consumer supplies their own `ANTHROPIC_API_KEY`, and this repo's secrets are
never in scope. That is the intended behavior — cost and credential isolation both fall out of it.

**Reverse-direction risk that must be documented:** `secrets: inherit` hands the caller's *entire*
secret set to code this repo controls, and `@v1` is a floating tag force-moved on every v1.x
release. External consumers should pass secrets explicitly rather than inherit.

**Undocumented semantics — do not rely on it.** GitHub's docs do not state how
`on.workflow_call.secrets.<id>.required: true` interacts with `secrets: inherit`. The explicit guard
step removes the dependency on that behavior entirely.

## Steps

1. **Create `.github/workflows/code-review.yml`** with the full `on: workflow_call` block (9 inputs,
   2 secrets, no outputs, no job-level `permissions:`).
   **Done when:** `actionlint` parses the file with zero errors and all 9 inputs plus both secrets
   are present in the `on.workflow_call` block.

2. **Add the `Resolve auth` step** with `id: auth`, reading secrets through `env:` (the `secrets`
   context is not usable in a job-level `if:`), writing `ready=true|false` to `$GITHUB_OUTPUT`.
   Ready is true when `ANTHROPIC_API_KEY` is non-empty, or `CLAUDE_CODE_OAUTH_TOKEN` is non-empty,
   or both `federation-rule-id` and `anthropic-org-id` are non-empty.
   **Done when:** with all three credential paths empty the step emits a `::notice` and sets
   `ready=false`; with `ANTHROPIC_API_KEY` non-empty it sets `ready=true`.

3. **Gate the review steps.** `Checkout caller repo` (`actions/checkout@v7`,
   `fetch-depth: ${{ inputs.fetch-depth }}`) and `Code review` both carry
   `if: steps.auth.outputs.ready == 'true'`.
   **Done when:** `rg -c "if: steps.auth.outputs.ready == 'true'" .github/workflows/code-review.yml`
   returns exactly `2`.

4. **Wire `anthropics/claude-code-action@${{ inputs.claude-code-action-ref }}`**, mapping all 9
   inputs to their upstream names.
   **Done when:** every input name passed to the action exists in `action.yml@v1`, verified with
   `rg` against a fetched copy rather than from memory.

5. **Create `examples/pr-code-review.yml`** matching the `pr-ci.yml` template, granting
   `contents: read`, `pull-requests: write`, `issues: read`, `id-token: write`, with an inline
   comment stating that `id-token: write` is mandatory and why.
   **Done when:** the file declares all four permissions plus `secrets: inherit`, and its header
   comment matches the two-line convention.

6. **Create `.github/workflows/pr-code-review.yml`** — this repo's own caller, pointing at
   `./.github/workflows/code-review.yml`.
   **Done when:** `rg -l "pull_request" .github/workflows/` includes the new file (it currently
   matches nothing).

7. **Update `docs/architecture.md`**: add `### Reusable workflow: code-review.yml` between
   `release.yml` and `### Callers`, and `### Why does code-review.yml skip the platform re-checkout?`
   under Key design decisions.
   **Done when:** both headings exist and the second cross-references the existing
   `### Why does each reusable re-checkout the platform repo?`.

8. **Update `docs/secrets.md`** (table row + configuration subsection),
   **`docs/dependabot.md`** (code-review note), **`README.md`** (table row + two tree lines).
   **Done when:** `rg -c ANTHROPIC_API_KEY docs/secrets.md` is at least `2` and
   `rg -c "pr-code-review" README.md` is at least `2`.

## Interfaces

`on.workflow_call` contract for `code-review.yml`:

| Input | Type | Default |
|---|---|---|
| `plugins` | string | `code-review@claude-code-plugins` |
| `plugin-marketplaces` | string | `https://github.com/anthropics/claude-code.git` |
| `prompt` | string | `/code-review:code-review --comment ${{ github.repository }}/pull/<number>` |
| `allowed-tools` | string | `mcp__github_inline_comment__create_inline_comment,Bash(gh pr diff:*),Bash(gh pr view:*),Bash(gh pr comment:*),Bash(gh pr list:*),Bash(gh issue view:*),Bash(gh issue list:*),Bash(gh search:*)` |
| `track-progress` | boolean | `false` |
| `fetch-depth` | string | `'1'` |
| `claude-code-action-ref` | string | `'v1'` |
| `federation-rule-id` | string | `''` |
| `anthropic-org-id` | string | `''` |

Secrets, both `required: false`: `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`.

No outputs. No job-level `permissions:` block — see AC-1.

## Function Design

- **`.github/workflows/code-review.yml`** — three steps, each with one concern:
  - `Resolve auth` — resolves a credential to a single boolean. Nothing else.
  - `Checkout caller repo` — checkout only.
  - `Code review` — invokes the action only.
- **`examples/pr-code-review.yml`** — declaration only: trigger, permissions, concurrency, `uses:`.
  No logic.
- **`.github/workflows/pr-code-review.yml`** — identical in shape to the example, but resolving the
  reusable by local path so a PR exercises the branch's own version.

## Acceptance Criteria (EARS)

- **AC-1.** The reusable workflow shall declare `on: workflow_call` and shall not declare a
  job-level `permissions:` block.
- **AC-2.** The reusable workflow shall declare every secret with `required: false`.
- **AC-3.** When no Anthropic credential is resolvable, the workflow shall emit a `::notice`, skip
  the review steps, and complete with a success conclusion.
- **AC-4.** When `ANTHROPIC_API_KEY` is non-empty, the workflow shall run the review steps.
- **AC-5.** When `federation-rule-id` and `anthropic-org-id` are both non-empty, the workflow shall
  run the review steps without requiring a static key.
- **AC-6.** The workflow shall pass an `allowed-tools` default that includes
  `Bash(gh pr diff:*)`, `Bash(gh pr view:*)`, `Bash(gh pr comment:*)` and
  `mcp__github_inline_comment__create_inline_comment`.
- **AC-7.** The workflow shall check out the caller repository with `actions/checkout@v7`.
- **AC-8.** If a Dependabot-authored pull request triggers the workflow, then the workflow shall
  skip the review and complete green.
- **AC-9.** If a fork-authored pull request triggers the workflow, then the workflow shall skip the
  review and complete green.
- **AC-10.** The caller example shall grant `contents: read`, `pull-requests: write`,
  `issues: read` and `id-token: write`, and shall use `secrets: inherit`.
- **AC-11.** The change shall be released on the v1.x line using a `feat:` commit, with no input
  removed, renamed, or made required.

## Out of Scope

- Creating the `ANTHROPIC_API_KEY` org secret. Requires `admin:org`; the current token returns 403
  on `/orgs/refokus-agency/actions/secrets`.
- Configuring the Anthropic workload-identity federation rule.
- Migrating existing consumer repos to add the new caller.
- Fixing the stale `GH_PAT_TOKEN` line in `CLAUDE.md` and adding `.atl/` to `.gitignore` — both now
  live on the separate `fix/stale-gh-pat-token-and-atl-gitignore` branch.
- Reconciling `docs/troubleshooting.md`, which instructed consumers to configure and scope
  `GH_PAT_TOKEN` while its own banner said referencing it is the bug. Fixed in PR #66.

## Edge Cases + Error Handling

| # | Scenario | Source | Handling |
|---|---|---|---|
| 1 | Dependabot PR — no custom Actions secrets | [from issue] | Guard resolves `ready=false`, skips green |
| 2 | Fork PR on a public repo — read-only token, no secrets | [from issue] | Same guard; strictly broader than an actor guard |
| 3 | Consumer configured neither API key nor federation | [from issue] | `::notice` naming exactly what to configure |
| 4 | Consumer passes multiple plugins | [from issue] | Documented as newline-separated, not comma-separated |
| 5 | Caller omits `id-token: write` | [from issue] | Not detectable from inside the reusable; mandatory comment in the example and a note in `secrets.md` |
| 6 | Draft PR | [from issue] | `ready_for_review` is in the trigger types, and the plugin's own step 1 already skips drafts |
| 7 | `--allowedTools` missing the `gh` commands | [inferred] | Default is the union of the plugin frontmatter's `Bash(gh ...)` entries plus the inline-comment MCP tool |
| 8 | `secrets` context unusable in a job-level `if:` | [inferred] | Guard runs in `run:` with `env:`, writing to `$GITHUB_OUTPUT` |
| 9 | Federation or OAuth-only path active | [inferred] | Corrected during review: `classify_inline_comments` defaults to **`true`** upstream, not disabled. But its classification step receives only `anthropic_api_key`, so on the OAuth-only and federation-only paths classification is skipped and all buffered inline comments post unfiltered. Verified fail-open in `post-buffered-inline-comments.ts` (no error, no dropped comments). Documented in `docs/secrets.md`. |

## Done Criteria per Feature

| Feature | Done when |
|---|---|
| Reusable workflow | AC-1, AC-2, AC-7 |
| Auth guard | AC-3, AC-4, AC-5, AC-8, AC-9 |
| Correct tool allowlist | AC-6 |
| Caller example + dogfooding | AC-10 |
| v1.x compatibility | AC-11 |

## Risks

- **Declaring `permissions:` in the reusable** → every caller that does not grant the exact scope
  fails at startup, across the whole org. Mitigation: AC-1 forbids it; `deploy.yml`'s comment is the
  documented precedent.
- **Marking the secret `required: true`** → relies on undocumented `secrets: inherit` interaction and
  could fail red in every consumer. Mitigation: `required: false` plus the explicit guard.
- **The floating `@v1` tag** → merging propagates to every Refokus repo at the next release.
  Mitigation: before merge, point a low-stakes consumer repo at
  `refokus-agency/platform/.github/workflows/code-review.yml@feat/code-review-reusable-workflow`
  and watch a real run.
- **`secrets: inherit` from external consumers** → they hand their full secret set to code this repo
  controls. Mitigation: document explicit-secret passing for consumers outside the org.
- **Unbounded API cost** → the plugin fans out four parallel review agents, two on Opus, per PR
  event. Mitigation: document the cost in `secrets.md`; the trigger deliberately excludes `push`.
- **Runtime artifacts committed** → resolved out-of-band: `.atl/` is now ignored on
  `fix/stale-gh-pat-token-and-atl-gitignore`. Re-check `git status --porcelain` before opening this
  feature's PR in case that branch has not merged yet.

## Test Strategy

A reusable workflow cannot be executed locally, and `act` does not reliably exercise secrets or
composite actions. So verification is layered:

1. **Static** — `actionlint` over all three new YAML files (syntax, expression validity, action refs).
2. **Contract** — confirm every input name passed to `claude-code-action` exists in a freshly
   fetched `action.yml@v1`, using `rg`. Never from memory.
3. **Guard in isolation** — run the guard's bash block directly with `ANTHROPIC_API_KEY` unset and
   then set to a dummy value, asserting the `ready` value written to a temp `$GITHUB_OUTPUT`.
4. **Integration** — push the branch, then open a draft PR against this repo. The dogfood caller in
   `.github/workflows/pr-code-review.yml` resolves the reusable by local path, so the PR exercises
   the branch's own code. This is why dogfooding is part of the plan rather than a nice-to-have:
   it is the only real integration test available.
5. **Dependabot path** — wait for the next Dependabot PR on the branch, or simulate with a fork PR,
   and assert the run completes green with the skip notice.

**Known limitation:** step 4 only proves the guard skips green unless `ANTHROPIC_API_KEY` exists at
the org or repo level. Proving the review actually runs requires that secret, which is out of scope
here and needs an org admin.
