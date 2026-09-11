# Architecture

Design decisions behind this repo. Read this when you're about to change something and want to understand the tradeoffs the current shape is making.

## The problem

Before this repo existed, each Refokus project carried its own CI/CD workflows:

- Custom-code repos (~7 active) each had `preview.yml`, `stage.yml`, `production.yml`.
- Service repos had `ci.yml`, `deploy-preview.yml`, `deploy-production.yml`.
- Library repos had `release-package-version.yml`.

Three consequences:

1. **Drift.** Repos diverged over time. Node versions, pnpm versions, deploy flags — all slightly different. Hard to tell what was intentional vs. leftover.
2. **Duplicated fixes.** Every CI improvement had to be copy-pasted into N repos. In practice, one repo would get the fix and the others wouldn't.
3. **Friction on change.** Trying a new tool (e.g. moving from Node 22 to 24) meant touching 10+ repos.

The goal of this repo is to make those problems go away by having **one place** where CI/CD logic lives, and **thin callers** in each repo that point to it.

## The building blocks

### Composite action: `setup`

`.github/actions/setup/action.yml`

Detects the package manager from the lockfile, installs Node and the pm, runs the install command, and configures caching. Used by all three reusables.

Outputs `pm` (the detected or explicitly-chosen package manager) so subsequent steps can run `${{ steps.setup.outputs.pm }} run <script>`.

### Reusable workflow: `ci.yml`

Runs the standard CI checklist (lint, typecheck, test, build) against a repo. Each step is skipped automatically if the corresponding `package.json` script doesn't exist — so a repo with only tests works as well as one with the full kit.

### Reusable workflow: `deploy.yml`

Deploys to Vercel at a specific environment (`preview`, `stage`, or `production`). The workflow itself is environment-agnostic — the caller passes the environment, the reusable handles the Vercel CLI incantations.

When the triggering event is `pull_request` (i.e. a `pr-preview.yml`-style caller), the job also upserts a single sticky comment on the PR with the deployed URL — found via a hidden HTML marker and updated in place on subsequent pushes, rather than piling up one comment per commit. This requires the caller to grant `pull-requests: write`; callers triggered by `push` (stage/production) never hit this step, so they don't need the extra permission.

### Reusable workflow: `release.yml`

Runs semantic-release, which handles version bumps, changelog generation, git tags, and publishing. The publish target is selected by the `registry` input:

- `registry: github-packages` (default) — publishes `@refokus-agency/*` packages to GitHub Packages, authenticated with the built-in `GITHUB_TOKEN`. This is the original behavior; existing callers need no change.
- `registry: npm` — publishes to the public npm registry (registry.npmjs.org) via **OIDC Trusted Publishing**. No `NPM_TOKEN` is used: the job declares `id-token: write`, and npm exchanges the GitHub OIDC token for a short-lived publish credential. Two supporting inputs apply on this path only: `npm-version` (the workflow guarantees npm ≥ this value before publishing, because OIDC Trusted Publishing requires npm ≥ 11.5.1, newer than the npm bundled with older Node releases) and `provenance` (default `false`; set to `true` only when the caller repo is **public**, since npm provenance attestation requires a public repository).

The two paths are conditional steps inside the same `publish` job, so `npm publish` always runs from `release.yml` — that is the workflow filename consumers register in their npmjs.org Trusted Publisher config. On the npm path `NODE_AUTH_TOKEN` is deliberately left unset; if it were set, npm would skip the OIDC exchange. See [secrets.md](secrets.md) for the npmjs.org Trusted Publisher setup.

### Reusable workflow: `code-review.yml`

Runs an AI code review on a pull request via [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action), which installs the `code-review@claude-code-plugins` plugin and posts inline comments plus a summary comment on the PR.

**It runs on request and on nothing else.** The caller is bound to `issue_comment`, and a review starts when someone comments the `trigger-phrase` (default `@claude review`) on a pull request. There is no `pull_request` trigger and no `push` trigger. Comment again after a push to review the new head — the reusable is built for exactly that and will not refuse on the grounds that it already commented.

That is a deliberate trade of automatic coverage for cost control: the review fans out several parallel agents per run, so on `synchronize` the bill scaled with push activity and a good share of it went to re-reviewing work in progress. On request, every run is one a human asked for.

