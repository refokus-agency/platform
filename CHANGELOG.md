# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases on or after `v1.1.0` are managed by [release-please](https://github.com/googleapis/release-please-action) — the changelog below those entries is generated from conventional commits. The pre-`v1.1.0` history is preserved manually.

## [1.7.0](https://github.com/refokus-agency/platform/compare/v1.6.0...v1.7.0) (2026-07-16)


### Features

* support git submodules in ci.yml and deploy.yml ([b569ebe](https://github.com/refokus-agency/platform/commit/b569ebe1da414b71809202f30c4a48e2b78d8388))
* support git submodules in ci.yml and deploy.yml ([506ecf7](https://github.com/refokus-agency/platform/commit/506ecf764c0284c1c8e1b5a84a39fce5d2b9874d))

## [1.6.0](https://github.com/refokus-agency/platform/compare/v1.5.0...v1.6.0) (2026-07-02)


### Features

* **deploy:** comment preview URL on PR ([b4bf28d](https://github.com/refokus-agency/platform/commit/b4bf28dee83cfa859174599a691cd91c132f0e3e))
* **deploy:** comment preview URL on PR ([c366920](https://github.com/refokus-agency/platform/commit/c366920612e478ebd5b32e1518e0728aa3ed2b4e))

## [1.5.0](https://github.com/refokus-agency/platform/compare/v1.4.0...v1.5.0) (2026-06-30)


### Features

* add transferred input to deploy.yml reusable ([b5cbe85](https://github.com/refokus-agency/platform/commit/b5cbe8504cb5fc6351e06b50f792cea1834e5042))
* add transferred input to deploy.yml reusable ([#21](https://github.com/refokus-agency/platform/issues/21)) ([7c8ca8b](https://github.com/refokus-agency/platform/commit/7c8ca8bceede6e18b16b89276cfb24841228703d))

## [1.4.0](https://github.com/refokus-agency/platform/compare/v1.3.1...v1.4.0) (2026-06-24)


### Features

* add release workflow variant for public npm via OIDC Trusted Publishing ([a15f725](https://github.com/refokus-agency/platform/commit/a15f725840eedab92fba909e49c7eedcaa5d9ce9))
* add release workflow variant for public npm via OIDC Trusted Publishing ([#30](https://github.com/refokus-agency/platform/issues/30)) ([549042d](https://github.com/refokus-agency/platform/commit/549042d2058ac0987b1a445b76335026014c35bb))

## [1.3.1](https://github.com/refokus-agency/platform/compare/v1.3.0...v1.3.1) (2026-06-01)


### Reverts

* **ci:** drop GitHub App token for private package reads ([04d2a4d](https://github.com/refokus-agency/platform/commit/04d2a4dddad44b641c36a2b45589c279639cd00e))
* **ci:** drop GitHub App token for private package reads ([babdd38](https://github.com/refokus-agency/platform/commit/babdd381473329c2a042f60e9075b0c951788e6e))

## [1.3.0](https://github.com/refokus-agency/platform/compare/v1.2.1...v1.3.0) (2026-06-01)


### Features

* **ci:** mint Package Consumer App token to read private packages ([e8df169](https://github.com/refokus-agency/platform/commit/e8df169757760f42981b6133c52078ae20b6f94d))
* **ci:** mint Package Consumer App token to read private packages ([bfb0758](https://github.com/refokus-agency/platform/commit/bfb0758df2f7c45a6833fe111a131b347db5a1cc))

## [1.2.1](https://github.com/refokus-agency/platform/compare/v1.2.0...v1.2.1) (2026-04-29)


### Bug Fixes

* **release:** use job-level env to gate app-token step ([#18](https://github.com/refokus-agency/platform/issues/18)) ([ad158a2](https://github.com/refokus-agency/platform/commit/ad158a22b68c36036f5803d06e483ce4d3685c8e))

## [1.2.0](https://github.com/refokus-agency/platform/compare/v1.1.0...v1.2.0) (2026-04-29)


### Features

* add release-please automated versioning ([69b0c83](https://github.com/refokus-agency/platform/commit/69b0c83672209ed450ad3c1ad9caaa433ed217aa))
* add release-please automated versioning ([5af91ef](https://github.com/refokus-agency/platform/commit/5af91ef1a040d6497af7ad8d8059c4bb63ea4d25))
* default --ignore-scripts in install, add unsafe-install-scripts escape hatch ([51e025b](https://github.com/refokus-agency/platform/commit/51e025b9cfd60532cbb094c53e273513890fa90d))
* **examples:** add workflow_dispatch trigger to all callers ([274a51b](https://github.com/refokus-agency/platform/commit/274a51b40318615af246f1320d8b163c52c83692))
* **release:** support GitHub App token for branch-protection bypass ([6198c74](https://github.com/refokus-agency/platform/commit/6198c743e7349abe1c60b0f2740c47f21217473d))
* **release:** support GitHub App token for branch-protection bypass ([2d94bcb](https://github.com/refokus-agency/platform/commit/2d94bcb34a9b2cd2e2debba6881444df51612074))
* use GITHUB_TOKEN instead of GH_PAT_TOKEN now that platform is public ([1a0cd65](https://github.com/refokus-agency/platform/commit/1a0cd65a0e5bb4ca1b553151f0f842b5694963d5))


### Bug Fixes

* **deploy:** pass --scope to vercel alias set ([04c2004](https://github.com/refokus-agency/platform/commit/04c2004fef51c5e55a8ca4f6b14d9c08ff92033c))
* **examples:** dedupe push+pull_request runs and deploy previews only on PRs ([40736e6](https://github.com/refokus-agency/platform/commit/40736e668f9cddc6a5dc82c625d07ef4443557b9))
* **release:** use cycjimmy/semantic-release-action with extra-plugins input ([e6ba4d8](https://github.com/refokus-agency/platform/commit/e6ba4d80105ad84da3d22a1a8c9a684fa050e445))

## [1.1.0](https://github.com/refokus-agency/platform/compare/v1.0.0...v1.1.0) (2026-04-27)


### Features

* add release-please automated versioning ([69b0c83](https://github.com/refokus-agency/platform/commit/69b0c83672209ed450ad3c1ad9caaa433ed217aa))
* add release-please automated versioning ([5af91ef](https://github.com/refokus-agency/platform/commit/5af91ef1a040d6497af7ad8d8059c4bb63ea4d25))
* default --ignore-scripts in install, add unsafe-install-scripts escape hatch ([51e025b](https://github.com/refokus-agency/platform/commit/51e025b9cfd60532cbb094c53e273513890fa90d))
* **examples:** add workflow_dispatch trigger to all callers ([274a51b](https://github.com/refokus-agency/platform/commit/274a51b40318615af246f1320d8b163c52c83692))
* use GITHUB_TOKEN instead of GH_PAT_TOKEN now that platform is public ([1a0cd65](https://github.com/refokus-agency/platform/commit/1a0cd65a0e5bb4ca1b553151f0f842b5694963d5))


### Bug Fixes

* **deploy:** pass --scope to vercel alias set ([04c2004](https://github.com/refokus-agency/platform/commit/04c2004fef51c5e55a8ca4f6b14d9c08ff92033c))
* **examples:** dedupe push+pull_request runs and deploy previews only on PRs ([40736e6](https://github.com/refokus-agency/platform/commit/40736e668f9cddc6a5dc82c625d07ef4443557b9))
* **release:** use cycjimmy/semantic-release-action with extra-plugins input ([e6ba4d8](https://github.com/refokus-agency/platform/commit/e6ba4d80105ad84da3d22a1a8c9a684fa050e445))

## [1.0.0] — 2026-04-24

Initial tagged release. Stable surface for consumers; callers should reference `@v1`.

### Added
- Reusable workflows: `ci.yml` (lint + typecheck + test + build), `deploy.yml` (Vercel deploy parameterized by environment), `release.yml` (semantic-release to GitHub Packages).
- Composite action `setup` (auto-detects pm from lockfile, installs Node + pm, caches).
- Atomic caller examples in `examples/` (`pr-ci.yml`, `pr-preview.yml`, `main-stage.yml`, `main-production.yml`, `production-deploy.yml`, `main-release.yml`).
- Open-source foundation: `CONTRIBUTING.md`, issue templates, PR template, `LICENSE` (MIT), `SECURITY.md`, `CODE_OF_CONDUCT.md`, `GOVERNANCE.md`, `.github/dependabot.yml`.
- `GITHUB_TOKEN`-based auth across all reusables (replaces `GH_PAT_TOKEN`), so Dependabot PRs run CI without manual intervention.

[1.0.0]: https://github.com/refokus-agency/platform/releases/tag/v1.0.0
