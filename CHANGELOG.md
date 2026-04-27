# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases on or after `v1.1.0` are managed by [release-please](https://github.com/googleapis/release-please-action) — the changelog below those entries is generated from conventional commits. The pre-`v1.1.0` history is preserved manually.

## [1.0.0] — 2026-04-24

Initial tagged release. Stable surface for consumers; callers should reference `@v1`.

### Added
- Reusable workflows: `ci.yml` (lint + typecheck + test + build), `deploy.yml` (Vercel deploy parameterized by environment), `release.yml` (semantic-release to GitHub Packages).
- Composite action `setup` (auto-detects pm from lockfile, installs Node + pm, caches).
- Atomic caller examples in `examples/` (`pr-ci.yml`, `pr-preview.yml`, `main-stage.yml`, `main-production.yml`, `production-deploy.yml`, `main-release.yml`).
- Open-source foundation: `CONTRIBUTING.md`, issue templates, PR template, `LICENSE` (MIT), `SECURITY.md`, `CODE_OF_CONDUCT.md`, `GOVERNANCE.md`, `.github/dependabot.yml`.
- `GITHUB_TOKEN`-based auth across all reusables (replaces `GH_PAT_TOKEN`), so Dependabot PRs run CI without manual intervention.

[1.0.0]: https://github.com/refokus-agency/platform/releases/tag/v1.0.0
