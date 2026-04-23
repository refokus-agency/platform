# platform

Centralized CI/CD for Refokus projects. A single source of truth for reusable GitHub Actions workflows used across all `refokus-agency` repos.

## What this is for

Every Refokus project falls into one of three categories:

| Type | What it does | Example repos |
|---|---|---|
| **custom-code** | Webflow sites with custom JS/CSS, deployed to Vercel | `webflow-custom-code-tmp`, client sites |
| **service** | Backend services / integrations, deployed to Vercel | `webflow-integration-app` |
| **library** | Internal npm packages, published to GitHub Packages (`@refokus-agency`) | `navigation` |

Instead of duplicating CI/CD logic across ~10+ repos, this repo provides three reusable workflows and one composite action that each project consumes with a short caller workflow.

## Quick start

Copy the caller templates that match your project type into `.github/workflows/` of your repo. Each type uses one file per trigger (PR, push to main, etc.) so no workflow run produces skipped jobs in the PR UI.

- **custom-code** → [`examples/custom-code/`](examples/custom-code/) — `pr.yml` (PR + preview), `stage.yml` (push to `main`), `production.yml` (push to `production`)
- **service** → [`examples/service/`](examples/service/) — `pr.yml` (PR + preview), `deploy.yml` (push to `main` → production)
- **library** → [`examples/library/`](examples/library/) — `pr.yml` (PR), `release.yml` (push to `main` → semantic-release)

Make sure the required secrets are available at org or repo level (see [docs/secrets.md](docs/secrets.md)), then push a branch and watch it run.

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
├── examples/
│   ├── custom-code/            # pr.yml + stage.yml + production.yml
│   ├── service/                # pr.yml + deploy.yml
│   └── library/                # pr.yml + release.yml
└── docs/                       # Detailed documentation
```

## Documentation

- [Getting started](docs/getting-started.md) — set up a new repo step by step
- [Migration guide](docs/migration.md) — move an existing repo off its bespoke workflows
- [Secrets](docs/secrets.md) — which secrets are needed and where to configure them
- [Architecture](docs/architecture.md) — design decisions and how the pieces fit together
- [Troubleshooting](docs/troubleshooting.md) — common issues and fixes
- [Contributing](docs/contributing.md) — how to change the reusables safely

## Versioning

Callers currently reference `@main`:

```yaml
uses: refokus-agency/platform/.github/workflows/ci.yml@main
```

This lets us iterate quickly while the first repos migrate. Once the workflows stabilize (target: 2–3 months without breaking changes), we'll cut `@v1` tags and migrate callers to pinned versions. See [docs/contributing.md](docs/contributing.md) for details.

## Support

Ping `@taprile314` or open an issue on this repo.