#### Why the trigger phrase is checked here and not by the action

`claude-code-action` has its own `trigger_phrase` input, and wiring it up would be a **no-op**. The action auto-detects its mode, and any comment event carrying a `prompt` is routed to agent mode (`src/modes/detector.ts`); the trigger is then resolved as:

```ts
const containsTrigger =
  modeName === "tag"
    ? isEntityContext(context) && checkContainsTrigger(context)
    : !!context.inputs?.prompt;
```

— `src/entrypoints/prepare.ts`

The phrase is only ever consulted in **tag** mode. This reusable always passes a `prompt` (the code-review slash command is the whole point), so it is always in agent mode, where the trigger is simply "was a prompt supplied" — always true. Passing `trigger_phrase` through would look like a gate and let every comment start a review.

So the gate is the job's own `if:`:

```yaml
if: >-
  github.event.issue.pull_request &&
  inputs.trigger-phrase != '' &&
  contains(github.event.comment.body, inputs.trigger-phrase)
```

All three clauses are free. GitHub evaluates a job-level `if:` **before** it provisions a runner, so ordinary pull request chatter costs no runner time and leaves no skipped-looking check on the PR. `github.event.issue.pull_request` is the documented way to tell a pull request comment from a plain issue comment — `issue_comment` fires for both, and that key exists in the payload only when the commented-on issue is a pull request. Without it, every comment on every issue would start a review of a pull request that does not exist.

The `!= ''` clause is not defensive noise. `contains(body, '')` is true for every string, so a caller that blanked `trigger-phrase` hoping to disable the workflow would instead have armed it on every comment on every pull request. Blank means off.

`inputs` is available in a job-level `if:`; `secrets` is the one context that is not, which is why the credential gate is still a step.

#### Four gates, all skipping green

The workflow is gated rather than required at every stage: each gate emits a `::notice` naming the reason and finishes green, because an advisory job should never be the thing that blocks a pull request.

1. **`Resolve auth`** — resolves one of three credential paths (the `ANTHROPIC_API_KEY` secret, the `CLAUDE_CODE_OAUTH_TOKEN` secret, or the `federation-rule-id` + `anthropic-org-id` pair for workload identity federation) into a single `ready` boolean. None configured → skip.

2. **`Resolve actor`** — two checks on **whoever posted the comment**. Note the change of subject: under the old `pull_request` trigger this gate was about who *opened* the PR.
   - *Not a human.* `claude-code-action` resolves the actor's account type and **throws** unless it matches `allowed_bots`. Pre-checking turns that red failure into a green skip. The review bot's own identity is rejected *before* `allowed-bots` is consulted, so no value of that input — `'*'` included — can arm a loop where a summary quoting the trigger phrase requests the next review. The bot is identified by name (`claude[bot]`, matched after the same lowercase/`[bot]`-stripping normalisation as the allowlist), which is what the action's GitHub App posts as.
   - *No write access.* `src/entrypoints/prepare.ts` runs `checkWritePermissions` for every entity context — `issue_comment` is one — and throws `"Actor does not have write permissions to the repository"`. On a **public** caller repo this matters a great deal: anyone on GitHub can post the trigger phrase, and without the gate every one of them leaves a red X. The gate reads `github.event.comment.author_association` (`OWNER` / `MEMBER` / `COLLABORATOR`) because it arrives in the payload — no token scope, no request, no rate limit. It is an approximation: `MEMBER` means "member of the owning org", which does not strictly imply write here, so an org member with read-only access still reaches the action and still fails there. The action stays authoritative; this gate absorbs the common cases.

3. **`Resolve pull request`** — the pull request must be open, and its head must live in the caller's own repository. See below.

4. Everything downstream (`Acknowledge request`, checkout, review) hangs off gate 3's `eligible` output.

Once gate 3 passes, the first thing that happens is an acknowledgement. A comment trigger has no natural feedback: you type the phrase and, without help, watch nothing happen for the several minutes a review takes. So the reusable reacts to the triggering comment with 👀 before starting. It needs `issues: write` (comment reactions go through the issues API) and is deliberately best-effort — a caller granting only `issues: read` loses the reaction, not the review.

#### Why fork pull requests are skipped

