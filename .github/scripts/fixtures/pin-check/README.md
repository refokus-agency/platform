# pin-check fixtures

Inputs for `check-action-pins.sh --self-test`. Each file is named for what the script
must do with it: `good-*` must produce zero findings, `bad-*` must produce exactly one.

These deliberately live under `.github/scripts/` rather than `.github/workflows/`. Two
reasons, both load-bearing:

- GitHub runs every `.yml` under `.github/workflows/`. A fixture holding an unpinned
  `uses:` placed there would be a real workflow, not a test input.
- The gate scans `.github/workflows/` and `.github/actions/`. A fixture placed in
  either would be scanned as production input and the gate would fail on its own
  test data.

`bad-lying-comment.yml` pins a real commit with a version comment that names a
different release, so verifying it requires the GitHub API. Every other case is
decidable offline.
