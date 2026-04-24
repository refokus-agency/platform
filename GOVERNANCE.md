# Governance

This is a small project. Governance is intentionally lightweight and will scale up when (and if) the contributor base grows.

## Roles

- **Maintainer:** merge access and release authority. Current maintainers: [@taprile314](https://github.com/taprile314), [@beogip](https://github.com/beogip).
- **Contributor:** anyone with an accepted pull request.

## Decision Making

- **Minor changes** (bug fixes, docs, additive inputs): any maintainer can merge after CI passes.
- **Architectural changes** (new reusable, breaking change to an existing reusable, changes to the composite action contract): consensus among active maintainers. If there is no consensus, the BDFL has the final vote.
- **Tie-breaking:** [@taprile314](https://github.com/taprile314) (BDFL) has the final vote.

Both maintainers can merge minor changes. Architectural changes need both to agree; if they disagree, the BDFL decides.

Every caller in the `refokus-agency` org pins its CI/CD at this repo, so treat "minor" and "architectural" through the lens of blast radius rather than diff size. See [`docs/contributing.md`](docs/contributing.md) for how we reason about that.

## Becoming a Maintainer

- History of quality PRs over 3+ months.
- Nomination by an existing maintainer.
- No veto from other maintainers within 7 days of the nomination.

## Inactive Maintainers

- No activity for 6 months: moved to Emeritus. Can return on request.

## Changing This Document

Changes to `GOVERNANCE.md` are architectural by definition and require the same consensus as architectural code changes.
