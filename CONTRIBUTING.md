# Contributing

Thanks for your interest in contributing to `refokus-agency/platform`.

Because every repo in the org pins its CI/CD at this one, the main contributor guide lives in [`docs/contributing.md`](docs/contributing.md) and covers the blast radius, testing strategy, and release process in detail. **Read that before opening a non-trivial PR.**

This file is the quick reference.

## How to contribute

1. Fork the repo (or branch if you have write access).
2. Branch off `main`: `git checkout -b fix/short-description`.
3. Make the change. Keep PRs small — one reusable at a time.
4. Test it on a branch against a real caller repo before opening the PR (see [`docs/contributing.md`](docs/contributing.md#testing-changes)).
5. Open a PR against `main`. Fill in the PR template.

We follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `chore:`, `docs:`, `ci:`, ...). The commit message drives the changelog.

## Submitting issues

Use the issue templates — they ask for the ref your caller is pinned to and a link to the failing Actions run, which are what we need to triage.

For questions that aren't bugs or feature requests, use [Discussions](https://github.com/refokus-agency/platform/discussions).

## Submitting PRs

- CI must pass.
- If you change a reusable's inputs, update the matching example in `examples/` and the affected docs in `docs/`.
- Breaking changes need an explicit call-out in the PR description. See [`docs/contributing.md`](docs/contributing.md#breaking-changes) for what counts as breaking.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By participating you agree to abide by it.

## Response time

This is maintained alongside other work. Expect a response within ~1 week. Security reports are prioritized — see [`SECURITY.md`](SECURITY.md).
