# Dependabot PRs

How the centralized workflows handle Dependabot-triggered runs, why secrets need special handling, and the dual-layer defense we use to keep things safe.

## TL;DR

Dependabot PRs run normally once **both** of these are in place:

1. **Secrets are stored in the Dependabot secrets store** (separate from the Actions store) at the org level. Dependabot-triggered workflows access this store instead of the blocked Actions store.
2. **Install scripts are disabled by default** (`--ignore-scripts` passed to pnpm/npm/bun). This closes the main supply-chain attack surface even when secrets are available.

Both are required. Either alone is insufficient:
- Secrets without ignore-scripts: a compromised dependency can still exfiltrate secrets via postinstall.
- Ignore-scripts without secrets: Dependabot workflows still fail because they can't call the reusables (need `GH_PAT_TOKEN`).

## Why secrets need a separate store

Since February 2021, GitHub **blocks Actions secrets from workflows triggered by Dependabot** (`github.actor == "dependabot[bot]"`). The reason: a malicious dependency's `postinstall` script can exfiltrate environment variables, and Dependabot PRs run arbitrary package versions.

Our reusables (`ci.yml`, `deploy.yml`, `release.yml`) declare `GH_PAT_TOKEN` as `required: true` (needed to clone the private `platform` repo and auth `.npmrc`). When Dependabot triggers a workflow, `secrets: inherit` returns empty for `GH_PAT_TOKEN` → the workflow fails at validation, before any runner starts:

```
Error when evaluating 'secrets'. pr-preview.yml (Line: 15, Col: 11):
Secret GH_PAT_TOKEN is required, but not provided while calling.
```

Dependabot secrets store (`github.com/organizations/<org>/settings/secrets/dependabot`) is a **separate bucket** of secrets that GitHub explicitly exposes to Dependabot-triggered workflows. Putting our tokens there unblocks Dependabot runs.

### Manual rerun is not a workaround anymore

An older GitHub Dependabot FAQ (2021) suggested that re-running a failed Dependabot workflow as a human would grant secrets access. **This is no longer true.** Current official docs state:

> When you manually re-run a Dependabot workflow, it will run with the same privileges as before even if the user who initiated the rerun has different privileges.

Rerunning does not help. Don't rely on it.

## Why ignore-scripts is the second layer

Allowing Dependabot-triggered workflows to access secrets re-opens the attack surface that GitHub's block was designed to prevent. A malicious version of a trusted package could be published (e.g., maintainer account compromise, as happened with `eslint-scope` in 2018, `ua-parser-js` in 2021, `node-ipc` in 2022), and Dependabot would auto-open a PR to bump to that version. When the workflow runs `pnpm install`, the malicious package's `postinstall` runs with full env access.

Our composite action `setup` passes `--ignore-scripts` to pnpm/npm/bun by default. This disables:
- `preinstall` / `postinstall` / `install` lifecycle scripts
- `prepare` / `prepublish` scripts

Legitimate cases that rely on these (native-module packages like `sharp`, `bcrypt`, `canvas`, or binary-downloaders like `puppeteer` / `electron`) stop working in CI. For Refokus projects, the current stack (GSAP / Vite / Next.js / Vercel) doesn't include any of those — every migrated repo builds fine with scripts disabled.

If your repo legitimately needs postinstall, opt out by passing `unsafe-install-scripts: true` in the caller:

```yaml
jobs:
  ci:
    uses: refokus-agency/platform/.github/workflows/ci.yml@main
    with:
      unsafe-install-scripts: true   # I know what I'm doing
    secrets: inherit
```

The name intentionally signals the risk. Don't enable it without thinking through the threat model for your specific dependencies.

## Setup checklist

For a new repo (or retrofitting an existing one):

- [ ] Repo is in `refokus-agency` with Dependabot enabled (usually `.github/dependabot.yml` present).
- [ ] Callers in the repo use `secrets: inherit` and the reusables from `platform`.
- [ ] Org-level Dependabot secrets are populated (see next section).

For the org (one-time setup):

- [ ] `GH_PAT_TOKEN` in `https://github.com/organizations/refokus-agency/settings/secrets/dependabot`
- [ ] `VERCEL_TOKEN` in the same Dependabot store
- [ ] `VERCEL_ORG_ID` in the same Dependabot store

Use the same values as in the Actions store, or create scoped-down tokens specifically for Dependabot (recommended for `GH_PAT_TOKEN` — a `read:packages`-only token is enough for install, and limits blast radius if a malicious postinstall somehow runs).

## What the flow looks like end-to-end

1. Dependabot opens a PR bumping a dependency.
2. `pr-preview.yml` triggers on the PR event.
3. The workflow reads secrets from the **Dependabot store** (not the Actions store — GitHub routes automatically based on the trigger actor).
4. The composite action `setup` runs `pnpm install --frozen-lockfile --ignore-scripts` (or `npm ci --ignore-scripts`, or `bun install --frozen-lockfile --ignore-scripts`).
5. CI runs lint/typecheck/test/build — all the same checks as a human PR.
6. Preview deploy (if the caller includes it) runs Vercel pull/build/deploy.
7. Reviewer checks the PR diff and the preview URL; merges when confident.

If any step fails for a real reason (broken types, failing test, etc.), fix in a follow-up or close the Dependabot PR.

## Residual risks

Even with both layers in place, some risks remain:

- **Build-time exploitation**: a malicious package's code runs during `npm run build`. Not prevented by `--ignore-scripts`. If the build process imports and executes dependency code (normal for bundlers), a malicious package can run arbitrary code at that point. Mitigation: review PRs, keep the Vercel token scoped to specific projects.
- **Test-time exploitation**: tests import deps. Same risk. Same mitigation.
- **Indirect exfiltration**: a malicious build output that exfiltrates from end-user runtime rather than CI. Outside the scope of CI secret protection.

Bottom line: the two-layer setup (Dependabot store + ignore-scripts) closes the most common and lowest-effort attack vector (postinstall exfiltration). Human review of the PR diff remains the last line of defense for everything else.

## References

- [GitHub Docs: Automating Dependabot with GitHub Actions](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/automating-dependabot-with-github-actions)
- [GitHub Docs: Troubleshooting Dependabot on GitHub Actions](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/troubleshooting-dependabot-on-github-actions)
- [GitHub Docs: Managing encrypted secrets for Dependabot](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/managing-encrypted-secrets-for-dependabot)
- [GitHub Security Lab: Preventing pwn requests](https://securitylab.github.com/research/github-actions-preventing-pwn-requests)
