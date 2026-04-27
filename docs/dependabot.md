# Dependabot PRs

How the centralized workflows handle Dependabot-triggered runs.

## TL;DR

**Dependabot PRs run normally — same as human PRs.** No special handling, no manual dispatch, no separate secrets store. The workflow uses `GITHUB_TOKEN` (which Dependabot does have access to, unlike custom Actions secrets), and the reusables in `refokus-agency/platform` are public so no PAT is needed to clone them.

The supply-chain attack surface is closed at install time by `--ignore-scripts`, on by default in the composite `setup` action.

## Why this works

GitHub blocks **custom Actions secrets** (anything you've defined under Settings → Secrets and variables → Actions) from workflows triggered by Dependabot. The block exists because a malicious dependency could exfiltrate them via lifecycle scripts during install.

What the block does NOT cover:

- The auto-generated `GITHUB_TOKEN`, available to every workflow including Dependabot's. It's read-only by default for Dependabot, but you can explicitly request scopes via `permissions:`.
- Anonymous reads to public repositories (so cloning a public reusable workflow needs no token at all).
- Reads to GitHub Packages from the same organization, which `GITHUB_TOKEN` can do with `packages: read` granted.

By making `refokus-agency/platform` public and using `GITHUB_TOKEN` for everything our reusables need, the Dependabot block becomes irrelevant — there's nothing in our pipeline that requires a custom secret to start.

For workflows that genuinely need custom secrets (Vercel deploys, semantic-release publishing), Dependabot's auto-trigger still fails at the `secrets.VERCEL_TOKEN` lookup. Those jobs are gated behind `needs: ci`, so they simply don't run for Dependabot PRs — the CI check still passes (because it doesn't need Vercel), and a human merging the PR triggers the deploy chain. See "Vercel preview deploys" below for the recommended `if:` guard.

## Configuration in your repo

If you're consuming the centralized workflows via the `examples/` callers as-is, **there's nothing extra to do**. The provided callers declare the right `permissions:` and reference the public reusables.

If you're authoring a custom caller, the relevant pieces:

```yaml
on:
  pull_request:

permissions:
  contents: read
  packages: read     # only if your repo installs @refokus-agency/* private packages

jobs:
  ci:
    uses: refokus-agency/platform/.github/workflows/ci.yml@v1
    secrets: inherit
```

`secrets: inherit` is harmless — the reusables don't require any custom secrets for the CI path.

## Vercel preview deploys (`pr-preview.yml`)

Dependabot can't access `VERCEL_TOKEN`, so the `deploy-preview` job in `pr-preview.yml` would fail validation. The example caller skips that job for Dependabot PRs:

```yaml
jobs:
  ci:
    uses: refokus-agency/platform/.github/workflows/ci.yml@v1
    secrets: inherit

  deploy-preview:
    needs: ci
    if: github.actor != 'dependabot[bot]'
    uses: refokus-agency/platform/.github/workflows/deploy.yml@v1
    with:
      environment: preview
    secrets: inherit
```

Result: Dependabot PRs get CI green and `deploy-preview` shows as "skipped" (which counts as passing, not failing). Human PRs run both jobs as usual.

## Defensive layers

What's in place to limit blast radius if a dependency is compromised:

| Layer | What it does |
|---|---|
| `--ignore-scripts` (default in `setup`) | Disables `postinstall` / `prepare` / etc. lifecycle scripts. Closes the historical primary attack vector. |
| Custom Actions secrets blocked for Dependabot | `VERCEL_TOKEN`, etc. are unavailable. Their absence is enforced at the GitHub workflow level — not something the workflow can leak. |
| `GITHUB_TOKEN` is read-only + scoped + short-lived | If exfiltrated during build/test, an attacker gets repo read + package read for ~2 hours. Cannot write, cannot escape the repo. |
| Branch protection requiring review | A human must approve the PR before merge, providing a chance to inspect the diff and the bumped package's release notes. |

## Residual risk

Even with all of the above, code from a compromised dependency can run during the `build` and `test` phases (bundlers and test runners evaluate dep code). During those phases:

- It can read environment variables, including `GITHUB_TOKEN`.
- Exfiltrated `GITHUB_TOKEN` gives read access to the repo and (if granted) `@refokus-agency/*` packages, until it expires.
- It cannot exfiltrate `VERCEL_TOKEN` or other Actions secrets — those simply aren't in env on Dependabot runs.

This residual is the same as for any PR (human or bot) that introduces a new dependency. The mitigation is reviewer discipline: when a Dependabot PR shows up, glance at the bumped package's release notes and recent commits before merging.

## Anti-patterns

Don't do this:

```yaml
# WRONG — pull_request_target with untrusted checkout re-opens the attack surface
on: pull_request_target
jobs:
  ci:
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}   # untrusted code
      - run: pnpm install                                   # exec with secrets
```

`pull_request_target` runs in the trusted base-branch context with secrets available. Checking out the PR's code in that context defeats the entire reason GitHub blocks `pull_request` from secrets. If you see this pattern in a Refokus repo, flag it.

## What we tried before this approach

For history. Patterns we evaluated and ruled out:

- **Manual rerun of the failed Dependabot workflow.** GitHub used to escalate the rerun's privileges to the human re-running it. They changed this. Reruns now inherit the original Dependabot privilege context. Doesn't work.
- **Dependabot secrets store.** A separate bucket of secrets specifically exposed to Dependabot-triggered workflows. Functional, but duplicates secrets and adds operational overhead. Made obsolete by the public-platform + `GITHUB_TOKEN` approach.
- **`workflow_dispatch` + required-check gate.** Add `workflow_dispatch` to the caller, have a reviewer dispatch manually after reading the diff, require the resulting check via Rulesets. **Does not work**: GitHub Rulesets tracks separate check-suites for `pull_request` and `workflow_dispatch` events; the failed auto-run remains "stuck" even after a successful dispatch on the same SHA.

## References

- [GitHub Docs — Automating Dependabot with GitHub Actions](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/automating-dependabot-with-github-actions)
- [GitHub Docs — Permissions for the GITHUB_TOKEN](https://docs.github.com/en/actions/using-jobs/assigning-permissions-to-jobs)
- [Carlos Becker — Automerge Dependabot PRs](https://carlosbecker.com/posts/dependabot-automerge/) — pointed us toward `GITHUB_TOKEN` as the path forward
- Issue [#7](https://github.com/refokus-agency/platform/issues/7) — full investigation log
