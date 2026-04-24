# Dependabot PRs

How the centralized workflows handle Dependabot-triggered runs, why automatic runs fail, and how the `workflow_dispatch` + required-check pattern unblocks merges after human review.

## TL;DR

Dependabot-triggered workflows in our setup **fail automatically** because GitHub blocks them from accessing Actions secrets (and our reusables require `GH_PAT_TOKEN` to clone the private `platform` repo). The fix is not to give Dependabot automatic secret access — it is to make the manual re-trigger an explicit, auditable review step.

**The flow:**

1. Dependabot opens a PR. The automatic workflow fails at secrets validation; the check appears as red on the PR.
2. A reviewer reads the diff (bumps, transitive deps, release notes).
3. The reviewer dispatches the same workflow manually from the Actions tab, targeting the Dependabot branch. The dispatched run executes as the reviewer (not as Dependabot), so secrets are available.
4. The dispatched run's check status overwrites the failed one on the same commit SHA.
5. Branch protection requires that check — the successful dispatch unblocks merge.

Two defensive layers are always on:

- **`--ignore-scripts` by default** in the composite `setup` action, for every install (human PRs included). Closes the install-time supply-chain attack vector regardless of how the workflow was triggered.
- **Branch protection requiring the check**. Ensures a human cannot merge a Dependabot PR without dispatching the workflow first.

## Why the automatic run fails

Since February 2021, GitHub blocks Actions secrets for workflows triggered by Dependabot (`github.actor == "dependabot[bot]"`) on `pull_request`, `push`, and related events. The rationale: a malicious dependency could execute code during `npm install` that exfiltrates environment variables.

Our reusable workflows declare `GH_PAT_TOKEN` as `required: true` (needed to clone the private `platform` repo and authenticate `.npmrc` for `@refokus-agency/*` packages). On a Dependabot trigger, `secrets.GH_PAT_TOKEN` resolves to an empty string, failing the pre-run validation with:

```
Error when evaluating 'secrets'. pr-preview.yml (Line: 15, Col: 11):
Secret GH_PAT_TOKEN is required, but not provided while calling.
```

The workflow aborts in ~3 seconds without starting a runner. The check appears as failed on the PR.

## Why manual re-run doesn't work

An older (2021) GitHub FAQ suggested that re-running a failed Dependabot workflow would grant access to secrets because the actor becomes the human re-runner. **This is no longer true**:

> When you manually re-run a Dependabot workflow, it will run with the same privileges as before even if the user who initiated the rerun has different privileges.

Source: [GitHub Docs — Troubleshooting Dependabot on GitHub Actions](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/troubleshooting-dependabot-on-github-actions)

Rerun inherits the original privilege context. For our case, that means the same failure.

## Why `workflow_dispatch` does work

`workflow_dispatch` is a distinct trigger from `pull_request` or `push`. When a human invokes it from the Actions tab, the run's `github.actor` is the human, not Dependabot. GitHub's block on Dependabot secrets does not apply, so the full secrets set is available.

GitHub's status check system tracks the latest status per (commit SHA, check name). When a dispatched run completes for the same commit as the failed automatic run, its status replaces the failed one on the PR. Branch protection then sees a green check and unblocks merge.

## How to dispatch a run

From the repository's **Actions** tab:

1. Select the workflow (e.g., "Pull Request") from the left sidebar.
2. Click **Run workflow** (top-right of the list view).
3. From the **Branch** dropdown, select the Dependabot branch (e.g., `dependabot/npm_and_yarn/foo-1.2.3`).
4. Click **Run workflow** to confirm.

From the CLI:

```bash
gh workflow run "Pull Request" --repo <org>/<repo> --ref dependabot/npm_and_yarn/foo-1.2.3
```

The new run appears in the Actions list within a few seconds. When it finishes, the check status on the PR updates.

## Branch protection configuration

On every repo consuming the centralized workflows:

