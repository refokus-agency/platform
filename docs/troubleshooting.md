# Troubleshooting

Common failure modes when using the centralized workflows, and how to fix them.

> **Dependabot PRs failing?** Most likely your caller still references `GH_PAT_TOKEN` or your repo declares it as a required secret. The current platform reusables use `GITHUB_TOKEN` instead — sync your caller from [examples/](../examples/) and you're done. See [dependabot.md](dependabot.md).

## CI or deploy doesn't trigger at all

**Symptoms:** you push and nothing happens in the Actions tab.

**Likely causes:**

- The caller file isn't in `.github/workflows/`. Must be that exact path.
- The file has a YAML syntax error. GitHub silently ignores invalid workflows. Check Actions → "All workflows" — broken files sometimes show up with a warning icon. You can also lint locally with `gh workflow view` or `yamllint`.
- The triggering event doesn't match. Each caller file declares specific triggers (`pull_request`, or `push: branches: [main]`, etc.). A push to a branch that's not in the list, or a PR event that doesn't fire (draft PRs on some configurations), won't trigger anything.
- Branch protection is blocking the run before it starts.

**Fix:** verify the file path and syntax, then check the event type matches `on:`.

## "Resource not accessible by integration" on checkout

**Symptoms:** a checkout step fails — either your own repo or a submodule.

**Cause:** the caller didn't grant `contents: read`, or the checkout needs to reach a private repo the built-in `GITHUB_TOKEN` can't see (in practice, a submodule that lives in a different private repo).

> The secondary checkout of `refokus-agency/platform` into `.platform/` is **not** a likely cause. `platform` is public, and the reusables check it out with the default `GITHUB_TOKEN` and no explicit `token:` — no PAT is involved anywhere in that step.

**Fix:**

