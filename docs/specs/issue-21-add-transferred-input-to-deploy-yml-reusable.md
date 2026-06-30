---
issue_number: 21
issue_title: "Add `transferred` input to `deploy.yml` reusable"
repo: "refokus-agency/platform"
labels: [bug]
plan_level: "full"
depth: "medium"
branch_name: "transferred-flag"
created_at: "2026-06-30T00:00:00Z"
---

# Implementation Plan: #21 — Add `transferred` input to `deploy.yml` reusable

Part of epic #20.

## Files

| # | Action | Path | Purpose |
|---|--------|------|---------|
| 1 | modify | `.github/workflows/deploy.yml` | Add `transferred` boolean input; short-circuit all Vercel work when true, emitting a grep-able skip line |

## Codebase Context

- `deploy.yml` is a reusable `workflow_call` workflow with a single `deploy` job (~10 steps): validate environment, checkout caller, checkout platform, configure npm, setup, map env→Vercel flags, install Vercel CLI, pull, build, deploy, alias-for-stage.
- Additive, default-preserving change → fits the **v1.x line** (no major bump). Per `CLAUDE.md` blast-radius rules, the new input **MUST default `false`** because all consumer repos pin `@v1` and would see it the moment it ships.
- GitHub Actions has no early-exit within a job; the idiom is per-step `if:` guards. The `Alias for stage` step already carries `if: inputs.environment == 'stage'` → its guard must be combined with the transferred check.
- A reusable workflow cannot be run locally or in this repo; real verification is pushing the branch and pointing a low-stakes caller at `@transferred-flag` (per `CLAUDE.md` testing protocol).

## Steps

1. Add `transferred` input (boolean, `required: false`, `default: false`) to `workflow_call.inputs` with a clear description. → `.github/workflows/deploy.yml`
   **Done when:** `inputs.transferred` is declared, type boolean, default false.
2. Add a first job step "Transferred repo — skip deploy" guarded by `if: ${{ inputs.transferred }}` that echoes `[deploy] skipped: repo marked as transferred`. → `.github/workflows/deploy.yml`
   **Done when:** the step exists, runs only when `transferred` is true, and emits that exact line.
3. Gate every remaining step with `if: ${{ !inputs.transferred }}` (validate, checkout caller, checkout platform, configure npm, setup, map env, install vercel, pull, build, deploy); combine the alias step into `if: ${{ !inputs.transferred && inputs.environment == 'stage' }}`. → `.github/workflows/deploy.yml`
   **Done when:** no Vercel CLI / setup step can execute while `transferred` is true.

## Interfaces

- **`transferred` input** — `type: boolean`, `required: false`, `default: false`. Caller-supplied flag marking a repo that has been handed off to a client's Vercel team; when true the deploy job no-ops cleanly.

## Function Design

N/A — single declarative YAML workflow, no functions to decompose. The only "control flow" is the per-step `if:` guard expressions described in Steps.

## Acceptance Criteria (EARS)

- **AC-1** (ubiquitous): The `deploy.yml` reusable shall declare a `transferred` input of type boolean with default `false`.
- **AC-2** (event-driven): When `transferred` is `true`, the deploy job shall emit the log line `[deploy] skipped: repo marked as transferred` and exit 0 without invoking the Vercel CLI (pull/build/deploy/alias).
- **AC-3** (event-driven): When `transferred` is `false` or omitted, the deploy job shall behave identically to the pre-change workflow.
- **AC-4** (ubiquitous): The change shall affect only deploy steps; the separate `ci.yml` reusable shall remain unaffected.
- **AC-5** (unwanted-behavior): If `transferred` is `true`, then the job shall succeed without requiring valid Vercel secrets or a valid environment mapping.

## Out of Scope

- Updating transferred callers (`umh-custom-code`, `profile-behavior-custom-code`) to pass `transferred: true` → issue #22.
- Documenting the pattern in `README.md` → issue #23.
- Org-wide alert on consecutive Vercel-deploy failures → issue #24.

## Edge Cases + Error Handling

| # | Scenario | Source | Handling |
|---|----------|--------|----------|
| 1 | `transferred: true` + invalid/empty `environment` | [inferred] | Validate step gated off → no failure, clean skip |
| 2 | `transferred` omitted | [from issue] | Default `false` → identical behavior (AC-3) |
| 3 | `transferred: true` + Vercel secrets missing | [inferred] | No Vercel steps run → job still green (AC-5) |
| 4 | `Alias for stage` step has its own `if:` | [inferred] | Combine: `!inputs.transferred && inputs.environment == 'stage'` |
| 5 | Accidental `transferred: true` on an active repo | [from issue] | Loud, grep-able skip line so the silent-skip is noticeable |

## Done Criteria per Feature

| Feature | Done when |
|---------|-----------|
| `transferred` input declared | AC-1 |
| Clean skip behavior | AC-2, AC-3, AC-4, AC-5 |

## Risks

- **Contract change visible to all `@v1` callers** → default `false` (mandatory) preserves existing behavior; this is the load-bearing safeguard.
- **Per-step `if:` proliferation could miss a Vercel-invoking step** → review every step is gated before opening the PR; the skip path must invoke zero Vercel commands.

## Test Strategy

- **Static:** YAML parse / `actionlint` on `deploy.yml` to catch syntax and expression errors.
- **Manual (per `CLAUDE.md`, no local run of reusables):** push `transferred-flag`, point a low-stakes caller at `refokus-agency/platform/.github/workflows/deploy.yml@transferred-flag`:
  - (a) `transferred: true` → run is green, log shows `[deploy] skipped: repo marked as transferred`, no Vercel invocation.
  - (b) `transferred: false` → normal deploy unchanged.
  - Performed in the `/implement-code` verify step.
