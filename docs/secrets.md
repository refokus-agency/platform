# Secrets

What secrets the reusables need, where they should live, and how to configure them.

## Summary

| Secret | Used by | Expected level | Notes |
|---|---|---|---|
| `GH_PAT_TOKEN` | all workflows | **org** | PAT with `read:packages`, `write:packages`, `contents:write` |
| `VERCEL_TOKEN` | `deploy.yml` | **org** | Vercel personal token or org-scoped token |
| `VERCEL_ORG_ID` | `deploy.yml` | **org** | Same across all Refokus Vercel projects |
| `VERCEL_PROJECT_ID` | `deploy.yml` | **repo** | Unique per Vercel project |

Callers pass these to the reusables via `secrets: inherit`, which forwards whatever the caller has access to (both org-level and repo-level). You don't need to declare individual secrets in each caller.

## How `secrets: inherit` works

In the caller:

```yaml
ci:
  uses: refokus-agency/platform/.github/workflows/ci.yml@main
  secrets: inherit   # <- passes all available secrets
```

The caller has access to:
- **Organization secrets** that the repo is allowed to use (configured at the org level).
- **Repository secrets** defined in the repo itself.
- **Environment secrets** if the job targets a specific environment.

`secrets: inherit` forwards all three to the reusable. The reusable declares which ones it actually needs (`required: true`); anything else just gets ignored.

## Configuring secrets

### Organization-level (recommended for shared secrets)

For `GH_PAT_TOKEN`, `VERCEL_TOKEN`, `VERCEL_ORG_ID`:

1. Go to `https://github.com/organizations/refokus-agency/settings/secrets/actions`.
2. Click **New organization secret**.
3. Set the value.
4. Under **Repository access**, pick one of:
   - **All repositories** — simplest; every repo in the org can use it.
   - **Private repositories** — safer if you have public repos that shouldn't see these secrets.
   - **Selected repositories** — most controlled; list the repos explicitly.
5. Save.

Once set, any repo with access can use it via `secrets.SECRET_NAME` or `secrets: inherit`.

### Repository-level (for per-project secrets)

For `VERCEL_PROJECT_ID` (one value per Vercel project):

1. Go to `https://github.com/refokus-agency/<repo>/settings/secrets/actions`.
2. Click **New repository secret**.
3. Set the value (get it from the Vercel project settings or by running `vercel link` locally and inspecting `.vercel/project.json`).

## Creating the secrets

### GH_PAT_TOKEN

A GitHub Personal Access Token with these scopes:

- `read:packages` — for `ci.yml` and `deploy.yml` to install `@refokus-agency/*` packages from GitHub Packages.
- `write:packages` — for `release.yml` to publish new versions.
- `contents:write` — for `release.yml`'s semantic-release to push version tags and commits.

How to create:

1. Go to `https://github.com/settings/tokens` (your personal account, under a bot account, or a service account — see below).
2. Click **Generate new token (classic)**.
3. Name it something like `refokus-platform-ci`.
4. Pick an expiration (recommended: 90 days, rotate before expiry).
5. Select scopes: `write:packages`, `repo` (covers `contents:write`).
6. Generate and copy the token — you won't see it again.
7. Add it as `GH_PAT_TOKEN` in the org secrets.

**Who should own this token?**

Prefer a **dedicated service account** (e.g. `refokus-bot`) over a personal token. A personal token dies when the person leaves the org; a service account token is stable. If you're not ready to set up a service account, use your personal token and document who owns it, but plan to rotate.

### VERCEL_TOKEN

A Vercel token with access to deploy the project.

1. Log in to Vercel.
2. Go to `https://vercel.com/account/tokens`.
3. Click **Create Token**.
4. Name it (e.g. `github-actions-refokus`).
5. Scope: if possible, scope to the Refokus team/org. Otherwise it's a personal token.
6. Copy and save as `VERCEL_TOKEN` in org secrets.

### VERCEL_ORG_ID

The ID of the Vercel team/org. Same value for every Refokus Vercel project.

1. Run `vercel whoami` or check the team settings URL (`vercel.com/teams/<team-slug>/settings` — the `teamId` is in the URL or in the page).
2. Alternatively, from any locally-linked project, run `cat .vercel/project.json` — the `orgId` field is what you want.
3. Save as `VERCEL_ORG_ID` in org secrets.

### VERCEL_PROJECT_ID

Unique per Vercel project. Configured **per repo**.

1. In the project root locally: `vercel link` (follow prompts to link to the right Vercel project).
2. `cat .vercel/project.json` — the `projectId` field.
3. Go to the repo's Actions secrets and add it as `VERCEL_PROJECT_ID`.

You can also find the project ID in the Vercel dashboard: Project → Settings → General → "Project ID".

## Rotating secrets

When a PAT or Vercel token expires or is compromised:

1. Create a new one following the steps above.
2. Update the secret value in the org (or repo) settings.
3. No code change needed — reusables read the current value each run.

If rotation breaks a deploy, double-check:
- The new token has the right scopes.
- It hasn't expired already.
- The org has it scoped to the right repos.

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
          echo "GH_PAT_TOKEN set: ${{ secrets.GH_PAT_TOKEN != '' }}"
          echo "VERCEL_TOKEN set: ${{ secrets.VERCEL_TOKEN != '' }}"
          echo "VERCEL_ORG_ID set: ${{ secrets.VERCEL_ORG_ID != '' }}"
          echo "VERCEL_PROJECT_ID set: ${{ secrets.VERCEL_PROJECT_ID != '' }}"
```

Run it manually via the Actions tab. Never `echo` the secrets themselves — GitHub masks them, but the booleans are safe.
