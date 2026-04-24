# Contributing

How to change the reusables in this repo without breaking every downstream project.

## Who this is for

If you're one of the small group of maintainers on this repo (CI/CD improvements, fixes to the reusables, adding new project types), read this before opening a PR.

If you're a consumer of the reusables (you have a caller workflow in your repo), you don't need this — read [getting-started.md](getting-started.md) or [migration.md](migration.md) instead.

## The blast radius

Every repo in the org points its workflows at `refokus-agency/platform@main`. A broken `main` here breaks CI/CD across **all** Refokus projects simultaneously.

Treat this repo accordingly:

- Never push directly to `main`. Always PR.
- Always test on a branch first (see "Testing changes" below).
- When in doubt, ask someone to review even trivial changes — a missing backtick in YAML can take everything down.

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

### Current state: `@main`

All callers reference `@main`. Changes ship immediately.

**Advantages:** fast iteration, no per-repo PR to pick up fixes.

**Disadvantages:** a bad commit to `main` breaks everyone at once. No way for a repo to pin to a known-good version.

This is the right tradeoff *while everyone's migrating*. It's not the right tradeoff long-term.

### Transitioning to tags

Once the reusables have been stable for 2–3 months with no breaking changes, we move to tagged versions:

1. Cut a `v1.0.0` tag on `main` (`git tag v1.0.0 && git push --tags`).
2. Also create a moving `v1` tag that always points at the latest compatible release (`git tag -f v1 && git push --tags --force`).
3. Update the examples in `platform` to use `@v1` instead of `@main`.
4. PR each consumer repo to point at `@v1`.

After the transition:

- **Patch / minor changes** (non-breaking): update `v1` to point at the new commit. Callers on `@v1` pick it up automatically.
- **Breaking changes**: cut `v2.0.0`, create `v2` tag. Callers stay on `@v1` until they explicitly migrate.

`@main` stays useful for testing new changes — a repo that wants bleeding edge can pin to `@main`, everyone else stays on `@v1`.

## Breaking changes

A change is **breaking** if it:

- Removes or renames an input.
- Changes the default of an input in a way that changes behavior.
- Adds a `required: true` input or secret.
- Changes the semantics of an existing input (e.g. `environment: stage` now means something different).

For breaking changes:

1. Don't merge it to `main` if callers are on `@main` — it'll break everyone.
2. Instead, wait until we've transitioned to tags, then cut a new major version.
3. Document the migration path in this repo (add a `docs/migrations/v1-to-v2.md` or similar).

While we're on `@main`, avoid breaking changes. If one is unavoidable:

- Announce it in the team channel with a date.
- Add a deprecation notice in the reusable logs (`echo "::warning::..."`).
- Coordinate the rollout across repos.

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

## Releasing (once we're on tags)

From `main` after PR merge:

```bash
git checkout main && git pull
# For a new minor or patch:
git tag v1.2.3
git tag -f v1           # move the moving tag
git push --tags --force
```

GitHub Actions doesn't have a built-in release workflow for this repo (it's not a package; no semver enforcement tooling applies). Just keep it simple and disciplined.

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
