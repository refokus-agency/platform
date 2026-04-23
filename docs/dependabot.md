# Dependabot PRs

How the centralized workflows interact with Dependabot, why they don't run automatically, and the recommended process for reviewing and merging dep bumps.

## TL;DR

Dependabot PRs **will show a failed workflow** by default. This is expected. To run the workflow with secrets, a human reviewer opens the PR, checks the diff, and clicks **"Re-run jobs"** — the rerun executes as the human actor and has access to secrets. Merge once green.

## Why the workflow fails automatically

GitHub intentionally **blocks Dependabot-triggered workflows from accessing secrets** (since February 2021). When `github.actor == "dependabot[bot]"`:

- `GITHUB_TOKEN` is read-only.
- **Organization and repository secrets are inaccessible.**

Our callers (`pr-preview.yml`, `pr-ci.yml`, etc.) invoke reusable workflows in `refokus-agency/platform` with `secrets: inherit`. The reusables declare `GH_PAT_TOKEN` as `required: true` (needed to clone the private `platform` repo and configure GitHub Packages auth). When Dependabot triggers the workflow, the secret is unavailable → workflow fails immediately with:

```
Error when evaluating 'secrets'. pr-preview.yml (Line: ..., Col: ...):
Secret GH_PAT_TOKEN is required, but not provided while calling.
```

The job never starts a runner — it's a pre-run validation error.

### Why GitHub blocks this

A compromised dependency could execute a `postinstall` script during `npm install` that exfiltrates environment variables (including secrets). Real-world cases: `eslint-scope` (2018), `ua-parser-js` (2021), `node-ipc` (2022). Blocking secrets by default prevents this exfiltration vector.

Official FAQ: [github.com/dependabot/dependabot-core#3253](https://github.com/dependabot/dependabot-core/issues/3253#issuecomment-852541544)

## Recommended process

For each Dependabot PR:

1. **Read the diff.** Pay attention to:
   - `package.json` changes — what's being bumped? From what to what?
   - `package-lock.json` / `pnpm-lock.yaml` changes — are there unexpected new transitive dependencies?
   - Any non-lockfile changes Dependabot included (it shouldn't, but check).
2. **Check the release notes** for the bumped package (Dependabot includes them in the PR body). Look for breaking changes, suspicious additions, or compromised-account warnings.
3. **Click "Re-run jobs"** in the failed workflow run. This re-triggers the workflow with you as the actor — secrets are available, CI + preview deploy run normally.
4. **Verify the rerun passes.** If CI fails now for a real reason (broken types, tests, etc.), fix in the same PR or defer the bump.
5. **Merge** once the rerun is green.

Why this is safe: by reading the diff before rerunning, you take responsibility for the decision to execute that code with secrets available. GitHub's model is explicit about this ("a human reviews the PR and/or is willing to accept the risk").

## Alternatives (when manual rerun is too much friction)

If your repo receives many Dependabot PRs and manual rerun is painful, there are two paths. Both have tradeoffs.

### Option A: Dependabot secrets store

GitHub provides a separate secrets store scoped to Dependabot-triggered workflows:
`https://github.com/organizations/refokus-agency/settings/secrets/dependabot`

Replicate `GH_PAT_TOKEN`, `VERCEL_TOKEN`, and `VERCEL_ORG_ID` there. Dependabot-triggered workflows then have access to these copies.

**Tradeoff:** the supply-chain attack surface is still present. A compromised dependency can still exfiltrate the tokens. You're only isolating them (different bucket, possibly different values) — not removing the risk. This is acceptable if:
- Tokens are scoped as narrowly as possible.
- You rotate the Dependabot-scoped tokens separately.
- You accept the risk in exchange for zero-touch automation.

To limit blast radius, consider creating **dedicated tokens for Dependabot** with reduced scope (e.g., `read:packages` only instead of `write:packages`).

### Option B: `pull_request_target` + two-workflow split

Advanced pattern. Move the trusted operations (that need secrets) to a workflow triggered by `workflow_run` after a safe preliminary `pull_request` workflow completes. Or use `pull_request_target` to run in the base branch's trusted context.

**Tradeoff:** same risk as before if you're not careful to avoid checking out and executing the PR's code in the trusted workflow. Easy to misconfigure.

Not currently used in `platform`. If a repo really needs it, add the pattern directly in that repo's callers, not in the reusables — it's a per-repo escape hatch, not a platform concern.

### Anti-pattern: `pull_request_target` with untrusted checkout

Don't do this in any Refokus repo:

```yaml
# WRONG
on: pull_request_target
jobs:
  ci:
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}   # <-- untrusted PR code
          # ...now has access to secrets via pull_request_target
      - run: pnpm install   # <-- executes untrusted postinstall with secrets
```

This reintroduces the full supply-chain risk the original `pull_request` block prevents. If you see this pattern, flag it.

## Current state across Refokus repos

As of the first migration rollout, all repos using the centralized workflows follow the **manual rerun** pattern. Dependabot PRs appear with failed checks; reviewers unblock them by rerunning after reading the diff.

This is documented here rather than fixed via configuration because:

1. It's low-volume (each repo gets a handful of Dependabot PRs per week).
2. The manual step enforces a security review gate that we'd otherwise have to replicate.
3. It avoids replicating secrets to the Dependabot store (which adds operational burden and no real security gain).

If the volume grows or the friction becomes painful, revisit Option A.

## Troubleshooting

### "I clicked Re-run and it still fails with the same error"

- Confirm you're logged in as a human user, not as a bot.
- Confirm the rerun kicked off a **new run** (check the Actions tab for a new entry, not just the old one). GitHub sometimes uses cached definitions for reruns — if the failed run is over a few hours old, close and reopen the PR to force a fresh trigger.
- Check that the original failure was actually the secret-availability error. A real CI failure (e.g. broken lint) will fail the same way on rerun.

### "The PR has conflicts with main"

Comment `@dependabot rebase` on the PR. Dependabot rebases the branch onto the latest main, re-triggering the workflow (which will again fail until you rerun it manually).

### "I merged a Dependabot PR without running CI. Now main is broken."

The merge-triggered workflow (`main-stage.yml` / `main-deploy.yml` / `main-release.yml`) runs with secrets because the actor is the merger, not Dependabot. If it fails on main, revert the merge commit and investigate on a branch.

## References

- [GitHub Changelog: Dependabot workflows run with read-only permissions](https://github.blog/changelog/2021-02-19-github-actions-workflows-triggered-by-dependabot-prs-will-run-with-read-only-permissions/)
- [GitHub Security Lab: Preventing pwn requests](https://securitylab.github.com/research/github-actions-preventing-pwn-requests)
- [Dependabot FAQ on this change](https://github.com/dependabot/dependabot-core/issues/3253#issuecomment-852541544)
- [Dependabot secrets docs](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/managing-encrypted-secrets-for-dependabot)