- Confirm the caller's `permissions:` block grants `contents: read`. Sync the caller from [examples/](../examples/) if you're unsure.
- If you pass `submodules: true` and a submodule points at a different private repo, configure `CHECKOUT_TOKEN`. See [secrets.md → Submodules](secrets.md#submodules).
- If the failing step is the `.platform/` checkout specifically, confirm the `platform-ref` input points at a ref that actually exists.

## "401 Unauthorized" when installing from GitHub Packages

**Symptoms:** `pnpm install` / `npm ci` / `bun install` fails with `401` on a `@refokus-agency/*` package.

**Cause:** the caller didn't grant `packages: read`, so the `GITHUB_TOKEN` written into `.npmrc` can't read from GitHub Packages. Or the package lives outside `refokus-agency`.

**Fix:**

- Each reusable writes `.npmrc` before install, authenticating with the built-in `GITHUB_TOKEN` — not a PAT. Confirm the caller's `permissions:` block grants `packages: read`; every file in [examples/](../examples/) already does.
- If the package lives in a different org, `GITHUB_TOKEN` can't reach it at all. That needs a PAT with `read:packages` written by your own workflow — the platform reusables don't accept one for this.
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

## Semantic-release fails with "GH013: Repository rule violations found"

**Symptoms:** the release job fails at the `prepare` step of `@semantic-release/git` with:

```
remote: error: GH013: Repository rule violations found for refs/heads/main.
- Changes must be made through a pull request.
```

**Cause:** `@semantic-release/git` tries to push the version-bump + CHANGELOG commit directly to `main`, but the branch is protected by a ruleset that requires PRs. The built-in `GITHUB_TOKEN` cannot bypass that ruleset.

**Fix:** configure a GitHub App with branch-protection bypass and pass its credentials to the release job. See [secrets.md → Release bypass with a GitHub App](secrets.md#release-bypass-with-a-github-app) for the full setup.

If you don't want to set up a GitHub App, two alternatives:

- Remove `@semantic-release/git` from the plugins list in `.releaserc.json`. The release still creates a tag, GitHub Release, and publishes the package — only the version-bump commit and CHANGELOG.md aren't pushed back to the repo.
- Switch to `release-please` (PR-based, no direct push to `main`). `platform` itself uses release-please for the same reason.

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

- Missing secrets in the second repo. `secrets: inherit` silently passes nothing for secrets the caller doesn't have, and **every secret the reusables declare is `required: false`** — so there is no startup error to point at it. The step that needs the secret either skips or fails deeper in the log. Check secret availability first; see [secrets.md → Verifying secrets are available](secrets.md#verifying-secrets-are-available).
- Different `package.json` scripts between repos (one has `lint`, the other doesn't).
- Different lockfile (one uses pnpm, the other npm).

**Fix:** compare the two repos' `package.json`, lockfile, and secret availability. 90% of divergence is one of these three.

## Workflow run is using old reusable code

**Symptoms:** you fixed a bug in `platform`, the release-please PR was merged (so a new release exists), but callers on `@v1` are still hitting the old behavior.

**Causes (in order of likelihood):**

1. The release-please PR was merged but no new release was actually cut yet. Check the [Actions tab](https://github.com/refokus-agency/platform/actions/workflows/release-please.yml) for the latest `Release Please` run and confirm a release was created.
2. `@v1` hasn't been force-moved yet. Run `git ls-remote origin refs/tags/v1` and compare the SHA against the latest release commit; they should match.
3. GitHub caches reusable workflow content briefly (seconds to a minute). Usually self-resolves.

**Fix:**

- Wait 1–2 minutes, then re-run.
- If it persists, try a `workflow_dispatch` manual trigger to force a fresh run.
- Verify the caller's `@v1` ref is actually pulling latest by checking the reusable's first step in the logs — the action URL includes a SHA.
- If the consumer needs a fix urgently and the release-please cycle is too slow, temporarily switch the caller to `@main` (or a specific commit SHA) until the next release lands.

## Code review finishes green but posts no comment

**Symptoms:** someone comments `@claude review`, the check goes green after several minutes, the run billed real money — and no review comment appeared on the pull request. Or one appeared, but it is generic prose with no inline comments, clearly not the output of the `code-review` plugin.

**Start with what the run told you.** Since [#79](https://github.com/refokus-agency/platform/issues/79) the `Verify review outcome` step reads the transcript the action leaves behind and comments on the pull request itself when the review did not run, did not finish, or finished without saying anything — so complete silence is no longer one of the shapes this takes. Read that comment first and match it against the causes below.

If you need the turn-by-turn detail, set `show-full-output: true` on your caller and re-run. It defaults to `false` because tool results are unsanitized and a public run log outlives the pull request, so turn it on temporarily and on a private repo. Read the transcript looking for `permission_denied` — that is what finally settled [#76](https://github.com/refokus-agency/platform/issues/76) after two plausible-but-wrong fixes.

**Causes (in order of likelihood):**

1. **Your caller overrides `allowed-tools` with a value that predates [#76](https://github.com/refokus-agency/platform/issues/76)**, which omits `Skill`. The `prompt` default *is* a slash command and `Skill` is the tool that executes one; denied, the orchestrator improvises a review from the prompt's plain English instead. Tell-tale: not one `Task` call anywhere in the transcript.
2. **Your override omits `Task`.** The command is built from subagents — two triage agents, a change summariser, four parallel reviewers, one validator per finding — and none of them launch. Tell-tale: `modelUsage` carries a single model entry, when the command mandates two haiku triage agents before it reaches the diff.
3. **Your caller overrides `prompt` with the bare slash command.** That drops the step 1 override and restores both the one-review-per-pull-request dead end and the `trivial` stop.
4. **A stop condition legitimately fired** — the pull request is closed, or automated. Since [#76](https://github.com/refokus-agency/platform/issues/76) the `prompt` default requires the command to post a comment naming the condition before stopping, so *complete* silence is not this.
5. **The fan-out ran in the background and the run ended under it** — [#91](https://github.com/refokus-agency/platform/issues/91). The guard reports `fanout_ran=true comment_posted=false`, and the transcript carries `"status": "async_launched"` per agent plus a `subagent_stats` block reading `started_in_background: N, completed: 0`. The orchestrator's closing message says it is waiting for completion notifications. Tell-tale: `subagent_stats.requested` is `unset`, not `foreground`. Fixed in the `prompt` default; a caller pinned to a tag older than that fix, or overriding `prompt`, still has it. A healthy run reads `requested: {foreground: N}`, `started_in_background: 0`, `completed: N` — see [34868917208](https://github.com/refokus-agency/meetmira-custom-code/actions/runs/34868917208).

**Fix:** drop the override and inherit the defaults — that is what they are for, and neither [examples/comment-code-review.yml](../examples/comment-code-review.yml) nor this repo's own caller overrides either input. If you genuinely need to override, copy the current default out of [.github/workflows/code-review.yml](../.github/workflows/code-review.yml) verbatim and add to it rather than writing one from scratch. Full argument in [architecture.md → Two input defaults that look redundant and are not](architecture.md#two-input-defaults-that-look-redundant-and-are-not).

## No telemetry comment appeared after a code review

**Symptoms:** the review ran and commented, but the separate **Run telemetry** comment — cost, turns, duration, per-agent context — is missing. Or it appeared with the aggregate line and no per-agent table.

**Start with the run log.** The telemetry step never fails the job, so it reports every one of its own dead ends as a `::notice::` instead. Open the `Report run telemetry` step and read it — the notice names the cause directly, and the list below just expands on what each one means.

**Causes:**

1. **The review was skipped by one of the four eligibility gates.** No run, no spend, no comment — by design. The gate that fired left its own `::notice::` in an earlier step.
2. **`::notice::… could not comment on pull request #N`** — your caller has not granted `pull-requests: write`. The review's own comment would have failed the same way; if that one landed and this one did not, check that the caller did not narrow permissions between them.
3. **`::notice::… no run transcript to report on`** — the action produced no `execution_file`. Usually the review never started (an auth failure, a cancelled run). The `Verify review outcome` step above will have more to say about it.
4. **`::notice::… the run transcript is not valid JSON`** — the run was killed while the action was still writing the transcript, or `claude-code-action` changed the file's format. If the run itself looks healthy, suspect the format: the script expects a single JSON array of `SDKMessage`, and the action pins its own moving CLI version.
5. **`::notice::… the reporting script is missing`** — the `Checkout platform repo` step failed, so `.platform/.github/scripts/` is not on disk. Transient GitHub failures do this; re-run the job.
6. **The comment has no per-agent table.** Either the run genuinely fanned out to nothing, or — the more likely one — the transcript carries `Task` calls but no itemised per-agent usage, and the table was dropped on purpose rather than rendered with the main agent standing alone. The notice says which. See [architecture.md → What the run reports about itself](architecture.md#what-the-run-reports-about-itself) for why all-or-nothing is the right behaviour there.

**Not a cause:** a red job. The step carries `continue-on-error: true` and the script cannot exit non-zero, so a missing telemetry comment never shows up as a failed check. If the job is red, something else made it red — read `Verify review outcome`.

## Code review shows `permission_denied` on a tool that IS in `allowed-tools`

**Symptoms:** the transcript denies a `Bash` call whose command clearly matches an allowlist entry — `gh pr diff ...` against `Bash(gh pr diff:*)`, say. The `decision_reason` is not about permission at all; it reads `Contains for_statement`, `Contains simple_expansion`, `Contains command_substitution` or similar.

**Cause:** a prefix rule matches the literal command, and the parser refuses any line carrying a shell construct that could smuggle a second command past the prefix — a loop, a `;`-chain, a redirection, a `$?` or `$(...)`. The tool was allowed; the *shape* was not. Three of the twenty denials in run [34868917208](https://github.com/refokus-agency/meetmira-custom-code/actions/runs/34868917208) were this, all on allowed tools.

**Fix:** nothing in this repo, and adding allowlist entries does not help. The model recovers on its own by reissuing the command plainly, at the cost of a turn. If you see it dominating a run, the lever is the `prompt` input — one command per call, no loops, no redirection, no `$?`.

**Not to be confused with** a denial whose reason is `This command requires approval` or a bare permission message. That one *is* the allowlist, and it is usually correct: `Write`, `Edit`, `git fetch`, `tar`, `node -e`, `python3 -c` and `rm` are all deliberately absent, because the checked-out pull request head is untrusted. Before widening the list, read [architecture.md → Two input defaults that look redundant and are not](architecture.md#two-input-defaults-that-look-redundant-and-are-not); a review that completed and posted findings while logging these denials is working as designed, not degraded.

## Still stuck

- Re-read [architecture.md](architecture.md) to check whether you're fighting the design.
- Check the Actions tab for similar failures in other repos — the issue may be org-wide (expired token, Vercel outage, etc.).
- Ping `@taprile314`.
