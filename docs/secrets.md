# Secrets

What secrets the reusables need, where they should live, and how to configure them.

## Summary

| Secret | Used by | Expected level | Notes |
|---|---|---|---|
| `GITHUB_TOKEN` | all workflows | **automatic** | Built-in, generated per run. No setup needed. |
| `VERCEL_TOKEN` | `deploy.yml` | **org** | Vercel personal or org-scoped token |
| `VERCEL_ORG_ID` | `deploy.yml` | **org** | Same across all Refokus Vercel projects |
| `VERCEL_PROJECT_ID` | `deploy.yml` | **repo** | Unique per Vercel project |
| `RELEASE_APP_ID` | `release.yml` | **org or repo** | Optional. GitHub App ID for branch-protection bypass on `main`. Required when using `@semantic-release/git` against a branch with a "PRs required" ruleset. |
| `RELEASE_APP_PRIVATE_KEY` | `release.yml` | **org or repo** | Optional. PEM private key paired with `RELEASE_APP_ID`. |
| `ANTHROPIC_API_KEY` | `code-review.yml` | **org or repo** | Optional. Anthropic API key for the AI code review. Without it the review skips green — it never fails the run. See [Anthropic credentials for code review](#anthropic-credentials-for-code-review) below. |
| `CLAUDE_CODE_OAUTH_TOKEN` | `code-review.yml` | **org or repo** | Optional. Alternative to `ANTHROPIC_API_KEY`. |
| `CHECKOUT_TOKEN` | `ci.yml`, `deploy.yml` | **org or repo** | Optional. Only needed when `submodules: true` and a submodule points at a private repo other than the caller's own — `GITHUB_TOKEN` can't read across repos. See [Submodules](#submodules) below. |

`GITHUB_TOKEN` covers what we used to need a PAT for: cloning the public `refokus-agency/platform` reusables (no auth needed for public repos), authenticating `.npmrc` for `@refokus-agency/*` packages on GitHub Packages, and tagging/publishing in `release.yml`. The caller declares the scopes via `permissions:` (`contents`, `packages`).

Custom Actions secrets (`VERCEL_*`) are required only for the deploy reusable. Dependabot-triggered workflows can't access these and won't try to deploy — see [dependabot.md](dependabot.md) for the `if:` guard pattern.

## How `secrets: inherit` works

In the caller:

```yaml
ci:
  uses: refokus-agency/platform/.github/workflows/ci.yml@v1
  secrets: inherit   # <- passes all available secrets
```

The caller has access to:
- **Organization secrets** that the repo is allowed to use (configured at the org level).
- **Repository secrets** defined in the repo itself.
- **Environment secrets** if the job targets a specific environment.

`secrets: inherit` forwards all three to the reusable. The reusable declares which ones it actually requires; anything else is ignored. `GITHUB_TOKEN` is special — it's automatically available without needing to be passed.

## Configuring secrets

### `GITHUB_TOKEN`

Nothing to do. GitHub generates one per workflow run automatically. Scopes are controlled via the `permissions:` block in the caller — see [getting-started.md](getting-started.md) for the standard set.

### Organization-level (for shared Vercel secrets)

For `VERCEL_TOKEN` and `VERCEL_ORG_ID`:

1. Go to `https://github.com/organizations/refokus-agency/settings/secrets/actions`.
2. Click **New organization secret**.
3. Set the value.
4. Under **Repository access**, pick one of:
   - **All repositories** — simplest; every repo in the org can use it.
   - **Private repositories** — safer if you have public repos that shouldn't see these secrets.
   - **Selected repositories** — most controlled; list the repos explicitly.
5. Save.

Once set, any repo with access can use it via `secrets.SECRET_NAME` or `secrets: inherit`.

### Repository-level (per-project Vercel secret)

For `VERCEL_PROJECT_ID` (one value per Vercel project):

1. Go to `https://github.com/refokus-agency/<repo>/settings/secrets/actions`.
2. Click **New repository secret**.
3. Set the value (get it from the Vercel project settings or by running `vercel link` locally and inspecting `.vercel/project.json`).

### Anthropic credentials for code review

`code-review.yml` accepts three mutually exclusive credential paths and needs exactly one:

| Path | How | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` secret | Org or repo secret. Get the key from [console.anthropic.com](https://console.anthropic.com/settings/keys). | Simplest. Recommended at org level so every repo's caller works with no per-repo setup. |
| `CLAUDE_CODE_OAUTH_TOKEN` secret | Org or repo secret. | Alternative to the API key. |
| `ANTHROPIC_FEDERATION_RULE_ID` + `ANTHROPIC_ORG_ID` org **variables** | Actions *variables*, not secrets — neither value is sensitive. Set once at org level; the inputs of the same name default to them. | Anthropic workload identity federation: the action exchanges the workflow's GitHub OIDC token for a short-lived credential, so there is no static key to store or rotate. |

If none is configured, the workflow emits a `::notice` naming what's missing, skips the review, and completes **green**. It never fails a PR over a missing credential.

**Federation needs no per-repo wiring, and no secrets at all.** `federation-rule-id` and `anthropic-org-id` default to the caller's `ANTHROPIC_FEDERATION_RULE_ID` and `ANTHROPIC_ORG_ID` Actions **variables**. GitHub resolves the `vars` context in a reusable against the *caller's* repository and organization — per GitHub's docs, *"For reusable workflows, the variables from the caller workflow's repository are used"* — so setting the two org variables once configures every repo in the org, and the caller stays exactly as it ships:

```yaml
jobs:
  code-review:
    uses: refokus-agency/platform/.github/workflows/code-review.yml@v1
```

Set them at `https://github.com/organizations/<org>/settings/variables/actions` (the **Variables** tab, not Secrets). A caller can still override either per repo by passing it explicitly under `with:`. If a variable is unset, the input resolves to an empty string and the guard falls through to the other credential paths — nothing breaks.

This is also the cleanest answer to the `secrets: inherit` concern above: on the federation path there is no secret to inherit in the first place.

#### Scoping the federation rule — read before enabling it on a public repo

Federation's safety lives entirely in the **rule's `match` block**, not in keeping the two identifiers quiet. They are identifiers, not credentials — Anthropic's own documentation puts them in a plaintext `env:` block in the workflow file. Nobody can use them without a GitHub-signed OIDC token whose claims satisfy your rule. But a loosely scoped rule turns that pair into an open door, and Anthropic warns about it directly:

> A `subject_prefix` of `repo:your-org/*` alone matches every repository in your organization, and without a `ref` constraint it also matches `pull_request` runs triggered from forks. Anyone who can open a pull request against a matching repository could obtain a federated Anthropic token.
>
> — [Use WIF with GitHub Actions](https://platform.claude.com/docs/en/manage-claude/wif-providers/github-actions)

**That warning used to be about exactly this workflow, and the comment trigger is what defused it.** The `sub` claim's shape depends on the event. GitHub's [OIDC reference](https://docs.github.com/en/actions/reference/security/oidc) gives the two that matter here:

| Trigger | `sub` |
|---|---|
| `pull_request` event | `repo:ORG-NAME/REPO-NAME:pull_request` |
| anything else, no environment | `repo:ORG-NAME/REPO-NAME:ref:refs/heads/BRANCH-NAME` |

On the old `pull_request` trigger the review's token carried `…:pull_request` — a shape that does not distinguish a fork PR from an internal one — and the mitigation Anthropic recommends was unavailable: pinning `claims.ref` to `refs/heads/main` meant the review never authenticated at all, because a pull request carries no such ref. You had to admit `pull_request`, the very event the warning concerns.

`issue_comment` is not a pull request event and the job references no environment, so it takes the second row. And because GitHub always runs an `issue_comment` workflow **from the default branch**, that ref is the default branch every time, whatever pull request the comment sits on. So the recommended pin now both works and is exact:

```json
"match": {
  "subject_prefix": "repo:refokus-agency/<repo>:ref:refs/heads/main",
  "audience": "https://api.anthropic.com",
  "claims": {
    "repository_owner": "refokus-agency",
    "ref": "refs/heads/main"
  }
}
```

Scope to the exact repository, never to the org — `repo:your-org/*` is the shape Anthropic's warning names.

(Repositories created after 2026-07-15 use an immutable default subject format that embeds owner and repository IDs. If a rule against a new repo never matches, read the actual `sub` off a run's token before assuming the format above.)

**Federation is now a reasonable choice on a public repo, which it was not before.** The old advice here was to prefer the `ANTHROPIC_API_KEY` secret, because GitHub *structurally* withholds secrets from fork pull requests — a platform guarantee you cannot misconfigure — while a federation rule scoped by hand fails open and silent when you get it wrong. Two things changed. The ref pin above closes the scoping hole properly rather than by hand-waving. And the structural guarantee is gone regardless of which path you pick: `issue_comment` runs with the repository's secrets *always*, even on a fork's pull request, exactly like `pull_request_target` — which is why the reusable refuses to check out a fork head at all (see [architecture.md](architecture.md#why-fork-pull-requests-are-skipped)). Neither path is protected by the platform any more, so pick on the merits: federation has no static key to store, leak or rotate.

**Known limitation.** The reusable exposes only `federation-rule-id` and `anthropic-org-id`. Upstream also accepts `anthropic_service_account_id`, `anthropic_workspace_id` (required when the rule spans multiple workspaces) and `anthropic_oidc_audience`. If your rule needs any of those, the reusable cannot pass them yet — adding them is additive and non-breaking.

**The three paths are not perfectly equivalent for inline comments.** By default `claude-code-action` buffers unconfirmed inline comments and classifies them (real review vs. test/probe) before posting — its `classify_inline_comments` input defaults to `true`. That classification pass reads `ANTHROPIC_API_KEY` and only that key; the OAuth token and the federation credential are not forwarded to it. On those two paths the classification is therefore skipped and **every** buffered comment posts unfiltered. It fails open — nothing errors and no comment is lost — but expect slightly noisier reviews on the OAuth-only and federation-only paths.

Three things worth knowing before you enable this:

- **`id-token: write` is mandatory in the caller**, on every path — not just federation. The action exchanges the workflow's GitHub OIDC token for a GitHub App token. The reusable cannot detect the omission from the inside; the run just fails. `examples/comment-code-review.yml` grants it.
- **The API key belongs to the caller, and so does the bill.** A reusable workflow runs in the caller's context with the caller's secrets, so each repo (and each external consumer) pays for its own reviews. The review fans out several parallel agents per run, and cost scales with how often it runs, not with repo count. That is the whole reason the trigger is a comment and not `pull_request` or `push`: every run is one a human asked for.
- **External consumers should pass secrets explicitly rather than `secrets: inherit`.** `inherit` hands a caller's entire secret set to code in this repo, and `@v1` is a floating tag force-moved on every v1.x release. Inside `refokus-agency` that trust already exists; outside it, prefer:

  ```yaml
  permissions:
    contents: read
    pull-requests: write
    issues: write     # for the 👀 acknowledgement on the triggering comment
    id-token: write   # mandatory — see the bullet above

  jobs:
    code-review:
      uses: refokus-agency/platform/.github/workflows/code-review.yml@v1
      secrets:
        ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
  ```

## Creating the Vercel secrets

### `VERCEL_TOKEN`

A Vercel token with access to deploy the project.

1. Log in to Vercel.
2. Go to `https://vercel.com/account/tokens`.
3. Click **Create Token**.
4. Name it (e.g. `github-actions-refokus`).
5. Scope: if possible, scope to the Refokus team/org. Otherwise it's a personal token.
6. Copy and save as `VERCEL_TOKEN` in org secrets.

### `VERCEL_ORG_ID`

The ID of the Vercel team/org. Same value for every Refokus Vercel project.

1. Run `vercel whoami` or check the team settings URL (`vercel.com/teams/<team-slug>/settings` — the `teamId` is in the URL or in the page).
2. Alternatively, from any locally-linked project, run `cat .vercel/project.json` — the `orgId` field is what you want.
3. Save as `VERCEL_ORG_ID` in org secrets.

### `VERCEL_PROJECT_ID`

Unique per Vercel project. Configured **per repo**.

1. In the project root locally: `vercel link` (follow prompts to link to the right Vercel project).
2. `cat .vercel/project.json` — the `projectId` field.
3. Go to the repo's Actions secrets and add it as `VERCEL_PROJECT_ID`.

You can also find the project ID in the Vercel dashboard: Project → Settings → General → "Project ID".

## Release bypass with a GitHub App

`release.yml` runs `semantic-release`, which by default uses `@semantic-release/git` to push a commit (CHANGELOG, version bump) back to `main`. The built-in `GITHUB_TOKEN` cannot push to `main` if the branch is protected by a ruleset that requires PRs — pushes are rejected with `GH013: Repository rule violations found`.

The fix is to mint a short-lived token from a GitHub App that is on the ruleset's bypass list, and use that token for `semantic-release`. This is scoped to the release job only — Dependabot PR runs use `pull_request` workflows that don't touch this token, so this setup doesn't reintroduce the secret-exposure pattern that pushed the project off PATs.

### Setup

1. **Create a GitHub App** at the org level: `https://github.com/organizations/refokus-agency/settings/apps/new`.
   - Repository permissions: `contents: read and write`, `issues: read and write`, `pull-requests: read and write`, `metadata: read`.
   - Webhook: disabled.
   - Where can be installed: **Only this account** (`refokus-agency`).
2. **Generate a private key** (`.pem`) on the app's settings page and download it.
3. **Install the app** on the repos that need release bypass.
4. **Add the app to the bypass list** of the org-level ruleset on `main`: `https://github.com/organizations/refokus-agency/settings/rules` → ruleset → Bypass list → Add bypass → select the app → mode "Always". Requires org-owner permissions.
5. **Set the secrets** on the repo (or org level if you want to share the app across many repos):
   ```bash
   gh secret set RELEASE_APP_ID --repo <owner>/<repo> --body "<app-id>"
   gh secret set RELEASE_APP_PRIVATE_KEY --repo <owner>/<repo> < path/to/key.pem
   ```
   On Windows / PowerShell:
   ```powershell
   Get-Content path/to/key.pem -Raw | gh secret set RELEASE_APP_PRIVATE_KEY --repo <owner>/<repo>
   ```

If both secrets are present when `release.yml` runs, the job mints an installation token and uses it as `GITHUB_TOKEN` for `semantic-release`. If either is missing, the job falls back to the built-in `GITHUB_TOKEN` — fine for repos without branch protection or that don't use `@semantic-release/git`.

## Publishing to public npm via OIDC Trusted Publishing

When `release.yml` is called with `registry: npm`, it publishes to the public npm registry (registry.npmjs.org) using **OIDC Trusted Publishing** — there is **no `NPM_TOKEN` or any static npm secret**. The runner mints a short-lived GitHub OIDC token and npm exchanges it for a one-time publish credential. This is why the npm path adds no row to the secrets table above.

Two things are required for it to work:

1. **`permissions: id-token: write` in the caller.** This is what allows the OIDC token to be minted. The [`main-release-npm.yml`](../examples/main-release-npm.yml) example includes it. Without it the publish fails with an auth error.
2. **A Trusted Publisher configured on npmjs.org**, per package. On npmjs.com go to the package → **Settings → Trusted Publisher → GitHub Actions** and set:
   - **Organization or user:** `refokus-agency`
   - **Repository:** the caller repo name (e.g. `navigation`)
   - **Workflow filename:** `release.yml` — the reusable runs `npm publish` from this file, and npm matches the OIDC token's `job_workflow_ref` against it. This must match exactly.
   - **Environment:** leave blank unless your caller job targets a named environment.

You also need to make sure the package routes its **publish** to npm, not back to GitHub Packages:

- **`publishConfig.registry` must not point at GitHub Packages.** `publishConfig.registry` in `package.json` takes precedence over every other config (env vars, `.npmrc`, the workflow), so a leftover `"publishConfig": { "registry": "https://npm.pkg.github.com" }` from a GitHub Packages setup will silently send the OIDC publish to the wrong registry and fail. For the `npm` path, set it explicitly (or omit it — a scoped package defaults to npm when no scope registry is configured):
  ```json
  "publishConfig": { "registry": "https://registry.npmjs.org", "access": "public" }
  ```

Notes:

- The package name must already exist on npm, or the publishing identity must be allowed to create it. The Trusted Publisher config must exist **before** the first OIDC publish.
- `NODE_AUTH_TOKEN` is intentionally **not** set on this path. If it is present, npm skips the OIDC exchange and tries a static token instead.
- **Provenance** (`provenance: true`) requires a **public** repository. Leave it off (the default) while the caller repo is private, or the publish fails. Note that `provenance` only controls `NPM_CONFIG_PROVENANCE`; if your `.releaserc` (or `package.json` `release` config) sets `npmProvenance: true` inside the `@semantic-release/npm` plugin, that overrides the input — remove it and use the `provenance` input instead.
- **Private dependencies:** the `npm` path does **not** write GitHub Packages auth to `~/.npmrc`, so it can only install dependencies that are publicly resolvable. If your package depends on private `@refokus-agency/*` packages hosted on GitHub Packages, the install step will fail — open an issue on `platform` if you hit this; it needs a deliberate fix (install auth for one scope while publishing under it to a different registry is a non-trivial combination).
- `GITHUB_TOKEN` is still used on this path — not for npm auth, but for creating the GitHub Release, tagging, and the `@semantic-release/git` push. The optional `RELEASE_APP_*` bypass works the same as on the GitHub Packages path.

## Submodules

`ci.yml` and `deploy.yml` accept a `submodules` input (default `false`). When `true`, both reusables pass `submodules: true` to the caller-repo checkout step, so registered submodules get populated (otherwise the submodule path checks out empty and any build importing from it fails).

If every submodule lives in the **same repo family the default `GITHUB_TOKEN` already covers** (i.e. points back at the caller's own repo — not realistic for a true submodule, but included for completeness), no further setup is needed. In practice a submodule almost always points at a **different** repo, and the default `GITHUB_TOKEN` cannot read across repos — the checkout of the submodule fails with a 403/404 even though the caller repo itself checks out fine.

To fix that, pass `CHECKOUT_TOKEN` — a token with read access to the submodule's repo — via `secrets: inherit` (or explicitly):

```yaml
ci:
  uses: refokus-agency/platform/.github/workflows/ci.yml@v1
  with:
    submodules: true
  secrets: inherit   # forwards CHECKOUT_TOKEN if the org/repo has one configured
```

**Current recommended value:** a classic PAT with `repo` scope that has access to the submodule repo, stored as `CHECKOUT_TOKEN` (org-level if multiple repos share the same submodule, repo-level otherwise). This is the same shape as the legacy `GH_PAT_TOKEN` several pre-migration custom-code repos already use for this exact purpose — reuse that value instead of minting a new one if it already has the right access.

**This is a stop-gap, not the target state.** A long-lived PAT is exactly what `GITHUB_TOKEN` and the `RELEASE_APP_*` GitHub App pattern (above) were introduced to get away from. When there's time to do it properly, replace `CHECKOUT_TOKEN` with a GitHub App installation token minted the same way `release.yml` mints one for the branch-protection bypass: create/reuse an org GitHub App with `contents: read` on the submodule repo, install it there, and mint a short-lived token in a step before checkout. Track this as follow-up work rather than blocking the submodule support on it.

## Rotating secrets

When a Vercel token expires or is compromised:

1. Create a new one following the steps above.
2. Update the secret value in the org (or repo) settings.
3. No code change needed — reusables read the current value each run.

`GITHUB_TOKEN` rotates automatically with every workflow run; nothing to do.

## Verifying secrets are available

A quick sanity check workflow (don't commit — run it on a throwaway branch):

```yaml
name: Debug secrets

on: workflow_dispatch

jobs:
  debug:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "VERCEL_TOKEN set: ${{ secrets.VERCEL_TOKEN != '' }}"
          echo "VERCEL_ORG_ID set: ${{ secrets.VERCEL_ORG_ID != '' }}"
          echo "VERCEL_PROJECT_ID set: ${{ secrets.VERCEL_PROJECT_ID != '' }}"
```

Run it manually via the Actions tab. Never `echo` the secrets themselves — GitHub masks them, but the booleans are safe.
