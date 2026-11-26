# Migration guide

How to move an existing repo off its bespoke workflows and onto the centralized setup.

> **Already on the centralized workflows and still on `@v1`?** You don't need most of this page. Go to [Upgrading from v1 to v2](#upgrading-from-v1-to-v2): `@v1` is frozen at `v1.12.1` and gets no more fixes.

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
- **pnpm follows `package.json`.** If `package.json` pins `packageManager` (or `devEngines.packageManager`), that version is used. Otherwise pnpm `10` is used. If your old workflow passed a pnpm version, drop it, or make it match `packageManager` exactly: `pnpm-version: '11'` against `pnpm@11.17.0` fails. Only `packageManager` is checked: against `devEngines.packageManager` a passed version wins with no error, so drop it there. `bun-version` is also forwarded and defaults to `latest`.

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

## Upgrading from v1 to v2

Already on the centralized workflows and moving a caller from `@v1` to `@v2`. The steps below are in order: find every reference, re-pin it, add the permissions, compare against `examples/`, then verify.

### 1. Find every reference

v2 is a version of the whole repository, not of one workflow: `ci.yml`, `deploy.yml`, `release.yml` and `code-review.yml` all moved to `@v2` together. Once `v2` exists the `v1` tag stops moving, so a caller left on `@v1` keeps working but never gets another fix (see [contributing.md → Breaking changes](contributing.md#breaking-changes)). Move every `uses: refokus-agency/platform/...` line of the repository's `.github/workflows/` in the same pull request.

List every reference, whatever its ref, together with every `platform-ref` input:

```bash
grep -rnE 'refokus-agency/platform/\.github/workflows/[^@ ]+@|platform-ref:' .github/workflows/
```

Sort each hit into one of these:

| What you find | What to do |
|---|---|
| `@v1` (the floating tag) | Replace mechanically, see step 2. |
| `@v1.x.y` (an exact release) | Pick on purpose: `@v2` to float like the examples, or an exact `@v2.x.y` to keep pinning. Do not let a substitution turn it into `@v2.x.y` with the old minor: `@v2.12.1` does not exist. |
| `@<40-char SHA>` | Resolve the v2 release you want to its commit and pin that, keeping a `# v2.x.y` comment: `git ls-remote https://github.com/refokus-agency/platform refs/tags/v2.1.0`. |
| `@main` or another branch | Decide whether the caller should leave the branch. If it stays, it is not on v1 or v2; nothing in this section applies. |
| `platform-ref: ...` | See [`platform-ref`](#platform-ref-must-not-point-at-v1). |

### 2. Re-pin `@v1` to `@v2`

Only for the floating `@v1`. The match is anchored on whitespace or end of line, so `@v1.12.1` and `@v10` are left alone; review those by hand per the table above. `perl` because `sed -i` takes different arguments on macOS and Linux:

```bash
perl -pi -e 's{(refokus-agency/platform/\.github/workflows/[\w.-]+\.ya?ml)\@v1(?=\s|$)}{$1\@v2}g' .github/workflows/*.y*ml
git diff
```

Run the grep from step 1 again afterwards: the only `@v1` left should be ones you decided to keep.

Do not mix majors in one repository: the preview caller on `@v2` records the preview deployment that `comment-code-review.yml` on `@v2` reads.

A `# x-release-please-major` comment at the end of a `uses:` line is platform's own marker: release-please rewrites the `@vN` of `examples/` and the README on a major bump. It does nothing in your repository. Leaving it in after copying an example is harmless, and so is deleting it.

### 3. Required changes

- **Every caller that runs `deploy.yml` with `environment: preview` must grant `deployments: write`.** That is usually `pr-preview.yml`, but the file name is not what matters: find the jobs with `environment: preview` under `with:`. v2's `deploy.yml` records every preview as a GitHub deployment and fails the preview deploy, before the build, when it can't. Add the line to that workflow's `permissions:` block, as in [`examples/pr-preview.yml`](../examples/pr-preview.yml). If the job sets its own `permissions:`, add it there.
- **`comment-code-review.yml` should grant `deployments: read`.** Add it whether or not the repository uses `SITE_URL_TEMPLATE`, as [`examples/comment-code-review.yml`](../examples/comment-code-review.yml) does. With the variable set, v2's `code-review.yml` reads the preview deployment of the pull request head to review the site, and stops the review with a comment when it cannot read deployments. Without the variable the permission is never used. Adding it always saves checking, and keeps the review working if someone sets the variable later. To check anyway, the variable can be set on the repository or on the organization: `gh variable list --repo <owner>/<repo>` and `gh variable list --org <owner>` (names only are enough). See [secrets.md → `SITE_URL_TEMPLATE`](secrets.md#site_url_template-for-the-preview-site-review).
- **Delete any `opus-model:` line from the `code-review.yml` caller.** The input was removed in v2.1.0, and `@v2` floats to the latest v2.x release, so a caller that still passes it fails at startup with an unknown-input error. See the Opus entry under [behavior changes](#behavior-changes-with-no-action-required).

### Stage and production callers

Callers that run `deploy.yml` with `environment: stage` or `production` keep deploying without any permission change: when they cannot record the GitHub deployment they log a warning and carry on. The examples still grant `deployments: write` in [`main-stage.yml`](../examples/main-stage.yml), [`main-production.yml`](../examples/main-production.yml) and [`production-deploy.yml`](../examples/production-deploy.yml), because with it each stage and production deploy shows up as a GitHub deployment (the repository's **Environments** and deployment history) and the warning goes away. Recommended, not required.

### `platform-ref` must not point at v1

`deploy.yml` checks out platform a second time, at the `platform-ref` input, to load its composite action and scripts. In v2 that includes `github-deployment.cjs`, which records the preview. The default is `main`, which already has it. A caller that sets `platform-ref` to `v1`, `v1.x.y`, a commit from before v2 or an old branch makes the preview deploy fail with `Could not load github-deployment.cjs from platform-ref`. Stage and production only log the same message as a warning.

Delete `platform-ref` unless you know why it is there. If you need the reusable and its scripts to move together, set it to the same ref as the `uses:` line (`v2`, or the exact `v2.x.y`). See [architecture.md → Why does each reusable re-checkout the `platform` repo?](architecture.md#why-does-each-reusable-re-checkout-the-platform-repo).

### 4. Compare against `examples/`

Diff each caller against the example it came from (`diff .github/workflows/pr-preview.yml <(curl -s https://raw.githubusercontent.com/refokus-agency/platform/v2/examples/pr-preview.yml)`) and confirm the only differences are ones the repository needs on purpose: extra `with:` inputs, a different trigger branch, `submodules: true`. Anything else is drift from v1 that is worth fixing in the same pull request or noting in its description.

### 5. Verify

Before merging, on the migration pull request:

- [ ] Every platform job's log, in its **Set up job** step, shows the reusable resolved at `refs/tags/v2` (`Uses: refokus-agency/platform/.github/workflows/<name>.yml@refs/tags/v2 (<sha>)`), or at the exact tag or SHA you pinned.
- [ ] CI passes.
- [ ] For a repository with previews: the preview deploy succeeds, and the GitHub deployment it records is there, in `success`, for the pull request head:

  ```bash
  gh api "repos/<owner>/<repo>/deployments?environment=preview&sha=$(gh pr view <number> --repo <owner>/<repo> --json headRefOid -q .headRefOid)" \
    --jq '.[0].statuses_url' | xargs -I{} gh api {} --jq '.[0].state'
  ```

  The command prints `success`. An empty result means no deployment was recorded.
- [ ] For a repository with code review: comment the trigger phrase (default `@claude review`) and check that the review runs to the end and posts its summary. With `SITE_URL_TEMPLATE` set, the job log shows the preview site resolved, not a `Context not read:` block or a comment asking for `deployments: read`.

After merging:

- [ ] The first stage or production deploy from the default branch succeeds, and its log shows `@refs/tags/v2`.
- [ ] No `deployments: write` warning in that log, if you added the permission.

### Rolling back

Revert the migration pull request. `@v1` still works and still points at `v1.12.1`; it is frozen, not removed, so a reverted caller runs exactly as before the upgrade. Stage and production deploys recorded under v2 stay in the repository's deployment history and do no harm. Fix the problem on a branch and upgrade again; do not leave one repository on two majors.

### Behavior changes with no action required

These change what a review looks like for every v2 caller. Nothing in the caller file needs editing, but tell the people who read the reviews.

- **Every review posts a summary comment**, with findings or without. In v1 a summary was posted only when the review found nothing.
- **Every inline finding carries a verdict.** `🟢 CONFIRMED` is proven from the code; `🟠 PLAUSIBLE` is likely but could not be proven from the checkout and is now posted, marked unverified, with the reason. v1 dropped those. See [architecture.md → Verdicts, the summary and the review context](architecture.md#verdicts-the-summary-and-the-review-context).
- **The review reads more context**: the related pull requests in the stack and on the same base, the issues the pull request closes and their epic. Changes that belong to another issue are flagged `🔵 OUT OF SCOPE`, and acceptance criteria that are not met show up in the summary.
- **Every review weighs performance** (LCP, CLS, INP). The block is appended outside the `prompt` input, so it applies to repositories without a site too, where the review weighs performance from the code alone.
- **Reviews run on Opus (v2.1.0).** `model` defaults to `claude-opus-5-5` (it was `claude-sonnet-5`), and the `opus-model` input is gone, so the bug scans and their validators run on Opus as the review command intends. Expect a higher cost per review. A caller that still passes `opus-model` fails at startup with an unknown-input error; delete the line. Pass `model: claude-sonnet-5-5` to keep a cheaper orchestrator. See [architecture.md → How the review models are chosen](architecture.md#how-the-review-models-are-chosen).
- **Callers that override `prompt`** keep their own text and lose the default's summary and verdict rules, but still get the context blocks and the performance block. A review that posts inline findings without a summary now gets a "posted its findings but no summary" note in the job.

## Migration order recommendation

Start with the lowest-risk repos to build confidence:

1. **A library** (e.g. `navigation`) — failure mode is "release doesn't publish", recoverable.
2. **A low-traffic service** — easier to roll back a bad deploy.
3. **Template repos** (e.g. `webflow-custom-code-tmp`) — validates the 3-env flow without client pressure.
4. **Client-facing repos**, one at a time, starting with the least active.

Spread the rollout over a week or two, not a single day.
