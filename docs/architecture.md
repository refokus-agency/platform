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

Every deploy is also recorded as a **GitHub deployment**, with the same lifecycle in all three environments (`.github/scripts/github-deployment.cjs`):

1. **Start** — right after the platform checkout, before anything touches Vercel, the job creates a deployment and posts `in_progress`. Preview deployments use the PR head SHA as `ref` (`github.sha` is the merge commit on `pull_request`) and `transient_environment: true`; stage and production use `github.ref_name`, as before.
2. **Finish** — the last step runs under `always()` and posts `success` with the Vercel root URL as `environment_url` when `vercel deploy` succeeded (and, for stage, the stage alias too), or `failure` with no URL when the deploy failed, was skipped by an earlier failure, or the run was cancelled before it. The state follows the deploy, not `job.status`: a failed PR comment after a good deploy fails the job but still records `success`, because the preview is live. A failure never marks earlier deployments inactive, so the last good deploy stays active. A preview success doesn't either, because every PR's preview shares the `preview` environment.

This is what lets a later job find the preview for a commit: `GET /repos/{owner}/{repo}/deployments?environment=preview&sha=<head>`.

Recording a deployment needs the caller to grant `deployments: write`, and the rule depends on the environment:

- **preview: required.** Without it the start step fails, naming the permission, and the build never runs. This is a breaking change shipped in v2; see [migration.md](migration.md#upgrading-from-v1-to-v2).
- **stage / production: opt-in.** Without it the job logs a warning, skips the finish step, and deploys anyway, the same as in v1.

The job still declares no `permissions:` block, on purpose: a declared `deployments: write` would make every caller grant it or fail at startup, stage and production included.

`.github/scripts/record-github-deployment.cjs`, the v1 recorder (stage/production, success only), is no longer called by `deploy.yml` but stays in the repo: `platform-ref` defaults to `main`, so `deploy.yml@v1` loads its scripts from `main`, and deleting it there would break every v1 stage and production deploy.

### Reusable workflow: `release.yml`

Runs semantic-release, which handles version bumps, changelog generation, git tags, and publishing. The publish target is selected by the `registry` input:

- `registry: github-packages` (default) — publishes `@refokus-agency/*` packages to GitHub Packages, authenticated with the built-in `GITHUB_TOKEN`. This is the original behavior; existing callers need no change.
- `registry: npm` — publishes to the public npm registry (registry.npmjs.org) via **OIDC Trusted Publishing**. No `NPM_TOKEN` is used: the job declares `id-token: write`, and npm exchanges the GitHub OIDC token for a short-lived publish credential. Two supporting inputs apply on this path only: `npm-version` (the workflow guarantees npm ≥ this value before publishing, because OIDC Trusted Publishing requires npm ≥ 11.5.1, newer than the npm bundled with older Node releases) and `provenance` (default `false`; set to `true` only when the caller repo is **public**, since npm provenance attestation requires a public repository).

The two paths are conditional steps inside the same `publish` job, so `npm publish` always runs from `release.yml` — that is the workflow filename consumers register in their npmjs.org Trusted Publisher config. On the npm path `NODE_AUTH_TOKEN` is deliberately left unset; if it were set, npm would skip the OIDC exchange. See [secrets.md](secrets.md) for the npmjs.org Trusted Publisher setup.

### Reusable workflow: `code-review.yml`

Runs an AI code review on a pull request via [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action), which installs the `code-review@claude-code-plugins` plugin and posts inline comments plus a summary comment on the PR.

**It runs on request and on nothing else.** The caller is bound to `issue_comment`, and a review starts when someone comments the `trigger-phrase` (default `@claude review`) on a pull request. There is no `pull_request` trigger and no `push` trigger. Comment again after a push to review the new head — the reusable is built for exactly that and will not refuse on the grounds that it already commented.

That is a deliberate trade of automatic coverage for cost control: the review fans out several parallel agents per run, so on `synchronize` the bill scaled with push activity and a good share of it went to re-reviewing work in progress. On request, every run is one a human asked for.

#### Verdicts, the summary and the review context

The plugin command finds issues, validates each one and posts what survived. Left alone it has two gaps for a reader: an inline comment does not say whether its finding was proven or inferred, so the author re-checks every one by hand; and the command posts a summary only when it found nothing, so a review with findings has no overview. The `prompt` default closes both:

- **Every finding gets a verdict**, proposed by the agents that find issues and settled by the agents that validate them. `CONFIRMED` is proven from the code the run can read and is posted with its evidence. `PLAUSIBLE` is likely but not provable from the checkout — it depends on runtime behaviour, data or code outside it — and is posted anyway, marked unverified, with the reason it could not be proven; the command's rule of dropping unvalidated issues applies to `REJECTED` only. `REJECTED` is disproved and never posted.
- **A CONFIRMED or PLAUSIBLE finding already fixed by a related pull request** is covered elsewhere: it appears in the summary only, naming that pull request, and never inline — wherever that pull request sits in the stack, open or merged. It counts as fixed only when that pull request's diff touches the flagged place, resolves the described scenario and covers every occurrence; its description is never evidence. A pull request closed without merging fixes nothing, so the finding is posted inline with a note naming it. A contradiction with a sibling pull request is itself an inline finding, with a verdict. What counts as a contradiction is left to the review's judgement.
- **Each inline comment has one shape:** the verdict alone on the first line (`🟢 CONFIRMED` / `🟠 PLAUSIBLE`), the problem, the evidence or why it could not be proven, and a closing "Suggestion" section — a committable `suggestion` block when that fully fixes it, the fix in text otherwise. A block never rewrites lines another finding owns, so applying every suggestion cannot undo one of them; findings whose lines overlap share one combined block, on a comment anchored on all the lines of both, and the other comment points to it in text.
- **One summary comment is posted on every review**, findings or not, with `gh pr comment` — not `gh api`, because `review-guard.sh` only recognises a comment made through the inline MCP tool or `gh pr comment`. The body goes in one single-quoted `--body '...'` argument: the allowlist matches `gh pr comment` by prefix and denies a command with a shell construct in it, and the guard only counts a call whose result came back without an error, so a refused summary reads as no summary rather than as a review that spoke. The guard tracks the summary apart from the inline findings: a review that posted findings and lost its summary gets a "posted its findings but no summary" note, green, rather than passing in silence. It carries the change's intent, what was checked (the reviewed commit, and the preview site with its URL, or "No site was checked" when there is no site context — a configured site whose preview cannot be resolved stops the review instead, and one that resolves but does not load is named in the summary with its URL), each context the workflow could not read and what that left unchecked, the count per verdict and the findings covered elsewhere.

The review informs the author; it does not replace them. The author still decides whether each finding is actionable.

Those instructions live in the `prompt` default, so a caller that overrides `prompt` keeps its own text and loses them by design. What it keeps is the **Resolve review context** phase: a step between "Resolve pull request" and the review that appends data blocks *after* the prompt — line 1 has to stay the bare slash command — and hands the review the result. Each block is present only when its data is, and a blank prompt gets none — context with no slash command in front of it would be an instruction-less run. The first is the reviewed commit, emitted only when the head SHA is exactly 40 lowercase hex characters; the related pull requests and the closing issues blocks follow, and a later block (the site) slots in the same way. The blocks are composed by [`.github/scripts/review-context.sh`](../.github/scripts/review-context.sh), which the step runs out of a platform checkout taken just before it (see [Why `code-review.yml`'s platform checkout is not like the others](#why-code-reviewymls-platform-checkout-is-not-like-the-others)). [`test-review-context.sh`](../.github/scripts/test-review-context.sh) tests the script against a stub `gh`, and the `Script tests` workflow runs those tests on every pull request. If the script is missing or exits non-zero, the step logs a warning and the review runs with the caller's prompt plus a fixed `Context not read:` block for the review context as a whole (the reviewed commit, the related pull requests and the closing issues left unchecked), so the summary says so. The script reads every value from `env:`, and the step writes its output with a random per-run heredoc delimiter, so prompt text cannot end the value early or forge further outputs.

The second is the **related pull requests** block. The step fetches it itself with the job's `GITHUB_TOKEN`, from three lookups:

- **stack** — the GitHub stacks API (`repos/{owner}/{repo}/stacks?pull_request=N`, a public preview): every other pull request of each stack the reviewed one belongs to. An empty answer means no stack.
- **sibling** — only when the base branch is not the default branch: every other open pull request on the same base, across every page.
- **base** — the open pull request whose head is the reviewed one's base branch, then the one whose head is *that* pull request's base, and so on until no open pull request heads the branch, the branch is the default one, a number repeats, or more than one pull request heads it (all of them are listed, none is followed).

Each pull request appears once, under the first relation that found it (base, then stack, then sibling), and the reviewed pull request never appears. The block holds numbers, relations and statuses (`open`, `merged`, `closed without merging`) and nothing else: titles, bodies, branch names and diffs of other pull requests are author-written text, so none of it enters the prompt — every line is rebuilt from validated fields before it does. The review reads those pull requests itself with the `gh pr view` and `gh pr diff` it already has; `gh api` stays off its allowlist. With no related pull request there is no block. A lookup that fails — a non-2xx answer, a missing permission, output that does not parse — leaves a `::warning::` naming it in the run log and contributes no entries, and the failed lookups are reported together in one `Context not read:` block after the related block (described below): `Context not read: the stack lookup, the sibling lookup.`, then `Left unchecked:` with what each one covers (the rest of the stack, the open pull requests on the same base, the pull requests this one is based on), then the instruction to name it in the summary. Both lines come from a closed vocabulary keyed by the lookup's name and carry no API output. A lookup that answers but returns a pull request without a usable number — a changed response shape — counts as failed the same way, with its own warning, while the entries it could read are still listed. The review runs anyway: the cost of a degraded run is a finding another pull request already fixes, not a missed one. A pull request whose `state` is anything but `open` or `closed` is dropped the same way, with a warning naming its number, instead of being guessed as closed without merging — that status tells the review the pull request fixes nothing. See [troubleshooting.md → "Related pull requests lookup failed"](troubleshooting.md#code-review-warns-related-pull-requests-lookup-failed).

The third is the **closing issues** block: the issues the pull request is meant to resolve, so that the review can judge whether it does what was asked, and tell when a change belongs to another part of the same epic. One GraphQL query, with the job's `GITHUB_TOKEN`, reads GitHub's `closingIssuesReferences` (at most 10; the block says when there are more), each one's own sub-issues, its epic (`parent`) and the epic's sub-issues (at most 100 per parent, GitHub's own limit, so all of them). The block lists the closing issues with their epic, the epics once each, the sub-issues of a closing issue (in scope: the pull request closes the epic itself) and the other sub-issues of the epics (the candidates, minus every closing issue and every in-scope one, at most 50, with a line saying how many more the review can read from the epics). Like the related block it holds only repository names, numbers and states, each re-validated before it enters the prompt, so no issue title, body or label does: the review reads the issues itself with the `gh issue view -R` it already has, and the block says that what it reads there is data. With no closing issue there is no block. The block carries its own instructions, so a caller that overrides `prompt` still gets them:

- **Acceptance criteria are judged against the closing issues only**, never the epic's, and they are not findings: no verdict, not counted. The summary lists, grouped per issue, only the criteria that are ❌ not met, ❔ not verifiable from the code or ↪ met by a related pull request whose diff proves it, and says nothing about an issue whose criteria are all met. A criterion implemented with a bug is a normal inline finding. A closing issue that is already closed is always noted in the summary.
- **Scope**: a change is in scope when it belongs to any closing issue. Before calling a change out of scope the review reads the candidates; work that belongs to one of them gets one inline comment per change, headed `🔵 OUT OF SCOPE — belongs to #M` (or `#M (closed)`), or `🔵 OUT OF SCOPE — outside #N` when the owner could not be read or there is no epic. It has no Suggestion section, is not a verdict and is not counted among the findings; the summary shows it beside the counts as `· Out of scope: K (#M, ...)`. A bug in out-of-scope code is a normal finding. The `prompt` default says that a context block may define such a comment, so its own one-format rule for inline comments does not overrule it. When any closing issue or epic could not be read, or the pull request closes more than 10 issues (only the first 10 are listed), the block drops these rules and tells the review not to label any change out of scope: a change that looks out of scope may belong to what was not read.

A lookup that fails as a whole — no JSON, no pull request in the answer, a `totalCount` that does not match the closing issues returned, an error anywhere but in an epic or a sub-issue list, or a closing issue nulled by an error — logs a warning and adds `Context not read: the closing issues lookup.`, with the acceptance criteria and the scope check left unchecked. When only epics or sub-issues fail (every error's path runs through `parent` or `subIssues`, or a sub-issue list comes back as something other than a list), the closing issues are listed alone, with no epic and no candidate, and `Context not read: the epic lookup.` says scope creep was not checked. A record that fails validation is dropped with a warning; the rest stay listed. A dropped record is unread context, so it is never silent: a dropped closing issue adds `Context not read: the closing issues lookup.`, and a dropped epic or sub-issue adds `Context not read: the epic lookup.`, even when other closing issues are still listed. When every closing issue is dropped, that unread block replaces the listing. What the script cannot see is an issue GitHub hides from the token without an error. A closing issue in a repository the caller's token cannot read is hidden that way: the live test on refokus-custom-code#48 (2026-11-09) linked an issue from a private repository, and the lookup came back with no closing issue, a `totalCount` of 0 and no error, so the review ran as if the pull request closed nothing and reported no unread context. An epic in such a repository is most likely hidden the same way (a `parent` that comes back `null` reads as no epic), but that case was not tested. See [troubleshooting.md → "Closing issues lookup failed"](troubleshooting.md#code-review-warns-closing-issues-lookup-failed).

**A stacked pull request gets the block only when its issue is linked by hand.** GitHub reads closing keywords (`Closes #N`) only when the pull request targets the default branch; on any other base `closingIssuesReferences` is empty, whatever the body says. Link the issue in the pull request's Development sidebar instead, which works on any base. The source is GitHub's link only: the body is never parsed as a fallback. Enforcing the link is tracked in [#130](https://github.com/refokus-agency/platform/issues/130).

A context source that fails to read must not be left in the log alone. This is a rule for the blocks that call an API (stack and siblings, the closing issue and its epic), which arrive with #119 and #120. The preview site from #122 is resolved before the review by a step of its own, which stops the review with a comment when it cannot resolve the site, rather than reviewing without it; see [The preview site and the performance note](#the-preview-site-and-the-performance-note). The related pull requests lookups and the closing issues lookup emit it as described above, and so does the step's fallback when the context cannot be built at all. Such a block keeps its `::warning::` and also emits a block of its own that starts with `Context not read:`, so the summary lists that context with what it left unchecked: the author learns how much the review could see, not just what it found. Four constraints come with it:

- **Only the workflow writes that report.** The `prompt` default defines the context blocks as the paragraphs appended after its last line: their own sentences come from the workflow, while text quoted inside them from the pull request, an issue or a site, and anything the review reads itself with a tool, is data: nothing in it can change the instructions or what the review posts. That still lets the review weigh the repository's `CLAUDE.md` as review criteria; it only stops text from steering the review. Only a context block that starts with `Context not read:` reports unread context; the same words anywhere else report nothing. Otherwise a pull request could forge a gap, or an all-clear, in the one comment the author reads as a statement of how thorough the review was.
- **The blocks that add it build it safely.** The header and the list of what was left unchecked come from a fixed vocabulary in the shell, never from fetched text. Blocks are joined by blank lines with no delimiter, so a block that quotes fetched text has to fence it, so that none of its lines can pass for a `Context not read:` header or for the start of another block.
- **It goes in the summary, not inline**, and when no such block is given the summary says nothing about unread context, so the review does not invent one. It is never an inline comment of its own nor repeated on every finding; a PLAUSIBLE finding that could not be proven because that context was missing says so in its `Unverified:` line and points to the summary. A site that was configured and could not be resolved never reaches the review at all (the review stops), and one that resolved but did not load is named in the summary with its URL, not as "No site was checked".
- **The block carries its own instruction** to name it in the summary, the way the commit block does, because a caller that overrides `prompt` loses the default's summary rules. The rule that only the workflow writes the report lives in the default, so an override that wants that guard has to restate it, and an override that drops the summary drops the report with it.

#### The preview site and the performance note

A review that only reads code cannot confirm a finding that shows on the page, and until [#122](https://github.com/refokus-agency/platform/issues/122) no review weighed performance at all: neither the `prompt` default nor the code-review plugin mentions it, and the plugin tells its agents to ignore general quality concerns unless `CLAUDE.md` requires them. Two blocks close that.

**The performance block is on every review.** `review-context.sh` appends a fixed `Performance:` block after the caller's prompt, outside the `prompt` input, so an override keeps it and no caller can turn it off. It asks the review to take LCP, CLS and INP into account by inferring them from the code, to corroborate them in the preview when a site block is present, and to weigh performance in general when the code is not a site (a package, server code). The step's fallback, which runs when the script is missing or fails, carries the same text — change both together.

**The site block is there when the repository sets `SITE_URL_TEMPLATE`.** That Actions variable (repository or organization; the `site-url-template` input defaults to it, and the value `none` means no site, so a repository can opt out of an organization-level one) is a URL with a `{preview_url}` placeholder, for example `https://wiza-stage.webflow.io/?preview={preview_url}` on a Webflow site whose loader takes the script origin from `?preview=`. The `Resolve preview site` step, [`resolve-preview-site.sh`](../.github/scripts/resolve-preview-site.sh), reads the newest `preview` GitHub deployment that `deploy.yml` recorded for the pull request head ([#132](https://github.com/refokus-agency/platform/pull/132)), takes the `environment_url` of its newest status, and puts it in place of the placeholder. With a site, the review gets:

- the Playwright MCP, started headless with the runner's preinstalled Chrome, isolated, writing its files under `$RUNNER_TEMP` and never into the pull request checkout (see below), with `--blocked-origins` set to the runner's own and the cloud metadata addresses;
- eleven browser tools appended to `--allowedTools`: `browser_navigate`, `browser_snapshot`, `browser_take_screenshot`, `browser_console_messages`, `browser_network_requests`, `browser_network_request`, `browser_wait_for`, `browser_click`, `browser_hover`, `browser_press_key` and `browser_resize`;
- a `Site checked:` block naming the URL. It tells the review to read the HTML and CSS first and use the browser only to reproduce findings that show on the page, to read the `[cwv:<tag>]` console lines at a mobile and a desktop viewport (resize first, then navigate again: the numbers are measured per page load, so a resize alone repeats the previous viewport's; then wait 5 seconds with `browser_wait_for` before reading, because `site-vitals.js` logs a metric only when its observer fires, and late layout shifts and late largest paints arrive after the load; take the last line of each metric, since each change is logged again; a missing INP line means not measured, never 0), to confirm in the network requests that the preview deployment's assets loaded, and, if the site is unreachable or password-protected, to go on without it and say so in the summary with the URL.

The `[cwv:<tag>]` lines come from [`site-vitals.js`](../.github/scripts/site-vitals.js), passed to the MCP as `--init-script`: a `PerformanceObserver` for LCP, CLS and INP that logs `[cwv:<tag>] LCP_ms=…`, `[cwv:<tag>] CLS=…` and `[cwv:<tag>] INP_ms=…` each time a value changes, and never otherwise (a probe logged CLS eleven times). The block says the platform writes them, because in the live probe the agent distrusted console lines whose source was a local file. That claim is only safe because of the tag: the page's own scripts share the console, so a pull request could log `[cwv] LCP_ms=900` itself and hand the review forged numbers. `resolve-preview-site.sh` draws 16 random hex characters per run, writes them into the copied script's prefix and passes them to the prompt as the `vitals-tag` output; the block tells the agent to ignore every other `[cwv]` line. The tag lives inside the script's closure and the script keeps its own reference to `console.log` from before the page runs, so the page can neither read it from a global nor catch it by replacing `console.log`. `review-context.sh` drops the site block, with a warning, when the tag is not 16 hex characters.

**No site block, no browser.** The MCP config and the browser tools reach `claude_args` only when the composed prompt ends with the site block (the `site-checked` output of `Resolve review context`). A resolved site whose block is missing (the context fallback, a blank `prompt`, or a block `review-context.sh` dropped) runs the review without the browser, instead of with a browser and no instruction to use it. The fallback still names the site, with its URL, among the context left unchecked, so the summary says which site was not checked.

**Why the browser is an exception to the read-only allowlist.** A page is untrusted content in front of the model, like the pull request head. The tool list is the boundary: none of the eleven runs code in the page or on the runner (`browser_evaluate` and `browser_run_code_unsafe` are left out) or uploads a file (`browser_file_upload`). Navigation and clicks change the state of a preview site, never of the runner or the repository.

**Why the MCP starts in its own directory, with `--ignore-roots`.** Three of the eleven tools (`browser_snapshot`, `browser_console_messages`, `browser_network_requests`) take an optional `filename`, and the MCP writes it anywhere under its output directory or its workspace. The workspace is the client's first root, else the MCP's own working directory, and both are the pull request checkout by default. A page that prompt-injects the agent could otherwise have it write page text into `.claude/`, `CLAUDE.md` or `.git/` of the checkout under review, the files `claude-code-action` deliberately restores from the base branch. So the config in `resolve-preview-site.sh` starts the MCP through `/bin/sh`, which `cd`s into `$RUNNER_TEMP/playwright-mcp` first, and passes `--ignore-roots`: workspace and output directory are then the same directory under `$RUNNER_TEMP`. A live probe with a client that advertises the checkout as its root confirmed it: without the two, a relative, an absolute and a `../` filename all landed in the checkout; with them, the relative one lands under `$RUNNER_TEMP` and the other two get `File access denied`.

The browser does open one channel the read-only tools do not: a page can ask the agent to navigate, and a URL can carry what the agent has read. A prompt injection in the preview could make it open `https://attacker.example/?q=<repository content>`, or a runner-local address. Two layers answer it, and neither closes it:

- **`--blocked-origins`** keeps the browser off exactly these hosts, on every port: `localhost` (also with a trailing dot), `127.0.0.1`, `[::1]`, `0.0.0.0`, the metadata addresses `169.254.169.254` and `169.254.170.2`, and Azure's wire server `168.63.129.16` (GitHub-hosted runners run on Azure). The list lives in `resolve-preview-site.sh`. Playwright matches each entry as a literal glob, with no address ranges, so the rest of `127.0.0.0/8` (`127.0.0.2`), the rest of `169.254.0.0/16` and the private ranges are **not** blocked. IPv6 needs its own form: Playwright turns `http://[::1]:*` into a glob that matches nothing, so the list uses `[::1]:*`. It is defense in depth, not a boundary: Playwright does not apply it to redirects, and a public host name that resolves to a blocked address is not matched.
- **The prompt rules** treat page content as untrusted data, never as instructions. The rule lives in the fixed `Site checked:` block, not only in the default `prompt`, so it travels with the browser when a caller overrides `prompt`; the same block forbids submitting forms, logging in or signing up, and opening any URL outside the site checked.

An allowlist (`--allowed-origins`) was considered and left out. Playwright's own help says it does not serve as a security boundary either, and a Webflow site loads its images, fonts and scripts from other origins, so limiting it to the site and the preview breaks the page and the `[cwv]` readings with it. The residual risk, an exfiltration through an outside URL, is accepted, but it is wider than the pull request: the page is whatever the site renders, so besides a malicious change in a pull request of the same repository (whose author can already read that content), it can come from content nobody in the pull request wrote, such as the site's CMS entries, third-party embeds or anything its users can submit. Anyone who can put text on that page can attempt the injection. So set `SITE_URL_TEMPLATE` only for a site whose content the team controls, and not for one that renders untrusted user content. The MCP config is passed inline in `claude_args`, never as a file: `claude-code-action` merges an inline `--mcp-config` with its own servers, while a file path would replace them and drop `mcp__github_inline_comment__create_inline_comment`.

**When the preview is not usable, the review does not run.** With a site configured, a review without it would look complete and not be. So the step comments on the pull request why, with a link to the run, skips the review and fails the job:

| Stop reason | When |
|---|---|
| `pending-timeout` | The newest deployment was still `queued`, `pending` or `in_progress` (or had no status yet) after the wait. The comment asks for the trigger phrase again once it finishes. |
| `missing` | No preview deployment for the head commit: the deploy has not started (including CI still running or failed, since `pr-preview` deploys only after CI passes), `pr-preview` skipped the pull request (Dependabot), or the repository has no preview deploy. Also a 404 on the statuses of a listed deployment, which was deleted in the meantime. |
| `failed` | The newest status is `failure`, `error` or `inactive`, or `success` with no URL. The comment links the deploy's log. |
| `unreadable` | Listing the deployments returned 403 or 404, or reading a deployment's statuses returned 403: the caller does not grant `deployments: read`. A 403 that names a rate limit is not this. |
| `invalid-template` | The template does not start with `https://` and a literal host, has no `{preview_url}` after that host (in the path, query or fragment: `https://{preview_url}` would yield `https://https://…`), or holds characters outside `[A-Za-z0-9._~:/?#@!$&()*+,;=%{}-]`. |
| `invalid-url` | The deployment's URL is not `https://<name>.vercel.app`. |
| `error` | Anything else, including a resolver missing at `platform-ref` while a template is set. A read that fails for another reason (a GitHub 5xx, a rate limit, the network) is tried three times, 5 seconds apart, before it ends here. |

The browser is held to the same rule: when the preview resolves but the `Install Playwright MCP` step's `npm ci` fails, that step comments on the pull request and fails the job the same way, instead of handing the review a prompt that names a site it has no browser to open.

**Why the wait lives in the job.** A comment that lands while the preview is still deploying waits for it: the step polls every 15 seconds for up to `SITE_WAIT_SECONDS` (300 s for now — a first guess, being tuned; the sandbox's preview deploys take 1.5–3 minutes), logging each poll as `N/20` with the state and the time. Triggering the review from the deploy instead is not possible: #132's deployment statuses are created with `GITHUB_TOKEN`, and events created with it start no workflow run. On a private repository the wait costs Actions minutes, at most five per review.

**`@playwright/mcp` is pinned with a lockfile, and Dependabot proposes the bumps.** The `Install Playwright MCP` step runs `npm ci --ignore-scripts` from [`.github/scripts/playwright-mcp/package-lock.json`](../.github/scripts/playwright-mcp/package-lock.json), which `resolve-preview-site.sh` copies to `$RUNNER_TEMP/pwmcp`. The job holds the Anthropic credential and a GitHub token, and the MCP and Chrome inherit its environment, so every package is locked to an exact version and `sha512` integrity, including the transitive `playwright` and `playwright-core`: the MCP depends on an exact Playwright *alpha*, in every release. `--ignore-scripts` blocks install hooks, not malicious runtime code, so the version is also chosen old: `0.0.84` (published 2026-10-31, Playwright `1.65.0-alpha-2026-10-30`), not the `0.0.85` of two days before this was written. Pick a release at least two weeks old when bumping. `0.0.83` was not enough: it has no `--ignore-roots`. `Pin check` does not cover the lockfile; Dependabot's `npm` entry for `.github/scripts/playwright-mcp` opens the bump pull requests, with a 14-day `cooldown` that keeps the two-week rule for version bumps (security updates are not held back by it). Each bump still needs a person: read the release notes, check that the eleven tool names, their arguments and the flags in `resolve-preview-site.sh` still exist (the package is `0.0.x` and moves fast; `browser_click` already takes `target`, not `element`), and test the bump through `test/code-review-next` before merging. `test-resolve-preview-site.sh` checks that every locked package has an exact version, the npm registry, an integrity hash and no install script, so `--ignore-scripts` costs nothing.

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

#### Why serialization lives in the reusable, not the caller

`code-review.yml` declares `concurrency` on its own `review:` job, and the example caller declares none. That split is not stylistic — a caller physically cannot get this right.

Workflow-level `concurrency` is a property of the **run**, evaluated when GitHub creates it, and it has no access to the reusable's `inputs`. A caller therefore does not know the trigger phrase and cannot key its group on "is this a review request". Every comment on the pull request — `@claude review` or "thanks, fixing that now" — creates a run that joins the same group. `cancel-in-progress: false` looks like the fix and is not: it protects a run that is already **in progress**, while GitHub cancels a **pending** run in a group unconditionally. So a genuine queued review died the moment any unrelated comment landed, with no signal anywhere that it had.

Inside the reusable, `inputs.trigger-phrase` is in scope, so the group key can distinguish the two cases:

```yaml
group: >-
  code-review-${{ github.repository }}-${{ github.event.issue.number }}-${{
  inputs.trigger-phrase != '' && contains(github.event.comment.body, inputs.trigger-phrase)
  && 'request' || github.event.comment.id }}
cancel-in-progress: false
```

Comments carrying the phrase collapse onto the shared `-request` key and queue behind each other. Comments without it fall to `github.event.comment.id`, which is unique per comment — so each one sits alone in its own group and contends with nothing.

**The key is deliberately order-agnostic.** Whether GitHub evaluates a job's `if:` before or after it joins the job's concurrency group is undocumented. Giving non-matching comments a unique key makes the outcome the same either way: if the `if:` runs first the job skips, and if the group is joined first the group has exactly one member. The behaviour no longer depends on knowing which it is.

`cancel-in-progress` stays `false` for the same reason it always did. `true` earned its place under `synchronize`, where a new push genuinely obsoleted the review of the previous head; a comment-triggered run is a request someone made on purpose, and a second `@claude review` is a second request rather than a replacement for the first.

**Silent cancellation of a pending run is now acceptable**, where before it was the bug. With the group correctly scoped, the only way to displace a pending run is a *third* genuine review request on the same pull request while one is running and one is queued — and all three are requests for a review of the same pull request, so the newest run produces it. Nothing concrete is lost. The signal cannot be emitted anyway: a pending run never dispatches a job, so no step executes, not even `if: always()`, and the run that displaces it has no context or API field distinguishing a concurrency cancel from a manual one.

Because the group can now hold a queue, the job also carries `timeout-minutes: ${{ fromJSON(inputs.timeout-minutes) }}` (default 30, against GitHub's own default of 360). Before serialization a hung review inconvenienced only itself; now it would block everything behind it for six hours. Callers may raise the input.

**Callers must not add their own `concurrency` block.** A caller-level group applies *on top of* the job-level one and reintroduces exactly the bug described above.

#### How the review models are chosen

Two separate levers, and conflating them is the trap.

`model` sets the **orchestrator** — the agent that reads the command, dispatches subagents and posts the comments. It reaches the CLI as `--model` inside `claude_args`, because `claude-code-action@v1` exposes no `model` input; `claude_args` is also where `--allowedTools` goes, so the two are composed into one expression.

The orchestrator's model is *not* what the review costs. The `code-review` command names a tier per subagent in its own prompt text: haiku for the two triage steps, sonnet for the change summary and the CLAUDE.md audits, **opus for the two bug scans and for validating everything they flag**. The orchestrator honours those instructions, so `--model` moves dispatch and reporting while the fan-out — several parallel agents plus one validator per candidate finding — stays wherever the prompt put it.

To keep Opus out of the review, the reusable pins what the alias resolves to rather than arguing with the prompt. `opus-model` is exported as `ANTHROPIC_DEFAULT_OPUS_MODEL`; the command still asks for an "Opus bug agent", the request still goes out under the `opus` alias, and the alias resolves to Sonnet. Per Claude Code's [model configuration](https://code.claude.com/docs/en/model-config) the `ANTHROPIC_DEFAULT_*_MODEL` family is provider-independent and covers subagents that name an alias, which is exactly this shape.

Two reasons that beats appending a "use sonnet instead of opus" paragraph to `prompt`, which is the obvious alternative and how the eligibility-check override works:

- **It is a mechanism, not an instruction.** Alias resolution happens below the model; a prompt override is something the orchestrator has to remember for every subagent it spawns.
- **It does not depend on the command's wording.** The `prompt` default already carries one override that has to track the eligibility check's stop conditions. Every further paragraph is another thing to re-read when upstream rewrites the command. Remapping an alias survives a rewrite.

The variable is set at **job** level. The action re-exports it into the CLI subprocess from the `env` context, and its own step-level `env:` block shadows anything set on the step that calls it.

Set `opus-model: claude-opus-5` to get the command's intended tiers back. Both inputs are pinned to a generation rather than the floating `sonnet` / `opus` aliases, so the next generation does not move cost and behaviour for every caller in one release; bump them here, the way `claude-code-action@v1` is bumped here.

#### Testing a change to `code-review.yml`

The in-repo dogfood caller **no longer tests the branch under review.** GitHub runs an `issue_comment` workflow from the default branch, always — both the caller file and the `./`-relative reusable it resolves to. So commenting on a pull request here exercises `code-review.yml` as it exists on `main`.

Use Option A in [contributing.md](contributing.md#option-a-test-against-your-branch-in-a-real-repo): point a low-stakes repo's caller at `refokus-agency/platform/.github/workflows/code-review.yml@your-branch` and comment the phrase there. A caller running from its own default branch may invoke a reusable at any ref, so this works.

The same mechanism retired a long-standing annoyance: `claude-code-action` refuses to run when the triggering workflow on a pull request head differs from the default branch's copy, and a default-branch trigger cannot differ from itself.

#### On versioning

Moving from `pull_request` to `issue_comment` changed the **caller contract** — a caller still bound to `pull_request` gets a job whose `if:` is false and which therefore never runs, silently — while leaving the `workflow_call` interface backward compatible (`trigger-phrase` was added; nothing was removed). By the rule in [CLAUDE.md](../CLAUDE.md) that is a semantic change and would call for `feat!:`.

It shipped on the **v1** line as `feat:` anyway, as a deliberate, bounded exception: release-please treats this repo as a single package, so a major would have bumped `ci.yml`, `deploy.yml` and `release.yml` to `v2` as well and frozen every repo pinned at `@v1` on the last v1 release until each one re-pinned four caller files. `code-review.yml` had exactly one consumer, updated alongside this change. If `code-review.yml` ever has more than a couple of consumers, that exception stops being available and the next such change needs a real major.

Fixing [#79](https://github.com/refokus-agency/platform/issues/79) raised the same question again and was answered the same way. The guard step can fail the job on two paths that previously finished green and silent — a review that did not run, and one whose outcome cannot be verified — and a caller could in principle have depended on this check never going red. It ships as `fix:` because the job could **already** go red (the action calls `core.setFailed` on a thrown error), because the `workflow_call` interface is untouched and purely additive, and because the green those two paths used to return was the bug being fixed rather than behaviour worth preserving. A caller that wants an advisory-only review keeps it out of its required status checks.

The same exception covered a later fix to the two defaults below. Fixing a default that never worked is the easier case of the two: there is no behaviour for a consumer to depend on, so it ships as `fix:` as long as the `workflow_call` interface — input names, types, `required` flags — is untouched.

#### Two input defaults that look redundant and are not

Both have already been simplified into a broken state once, and both failed silently when they were. Each looks like something a tidy-minded maintainer would tighten up. Don't.

**`allowed-tools` must be a superset of the plugin's frontmatter, not a copy of it.** The `code-review` command declares its own `allowed-tools` in frontmatter, and the obvious default is that string verbatim plus the inline-comment MCP tool. Same text, inverted meaning: in frontmatter the list is *additive*, layering auto-approvals onto a session that already has Read, Glob and Grep, while as the CLI's `--allowedTools` it is the session's only source of approval — the run is headless, so a tool that needs permission and matches no entry is denied outright instead of prompting. So the default has to name everything the command needs, not just its extras:

- **`Read`, `Glob`, `Grep`** — the command's subagents collect the relevant CLAUDE.md paths, audit the diff against them and validate each candidate finding in the code. Starved of a file-reading tool the fan-out still launches and still bills, then reports "No issues found" having read nothing but `gh pr diff`.
- **`Skill`, `SlashCommand`** — `prompt` defaults to a *slash command*, and these are the tools that execute one. Without them the plugin command never runs at all: the orchestrator improvises a review from the plain English of the prompt. This is the failure that left the reusable unable to run at its own defaults.
- **`Task`, `Agent`** — the command is built out of subagents (agents that triage the pull request, summarise the change, find issues and validate each candidate finding). Without them a single orchestrator reviews the diff by hand and the triage tiers never run.
- **`TodoWrite`** — named in the command's own notes.

`Agent` sits beside `Task`, and `SlashCommand` beside `Skill`, for a mechanical reason rather than a stylistic one: each pair names a single tool that has been spelled both ways across Claude Code versions, while `claude-code-action@v1` pins its own moving CLI version. An allowlist entry matching no tool is inert, so naming both costs nothing and stops a CLI bump from reinstating this failure silently.

None of this is visible in the run log — see [troubleshooting.md](troubleshooting.md#code-review-finishes-green-but-posts-no-comment) for how to read a run that finishes green having reviewed nothing.

Keep additions read-only: `claude-code-action` treats the checked-out pull request head as untrusted and restores `.claude`, `CLAUDE.md`, `.mcp.json` and friends from the base branch for exactly that reason, so `Write`, `Edit` or a general `Bash(...)` entry would give a pull request author a foothold that the read-only tools do not. The execution tools stay inside that posture: a subagent inherits this same allowlist, so `Task` reaches nothing the orchestrator cannot already reach, and `TodoWrite` writes to the session's todo state rather than to the checked-out worktree. The browser tools added when a preview site is configured are the one exception, and a reasoned one: see [The preview site and the performance note](#the-preview-site-and-the-performance-note).

What the list does *not* do is describe the run's capabilities. It gates permission, not availability, and the distinction shows up the moment you read a transcript: run [34868917208](https://github.com/refokus-agency/meetmira-custom-code/actions/runs/34868917208) reports `permissionMode: default` and a `tools` array containing `Write`, `Edit` and `WebFetch` — none of them in the allowlist, all of them present, each denied on use for want of an approver. Two categories get through anyway. `ToolSearch` and `ReportFindings` were both used in that run without appearing in the allowlist, because they need no approval in the first place. And a built-in set of read-only shell commands — `ls`, `cat`, `echo`, `grep`, a bare `--version` probe — runs without matching a `Bash(...)` entry, which is why the orchestrator reads files with `cat` in a workflow whose allowlist names no such rule. The posture above still holds, since nothing in either category writes; the point is that auditing this default tells you what was *intended*, and only the transcript tells you what ran.

Two failure modes also survive a correct allowlist. A prefix rule matches on the literal command, so `Bash(gh pr diff:*)` rejects `gh pr diff 96 > /tmp/out; echo EXIT:$?` — a shell construct could smuggle a second command past the prefix, so the parser refuses the whole line and the transcript records `Contains simple_expansion` (or `Contains for_statement` for a loop) rather than a missing permission. Three of that run's twenty denials were this, on tools that were allowed. No list edit fixes them; only the command shape does. The other is reach: a subagent inherits the allowlist, so a reviewer that needs something outside it is stopped like the orchestrator. In that same run the reviewers could not inspect `vendor/*.tgz`, the vendored tarball this repo's callers now take `defineFeature` from — `tar` is not allowlisted and extraction writes, which is the boundary. They completed the review by inference instead. That is a coverage gap, not a defect: widening it means letting an untrusted head unpack an archive onto the runner, and the better fix lives upstream of this input.

**`prompt` must keep its eligibility-check override.** The command's eligibility check tells the model to stop without reviewing if Claude has already commented on the pull request, if the pull request is a draft, and if the diff is trivial. All three are sensible for a slash command a human runs once by hand, and all three are wrong here for the same reason: **the trigger is already an explicit human request.** Someone typing the phrase on a pull request Claude reviewed two pushes ago wants the current head reviewed; someone typing it on a draft wants the draft reviewed. Under the old `synchronize` trigger the first condition was outright destructive — once a run posted a summary, every later push short-circuited into a silent no-op with no comment and a green check.

`trivial` carries the sharpest version of the argument. This workflow has no automatic trigger, so a run exists *only* because a person decided the change was worth reviewing; the gate then re-decides that from the diff alone and silently overrules them. A documentation-only diff is reviewable material: "no code changed" is not "nothing to review".

The silent half is the worse half, and it is not specific to `trivial`. The action runs with `show_full_output: false`, so Claude's reasoning never reaches the run log and a deliberate decline is indistinguishable from a crash that swallowed its error. So the override adds one requirement on top of the three liftings: whatever the command decides, it says so in a pull request comment before the run ends. Closed and automated still stop the review — they just stop it out loud.

That requirement is an *instruction*, and an instruction only binds a model that is still running — which is precisely the case it was written to cover. So since [#79](https://github.com/refokus-agency/platform/issues/79) the same guarantee is also enforced from outside the model: the `Verify review outcome` step reads the transcript the action leaves behind and comments itself when the review did not run, did not finish, or finished without saying anything. The `show-full-output` input is the debugging escape hatch for the same blindness; it defaults to `false` because tool results are unsanitized and a public run log outlives the pull request.

**`prompt` must also keep its foreground requirement.** The `Agent` tool takes a launch mode, and when the caller omits one the runtime launches in the background. The command's fan-out omits it. A background launch hands back a receipt instead of a result, which leaves the orchestrator free to end its turn — and nothing follows the orchestrator in a headless run, so ending the turn terminates the run and kills every reviewer mid-flight. The transcript in [#91](https://github.com/refokus-agency/platform/issues/91) shows the shape: four agents spawned, four backgrounded, **zero completed**, and a closing message announcing it would wait for completion notifications that no longer had anywhere to arrive.

Whether the race is lost is a matter of pacing rather than configuration, which is what makes it look repo-specific and is why it survived this long. Where the orchestrator happens to stay in-turn long enough, the notifications land and the review completes; small diffs fail the most reliably, because there is nothing left to do after the fan-out and the turn ends immediately. `subagent_stats.requested` in the transcript is how to read it — `unset` is backgrounded by the runtime, and only an explicit `foreground` removes the race. Prompt wording alone is enough to obtain it, which is the only reason this is fixable from this repo at all.

The multiline block scalar is load-bearing — the override has to arrive as part of the same prompt, and the first line has to stay the bare slash command — and a caller that overrides `prompt` with that bare command re-introduces the bug for itself.

#### What the run reports about itself

A review costs real money and burns real context, and until [#94](https://github.com/refokus-agency/platform/issues/94) neither number was visible anywhere. `show-full-output` defaults to `false`, so Claude's own output never reaches the run log — but the action still writes the full transcript to disk and exposes its path as the `execution_file` output. The cost and every agent's token usage were already in there; nobody was reading them.

The `Report run telemetry` step does, and posts them as their **own** comment on the pull request:

```markdown
### Run telemetry

**Cost** $0.8421 · **Turns** 42 · **Duration** 3m 12s

| Agent | Context | Model |
|---|---|---|
| **⬥ main** (orchestrator) | **90k** | claude-opus-5 |
| ↳ code-reviewer | 120k | claude-sonnet-5 |
| ↳ security-reviewer | 88k | claude-sonnet-5 |
```

Its own comment, and not part of the review, because the review comment is written by the `code-review` plugin — a marketplace package this repo does not own. Telemetry that had to be threaded through the plugin's output would depend on the plugin's cooperation; a separate comment depends on nothing. Each run posts its own, with no upsert and no edit: how the spend moves across runs is worth more than a tidy thread.

Three decisions inside it are worth knowing before you change anything:

**Context is the agent's last message, never a sum across its messages.** Every assistant message reports the window that agent was holding at that turn, and the figure only grows — so the final message already *is* the maximum. Adding them up inflates it by roughly 25x. Measured on real transcripts: a main agent that went `71k → 90k` sums to `2,241k`, and a subagent that went `66k → 120k` sums to `3,230k`. The figure this reports is `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` on the agent's last assistant message, matching how Claude Code's own `/context` counts. Do not reach for `task_notification.usage.total_tokens` instead — it is cumulative across turns, which is the inflated number wearing a convenient name.

**There is no verdict.** The comment reports the raw count and stops. No threshold, no 200k comparison, no colour, no pass or fail. Whoever reads it makes that call against whatever yardstick they care about, and a workflow that made it for them would be wrong the first time the yardstick moved.

**The script cannot fail the job, by two independent mechanisms.** `report-run-telemetry.sh` returns `0` on every path — missing file, empty file, malformed JSON, missing field, a failing `gh pr comment` — emitting a `::notice::` instead, and the step carries `continue-on-error: true` on top of that. This is the deliberate divergence from its sibling `review-guard.sh`, which is *allowed* to go red: an unverified review is a result the caller has to see, an unreported cost is not. `@v1` is force-moved onto every consumer repo in the org, so a bug in an advisory reporter must never be able to redden a CI check anywhere.

Per-agent **cost** is absent for a reason: no per-agent USD figure exists anywhere in the transcript. `SDKResultMessage.usage` is main-agent-loop only by its own documentation, and `modelUsage` aggregates per *model* across every agent. A per-agent number would have to be estimated from model rates, and an estimate presented beside three measured figures reads as measured. Aggregate cost and per-agent context are what the transcript actually knows.

Per-agent rows are also all-or-nothing. Agents are separated by `parent_tool_use_id` — `null` is the orchestrator, any value is one Task subagent — and if a future `claude-code-action` stops emitting it, every subagent message becomes indistinguishable from an orchestrator one and the main row would silently absorb the lot. So when the transcript shows `Task` fan-out but itemises no per-agent usage, the whole table is dropped and only the aggregate figures are posted. One plausible wrong number is worse than no number.

Nothing from the transcript body reaches the comment. It is unsanitized tool output on a public repository, so only numbers, model names and subagent type names leave the runner — never prompt text, tool input, tool output or file contents. Same posture as the guard, for the same reason.

Because a reusable workflow runs in the **caller's** context, the API key is always the caller's. An external consumer supplies their own `ANTHROPIC_API_KEY`; this repo's secrets are never in scope, and neither is its Anthropic bill.

Caller-side requirements the reusable cannot enforce from the inside: `id-token: write` is mandatory (the action exchanges the workflow's GitHub OIDC token for a GitHub App token), `pull-requests: write` is needed to post the review, and `deployments: read` is needed when the repository sets `SITE_URL_TEMPLATE` (without it the review stops with a comment asking for it). See `examples/comment-code-review.yml`.

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

would be noisy and easy to miss when adding a new secret. `secrets: inherit` forwards everything the caller has access to, so adding a new secret is a one-line change in the reusable.

**This is the default for callers inside `refokus-agency`**, where the caller and the reusables share maintainers. An external caller gets the same blanket forward — every secret it holds, declared or not — against a floating `@v1` tag it doesn't control, which is a materially different trade. Those callers should enumerate instead: see [secrets.md](secrets.md#calling-from-outside-refokus-agency).

Note that every declared secret is `required: false`. A secret declared as required fails the run at startup for every caller that hasn't configured it, so the reusables gate the steps that need a secret instead of demanding it up front.

### Versioning with release-please

Callers reference the floating major tag `@v1`. Releases are automated by [release-please](https://github.com/googleapis/release-please-action):

1. Conventional commits land on `main` (`feat:`, `fix:`, `chore:`, etc., with `feat!:` or `BREAKING CHANGE:` footer for breakers).
2. release-please opens or updates a release PR aggregating unreleased commits, computing the next semver bump, and updating `CHANGELOG.md`.
3. Merging the release PR tags the new version (`v1.x.y`), creates a GitHub Release, and the `release-please.yml` workflow force-moves `@v1` to the same commit.

On a major bump the release PR also rewrites the `@vN` refs in `README.md` and in every `uses:` line of `examples/`, so new projects copy the new major the moment its tag exists. Each of those lines ends in `# x-release-please-major`, and each file is listed under `extra-files` in `release-please-config.json`. The marker replaces the first number on its line, so a `uses:` line must have no other digit before `@vN`. A new example file needs both the marker and an `extra-files` entry.

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

### Why are third-party actions pinned by SHA?

A Git tag is a mutable pointer. `uses: actions/checkout@v7` does not name code — it names a label that the action's owner, or anyone who compromises their account, can repoint at any commit at any time, with no PR and no notification to you. That is not hypothetical: in March 2025, `tj-actions/changed-files` had every one of its tags retargeted at a commit that dumped runner memory — including CI secrets — into publicly readable build logs, across roughly 23,000 repositories ([CVE-2025-30066](https://nvd.nist.gov/vuln/detail/CVE-2025-30066)).

This repo is a force multiplier for that failure. Consumers pin `refokus-agency/platform/...@v1`, and `v1` is force-moved to every release on the v1.x line (see [Versioning with release-please](#versioning-with-release-please)). A retargeted upstream tag reaches every Refokus project on the next run — no merge, no review, no version bump. The blast radius of a third-party action here is the whole org.

So every third-party `uses:` under `.github/workflows/` and `.github/actions/` names an immutable commit SHA, with the human-readable version carried in a trailing comment:

```yaml
uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

Three pieces make the convention hold rather than rot:

- **[pinact](https://github.com/suzuki-shunsuke/pinact) generates the pins, locally.** A hand-typed SHA is a hand-typed mistake, and here a wrong pin breaks CI/CD everywhere at once. `.pinact.yaml` scopes the tool to `.github/`. It runs on a developer's machine, not in CI — see below.
- **The `Pin check` workflow gates every PR** with [`.github/scripts/check-action-pins.sh`](../.github/scripts/check-action-pins.sh). It rejects a ref that isn't a full-length SHA, a pin with no version comment, and — the half that is easy to lose — a version comment that disagrees with the commit it labels, so a pin can't be made to *look* like `v7.0.1` while pointing somewhere else. Verification fails **closed**: if the GitHub API can't be reached, the check fails rather than passing something unverified. The gate runs read-only (`contents: read`) with no secrets — a security gate that can write to the repo is a bigger hole than the one it closes.
- **Dependabot owns the bumps,** so pinning trades "silently current" for "explicitly current" rather than for "stale". Composite actions need their own `dependabot.yml` entry — see [dependabot.md](dependabot.md#action-pins-in-this-repo).

**Why the gate is our own script and not an action.** There is a ready-made action that wraps pinact, and the first version of this gate used it. It worked. We replaced it anyway, because the shape was wrong: enforcing a policy about not trusting third-party code, by running third-party code. Pinning that wrapper to a SHA stops its tag from moving; it does not stop the code at that SHA from executing in the job. So the gate is ~200 lines of bash we own, depending only on `yq` and `gh`, both preinstalled on the runner.

pinact itself is not the problem and did not go away — it is still how pins are *generated*, on a developer's machine, where a compromise reaches a working tree under review rather than CI. And because the script resolves every tag itself, a pinact that wrote a bad SHA with a plausible-looking comment would be caught by the gate. Asking a tool to verify its own output is not verification.

The trade-off is that we maintain the check. That cost is bounded — the same trade this repo already took with [`check-dependabot-coverage.sh`](../.github/scripts/check-dependabot-coverage.sh) — and it buys a CI surface with no third-party code in it at all. The script carries a `--self-test` mode, run as its own CI step ahead of the real check, because a gate that has never been shown to fail is not a gate.

**First-party `@v1` references in `examples/` stay floating, deliberately.** A consumer copies those caller files once and must keep receiving fixes without editing them; that is the entire point of the floating major tag, and we control the repo it points at. The threat model here is *someone else's* mutable tag, not our own. (Whether first-party callers should pin too is a separate question with a separate trade-off — [#60](https://github.com/refokus-agency/platform/issues/60).)

This is a complement to an org-level allowed-actions policy, not a substitute: a policy decides *which* actions may run, a pin decides *which code* those actions are.

### Why does each reusable re-checkout the `platform` repo?

The composite action (`setup`) lives in `platform`. When a reusable runs, the working directory is a checkout of the **caller's** repo — not platform. To use a local composite action path like `./.github/actions/setup`, the reusable needs platform checked out somewhere accessible.

Each reusable does a secondary checkout of `refokus-agency/platform` into `.platform/`, then references `./.platform/.github/actions/setup`. The `platform-ref` input controls which ref to check out, and defaults to `main`.

**That default does not track the ref the caller pinned, and the two can drift.** A caller on `uses: ...@v1` runs the reusable's *definition* from the `v1` tag, but the secondary checkout takes whatever is on platform's `main` at run time — they are independent refs. Consequences worth knowing before you rely on a pin:

- A caller pinned to a released tag picks up later changes to the checked-out files with no version bump.
- Rolling `@v1` back to an earlier release does not roll back what the secondary checkout fetches.
- If a file the reusable depends on is moved or deleted on `main`, pinned callers break without having changed anything.

Set `platform-ref` explicitly when you need the reusable and the files it checks out to move together — in particular when pinning for reproducibility rather than for a rollback.

Since `platform` is public, the secondary checkout needs **no custom secret** — the built-in `GITHUB_TOKEN` reaches it, so there is no `GH_PAT_TOKEN` to provision. That was the key change that unblocked Dependabot PRs.

It is not, however, *anonymous*: no `token:` is set on those checkout steps, so `actions/checkout` falls back to its default of `${{ github.token }}` and authenticates the fetch. Keep that — an authenticated fetch avoids the runner IP's shared unauthenticated rate limit — but pair it with `persist-credentials: false`, or checkout writes that token into the checked-out `.git/config` and leaves it on disk for every later step in the job.

An alternative would be to publish the composite action as a standalone GitHub Action on the marketplace and reference it by name. That's overkill — this one's internal.

### Why `code-review.yml`'s platform checkout is not like the others

It is the one reusable that does not check out `refokus-agency/platform` into `.platform/` **for the composite `setup` action**. That is deliberate, not an oversight in the invariant described in [Why does each reusable re-checkout the `platform` repo?](#why-does-each-reusable-re-checkout-the-platform-repo) above. Since [#79](https://github.com/refokus-agency/platform/issues/79) it does take secondary checkouts, but only of `.github/scripts`, and for nothing else. There are two. The one after the review serves the guard from [#79](https://github.com/refokus-agency/platform/issues/79) and the telemetry reporter from [#94](https://github.com/refokus-agency/platform/issues/94). The one before the review serves `review-context.sh`, which composes the prompt ([#119](https://github.com/refokus-agency/platform/issues/119)).

In the other reusables that checkout exists for exactly one reason: reaching the local composite `setup` action. `code-review.yml` never calls `setup` — `claude-code-action` ships its own runtime and installs what it needs. Worse, calling `setup` here would hard-fail: it detects the package manager from a lockfile, and `platform` has no `package.json` at all, so it would exit with `::error::No lockfile found`.

A checkout with no consumer is just latency and one more moving part — which held exactly until the guard step gave it one. So the checkout it does take is kept as narrow as the need: sparse (`.github/scripts` only), and placed *after* the review rather than before it, so platform's files are not sitting in the workspace while the review reads an untrusted pull request head. It is sparse on the whole directory rather than on one file, which is why [#94](https://github.com/refokus-agency/platform/issues/94) added a second consumer without adding a second checkout.

The prompt has to be composed before the review, so [#119](https://github.com/refokus-agency/platform/issues/119) added the earlier checkout. It keeps the same rule. The `Resolve review context` step deletes `.platform/` on exit, whatever happens in it, before the pull request head is checked out, so the review still never sees platform's files. The order matters here in a way it does not after the review. `platform-ref` defaults to `main` and not to the ref the workflow runs from, so a broken `review-context.sh` on `main` would otherwise reach every caller's review at once. That is why the checkout is `continue-on-error` and the step falls back to the caller's prompt plus a fixed `Context not read:` block when the script is missing or fails: a failure here costs the review its context blocks, never the review itself — for a repository that does not set `SITE_URL_TEMPLATE`. One that sets it is told on the pull request instead: a failed checkout, or a `resolve-preview-site.sh` missing at `platform-ref`, stops the review with a comment and a red job, because a review without the configured site would look complete and not be (see [The preview site and the performance note](#the-preview-site-and-the-performance-note)). The same checkout also serves `resolve-preview-site.sh` ([#122](https://github.com/refokus-agency/platform/issues/122)), which runs just before the context step and copies the browser's init script to `$RUNNER_TEMP`, so nothing of it stays in the workspace either. `setup` is still never called here, which is the half of this that was always load-bearing.

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
