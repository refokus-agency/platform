# platform

Reusable GitHub Actions workflows for Node projects: CI, Vercel deploys, semantic-release, and on-demand AI code review. Built and maintained at Refokus, where it runs the CI/CD for every repo in the org.

## What this is for

Instead of duplicating CI/CD logic across repos, this repo provides five reusable workflows (CI, deploy, static deploy, release, code review) plus a composite action (setup) that each project consumes with small caller workflow files.

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
| [`pr-preview-static.yml`](examples/pr-preview-static.yml) | PR | Vercel preview deploy of an allowlisted set of static folders (no Node project needed) |
| [`main-production-static.yml`](examples/main-production-static.yml) | push to `main` | Vercel production deploy of an allowlisted set of static folders (no Node project needed) |
| [`main-release.yml`](examples/main-release.yml) | push to `main` | CI + semantic-release to GitHub Packages |
| [`main-release-npm.yml`](examples/main-release-npm.yml) | push to `main` | CI + semantic-release to public npm via OIDC Trusted Publishing |
| [`comment-code-review.yml`](examples/comment-code-review.yml) | `@claude review` comment on a PR | AI code review — inline comments + summary on the PR |

### Common shapes

| Your repo is… | Copy these |
|---|---|
| An npm library (release to GH Packages) | `pr-ci.yml` + `main-release.yml` |
| An npm library (release to public npm) | `pr-ci.yml` + `main-release-npm.yml` — needs `id-token: write` and a Trusted Publisher on npmjs.org; see [docs/secrets.md](docs/secrets.md) |
| A Vercel-deployed app, 2 envs (preview on PR, prod on main) | `pr-preview.yml` + `main-production.yml` |
| A Vercel-deployed app, 3 envs (preview on PR, stage on main, prod on a `production` branch) | `pr-preview.yml` + `main-stage.yml` + `production-deploy.yml` |
| A repo that is not a Node project and publishes only some folders (e.g. a Brand Brain's `wireframes/` and `artifacts/`) | `pr-preview-static.yml` + `main-production-static.yml` — only the folders listed in `folders` are uploaded. Deploy production once before the first preview: previews are refused until the Vercel project has a production deployment. See [docs/architecture.md](docs/architecture.md#reusable-workflow-deploy-staticyml) |

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
│       ├── deploy-static.yml   # Reusable: Vercel deploy of allowlisted static folders (preview | production)
│       ├── release.yml         # Reusable: semantic-release (GitHub Packages or public npm via OIDC)
│       └── code-review.yml     # Reusable: AI code review, on request, via claude-code-action
├── examples/                   # Atomic caller workflows, one per (trigger, action) pair
│   ├── pr-ci.yml               # PR → CI
│   ├── pr-preview.yml          # PR → CI + Vercel preview
│   ├── main-stage.yml          # push main → CI + Vercel stage
│   ├── main-production.yml     # push main → CI + Vercel production
│   ├── production-deploy.yml   # push production → CI + Vercel production
│   ├── pr-preview-static.yml   # PR → Vercel preview of allowlisted static folders
│   ├── main-production-static.yml # push main → Vercel production of allowlisted static folders
│   ├── main-release.yml        # push main → CI + semantic-release (GitHub Packages)
│   ├── main-release-npm.yml    # push main → CI + semantic-release (public npm via OIDC)
│   └── comment-code-review.yml # `@claude review` comment on a PR → AI code review
└── docs/                       # Detailed documentation
```

## Documentation

- [Getting started](docs/getting-started.md) — set up a new repo step by step
- [Migration guide](docs/migration.md) — move an existing repo off its bespoke workflows
- [Secrets](docs/secrets.md) — which secrets are needed and where to configure them
- [Dependabot](docs/dependabot.md) — how Dependabot PRs run (normally, via `GITHUB_TOKEN`) and the preview-deploy actor guard
- [Architecture](docs/architecture.md) — design decisions and how the pieces fit together
- [Troubleshooting](docs/troubleshooting.md) — common issues and fixes
- [Contributing](docs/contributing.md) — how to change the reusables safely

## Versioning

Callers reference the floating major tag `@v2`:

```yaml
uses: refokus-agency/platform/.github/workflows/ci.yml@v2 # x-release-please-major
```

`@v2` always points at the latest non-breaking release on the v2.x line, so callers pick up patches and minors automatically without per-repo PRs. Breaking changes cut a new major, and callers stay on their current major until they explicitly migrate.

Callers still on `@v1` keep working, but `@v1` no longer moves: it stays at `v1.12.1`. To move a repo to v2, see [Upgrading from v1 to v2](docs/migration.md#upgrading-from-v1-to-v2).

Releases are automated with [release-please](https://github.com/googleapis/release-please-action) — conventional commits on `main` open a release PR, merging it cuts the tag and moves `@v2`. For day-to-day maintenance and the breaking-change protocol, see [docs/contributing.md](docs/contributing.md).

`@main` stays available for testing pre-release changes; `@<sha>` works for paranoid pinning. Most repos should just use `@v2`.

## Support

Open an issue on this repo — that works whether or not you're at Refokus. Refokus folks can also ping `@taprile314` or `@beogip` directly.