`issue_comment` runs with the base repository's **secrets, always** — the same property as `pull_request_target`. That is a real change of posture. Under the old `pull_request` trigger a fork PR simply received no secrets and skipped at `Resolve auth` on its own, as a platform guarantee. Now the job always holds `ANTHROPIC_API_KEY`, so checking out a fork head would mean running contributor-authored code in a job that holds a credential — the classic [pwn request](https://securitylab.github.com/research/github-actions-preventing-pwn-requests/).

`claude-code-action`'s own `docs/security.md` prescribes a mitigation for this shape (base ref at the workspace root, head into a subdirectory, `--add-dir`). This reusable does something stricter instead and skips forks outright, keeping the trust boundary at the repository edge rather than relying on getting a mitigation right. Every Refokus repo takes pull requests from branches of the same repo — which is why `secrets: inherit` is workable here at all — so the head is always written by someone who already has write access. The `--add-dir` pattern remains the documented escape hatch if fork review is ever needed.

#### Why the head SHA is resolved explicitly

`issue_comment` carries no ref: the payload describes the comment and the issue, never a commit. `actions/checkout` with no `ref:` would therefore check out the caller's **default branch**, and the failure would be silent rather than loud — the review gets its diff from `gh pr diff` over the API, so it would still produce plausible findings while the subagents validating each one against the source read the wrong tree. So `Resolve pull request` fetches `.head.sha` from the API and the checkout pins it.

#### Why the caller sets `cancel-in-progress: false`

The example caller keys its concurrency group on `github.event.issue.number` — on `issue_comment` the payload has no `pull_request` object, so the usual `github.event.pull_request.number` is empty and would collapse every pull request into one group. The interesting half is the cancel flag.

`concurrency` is a property of the **run**, evaluated when GitHub creates it, while the trigger phrase is checked in the reusable's **job-level `if:`**. So every comment on the pull request creates a run that joins the group, whether or not it contains the phrase. Under `cancel-in-progress: true` an ordinary "thanks, fixing that now" posted while a review is in flight cancels the review — a normal-use failure, not just a griefing vector.

`false` also matches the trigger's semantics. `true` earned its place under `synchronize`, where a new push genuinely obsoleted the review of the previous head. A comment-triggered run is a request someone made on purpose, and a second `@claude review` is a second request rather than a replacement for the first.

#### How the review models are chosen

Two separate levers, and conflating them is the trap.

`model` sets the **orchestrator** — the agent that reads the command, dispatches subagents and posts the comments. It reaches the CLI as `--model` inside `claude_args`, because `claude-code-action@v1` exposes no `model` input; `claude_args` is also where `--allowedTools` goes, so the two are composed into one expression.

The orchestrator's model is *not* what the review costs. The `code-review` command names a tier per subagent in its own prompt text: haiku for the two triage steps, sonnet for the change summary and the CLAUDE.md audits, **opus for the two bug scans and for validating everything they flag**. The orchestrator honours those instructions, so `--model` moves dispatch and reporting while the fan-out — several parallel agents plus one validator per candidate finding — stays wherever the prompt put it.

To keep Opus out of the review, the reusable pins what the alias resolves to rather than arguing with the prompt. `opus-model` is exported as `ANTHROPIC_DEFAULT_OPUS_MODEL`; the command still asks for an "Opus bug agent", the request still goes out under the `opus` alias, and the alias resolves to Sonnet. Per Claude Code's [model configuration](https://code.claude.com/docs/en/model-config) the `ANTHROPIC_DEFAULT_*_MODEL` family is provider-independent and covers subagents that name an alias, which is exactly this shape.

Two reasons that beats appending a "use sonnet instead of opus" paragraph to `prompt`, which is the obvious alternative and how the step 1 override works:

- **It is a mechanism, not an instruction.** Alias resolution happens below the model; a prompt override is something the orchestrator has to remember for every subagent it spawns.
- **It does not depend on the command's wording.** The `prompt` default already carries one override that has to track step 1's stop conditions. Every further paragraph is another thing to re-read when upstream rewrites the command. Remapping an alias survives a rewrite.

The variable is set at **job** level. The action re-exports it into the CLI subprocess from the `env` context, and its own step-level `env:` block shadows anything set on the step that calls it.

Set `opus-model: claude-opus-5` to get the command's intended tiers back. Both inputs are pinned to a generation rather than the floating `sonnet` / `opus` aliases, so the next generation does not move cost and behaviour for every caller in one release; bump them here, the way `claude-code-action@v1` is bumped here.

