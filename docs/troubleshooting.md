# Troubleshooting

Common failure modes when using the centralized workflows, and how to fix them.

> **Dependabot PRs failing with `Secret GH_PAT_TOKEN is required, but not provided`?** GitHub blocks Actions secrets for Dependabot-triggered workflows. The fix is not to grant Dependabot auto access — it's to require a human to dispatch the workflow from the Actions tab. See [dependabot.md](dependabot.md).

## CI or deploy doesn't trigger at all

**Symptoms:** you push and nothing happens in the Actions tab.

**Likely causes:**

- The caller file isn't in `.github/workflows/`. Must be that exact path.
- The file has a YAML syntax error. GitHub silently ignores invalid workflows. Check Actions → "All workflows" — broken files sometimes show up with a warning icon. You can also lint locally with `gh workflow view` or `yamllint`.
- The triggering event doesn't match. Each caller file declares specific triggers (`pull_request`, or `push: branches: [main]`, etc.). A push to a branch that's not in the list, or a PR event that doesn't fire (draft PRs on some configurations), won't trigger anything.
- Branch protection is blocking the run before it starts.

**Fix:** verify the file path and syntax, then check the event type matches `on:`.

## "Resource not accessible by integration" on checkout

**Symptoms:** the secondary checkout of `refokus-agency/platform` fails.

**Cause:** the `GH_PAT_TOKEN` doesn't have access to the `platform` repo, or the token is missing.

**Fix:**

- Verify `GH_PAT_TOKEN` is configured as an org-level secret with access granted to the calling repo.
- Verify the token's scope includes `repo` (classic PAT) or has contents:read on the platform repo (fine-grained PAT).
- Make sure the PAT hasn't expired.

## "401 Unauthorized" when installing from GitHub Packages

**Symptoms:** `pnpm install` / `npm ci` / `bun install` fails with `401` on a `@refokus-agency/*` package.

**Cause:** `.npmrc` auth isn't set up before install, or the token doesn't have `read:packages`.

**Fix:**

- Each reusable writes `.npmrc` before install. If it's failing, check the `GH_PAT_TOKEN` scopes.
- If you have a committed `.npmrc` in your repo, make sure it doesn't override the one written by the workflow. Remove the committed one, or use `.npmrc` only for scope config (`@refokus-agency:registry=...`) without auth — the workflow adds auth at CI time.

## Vercel deploy fails with "Project not found"

**Symptoms:** `vercel pull` or `vercel deploy` errors out saying the project doesn't exist.

**Cause:** `VERCEL_PROJECT_ID` isn't set, or is pointing at a project the `VERCEL_TOKEN` can't access.

**Fix:**

- Confirm `VERCEL_PROJECT_ID` is set as a **repo-level** secret (it's unique per project; shouldn't be at org level).
- Confirm `VERCEL_TOKEN` belongs to a user/team that has access to that Vercel project.
- Run `vercel projects ls --token=<your-token>` locally to sanity-check that the token can see the project.

## CI step is skipped when I expected it to run

**Symptoms:** no lint/test/build step in the logs even though you have the scripts.

**Cause:** the reusable checks for the script in `package.json` before running it. If the check returns false, the step is skipped.

**Fix:**

- Verify the script exists in `package.json`: `node -e "console.log(require('./package.json').scripts)"`.
- The check is case-sensitive. `"Lint"` won't match — must be `"lint"`.
- If you have a monorepo, the reusable only checks the root `package.json`. You may need to add a root-level script that delegates (e.g. `"lint": "pnpm -r lint"`).

## Package manager auto-detect picks the wrong one

**Symptoms:** reusable uses npm when you expected pnpm (or vice versa).

**Cause:** multiple lockfiles in the repo. Order of precedence: `pnpm-lock.yaml` → `bun.lockb` / `bun.lock` → `package-lock.json`. If you have both pnpm and npm lockfiles, pnpm wins.

**Fix:**

- Delete the stale lockfile from your repo.
- Or pass `package-manager: <pm>` explicitly in the caller to override.

## Deploys work on preview but fail on production

**Symptoms:** `deploy-preview` is green, `deploy-production` fails.

**Likely causes:**

- Missing production-only env vars in the Vercel project. Preview uses development/preview env; production needs production env. Check Vercel → Project → Settings → Environment Variables.
- The `vercel build --prod` step surfaces build errors that a non-prod build tolerates (e.g. stricter TypeScript with production-only `next.config.js`).

**Fix:** run `vercel pull --environment=production && vercel build --prod` locally with the project token and reproduce.

## Semantic-release doesn't publish

**Symptoms:** `release` job runs and exits successfully but no new version is published.

**Likely causes:**

- No commits on main since the last release that trigger a version bump. Semantic-release follows Conventional Commits — `fix:` bumps patch, `feat:` bumps minor, `BREAKING CHANGE:` bumps major. Other commit types (`chore:`, `docs:`, `test:`) don't release.
- `.releaserc` missing or misconfigured. Check `releases` output in logs.
- `publishConfig.registry` in `package.json` not pointing at GitHub Packages.

**Fix:**

- Push a commit that follows Conventional Commits.
- Verify `.releaserc` (or `release` key in `package.json`) exists and configures the GitHub Packages plugin.
- Check the logs — semantic-release is verbose about why it didn't release.

## Caching seems ineffective

**Symptoms:** every run re-downloads all dependencies.

**Likely causes:**

- Lockfile changed between runs (check `git log` on the lockfile).
- Cache key is per-lockfile-hash; changing the lockfile invalidates the cache. This is correct behavior.
- For bun, caching is handled internally by `oven-sh/setup-bun` and differs from pnpm/npm's `actions/setup-node` cache.

**Fix:** usually none needed. If the lockfile churns on every PR (e.g. Dependabot), cache misses are expected.

## The reusable works for me but not for another repo

**Symptoms:** identical caller files behave differently.

**Likely causes:**

- Missing secrets in the second repo. `secrets: inherit` silently passes `null` for secrets the caller doesn't have access to — the reusable's `required: true` will then fail with a more useful error.
- Different `package.json` scripts between repos (one has `lint`, the other doesn't).
- Different lockfile (one uses pnpm, the other npm).

**Fix:** compare the two repos' `package.json`, lockfile, and secret availability. 90% of divergence is one of these three.

## Workflow run is using old reusable code

**Symptoms:** you fixed a bug in `platform`, pushed to main, but callers are still hitting the old behavior.

**Cause:** GitHub caches reusable workflow content aggressively but not forever. Usually a few seconds to a minute.

**Fix:**

- Wait 1–2 minutes, then re-run.
- If it persists, try a `workflow_dispatch` manual trigger to force a fresh run.
- Verify the caller's `@main` ref is actually pulling latest by checking the reusable's first step in the logs — the action URL will include a SHA.

## Still stuck

- Re-read [architecture.md](architecture.md) to check whether you're fighting the design.
- Check the Actions tab for similar failures in other repos — the issue may be org-wide (expired token, Vercel outage, etc.).
- Ping `@taprile314`.
