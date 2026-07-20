# Migration guide

How to move an existing repo off its bespoke workflows and onto the centralized setup.

## Before you start

- Read [getting-started.md](getting-started.md) first for the mental model — this guide covers what's different when a repo already has workflows.
- Migrate **one repo at a time** and verify it works end-to-end before moving on.
- Do it on a branch, not directly on `main`. You want to see the new workflows run on a PR before anything touches stage/production.

## The general pattern

1. Create a feature branch from `main`.
2. List the triggers your current workflows react to (PR events, push to main, push to production, etc.).
3. Pick the matching atomic files from [`examples/`](../examples/).
4. Delete the old workflow files and drop the new ones in.
5. Verify secrets are accessible.
6. Push and open a PR; watch the Actions tab.
7. Fix anything that breaks.
8. Merge when green.

## Figure out your shape

For each old workflow, ask: **what trigger is this responding to, and what does it do?** Then find the atomic file that covers it.

| Old workflow fires on… | …and does | Use |
|---|---|---|
| PR events | CI only | `pr-ci.yml` |
| PR events | CI + Vercel preview deploy | `pr-preview.yml` |
| push to `main` | CI + stage deploy | `main-stage.yml` |
| push to `main` | CI + production deploy | `main-production.yml` |
| push to `production` | CI + production deploy | `production-deploy.yml` |
| push to `main` | CI + semantic-release | `main-release.yml` |

Combos for the common shapes:

| Shape | Files |
|---|---|
| Library | `pr-ci.yml` + `main-release.yml` |
| Vercel 2-env | `pr-preview.yml` + `main-production.yml` |
| Vercel 3-env | `pr-preview.yml` + `main-stage.yml` + `production-deploy.yml` |

## Example migrations

### Library (`navigation`-style)

```bash
git checkout -b migrate-to-platform-cicd
rm .github/workflows/release-package-version.yml
BASE=https://raw.githubusercontent.com/refokus-agency/platform/main/examples
curl -o .github/workflows/pr-ci.yml $BASE/pr-ci.yml
curl -o .github/workflows/main-release.yml $BASE/main-release.yml
git add .github/workflows/
git commit -m "ci: migrate to centralized platform workflows"
git push -u origin migrate-to-platform-cicd
```

**Gotchas:**
- Need a `.releaserc` with the plugin list. The reusable ships `semantic-release` via `cycjimmy/semantic-release-action` with the common extras (`changelog`, `git`, `exec`) — no need to add them to devDependencies.
- Make sure `publishConfig` in `package.json` points at GitHub Packages.

### Vercel 2-env service (`ghost-site`-style)

```bash
git checkout -b migrate-to-platform-cicd
rm .github/workflows/ci.yml .github/workflows/deploy-preview.yml .github/workflows/deploy-production.yml
BASE=https://raw.githubusercontent.com/refokus-agency/platform/main/examples
curl -o .github/workflows/pr-preview.yml $BASE/pr-preview.yml
curl -o .github/workflows/main-production.yml $BASE/main-production.yml
git add .github/workflows/
git commit -m "ci: migrate to centralized platform workflows"
git push -u origin migrate-to-platform-cicd
```

### Vercel 3-env service or custom-code (`workflow-runner`, `webflow-custom-code-tmp`)

```bash
git checkout -b migrate-to-platform-cicd
rm .github/workflows/preview.yml .github/workflows/stage.yml .github/workflows/production.yml
BASE=https://raw.githubusercontent.com/refokus-agency/platform/main/examples
curl -o .github/workflows/pr-preview.yml $BASE/pr-preview.yml
curl -o .github/workflows/main-stage.yml $BASE/main-stage.yml
curl -o .github/workflows/production-deploy.yml $BASE/production-deploy.yml
git add .github/workflows/
git commit -m "ci: migrate to centralized platform workflows"
git push -u origin migrate-to-platform-cicd
```

**Gotchas:**
- `deploy.yml`'s job unconditionally requests `pull-requests: write` (it comments the deploy URL on the PR when triggered by one), and a reusable can't be granted more permissions than its caller holds. Add `pull-requests: write` to the `permissions:` block in **all three** caller files, not just `pr-preview.yml`, or the run fails to start.
- If the repo has a git submodule (common in custom-code sites sharing a component library across sibling sites), add `submodules: true` to every `ci:`/`deploy-*:` job's `with:` block and make sure `CHECKOUT_TOKEN` is available — see [secrets.md § Submodules](secrets.md#submodules). Without it the submodule path checks out empty and the build fails.

## Behavior changes to expect

Compared to the common pre-migration patterns:

- **Preview deploy triggers on `pull_request`, not on every push.** If your devs pushed feature branches without opening PRs to get previews, they'll now need to open a PR (draft works) to get the preview URL.
- **CI is stricter.** The new CI runs `lint`, `typecheck`, `test`, and `build` if the scripts exist. Many older workflows only ran `test`. Missing scripts are silently skipped; broken ones will surface.
- **Node pins at 24** unless the caller overrides `node-version`. Most repos update cleanly.

## Verifying the migration

Before merging:

- [ ] CI runs and passes on the migration branch.
- [ ] For Vercel repos: preview deploy succeeds and the URL loads.
- [ ] No old workflows still fire — check the Actions tab.
- [ ] No secrets errors in the logs.

After merging:

- **library**: push a Conventional Commit (`fix:`, `feat:`) and verify a new version in GitHub Packages.
- **Vercel 2-env**: the merge to `main` triggers production deploy.
- **Vercel 3-env**: the merge to `main` triggers stage deploy; to promote to production, push or merge into the `production` branch.
- If `main` isn't already protected with the `ci` check required, add that now — see [getting-started.md → step 6](getting-started.md#6-recommended-require-the-ci-check-on-main).

## Rolling back

1. Revert the migration commit on `main`.
2. Old workflows come back.
3. Investigate on a branch.
4. Re-migrate once fixed.

Don't leave a half-migrated state.

## Migration order recommendation

Start with the lowest-risk repos to build confidence:

1. **A library** (e.g. `navigation`) — failure mode is "release doesn't publish", recoverable.
2. **A low-traffic service** — easier to roll back a bad deploy.
3. **Template repos** (e.g. `webflow-custom-code-tmp`) — validates the 3-env flow without client pressure.
4. **Client-facing repos**, one at a time, starting with the least active.

Spread the rollout over a week or two, not a single day.
