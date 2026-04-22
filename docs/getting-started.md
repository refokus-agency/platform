# Getting started

This guide walks through setting up a **new repo** with the centralized CI/CD. If you're moving an existing repo with its own workflows, read the [migration guide](migration.md) instead.

## Prerequisites

Before you start, make sure:

- Your repo lives in the `refokus-agency` organization.
- The required secrets are available to the repo (see [secrets](secrets.md)).
- Your `package.json` has the scripts you want CI to run (`lint`, `typecheck`, `test`, `build` — all optional).
- For Vercel-deployed projects: a Vercel project exists and `VERCEL_PROJECT_ID` is set at the repo level.

## 1. Pick your project type

| Your project is… | Use this caller |
|---|---|
| A Webflow site with custom code | [`examples/custom-code-caller.yml`](../examples/custom-code-caller.yml) |
| A backend service or integration on Vercel | [`examples/service-caller.yml`](../examples/service-caller.yml) |
| An npm library for `@refokus-agency` | [`examples/library-caller.yml`](../examples/library-caller.yml) |

## 2. Add the caller to your repo

Copy the caller file into `.github/workflows/` in your repo. You can name it whatever makes sense (`ci-cd.yml`, `main.yml`, etc.) — GitHub just needs it in that directory.

```bash
# From your project root
mkdir -p .github/workflows
curl -o .github/workflows/ci-cd.yml \
  https://raw.githubusercontent.com/refokus-agency/platform/main/examples/custom-code-caller.yml
```

Or open the file in GitHub and copy-paste its contents.

## 3. Adapt the caller (if needed)

The examples are written to work out of the box. Tweak only if you need to:

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

Push a test branch to trigger the workflow:

```bash
git checkout -b test-ci
git commit --allow-empty -m "test: trigger CI"
git push -u origin test-ci
```

Go to the **Actions** tab in your repo and verify:

1. The workflow appeared and started running.
2. The `ci` job passes (or fails with a useful error you can fix).
3. For Vercel projects, the preview deployment job runs after CI and produces a preview URL.

If something breaks, check [troubleshooting.md](troubleshooting.md).

## 6. Merge and iterate

Once the test branch works, delete it and move on. Production and stage deploys will trigger automatically on pushes to `main` / `production`, per the caller's `if` conditions.

## What happens under the hood

When you push:

1. The caller workflow runs in your repo.
2. It calls the reusable(s) in `refokus-agency/platform`.
3. Each reusable checks out your repo, sets up Node + pm, runs its steps, and exits.
4. Your repo never has to know how lint/test/deploy actually work — it just declares "run CI + deploy to preview".

See [architecture.md](architecture.md) for the full design.
