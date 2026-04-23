# Getting started

This guide walks through setting up a **new repo** with the centralized CI/CD. If you're moving an existing repo with its own workflows, read the [migration guide](migration.md) instead.

## Prerequisites

Before you start, make sure:

- Your repo lives in the `refokus-agency` organization.
- The required secrets are available to the repo (see [secrets](secrets.md)).
- Your `package.json` has the scripts you want CI to run (`lint`, `typecheck`, `test`, `build` — all optional).
- For Vercel-deployed projects: a Vercel project exists and `VERCEL_PROJECT_ID` is set at the repo level.

## 1. Pick your project type

Each project type has a small set of caller workflows. Each file handles one trigger (PR, push to a specific branch) so the PR UI never shows a skipped check.

| Your project is… | Copy these files |
|---|---|
| A Webflow site with custom code | [`examples/custom-code/`](../examples/custom-code/) — 3 files: `ci.yml`, `stage.yml`, `production.yml` |
| A backend service or integration on Vercel | [`examples/service/`](../examples/service/) — 2 files: `ci.yml`, `deploy.yml` |
| An npm library for `@refokus-agency` | [`examples/library/`](../examples/library/) — 2 files: `ci.yml`, `release.yml` |

## 2. Add the caller files to your repo

Copy the files into `.github/workflows/` in your repo, keeping their filenames.

```bash
# From your project root, for a library
mkdir -p .github/workflows
curl -o .github/workflows/ci.yml \
  https://raw.githubusercontent.com/refokus-agency/platform/main/examples/library/ci.yml
curl -o .github/workflows/release.yml \
  https://raw.githubusercontent.com/refokus-agency/platform/main/examples/library/release.yml
```

Replace `library` with `service` or `custom-code` as needed.

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

## 5. Push a branch and verify

Open a pull request to trigger the workflow:

```bash
git checkout -b test-ci
git commit --allow-empty -m "test: trigger CI"
git push -u origin test-ci
gh pr create --fill
```

In the PR:

1. The `CI` workflow appears and starts running.
2. The `ci` job passes (or fails with a useful error you can fix).
3. For Vercel projects, `deploy-preview` runs after CI and produces a preview URL.

For stage/production deploys (custom-code) or production deploys (service) or releases (library), merge the PR into `main` (or push to `production` for custom-code's production env) and watch the corresponding workflow in the Actions tab.

If something breaks, check [troubleshooting.md](troubleshooting.md).

## 6. Iterate

Delete the test branch once it's green. Future PRs will follow the same flow automatically.

## What happens under the hood

When you push:

1. The relevant caller workflow runs in your repo (based on the event — PR, push to main, push to production).
2. It calls the reusable(s) in `refokus-agency/platform`.
3. Each reusable checks out your repo, sets up Node + package manager, runs its steps, and exits.
4. Your repo never has to know how lint/test/deploy actually work — it just declares "on this trigger, run these reusables".

See [architecture.md](architecture.md) for the full design.
