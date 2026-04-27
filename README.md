# platform

Centralized CI/CD for Refokus projects. A single source of truth for reusable GitHub Actions workflows used across all `refokus-agency` repos.

## What this is for

Instead of duplicating CI/CD logic across repos, this repo provides three reusable workflows (CI, deploy, release) plus a composite action (setup) that each project consumes with small caller workflow files.

## Quick start

Pick the workflow files that match **the triggers your repo cares about** and copy them from [`examples/`](examples/) into `.github/workflows/` in your repo. Each file is one trigger → one action, so nothing gets skipped in the UI.

### Available atomic workflows

| File | Trigger | What it runs |
|---|---|---|
| [`pr-ci.yml`](examples/pr-ci.yml) | PR | CI only (lint + typecheck + test + build) |
| [`pr-preview.yml`](examples/pr-preview.yml) | PR | CI + Vercel preview deploy |
| [`main-stage.yml`](examples/main-stage.yml) | push to `main` | CI + Vercel stage deploy |
| [`main-production.yml`](examples/main-production.yml) | push to `main` | CI + Vercel production deploy |
| [`production-deploy.yml`](examples/production-deploy.yml) | push to `production` | CI + Vercel production deploy |
| [`main-release.yml`](examples/main-release.yml) | push to `main` | CI + semantic-release to GitHub Packages |

### Common shapes

| Your repo is… | Copy these |
|---|---|
| An npm library (release to GH Packages) | `pr-ci.yml` + `main-release.yml` |
| A Vercel-deployed app, 2 envs (preview on PR, prod on main) | `pr-preview.yml` + `main-production.yml` |
| A Vercel-deployed app, 3 envs (preview on PR, stage on main, prod on a `production` branch) | `pr-preview.yml` + `main-stage.yml` + `production-deploy.yml` |

The shape is **per repo**, not per project type. A service can be 2-env or 3-env. A Webflow custom-code site can be 2-env if you don't need a stage gate. Pick the combo that matches your flow.

Make sure the required secrets are available at org or repo level (see [docs/secrets.md](docs/secrets.md)), then push and watch it run.

## What's inside

```
.
├── .github/
│   ├── actions/
│   │   └── setup/              # Composite action: detect pm, install deps, cache
│   └── workflows/
│       ├── ci.yml              # Reusable: lint + typecheck + test + build
│       ├── deploy.yml          # Reusable: Vercel deploy (preview | stage | production)
│       └── release.yml         # Reusable: semantic-release to GitHub Packages
├── examples/                   # Atomic caller workflows, one per (trigger, action) pair
│   ├── pr-ci.yml               # PR → CI
│   ├── pr-preview.yml          # PR → CI + Vercel preview
│   ├── main-stage.yml          # push main → CI + Vercel stage
│   ├── main-production.yml     # push main → CI + Vercel production
│   ├── production-deploy.yml   # push production → CI + Vercel production
│   └── main-release.yml        # push main → CI + semantic-release
└── docs/                       # Detailed documentation
```

## Documentation

- [Getting started](docs/getting-started.md) — set up a new repo step by step
- [Migration guide](docs/migration.md) — move an existing repo off its bespoke workflows
- [Secrets](docs/secrets.md) — which secrets are needed and where to configure them
- [Dependabot](docs/dependabot.md) — why Dependabot PRs need manual rerun and how to handle them
- [Architecture](docs/architecture.md) — design decisions and how the pieces fit together
- [Troubleshooting](docs/troubleshooting.md) — common issues and fixes
- [Contributing](docs/contributing.md) — how to change the reusables safely

## Versioning

Callers reference the floating major tag `@v1`:

```yaml
uses: refokus-agency/platform/.github/workflows/ci.yml@v1 # x-release-please-major
```

`@v1` always points at the latest non-breaking release on the v1.x line, so callers pick up patches and minors automatically without per-repo PRs. Breaking changes cut a new major (`v2`), and callers stay on `@v1` until they explicitly migrate.

Releases are automated with [release-please](https://github.com/googleapis/release-please-action) — conventional commits on `main` open a release PR, merging it cuts the tag and moves `@v1`. For day-to-day maintenance and the breaking-change protocol, see [docs/contributing.md](docs/contributing.md).

`@main` stays available for testing pre-release changes; `@<sha>` works for paranoid pinning. Most repos should just use `@v1`.

## Support

Ping `@taprile314` or `@beogip`, or open an issue on this repo.