1. **Settings → Branches → Branch protection rules → Add rule** (or edit existing `main` rule).
2. Enable **Require status checks to pass before merging**.
3. Search for and select the check(s) produced by the caller workflow. Names typically look like `Pull Request / ci / checks` (derived from `name:` in the caller + `jobs.<key>` + the reusable's inner `jobs.<key>`).
4. Also enable **Require branches to be up to date before merging** for safety.

Notes:

- The check name only appears in the search box **after the workflow has run at least once** on a PR or dispatch. For a brand-new repo, dispatch the workflow on `main` once to produce the first run, then configure the rule.
- For repos with a `production` branch (3-env custom-code), add a similar rule protecting that branch.
- The manual dispatch remains as an admin-bypass option if a green check is truly unachievable for a given PR (e.g., transient infrastructure failure).

## Defensive layers beyond the gate

### `--ignore-scripts` by default

Every install (human PR, Dependabot PR, dispatch) runs with `--ignore-scripts` unless the caller explicitly passes `unsafe-install-scripts: true`. This disables:

- `preinstall`, `install`, `postinstall` lifecycle scripts
- `prepare`, `prepublish`, `prepublishOnly` scripts

A malicious dependency's install-time code cannot run. Limits exfiltration even when secrets are in the environment (e.g., during a dispatched run).

### Reviewer discipline

The dispatch step is the effective sign-off. Guidance for reviewers:

- Read the diff of `package.json` and lockfile. Look for unexpected transitive bumps.
- Check the bumped package's release notes (Dependabot embeds them in the PR body).
- Be cautious of bumps to packages you're not familiar with, especially popular ones with recent maintainer changes.
- If anything looks off, close the PR instead of dispatching.

## Why not put secrets in the Dependabot secrets store?

GitHub offers an alternative: a separate Dependabot-scoped secrets store at `https://github.com/organizations/<org>/settings/secrets/dependabot`. Secrets there are exposed to Dependabot-triggered workflows automatically, removing the need for manual dispatch.

We chose **not** to use it in Refokus. Reasons:

- **Reviewer discipline is explicit** with the dispatch pattern. The act of clicking "Run workflow" is an audit-loggable event tied to a human. Populating the store makes the grant implicit and permanent.
- **No secret duplication.** Maintaining two stores means two rotation schedules, two scopes to keep in sync, and two potential exfiltration points.
- **Low Dependabot volume at Refokus.** One click per PR is not operationally painful for our current repo count. If volume grows significantly, we can revisit.

The store remains a valid fallback. If manual dispatch becomes a bottleneck, enabling it is straightforward: populate the store and remove the required check (or remove `workflow_dispatch` from callers).

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

`pull_request_target` runs in the trusted base-branch context (secrets available), but checking out and installing the PR's code in that context is equivalent to pre-2021 behavior — a malicious postinstall exfiltrates secrets. If you see this pattern in a Refokus repo, flag it.

## Troubleshooting

### The dispatched run still fails with the secrets error

- Confirm you dispatched as a human user, not as a bot or service account.
- Confirm the dispatched run is a new run (check the run ID), not a rerun of the failed automatic one.
- If the repo is private and the workflow files reference private reusables, ensure your user has access to the reusable-hosting repo (`platform`).

### The PR check doesn't update after the dispatched run succeeds

- Verify the dispatched run ran on the same commit SHA as the PR's head. If someone pushed to the Dependabot branch after dispatch, the SHAs diverge.
- Wait up to a minute — GitHub can lag on check status propagation.
- Ensure the caller workflow's job names (and thus check names) haven't changed between the two runs.

### Required-check name not appearing in branch-protection search

The workflow must have produced at least one check for GitHub to index it. Dispatch the workflow on `main` once, or trigger a PR against a branch that already has the caller file, then retry the search.

## References

- [GitHub Docs — Events that trigger workflows: workflow_dispatch](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#workflow_dispatch)
- [GitHub Docs — Automating Dependabot with GitHub Actions](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/automating-dependabot-with-github-actions)
- [GitHub Docs — Troubleshooting Dependabot on GitHub Actions](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/troubleshooting-dependabot-on-github-actions)
- [GitHub Security Lab — Preventing pwn requests](https://securitylab.github.com/research/github-actions-preventing-pwn-requests)
- Issue refokus-agency/platform#7 — full technical report and alternative approaches considered.
