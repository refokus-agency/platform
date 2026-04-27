# Contributing

How to change the reusables in this repo without breaking every downstream project.

## Who this is for

If you're one of the small group of maintainers on this repo (CI/CD improvements, fixes to the reusables, adding new project types), read this before opening a PR.

If you're a consumer of the reusables (you have a caller workflow in your repo), you don't need this — read [getting-started.md](getting-started.md) or [migration.md](migration.md) instead.

## The blast radius

Most repos in the org point their workflows at `refokus-agency/platform@v1` (the floating major tag). A breaking change merged into `main` becomes part of the next release, and once that release is cut, `@v1` moves to it — at which point every consumer picks it up.

Treat this repo accordingly:

- Never push directly to `main`. Always PR.
- Always test on a branch first (see "Testing changes" below).
- When in doubt, ask someone to review even trivial changes — a missing backtick in YAML can take everything down.
- A truly breaking change should not land on `main` casually — it requires a major bump (see [Breaking changes](#breaking-changes)).

## Development workflow

### 1. Branch off `main`

```bash
git checkout main
git pull
git checkout -b fix/whatever
```

### 2. Make your change

Common change types and their scope:

- **Bug in a reusable**: edit the `.yml` in `.github/workflows/` or `.github/actions/setup/`.
- **New input**: add to the `inputs:` section of the reusable. Make it optional with a sensible default unless you want to force every caller to update.
- **New project type**: usually means a new caller example in `examples/` + docs update. Rarely a new reusable.
- **Doc changes**: just edit the markdown.

Keep changes small. A PR that touches one reusable is easy to review; a PR that restructures everything is not.

### 3. Test on a branch (see next section)

### 4. Open a PR

PR description should cover:

- What changed and why.
- Which project types / repos are affected.
- Whether it's a breaking change (changes the contract callers depend on).
- How you tested it.

### 5. Merge

After review, squash-merge into `main`. Callers pinned at `@main` pick it up on their next run.

## Testing changes

You can't test a reusable workflow by "running" it — it only runs when called. Options:

### Option A: Test against your branch in a real repo

1. In your branch, push to `refokus-agency/platform`.
2. In a test repo (pick a low-stakes one — `navigation` or a throwaway), temporarily change the caller's `uses:` line to point at your branch:

   ```yaml
   uses: refokus-agency/platform/.github/workflows/ci.yml@your-branch-name
   ```

3. Push a commit to trigger the caller.
4. Watch the run. Iterate.
5. Once happy, revert the test repo to `@main`, merge your PR into `platform`.

This is the most realistic test — it exercises the actual caller → reusable path.

### Option B: act (local runner)

[`act`](https://github.com/nektos/act) runs workflows locally in Docker. It has limitations (reusable workflows with secrets don't work perfectly, composite actions sometimes misbehave) but it catches syntax errors and obvious logic bugs fast.

```bash
# From the platform repo root
act -j ci -W .github/workflows/ci.yml
```

Use it for quick feedback; don't rely on it as the only test.

### Option C: dry-run with `workflow_dispatch`

Add a temporary `workflow_dispatch:` trigger to the reusable's `on:` block (alongside `workflow_call`), push to a branch, and trigger it manually from the Actions tab. This runs the reusable standalone without a caller.

Useful for testing in isolation, but **remove the `workflow_dispatch` trigger before merging** — reusables shouldn't be manually triggerable in main.

## Versioning

Callers reference the floating major tag `@v1`. `@v1` always points at the latest non-breaking release on the v1.x line.

- **Patch / minor changes** (non-breaking): each release moves `@v1` to the new commit. Callers on `@v1` pick it up on their next run.
- **Breaking changes**: a new major (`v2`) is cut. Callers stay on `@v1` until they explicitly migrate by editing their `uses:` line.

`@main` is still available — useful for testing pre-release changes from a low-stakes consumer, or for repos that want bleeding edge. The vast majority should use `@v1`.

### How releases work

Releases are automated by [release-please](https://github.com/googleapis/release-please-action) on every push to `main`:

1. Commits on `main` use [conventional commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, etc., with `feat!:` or a `BREAKING CHANGE:` footer for breaking changes).
2. Release-please opens (or updates) a pending **release PR** that aggregates all unreleased commits, calculates the next semver bump from the conventional commit types, and updates `CHANGELOG.md`.
3. When you merge the release PR, release-please:
   - Tags the merge commit (`v1.2.3`).
   - Creates a GitHub Release.
   - The `release-please.yml` workflow's follow-up job force-moves `v1` to the same commit, so consumers on `@v1` pick up the change.

Two visible artifacts: the **release PR** (your gate to cut the version when you want) and the **GitHub Release** (after merge, with changelog).

## Breaking changes

A change is **breaking** if it:

- Removes or renames an input.
- Changes the default of an input in a way that changes behavior.
- Adds a `required: true` input or secret.
- Changes the semantics of an existing input (e.g. `environment: stage` now means something different).

For breaking changes:

1. Use a `feat!:` prefix or include a `BREAKING CHANGE:` footer in the commit. Release-please picks this up and cuts a major bump (`v1.x.y` → `v2.0.0`) on the next release PR.
2. Document the migration path in `docs/migrations/v1-to-v2.md` (or similar).
3. Announce in the team channel before merging the release PR — once `v2` exists, `@v1` stops moving and consumers stay on the old line until they migrate explicitly.
4. Update `examples/` in this repo to point at `@v2` so new repos start on the current major.

Note: callers on `@v1` are *not* broken when `v2` is cut — they keep getting v1.x updates. They only break if they actively change to `@v2` and don't migrate their config.

## Adding a new input

Prefer additive changes:

```yaml
inputs:
  existing-input:
    type: string
    default: 'old-default'
  new-input:            # <-- added
    type: string
    default: 'safe-default'
    required: false     # <-- optional, so existing callers don't break
```

When in doubt, default to the current behavior. Callers that want the new behavior opt in explicitly.

## Adding a new secret

Secrets are a touchier change because repos may not have the secret configured at all.

- If the reusable marks the secret as `required: true`, every caller must have it. Repos that don't will fail.
- Prefer making new secrets optional (`required: false`) and having the reusable behave gracefully when they're missing.

## Deprecating something

1. Add a warning in the reusable when the deprecated path is used:

   ```yaml
   - if: inputs.old-input != ''
     run: echo "::warning::old-input is deprecated; use new-input instead"
   ```

2. Update the docs to mark it deprecated.
3. Leave it in place for at least one "cycle" (practically: a few months) so callers have time to migrate.
4. Remove in the next major version.

## Code review expectations

PRs to this repo should get:

- **At least one review** from another maintainer.
- **Explicit confirmation** that the change was tested (Option A above, ideally).
- **A clear commit message** once squashed. The squash message becomes the commit on `main`; keep it useful for `git log` / `git blame` spelunking later.

## Releasing

Releases are fully automated. To cut one:

1. Land your conventional-commit PRs on `main` as usual.
2. Release-please will (re)open a PR titled something like `chore(main): release 1.2.3`. Review the proposed CHANGELOG and version.
3. Merge the release PR. The `release-please.yml` workflow tags `v1.2.3`, creates the GitHub Release, and force-moves `v1` to the same commit.
4. Verify on the Tags page that `v1` now points at the new commit. Consumers on `@v1` pick it up automatically on their next run.

You don't tag manually. If something looks off in the release PR (wrong version, missing entries), check that the underlying commit messages used the right conventional-commit types.

## File structure conventions

- **Reusables** live in `.github/workflows/`. One file per reusable, named after what it does (`ci.yml`, `deploy.yml`, `release.yml`).
- **Composite actions** live in `.github/actions/<name>/action.yml`. Each action is a directory; GitHub requires `action.yml` (or `action.yaml`) at that path.
- **Examples** live in `examples/`. One per (trigger, action) pair, flat — no per-project-type grouping. See [architecture.md](architecture.md#why-atomic-caller-files-instead-of-templates-per-project-type) for the rationale.
- **Docs** live in `docs/`. Markdown files, cross-linked.
- **Never** put YAML with secrets, tokens, or project-specific paths in this repo. It's meant to be generic.

## When to say no

It's tempting to centralize every shared-ish bit of CI into this repo. Resist it. The repo stays useful only if:

- Every reusable is used by multiple repos.
- Every reusable is generic (no special-casing per repo).
- The scope is "CI + Vercel deploy + GitHub Packages release". Not "every GitHub Action we've ever wanted".

If someone wants to add a reusable that's only used in one place, push back: it belongs in that repo's own `.github/workflows/`, not here.
