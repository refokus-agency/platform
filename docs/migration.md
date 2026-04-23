# Migration guide

How to move an existing repo off its bespoke workflows and onto the centralized setup.

## Before you start

- Read [getting-started.md](getting-started.md) first — the mechanics are the same, this guide only covers what's different when a repo already has workflows.
- Migrate **one repo at a time** and verify it works end-to-end before moving on.
- Do it on a branch, not directly on `main`. You want to see the new workflows run in preview before anything touches stage/production.

## The general pattern

1. Create a feature branch from `main`.
2. Delete the old workflow files.
3. Copy the new caller files (one per trigger) from the matching `examples/` subfolder.
4. Verify secrets are accessible.
5. Push and open a PR; watch the Actions tab.
6. Fix anything that breaks.
7. Merge when green.

## Per-type migration

### custom-code repos

**What's there today** (typically):
- `.github/workflows/preview.yml`
- `.github/workflows/stage.yml`
- `.github/workflows/production.yml`

**What to do:**

```bash
git checkout -b migrate-to-platform-cicd
rm .github/workflows/preview.yml .github/workflows/stage.yml .github/workflows/production.yml

# Copy the three new caller files from platform/examples/custom-code/
BASE=https://raw.githubusercontent.com/refokus-agency/platform/main/examples/custom-code
curl -o .github/workflows/pr.yml $BASE/pr.yml
curl -o .github/workflows/stage.yml $BASE/stage.yml
curl -o .github/workflows/production.yml $BASE/production.yml

git add .github/workflows/
git commit -m "ci: migrate to centralized platform workflows"
git push -u origin migrate-to-platform-cicd
```

**Gotchas:**
- The old workflows probably didn't run lint/typecheck/test. The new CI will. If your `package.json` has those scripts and they're currently broken, the migration PR will expose them. Decide: fix them, or delete the scripts.
- If your repo uses different branch names than `main` / `production`, adapt the `on: push: branches:` in `stage.yml` / `production.yml`.

### service repos

**What's there today**:
- `.github/workflows/ci.yml`
- `.github/workflows/deploy-preview.yml`
- `.github/workflows/deploy-production.yml`

**What to do:**

```bash
git checkout -b migrate-to-platform-cicd
rm .github/workflows/ci.yml .github/workflows/deploy-preview.yml .github/workflows/deploy-production.yml

# Copy the two new caller files from platform/examples/service/
BASE=https://raw.githubusercontent.com/refokus-agency/platform/main/examples/service
curl -o .github/workflows/pr.yml $BASE/pr.yml
curl -o .github/workflows/deploy.yml $BASE/deploy.yml

git add .github/workflows/
git commit -m "ci: migrate to centralized platform workflows"
git push -u origin migrate-to-platform-cicd
```

**Gotchas:**
- The new `ci.yml` reusable runs `build` if your `package.json` has it. If your old CI didn't build (only lint + test), the build might have drifted — be ready for it to surface issues.

### library repos

**What's there today**:
- `.github/workflows/release-package-version.yml` (or similar)

**What to do:**

```bash
git checkout -b migrate-to-platform-cicd
rm .github/workflows/release-package-version.yml

# Copy the two new caller files from platform/examples/library/
BASE=https://raw.githubusercontent.com/refokus-agency/platform/main/examples/library
curl -o .github/workflows/ci.yml $BASE/ci.yml
curl -o .github/workflows/release.yml $BASE/release.yml

git add .github/workflows/
git commit -m "ci: migrate to centralized platform workflows"
git push -u origin migrate-to-platform-cicd
```

**Gotchas:**
- Your repo needs a `.releaserc` (or equivalent) with the plugin list. The reusable ships `semantic-release` via `cycjimmy/semantic-release-action` with the common Refokus extras (`changelog`, `git`, `exec`) — you don't need them in devDependencies.
- Make sure `publishConfig` in `package.json` points at GitHub Packages:
  ```json
  {
    "publishConfig": {
      "registry": "https://npm.pkg.github.com"
    }
  }
  ```

## Verifying the migration

Before merging the migration PR, verify:

- [ ] CI runs and passes on the migration branch.
- [ ] For Vercel projects: the preview deployment succeeds and the URL works.
- [ ] No old workflows still run — check the Actions tab for ghost runs from deleted files.
- [ ] No secrets errors in the logs (`GH_PAT_TOKEN`, Vercel tokens, etc.).

Once the migration PR is merged:

- **library**: push a Conventional Commit (`fix:`, `feat:`) to `main` and verify a new version lands in GitHub Packages.
- **service**: the merge to `main` itself triggers `deploy.yml` → production.
- **custom-code**: the merge to `main` triggers `stage.yml`. To promote to production, push or merge into the `production` branch.

## Rolling back

If something breaks after merging:

1. Revert the migration commit on `main`.
2. Old workflows come back.
3. Investigate the failure on a branch.
4. Re-migrate once fixed.

Don't leave a half-migrated state — either fully on the centralized workflows or fully on the old ones.

## Migration order recommendation

Start with the lowest-risk repos to build confidence:

1. **A library** (e.g. `navigation`) — failure mode is "release doesn't publish", recoverable.
2. **A service** with low traffic — easier to roll back a bad deploy.
3. **Custom-code template** (`webflow-custom-code-tmp`) — validates the 3-env flow without client pressure.
4. **Client custom-code sites**, one at a time, starting with the least active.

Don't migrate 7 repos on the same day. Spread it over a week or two to catch issues in the reusables that only surface with real-world traffic.
