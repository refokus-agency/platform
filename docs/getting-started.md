# Getting started

This guide walks through setting up a **new repo** with the centralized CI/CD. If you're moving an existing repo with its own workflows, read the [migration guide](migration.md) instead.

## Prerequisites

Before you start, make sure:

- Your repo lives in the `refokus-agency` organization.
- The required secrets are available to the repo (see [secrets](secrets.md)).
- Your `package.json` has the scripts you want CI to run (`lint`, `typecheck`, `test`, `build` — all optional).
- For Vercel-deployed projects: a Vercel project exists and `VERCEL_PROJECT_ID` is set at the repo level.

## 1. Figure out which workflows you need

The workflows in [`examples/`](../examples/) are **atomic**: each file handles one trigger (PR, push to main, push to production) and one action. Pick the ones that match the triggers your repo cares about.

| File | Trigger | What it runs |
|---|---|---|
| `pr-ci.yml` | PR | CI only |
| `pr-preview.yml` | PR | CI + preview deploy |
| `main-stage.yml` | push to `main` | CI + stage deploy |
| `main-production.yml` | push to `main` | CI + production deploy |
| `production-deploy.yml` | push to `production` | CI + production deploy |
| `main-release.yml` | push to `main` | CI + semantic-release |

Common combinations:

| Shape | Files |
|---|---|
| Library (release on main) | `pr-ci.yml` + `main-release.yml` |
| Vercel 2-env (preview on PR, prod on main) | `pr-preview.yml` + `main-production.yml` |
| Vercel 3-env (preview on PR, stage on main, prod on production branch) | `pr-preview.yml` + `main-stage.yml` + `production-deploy.yml` |

If your repo has a shape not listed, combine the atomic files that match your triggers. The reusables work fine in any valid combo.

## 2. Copy the files into your repo

Keep their filenames — the naming convention is shared across Refokus repos so anyone browsing any `.github/workflows/` folder recognizes the pattern.

```bash
# Example for a 3-env Vercel service
mkdir -p .github/workflows
BASE=https://raw.githubusercontent.com/refokus-agency/platform/main/examples
curl -o .github/workflows/pr-preview.yml $BASE/pr-preview.yml
curl -o .github/workflows/main-stage.yml $BASE/main-stage.yml
curl -o .github/workflows/production-deploy.yml $BASE/production-deploy.yml
```

## 3. Adapt the callers (if needed)

The examples work out of the box. Tweak only if you need to:

- **Override the package manager.** Auto-detect works 99% of the time. If your repo has a weird lockfile state, pass it explicitly:

  ```yaml
  ci:
    uses: refokus-agency/platform/.github/workflows/ci.yml@main
    with:
      package-manager: bun
    secrets: inherit
  ```

- **Change the Node version.** Default is `24`. Override per-job:

  ```yaml
  with:
    node-version: '22'
  ```

- **Skip a CI step.** If your repo doesn't have a `lint` script (or doesn't want it run), it'll be skipped automatically. But you can also disable it explicitly:

  ```yaml
  with:
    run-lint: false
  ```

- **Allow install scripts.** By default the composite action passes `--ignore-scripts` to pnpm/npm/bun, which disables `postinstall` / `prepare` / similar lifecycle scripts during `install`. This is a security precaution against supply-chain attacks. If your repo legitimately needs those scripts to run (native modules like `sharp` or `bcrypt`, binary downloaders like `puppeteer`), opt out explicitly:

  ```yaml
  with:
    unsafe-install-scripts: true
  ```

  The name signals the risk — enabling this re-opens a path for compromised dependencies to exfiltrate secrets. See [dependabot.md](dependabot.md) for details.

## 4. Verify secrets

Your repo needs these secrets available (via org inheritance or repo-level):

| Secret | Needed by | Expected level |
|---|---|---|
| `GH_PAT_TOKEN` | all workflows | org |
| `VERCEL_TOKEN` | `deploy.yml` | org |
| `VERCEL_ORG_ID` | `deploy.yml` | org |
| `VERCEL_PROJECT_ID` | `deploy.yml` | **repo** (each project has its own) |

Check under **Settings → Secrets and variables → Actions** in the repo. Anything inherited from the org will show up under "Organization secrets".

See [secrets.md](secrets.md) for how to create them.

## 5. Configure branch protection

This step ensures Dependabot PRs can't be merged without a human reviewer explicitly dispatching the workflow (which makes secrets available). Without it, Dependabot PRs would land on a failed check forever.

1. Go to **Settings → Branches → Add rule** (or edit the existing `main` rule).
2. Set **Branch name pattern** to `main`.
3. Enable **Require status checks to pass before merging**.
4. Enable **Require branches to be up to date before merging**.
5. In the search box, find and select the check produced by your caller. Typical names:
   - `Pull Request / ci / checks` for repos with `pr-ci.yml` or `pr-preview.yml`.
   - (The exact name only appears after the workflow has run at least once.)
6. Save.

For 3-env custom-code repos, repeat for the `production` branch with the corresponding check (`Deploy Production / ...`).

Once configured, Dependabot PRs behave like this:

- Dependabot opens a PR → automatic run fails (no secrets), check appears red.
- Reviewer reads the diff, then goes to Actions tab → Run workflow → picks the Dependabot branch → dispatches.
- The dispatched run executes with secrets, succeeds, and updates the check status on the PR commit.
- Merge unblocks.

See [dependabot.md](dependabot.md) for the rationale and troubleshooting.

## 6. Open a PR and verify

```bash
git checkout -b test-ci
git commit --allow-empty -m "test: trigger CI"
git push -u origin test-ci
gh pr create --fill
```

In the PR checks:

1. Each workflow you added that triggers on `pull_request` appears.
2. The CI job passes (or fails with an actionable error).
3. If you included `pr-preview.yml`, the preview deploy runs and produces a URL.

For on-push flows (stage, production, release), merge the PR or push to the corresponding branch and watch the Actions tab.

If something breaks, check [troubleshooting.md](troubleshooting.md).

## 7. (Optional) Verify Dependabot flow

If your repo has Dependabot enabled, the first Dependabot PR is a good test of the manual-dispatch flow. If no Dependabot PRs are pending, you can create a test scenario by:

1. Force-triggering one with `@dependabot recreate` or `@dependabot rebase` on an existing Dependabot PR.
2. Watching the automatic run fail (expected).
3. Dispatching the workflow manually from the Actions tab on that branch.
4. Confirming the check updates and the PR becomes mergeable.

## What happens under the hood

When a trigger fires:

1. The matching workflow file in your repo runs.
2. It calls the reusable(s) in `refokus-agency/platform`.
3. Each reusable checks out your repo, sets up Node + package manager, runs its steps, and exits.
4. Your repo never has to know how lint/test/deploy actually work — it just declares "on this trigger, run these reusables".

See [architecture.md](architecture.md) for the full design.
