# Architecture

Design decisions behind this repo. Read this when you're about to change something and want to understand the tradeoffs the current shape is making.

## The problem

Before this repo existed, each Refokus project carried its own CI/CD workflows:

- Custom-code repos (~7 active) each had `preview.yml`, `stage.yml`, `production.yml`.
- Service repos had `ci.yml`, `deploy-preview.yml`, `deploy-production.yml`.
- Library repos had `release-package-version.yml`.

Three consequences:

1. **Drift.** Repos diverged over time. Node versions, pnpm versions, deploy flags — all slightly different. Hard to tell what was intentional vs. leftover.
2. **Duplicated fixes.** Every CI improvement had to be copy-pasted into N repos. In practice, one repo would get the fix and the others wouldn't.
3. **Friction on change.** Trying a new tool (e.g. moving from Node 22 to 24) meant touching 10+ repos.

The goal of this repo is to make those problems go away by having **one place** where CI/CD logic lives, and **thin callers** in each repo that point to it.

## The building blocks

### Composite action: `setup`

`.github/actions/setup/action.yml`

Detects the package manager from the lockfile, installs Node and the pm, runs the install command, and configures caching. Used by all three reusables.

Outputs `pm` (the detected or explicitly-chosen package manager) so subsequent steps can run `${{ steps.setup.outputs.pm }} run <script>`.

### Reusable workflow: `ci.yml`

Runs the standard CI checklist (lint, typecheck, test, build) against a repo. Each step is skipped automatically if the corresponding `package.json` script doesn't exist — so a repo with only tests works as well as one with the full kit.

### Reusable workflow: `deploy.yml`

Deploys to Vercel at a specific environment (`preview`, `stage`, or `production`). The workflow itself is environment-agnostic — the caller passes the environment, the reusable handles the Vercel CLI incantations.

### Reusable workflow: `release.yml`

Runs semantic-release, which handles version bumps, changelog generation, git tags, and publishing to GitHub Packages.

### Callers

Each repo has a thin workflow that composes the reusables. The caller owns branch logic (which branch triggers which deploy environment) and nothing else.

## Key design decisions

### Why split into separate reusables instead of one big workflow?

A single "run CI then deploy" workflow would couple CI to deploys. That's wrong because:

- Libraries don't deploy (they release).
- Some repos want CI on PRs without deploying.
- Different repos chain the pieces differently.

Three focused reusables compose into whatever a caller needs. The cost is a bit more verbosity in callers — worth it for the flexibility.

### Why a composite action for setup instead of inlining?

Without the composite action, every reusable would need conditional steps for pnpm vs. npm vs. bun. That's 3x the cases times 3 reusables = 9 places to get wrong.

The composite action centralizes the "what pm, how install" logic. The reusables stay readable.

### Why parameterize the deploy environment instead of having `deploy-preview.yml`, `deploy-stage.yml`, `deploy-production.yml`?

Earlier drafts had one reusable per environment. They were 90% identical — same checkout, same Vercel commands — with only a `--prod` flag or a different `vercel pull --environment=` value differing.

A parameterized reusable collapses them into one file. The caller loses nothing: it still declares three deploy jobs (preview, stage, production), but each job points at the same reusable with a different `environment` input.

### Why does the caller own the branch-to-environment mapping?

Two reasons:

1. **Different project types have different flows.** Custom-code has 3 environments, service has 2. A reusable that encoded "main → stage, production → production" would be wrong for services. A reusable that encoded "main → production" would be wrong for custom-code.
2. **Callers are cheap to read.** Each caller file declares its trigger in the `on:` block. No indirection to a reusable to figure out what a branch does.

### Why one caller file per trigger instead of one file with conditional jobs?

Earlier iterations had a single caller file per repo (`ci-cd.yml`) with multiple jobs gated by `if: github.event_name == 'push' && github.ref == '...'`. That works, but on every PR the UI shows a "skipped" check for each job that doesn't match the event.

Splitting into one file per trigger (e.g. custom-code: `pr.yml` on PR, `stage.yml` on main push, `production.yml` on production push) means every file that fires has all its jobs run — no skipped checks cluttering the PR UI. A bit more files per repo, but each one is tiny (10–15 lines) and does exactly one thing.

Libraries get `ci.yml` + `release.yml`. Services get `pr.yml` + `deploy.yml`. Custom-code gets `pr.yml` + `stage.yml` + `production.yml`.

File naming convention: the filename reflects **when** the workflow fires (`pr.yml`, `stage.yml`, `production.yml`, `release.yml`). The `name:` inside reflects the same. For libraries, `ci.yml` is kept because the workflow is pure CI — no preview deploy to muddy the name.

### Why build in both CI and deploy?

The `ci.yml` reusable runs `pnpm build` (or whichever pm). The `deploy.yml` reusable runs `vercel build`. That's two builds per deployment.

We could share the build output via artifacts (`vercel build --prebuilt`), but:

- For custom-code, the build is fast (<1 min). Saving a minute isn't worth the plumbing.
- For services (Next.js), builds differ by environment — a preview build isn't reusable for production.
- The plumbing (upload-artifact, download-artifact, caller coordination) adds complexity to the reusables.

We chose to tolerate the duplication. If it becomes painful (e.g. a heavy Next.js service with frequent deploys), we can add `--prebuilt` support with an input flag later without breaking existing callers.

### Why `secrets: inherit`?

Manually declaring each secret in each caller:

```yaml
secrets:
  VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}
  VERCEL_ORG_ID: ${{ secrets.VERCEL_ORG_ID }}
  # ... etc
```

would be noisy and easy to miss when adding a new secret. `secrets: inherit` forwards everything the caller has access to, so adding a new required secret is a one-line change in the reusable.

The reusable declares which secrets are `required: true`, so a missing one fails with a clear error.

### Why `@main` instead of `@v1`?

Pinning to tags is the "correct" thing long-term but wrong for the current phase:

- We're actively iterating. Every fix would need a new tag + bump in every caller repo. That's 10+ PRs per change.
- No repo depends on stability yet — everyone's migrating.

We use `@main` while things are changing frequently. When the reusables stabilize (target: 2–3 months without breaking changes), we cut `v1.0.0` and migrate callers to `@v1`. See [contributing.md](contributing.md) for the rollout plan.

### Why does each reusable re-checkout the `platform` repo?

The composite action (`setup`) lives in `platform`. When a reusable runs, the working directory is a checkout of the **caller's** repo — not platform. To use a local composite action path like `./.github/actions/setup`, the reusable needs platform checked out somewhere accessible.

Each reusable does a secondary checkout of `refokus-agency/platform` into `.platform/`, then references `./.platform/.github/actions/setup`. The `platform-ref` input controls which ref to check out (defaults to `main`, matches the workflow's own ref so they don't drift).

An alternative would be to publish the composite action as a standalone GitHub Action on the marketplace and reference it by name. That's overkill — this one's internal.

## What's out of scope for now

These came up in the design discussion and were explicitly deferred:

- **Artifact-based build sharing** (`vercel build --prebuilt`). Add later if duplication hurts.
- **Public npm publishing.** Libraries publish to GitHub Packages. If a lib ever needs npm public, add a `registry` input.
- **A shared "scripts" project type.** Doesn't exist yet. If one appears, it can reuse `ci.yml` with nothing new.
- **Notification integrations** (Slack on deploy, etc.). Not in scope for v1.
- **Dependabot config distribution.** Dependabot rules live per repo. Centralizing is a separate project.
