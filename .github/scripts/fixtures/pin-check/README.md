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

`bad-unparseable.yml` is not malformed by accident. It is the regression test for a
fail-open the gate actually had: `yq` rejected the file, the reader got zero lines, the
file scored zero findings, and the run went green over an unpinned `uses:` nobody had
read. Editors that strip tabs on save will "fix" this file and quietly disable the test
— the tab on the last line is the fixture.