#### Testing a change to `code-review.yml`

The in-repo dogfood caller **no longer tests the branch under review.** GitHub runs an `issue_comment` workflow from the default branch, always — both the caller file and the `./`-relative reusable it resolves to. So commenting on a pull request here exercises `code-review.yml` as it exists on `main`.

Use Option A in [contributing.md](contributing.md#option-a-test-against-your-branch-in-a-real-repo): point a low-stakes repo's caller at `refokus-agency/platform/.github/workflows/code-review.yml@your-branch` and comment the phrase there. A caller running from its own default branch may invoke a reusable at any ref, so this works.

The same mechanism retired a long-standing annoyance: `claude-code-action` refuses to run when the triggering workflow on a pull request head differs from the default branch's copy, and a default-branch trigger cannot differ from itself.

#### On versioning

Moving from `pull_request` to `issue_comment` changed the **caller contract** — a caller still bound to `pull_request` gets a job whose `if:` is false and which therefore never runs, silently — while leaving the `workflow_call` interface backward compatible (`trigger-phrase` was added; nothing was removed). By the rule in [CLAUDE.md](../CLAUDE.md) that is a semantic change and would call for `feat!:`.

It shipped on the **v1** line as `feat:` anyway, as a deliberate, bounded exception: release-please treats this repo as a single package, so a major would have bumped `ci.yml`, `deploy.yml` and `release.yml` to `v2` as well and frozen every repo pinned at `@v1` on the last v1 release until each one re-pinned four caller files. `code-review.yml` had exactly one consumer, updated alongside this change. If `code-review.yml` ever has more than a couple of consumers, that exception stops being available and the next such change needs a real major.

The same exception covered a later fix to the two defaults below. Fixing a default that never worked is the easier case of the two: there is no behaviour for a consumer to depend on, so it ships as `fix:` as long as the `workflow_call` interface — input names, types, `required` flags — is untouched.

#### Two input defaults that look redundant and are not

Both have already been simplified into a broken state once, and both failed silently when they were. Each looks like something a tidy-minded maintainer would tighten up. Don't.

**`allowed-tools` must be a superset of the plugin's frontmatter, not a copy of it.** The `code-review` command declares its own `allowed-tools` in frontmatter, and the obvious default is that string verbatim plus the inline-comment MCP tool. Same text, inverted meaning: in frontmatter the list is *additive*, layering auto-approvals onto a session that already has Read, Glob and Grep, while as the CLI's `--allowedTools` it is the *complete* tool set and everything absent is denied. So the default has to name everything the command needs, not just its extras:

- **`Read`, `Glob`, `Grep`** — the command's subagents collect the relevant CLAUDE.md paths, audit the diff against them and validate each candidate finding in the code. Starved of a file-reading tool the fan-out still launches and still bills, then reports "No issues found" having read nothing but `gh pr diff`.
- **`Skill`, `SlashCommand`** — `prompt` defaults to a *slash command*, and these are the tools that execute one. Without them the plugin command never runs at all: the orchestrator improvises a review from the plain English of the prompt. This is the failure that left the reusable unable to run at its own defaults.
- **`Task`, `Agent`** — the command is built out of subagents (triage, change summary, five parallel reviewers, one validator per candidate finding). Without them a single orchestrator reviews the diff by hand and the triage tiers never run.
- **`TodoWrite`** — named in the command's own notes.

`Agent` sits beside `Task`, and `SlashCommand` beside `Skill`, for a mechanical reason rather than a stylistic one: each pair names a single tool that has been spelled both ways across Claude Code versions, while `claude-code-action@v1` pins its own moving CLI version. An allowlist entry matching no tool is inert, so naming both costs nothing and stops a CLI bump from reinstating this failure silently.

None of this is visible in the run log — see [troubleshooting.md](troubleshooting.md#code-review-finishes-green-but-posts-no-comment) for how to read a run that finishes green having reviewed nothing.

Keep additions read-only: `claude-code-action` treats the checked-out pull request head as untrusted and restores `.claude`, `CLAUDE.md`, `.mcp.json` and friends from the base branch for exactly that reason, so `Write`, `Edit` or a general `Bash(...)` entry would give a pull request author a foothold that the read-only tools do not. The execution tools stay inside that posture: a subagent inherits this same allowlist, so `Task` reaches nothing the orchestrator cannot already reach, and `TodoWrite` writes to the session's todo state rather than to the checked-out worktree.

**`prompt` must keep its step 1 override.** Step 1 of the command tells the model to stop without reviewing if Claude has already commented on the pull request, if the pull request is a draft, and if the diff is trivial. All three are sensible for a slash command a human runs once by hand, and all three are wrong here for the same reason: **the trigger is already an explicit human request.** Someone typing the phrase on a pull request Claude reviewed two pushes ago wants the current head reviewed; someone typing it on a draft wants the draft reviewed. Under the old `synchronize` trigger the first condition was outright destructive — once a run posted a summary, every later push short-circuited into a silent no-op with no comment and a green check.

`trivial` carries the sharpest version of the argument. This workflow has no automatic trigger, so a run exists *only* because a person decided the change was worth reviewing; the gate then re-decides that from the diff alone and silently overrules them. A documentation-only diff is reviewable material: "no code changed" is not "nothing to review".

The silent half is the worse half, and it is not specific to `trivial`. The action runs with `show_full_output: false`, so Claude's reasoning never reaches the run log and a deliberate decline is indistinguishable from a crash that swallowed its error. So the override adds one requirement on top of the three liftings: whatever the command decides, it says so in a pull request comment before the run ends. Closed and automated still stop the review — they just stop it out loud.

The multiline block scalar is load-bearing — the override has to arrive as part of the same prompt, and the first line has to stay the bare slash command — and a caller that overrides `prompt` with that bare command re-introduces the bug for itself.

Because a reusable workflow runs in the **caller's** context, the API key is always the caller's. An external consumer supplies their own `ANTHROPIC_API_KEY`; this repo's secrets are never in scope, and neither is its Anthropic bill.

Two caller-side requirements the reusable cannot enforce from the inside: `id-token: write` is mandatory (the action exchanges the workflow's GitHub OIDC token for a GitHub App token), and `pull-requests: write` is needed to post the review. See `examples/comment-code-review.yml`.

### Callers

Each repo has a thin workflow that composes the reusables. The caller owns branch logic (which branch triggers which deploy environment) and nothing else.

GitHub renders a reusable's status check as `<caller job key> / <reusable job key>`, so the two halves must not repeat each other: the caller's key names *what* is running, the reusable's key names the *action* it performs. That is why the inner jobs are `checks`, `deploy`, `publish` and `review` rather than a second copy of the workflow name — `pr-ci.yml` reads as `ci / checks`, `comment-code-review.yml` as `code-review / review`. Renaming an inner job renames the check, which silently breaks any branch-protection rule that requires the old name, so pick it correctly before the first release that ships the reusable.

## Key design decisions

### Why split into separate reusables instead of one big workflow?

A single "run CI then deploy" workflow would couple CI to deploys. That's wrong because:

- Libraries don't deploy (they release).
- Some repos want CI on PRs without deploying.
- Different repos chain the pieces differently.

Three focused reusables compose into whatever a caller needs. The cost is a bit more verbosity in callers — worth it for the flexibility.

### Why a composite action for setup instead of inlining?

Without the composite action, every reusable would need conditional steps for pnpm vs. npm vs. bun. That's 3x the cases times 3 reusables = 9 places to get wrong.

The composite action centralizes the "what pm, how install" logic. The reusables stay readable.

### Why parameterize the deploy environment instead of having `deploy-preview.yml`, `deploy-stage.yml`, `deploy-production.yml`?

Earlier drafts had one reusable per environment. They were 90% identical — same checkout, same Vercel commands — with only a `--prod` flag or a different `vercel pull --environment=` value differing.

A parameterized reusable collapses them into one file. The caller loses nothing: it still declares three deploy jobs (preview, stage, production), but each job points at the same reusable with a different `environment` input.

### Why does the caller own the branch-to-environment mapping?

Two reasons:

1. **Different project types have different flows.** Custom-code has 3 environments, service has 2. A reusable that encoded "main → stage, production → production" would be wrong for services. A reusable that encoded "main → production" would be wrong for custom-code.
2. **Callers are cheap to read.** Each caller file declares its trigger in the `on:` block. No indirection to a reusable to figure out what a branch does.

### Why atomic caller files instead of templates per project type?

Earlier iterations grouped caller files by project type (`examples/library/`, `examples/service/`, `examples/custom-code/`). That assumed each type had a single canonical flow shape.

Reality across Refokus repos: shape varies per repo, not per type. Some services have 2 envs, others have 3. Some custom-code sites could use 2 envs if they don't need a client stage gate. A type-based taxonomy fights this variation.

The atomic approach instead: one caller file per (trigger, action) pair, stored flat in `examples/`:

- `pr-ci.yml` — PR → CI
- `pr-preview.yml` — PR → CI + preview deploy
- `main-stage.yml` — push main → CI + stage
- `main-production.yml` — push main → CI + production
- `production-deploy.yml` — push `production` branch → CI + production
- `main-release.yml` — push main → CI + semantic-release

Each repo copies the subset matching its actual triggers. No per-type assumption. If a repo has a weird shape (e.g. 4 envs, or a hotfix branch), new atomic files can be added without touching existing ones.

File naming: `<trigger>-<action>`. Keeps the filename readable and predictable — someone skimming a repo's `.github/workflows/` can infer what each file does from its name alone.

### Why one caller file per trigger instead of one file with conditional jobs?

Splitting per trigger means every file that fires has all its jobs run — no skipped checks cluttering the PR UI. Each file is tiny (10–15 lines) and does exactly one thing.

An alternative single-file-per-repo with `if: github.event_name == '...'` gates works functionally but shows "skipped" checks in the UI for every non-matching event. The atomic approach trades one file for two or three against a cleaner UX.

### Why build in both CI and deploy?

The `ci.yml` reusable runs `pnpm build` (or whichever pm). The `deploy.yml` reusable runs `vercel build`. That's two builds per deployment.

We could share the build output via artifacts (`vercel build --prebuilt`), but:

- For custom-code, the build is fast (<1 min). Saving a minute isn't worth the plumbing.
- For services (Next.js), builds differ by environment — a preview build isn't reusable for production.
- The plumbing (upload-artifact, download-artifact, caller coordination) adds complexity to the reusables.

We chose to tolerate the duplication. If it becomes painful (e.g. a heavy Next.js service with frequent deploys), we can add `--prebuilt` support with an input flag later without breaking existing callers.

### Why `secrets: inherit`?

Manually declaring each secret in each caller:

```yaml
secrets:
  VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}
  VERCEL_ORG_ID: ${{ secrets.VERCEL_ORG_ID }}
  # ... etc
```

would be noisy and easy to miss when adding a new secret. `secrets: inherit` forwards everything the caller has access to, so adding a new required secret is a one-line change in the reusable.

The reusable declares which secrets are `required: true`, so a missing one fails with a clear error.

### Versioning with release-please

Callers reference the floating major tag `@v1`. Releases are automated by [release-please](https://github.com/googleapis/release-please-action):

1. Conventional commits land on `main` (`feat:`, `fix:`, `chore:`, etc., with `feat!:` or `BREAKING CHANGE:` footer for breakers).
2. release-please opens or updates a release PR aggregating unreleased commits, computing the next semver bump, and updating `CHANGELOG.md`.
3. Merging the release PR tags the new version (`v1.x.y`), creates a GitHub Release, and the `release-please.yml` workflow force-moves `@v1` to the same commit.

Why a floating `@v1` instead of pinned `@v1.2.3` per caller?

- One tag to update means non-breaking improvements propagate without 10+ PRs per fix.
- Breaking changes go to a new major (`@v2`); callers stay on `@v1` until they explicitly migrate.
- Repos that want bleeding-edge can still use `@main`; SHA pins (`@<sha>`) work for paranoid scenarios.

The `v1.0.0` tag was bootstrapped manually on the first stable `main` HEAD; from `v1.1.0` onward release-please owns the process. The floating `@v1` is force-pushed on every release — that's the only place `--force` is acceptable.

### Why does the composite action pass `--ignore-scripts` by default?

Dependency install lifecycle scripts (`postinstall`, `prepare`, etc.) are the primary vector for supply-chain attacks in the npm ecosystem — a compromised package version runs arbitrary code during `npm install` with full env access, which means any secrets set for the workflow are exfiltratable.

Defaulting to `--ignore-scripts` closes this vector in CI at the cost of breaking packages that legitimately need those scripts (native modules like `sharp` or `bcrypt`, binary downloaders like `puppeteer`). The Refokus stack (GSAP / Vite / Next.js / Vercel) doesn't use any of those, so the default works everywhere we migrated.

Repos that do need scripts can opt out with `unsafe-install-scripts: true`. The name intentionally signals the risk.

This default is especially important in the Dependabot flow (see `docs/dependabot.md`): Dependabot PRs can trigger CI automatically (with `GITHUB_TOKEN` available), so a compromised dep would otherwise have a window to run install-time code with token access. `--ignore-scripts` closes that window.

### Why does each reusable re-checkout the `platform` repo?

The composite action (`setup`) lives in `platform`. When a reusable runs, the working directory is a checkout of the **caller's** repo — not platform. To use a local composite action path like `./.github/actions/setup`, the reusable needs platform checked out somewhere accessible.

Each reusable does a secondary checkout of `refokus-agency/platform` into `.platform/`, then references `./.platform/.github/actions/setup`. The `platform-ref` input controls which ref to check out (defaults to `main`, matches the workflow's own ref so they don't drift).

Since `platform` is public, the secondary checkout is anonymous — no token is needed. This was the key change that unblocked Dependabot PRs.

An alternative would be to publish the composite action as a standalone GitHub Action on the marketplace and reference it by name. That's overkill — this one's internal.

### Why does `code-review.yml` skip the platform re-checkout?

It is the one reusable that does **not** check out `refokus-agency/platform` into `.platform/`. That is deliberate, not an oversight in the invariant described in [Why does each reusable re-checkout the `platform` repo?](#why-does-each-reusable-re-checkout-the-platform-repo) above.

The secondary checkout exists for exactly one reason: reaching the local composite `setup` action. `code-review.yml` never calls `setup` — `claude-code-action` ships its own runtime and installs what it needs. Worse, calling `setup` here would hard-fail: it detects the package manager from a lockfile, and `platform` has no `package.json` at all, so it would exit with `::error::No lockfile found`.

A checkout with no consumer is just latency and one more moving part. So this reusable checks out the caller repo and nothing else.

### Why is `platform` public?

Two reasons, in order:

1. **Dependabot compatibility.** Custom Actions secrets (like a PAT) are blocked from Dependabot-triggered workflows. Before going public, the reusables required `GH_PAT_TOKEN` to clone this private repo, which broke Dependabot CI runs entirely. Public removes the auth requirement at the checkout step, and the rest of the pipeline uses the always-available `GITHUB_TOKEN`.
2. **Lower operational overhead.** No PAT to provision, scope, rotate, or audit. The blast radius of a compromised PAT was the whole org's CI/CD; eliminating it is a real risk reduction.

The contents of `platform` are CI/CD configuration (YAML), composite actions, and docs. There are no secrets, no business logic, no client information. Publishing was net-positive on every dimension we looked at.

### Why use `GITHUB_TOKEN` instead of a custom PAT?

`GITHUB_TOKEN` is auto-generated per workflow run, scoped to the repo it runs in, expires when the run ends (~hours), and is the recommended path for any operation GitHub itself supports (clone, GitHub Packages auth, semantic-release tagging).

The only reason we used a custom PAT initially was to clone the private `platform` repo and authenticate against GitHub Packages from inside another repo's workflow. Once `platform` went public, the clone needed no token; for GitHub Packages, `GITHUB_TOKEN` works as long as the caller declares `permissions: packages: read` (or `write` for publishing).

For Dependabot workflows specifically, `GITHUB_TOKEN` is one of the few things still available — they're blocked from custom Actions secrets but not from the built-in token. This is what makes the new design work without a separate Dependabot secrets store or manual dispatch gate.

## What's out of scope for now

These came up in the design discussion and were explicitly deferred:

- **Artifact-based build sharing** (`vercel build --prebuilt`). Add later if duplication hurts.
- **A shared "scripts" project type.** Doesn't exist yet. If one appears, it can reuse `ci.yml` with nothing new.
- **Notification integrations** (Slack on deploy, etc.). Not in scope for v1.
- **Dependabot config distribution.** Dependabot rules live per repo. Centralizing is a separate project.
