# Secrets

What secrets the reusables need, where they should live, and how to configure them.

## Summary

| Secret | Used by | Expected level | Notes |
|---|---|---|---|
| `GITHUB_TOKEN` | all workflows | **automatic** | Built-in, generated per run. No setup needed. |
| `VERCEL_TOKEN` | `deploy.yml` | **org** | Vercel personal or org-scoped token |
| `VERCEL_ORG_ID` | `deploy.yml` | **org** | Same across all Refokus Vercel projects |
| `VERCEL_PROJECT_ID` | `deploy.yml` | **repo** | Unique per Vercel project |
| `RELEASE_APP_ID` | `release.yml` | **org or repo** | Optional. GitHub App ID for branch-protection bypass on `main`. Required when using `@semantic-release/git` against a branch with a "PRs required" ruleset. |
| `RELEASE_APP_PRIVATE_KEY` | `release.yml` | **org or repo** | Optional. PEM private key paired with `RELEASE_APP_ID`. |

`GITHUB_TOKEN` covers what we used to need a PAT for: cloning the public `refokus-agency/platform` reusables (no auth needed for public repos), authenticating `.npmrc` for `@refokus-agency/*` packages on GitHub Packages, and tagging/publishing in `release.yml`. The caller declares the scopes via `permissions:` (`contents`, `packages`).

Custom Actions secrets (`VERCEL_*`) are required only for the deploy reusable. Dependabot-triggered workflows can't access these and won't try to deploy — see [dependabot.md](dependabot.md) for the `if:` guard pattern.

## How `secrets: inherit` works

In the caller:

```yaml
ci:
  uses: refokus-agency/platform/.github/workflows/ci.yml@v1
  secrets: inherit   # <- passes all available secrets
```

The caller has access to:
- **Organization secrets** that the repo is allowed to use (configured at the org level).
- **Repository secrets** defined in the repo itself.
- **Environment secrets** if the job targets a specific environment.

`secrets: inherit` forwards all three to the reusable. The reusable declares which ones it actually requires; anything else is ignored. `GITHUB_TOKEN` is special — it's automatically available without needing to be passed.

## Configuring secrets

### `GITHUB_TOKEN`

Nothing to do. GitHub generates one per workflow run automatically. Scopes are controlled via the `permissions:` block in the caller — see [getting-started.md](getting-started.md) for the standard set.

### Organization-level (for shared Vercel secrets)

For `VERCEL_TOKEN` and `VERCEL_ORG_ID`:

1. Go to `https://github.com/organizations/refokus-agency/settings/secrets/actions`.
2. Click **New organization secret**.
3. Set the value.
4. Under **Repository access**, pick one of:
   - **All repositories** — simplest; every repo in the org can use it.
   - **Private repositories** — safer if you have public repos that shouldn't see these secrets.
   - **Selected repositories** — most controlled; list the repos explicitly.
5. Save.

Once set, any repo with access can use it via `secrets.SECRET_NAME` or `secrets: inherit`.

### Repository-level (per-project Vercel secret)

For `VERCEL_PROJECT_ID` (one value per Vercel project):

1. Go to `https://github.com/refokus-agency/<repo>/settings/secrets/actions`.
2. Click **New repository secret**.
3. Set the value (get it from the Vercel project settings or by running `vercel link` locally and inspecting `.vercel/project.json`).

## Creating the Vercel secrets

### `VERCEL_TOKEN`

A Vercel token with access to deploy the project.

1. Log in to Vercel.
2. Go to `https://vercel.com/account/tokens`.
3. Click **Create Token**.
4. Name it (e.g. `github-actions-refokus`).
5. Scope: if possible, scope to the Refokus team/org. Otherwise it's a personal token.
6. Copy and save as `VERCEL_TOKEN` in org secrets.

### `VERCEL_ORG_ID`

The ID of the Vercel team/org. Same value for every Refokus Vercel project.

1. Run `vercel whoami` or check the team settings URL (`vercel.com/teams/<team-slug>/settings` — the `teamId` is in the URL or in the page).
2. Alternatively, from any locally-linked project, run `cat .vercel/project.json` — the `orgId` field is what you want.
3. Save as `VERCEL_ORG_ID` in org secrets.

### `VERCEL_PROJECT_ID`

Unique per Vercel project. Configured **per repo**.

1. In the project root locally: `vercel link` (follow prompts to link to the right Vercel project).
2. `cat .vercel/project.json` — the `projectId` field.
3. Go to the repo's Actions secrets and add it as `VERCEL_PROJECT_ID`.

You can also find the project ID in the Vercel dashboard: Project → Settings → General → "Project ID".

## Release bypass with a GitHub App

`release.yml` runs `semantic-release`, which by default uses `@semantic-release/git` to push a commit (CHANGELOG, version bump) back to `main`. The built-in `GITHUB_TOKEN` cannot push to `main` if the branch is protected by a ruleset that requires PRs — pushes are rejected with `GH013: Repository rule violations found`.

The fix is to mint a short-lived token from a GitHub App that is on the ruleset's bypass list, and use that token for `semantic-release`. This is scoped to the release job only — Dependabot PR runs use `pull_request` workflows that don't touch this token, so this setup doesn't reintroduce the secret-exposure pattern that pushed the project off PATs.

### Setup

1. **Create a GitHub App** at the org level: `https://github.com/organizations/refokus-agency/settings/apps/new`.
   - Repository permissions: `contents: read and write`, `issues: read and write`, `pull-requests: read and write`, `metadata: read`.
   - Webhook: disabled.
   - Where can be installed: **Only this account** (`refokus-agency`).
2. **Generate a private key** (`.pem`) on the app's settings page and download it.
3. **Install the app** on the repos that need release bypass.
4. **Add the app to the bypass list** of the org-level ruleset on `main`: `https://github.com/organizations/refokus-agency/settings/rules` → ruleset → Bypass list → Add bypass → select the app → mode "Always". Requires org-owner permissions.
5. **Set the secrets** on the repo (or org level if you want to share the app across many repos):
   ```bash
   gh secret set RELEASE_APP_ID --repo <owner>/<repo> --body "<app-id>"
   gh secret set RELEASE_APP_PRIVATE_KEY --repo <owner>/<repo> < path/to/key.pem
   ```
   On Windows / PowerShell:
   ```powershell
   Get-Content path/to/key.pem -Raw | gh secret set RELEASE_APP_PRIVATE_KEY --repo <owner>/<repo>
   ```

If both secrets are present when `release.yml` runs, the job mints an installation token and uses it as `GITHUB_TOKEN` for `semantic-release`. If either is missing, the job falls back to the built-in `GITHUB_TOKEN` — fine for repos without branch protection or that don't use `@semantic-release/git`.

## Rotating secrets

When a Vercel token expires or is compromised:

1. Create a new one following the steps above.
2. Update the secret value in the org (or repo) settings.
3. No code change needed — reusables read the current value each run.

`GITHUB_TOKEN` rotates automatically with every workflow run; nothing to do.

## Verifying secrets are available

A quick sanity check workflow (don't commit — run it on a throwaway branch):

```yaml
name: Debug secrets

on: workflow_dispatch

jobs:
  debug:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "VERCEL_TOKEN set: ${{ secrets.VERCEL_TOKEN != '' }}"
          echo "VERCEL_ORG_ID set: ${{ secrets.VERCEL_ORG_ID != '' }}"
          echo "VERCEL_PROJECT_ID set: ${{ secrets.VERCEL_PROJECT_ID != '' }}"
```

Run it manually via the Actions tab. Never `echo` the secrets themselves — GitHub masks them, but the booleans are safe.
