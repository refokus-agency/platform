---
issue_number: 83
issue_title: "feat(workflows): pin third-party actions by commit SHA in secrets-bearing jobs"
repo: "refokus-agency/platform"
labels: [enhancement, github_actions]
plan_level: "standard"
depth: "medium"
branch_name: "beogip/feat-workflows-pin-third-party-actions-by-commit"
created_at: "2026-09-14T21:39:36Z"
---

# Implementation Plan: #83 — feat(workflows): pin third-party actions by commit SHA in secrets-bearing jobs

Replace every third-party `uses:` reference in this repo — 22 call sites across 9
distinct actions — with a full-length commit SHA plus a trailing `# vX.Y.Z`
version comment, and add the machinery that keeps them correct and current.

Discovery session: `.cothinker/session-2026-09-14-83-pin-third-party-actions-by-commit-sha.md`
(6 branches, decisions D-1 through D-6).

## Revision — the gate is our own script, not an action

**Changed during implementation, after review.** The plan below originally had the PR
gate run [`suzuki-shunsuke/pinact-action`](https://github.com/suzuki-shunsuke/pinact-action).
That version was built, and it worked: its `fix` / `skip_push` / `verify` inputs were
verified against the action's own bundle to map onto `--fix=false` / `--verify-comment`,
and all pins passed.

It was replaced anyway. The wrapper has 77 stars and 6 forks against 1198 for the pinact
CLI it wraps, and — the substantive objection — enforcing a policy about not trusting
third-party actions by running a third-party action is the wrong shape. A SHA pin stops
an upstream tag from moving; it does not stop the code at that SHA from executing in the
job with the workspace in front of it.

So the gate is now `.github/scripts/check-action-pins.sh`, depending only on `yq` and
`gh`, both preinstalled on `ubuntu-latest`. **pinact itself did not go away** — it
remains the local generator (`pinact run`), and `.pinact.yaml` stays with it. Because
the script resolves every tag itself, a compromised pinact writing a bad SHA under a
plausible comment is now *caught* by the gate rather than trusted by it.

This revision rewrites the rows, steps, criteria and risks below that named the action.
Decisions D-1 through D-6 from the discovery session are unaffected; D-5 (accepting
pinact as a dependency) is narrowed to accepting it as a **local** dependency only.

## Files

| # | Action | Path | Purpose |
|---|---|---|---|
| 1 | modify | `.github/actions/setup/action.yml` | SHA-pin 4 refs: `pnpm/action-setup@v4` (L71), `oven-sh/setup-bun@v2` (L77), `actions/setup-node@v4` (L83, L90) |
| 2 | modify | `.github/workflows/ci.yml` | SHA-pin `actions/checkout@v7` (L70, L76) |
| 3 | modify | `.github/workflows/deploy.yml` | SHA-pin `actions/checkout@v7` (L96, L103), `actions/github-script@v9` (L178, L215) |
| 4 | modify | `.github/workflows/release.yml` | SHA-pin `actions/create-github-app-token@v3` (L125), `actions/checkout@v7` (L131, L137), `cycjimmy/semantic-release-action@v6` (L176, L191) |
| 5 | modify | `.github/workflows/code-review.yml` | SHA-pin `actions/checkout@v7` (L419, L470) and `anthropics/claude-code-action@v1` (L440); reword the "Pinned literally" comment at L438-439 |
| 6 | modify | `.github/workflows/release-please.yml` | SHA-pin `googleapis/release-please-action@v5` (L19) and `actions/checkout@v7` (L25) — uses the `- uses:` dash form |
| 7 | modify | `.github/dependabot.yml` | Add a second `github-actions` entry for `/.github/actions/setup` |
| 8 | create | `.github/workflows/pin-check.yml` | Net-new `pull_request` gate: two jobs, three steps, no third-party action beyond `actions/checkout` |
| 9 | create | `.pinact.yaml` | Scope pinact to `.github/**`; keep first-party and local refs out. **Local tool only** — CI never runs pinact |
| 10 | create | `.github/scripts/check-action-pins.sh` | The gate itself. Verifies ref shape, comment presence, and that the comment resolves to the pinned commit. Fails closed |
| 11 | create | `.github/scripts/fixtures/pin-check/` | 8 fixtures for `--self-test`: 6 the gate must reject, 2 it must accept |
| 12 | create | `.github/scripts/check-dependabot-coverage.sh` | Fails the PR when a composite action has no Dependabot entry — a pin nothing bumps still passes the pin check |
| 13 | modify | `docs/contributing.md` | New `## Pinning third-party actions` section — the operational rule |
| 14 | modify | `docs/architecture.md` | New `### Why are third-party actions pinned by SHA?` under `## Key design decisions`, including why the gate takes no third-party action |
| 15 | modify | `CLAUDE.md` | New bullet under `## Invariants to preserve` |
| 16 | modify | `docs/dependabot.md` | Document the second entry and the manual-entry duty for a future composite |

## Codebase Context

**Modules and patterns to respect:**

- `CLAUDE.md` → `## Invariants to preserve` is this repo's established home for
  load-bearing rules (`--ignore-scripts` default, the `.platform/` re-checkout,
  `secrets: inherit` + `required: false`). The pinning rule joins them, phrased in
  the same "don't undo this without reading the rationale" shape.
- `docs/contributing.md` already has the "when you touch X, do Y" section shape:
  `## Adding a new input`, `## Adding a new secret`, `## Breaking changes`,
  `## Deprecating something`. The new section follows it.
- `docs/architecture.md` → `## Key design decisions` uses a `### Why ...?` heading
  pattern (e.g. `### Why does the composite action pass --ignore-scripts by default?`).
- `.github/scripts/` holds `review-guard.sh` and `record-github-deployment.cjs` —
  script precedent exists, but **no `pull_request` trigger exists anywhere in this
  repo**. Every workflow is `workflow_call`, except `comment-code-review.yml`
  (`issue_comment`) and `release-please.yml` (`push` to main). The gate is net-new
  CI surface.
- `code-review.yml:417-433` — the checkout at L419 carries a load-bearing
  `persist-credentials: false` with an explanatory comment. Change only the `uses:`
  line; leave the `with:` block and comment intact.
- `examples/*.yml` contain **zero** third-party actions — only first-party
  `refokus-agency/platform/...@v1` references. Verified, not assumed.

**Reference implementations:**

- No SHA-pinned `uses:` exists in this repo today (`rg "uses:.*@[0-9a-f]{7,40}"` →
  0 matches). This change establishes the convention, so the comment format from
  the issue is normative: `uses: actions/checkout@<40-hex> # v4.2.2`.

## Steps

1. **Install pinact and generate the pins.** Run `pinact run` at the repo root.
   **Done when:** `rg -c "uses:.*@[0-9a-f]{40}"` totals 22 across the seven
   workflow/action files, and `git diff --stat -- examples/` is empty.

2. **Write `.pinact.yaml`** restricting the file set to `.github/workflows/**` and
   `.github/actions/**`.
   **Done when:** `pinact run --check` exits 0 and `git status --porcelain examples/`
   is empty. Note `files:` is an **include-list that replaces** pinact's default
   discovery, not a filter layered on top — confirmed in `pkg/controller/run/search_file.go`.

3. **Reword `code-review.yml:438-439`.** The current comment says "Bump it here when
   upstream cuts a new major", which becomes false once Dependabot owns the bump.
   **Done when:** the comment names Dependabot as the bump mechanism and still
   explains why the ref cannot be a workflow input.

4. **Add the second Dependabot entry.**
   **Done when:** `.github/dependabot.yml` contains two `github-actions` entries
   with `directory: "/"` and `directory: "/.github/actions/setup"`, and
   `python3 -c "import yaml,sys; yaml.safe_load(open('.github/dependabot.yml'))"`
   exits 0.

5. **Write `.github/scripts/check-action-pins.sh`** — extract every `uses:` with `yq`
   (three shapes: workflow steps, job-level reusable calls, composite-action steps),
   skip `./` and `docker://`, then validate shape, comment presence, and that the
   comment resolves to the pinned commit via `gh api repos/O/R/commits/<version>`.
   Memoize by `owner/repo@version`; fail closed when the API cannot answer.
   **Done when:** it exits 0 on the repo, exits 1 with a correct line number on a
   planted bad ref, and runs under macOS stock bash 3.2 as well as the runner's bash 5.

6. **Write the fixtures and `--self-test`.** `.github/scripts/fixtures/pin-check/`,
   deliberately outside both `.github/workflows/` (GitHub would execute them) and the
   gate's own scan globs (it would fail on its own test data).
   **Done when:** every `bad-*` fixture yields exactly 1 finding, every `good-*` yields
   0, and the two fixtures that need the network skip cleanly under `--no-api`.

7. **Create `.github/workflows/pin-check.yml`** triggered `on: pull_request`, running
   `--self-test` first and the real check second, with `GH_TOKEN` in env.
   **Done when:** every `uses:` in the new file is a 40-hex SHA, the workflow declares
   `permissions:` with `contents: read` and no write scope, and it references no
   third-party action other than `actions/checkout`.

8. **`docs/contributing.md`** — add `## Pinning third-party actions`.
   **Done when:** the section states the rule, names `pinact`, and gives the
   copy-paste command a contributor runs to fix a red gate.

9. **`CLAUDE.md`** — add the invariant bullet.
   **Done when:** a bullet under `## Invariants to preserve` states the rule and
   points at the `docs/architecture.md` rationale.

10. **`docs/architecture.md`** — add `### Why are third-party actions pinned by SHA?`.
   **Done when:** the entry sits under `## Key design decisions` and cites
   CVE-2025-30066 and the `@v1` blast radius.

11. **`docs/dependabot.md`** — document the second entry.
   **Done when:** it states explicitly that Dependabot's `github-actions` ecosystem
   does not reach `.github/actions/**` without an explicit entry, and that a future
   composite action needs its entry added by hand.

## Interfaces

N/A — this change is YAML configuration and documentation. No data structures are
exchanged between functions or returned from external tools.

## Function Design

Superseded by the revision — the gate is now a script, so there is code to decompose.
`.github/scripts/check-action-pins.sh`:

| Function | Responsibility |
|---|---|
| `extract_refs` | One `yq` pass per file, emitting `ref<TAB>comment` for all three `uses:` shapes |
| `resolve_version` | `owner/repo` + version → commit SHA, memoized; returns 0 resolved, 2 "no such version", 1 "no answer" |
| `line_of` | Line number for the annotation, by literal lookup of the ref |
| `check_file` | Per-file validation; accumulates into the `FILE_FINDINGS` global |
| `scan_targets` | The files the gate owns: `.github/workflows/*.y{a,}ml` + every `action.y{a,}ml` under `.github/actions/` at any depth |
| `run_self_test` | Runs `check_file` over the fixtures and asserts the finding count per file |

Three implementation constraints, each of which produced a bug before it was understood:

- **`check_file` returns its count in a global, not on stdout.** Under CI, `err()` writes
  `::error` annotations to stdout; capturing the function with `$(...)` swallows every
  annotation into the count string, so the reviewer sees nothing and the arithmetic
  breaks.
- **yq's `,` binds looser than `|`.** `... | .uses, (.uses | line_comment)` emits every
  ref first and then every comment, silently destroying the pairing. The extraction must
  concatenate per item.
- **No associative arrays.** macOS ships bash 3.2; the memo cache is a temp file.

## Acceptance Criteria (EARS)

- **AC-1.** Every `uses:` referencing a third-party action under `.github/workflows/`
  and `.github/actions/` shall specify a 40-character commit SHA followed by a
  trailing `# vX.Y.Z` version comment.
- **AC-2.** First-party `refokus-agency/platform/...@v1` references and local `./`
  references shall remain unchanged.
- **AC-3.** When a pull request is opened or synchronized, the repository shall run
  `.github/scripts/check-action-pins.sh`.
- **AC-4.** If a pull request introduces a third-party `uses:` that is not pinned to
  a commit SHA, then the gate shall fail that pull request.
- **AC-5.** If a pin's trailing version comment does not match its SHA, then the gate
  shall fail that pull request.
- **AC-5a.** If a pin's version comment names a version that does not exist, then the
  gate shall fail that pull request and say the comment is wrong — not that the API
  could not be reached.
- **AC-5b.** If the GitHub API cannot be reached, then the gate shall fail rather than
  pass an unverified pin.
- **AC-5c.** The gate shall run its own `--self-test` before the real check, and that
  self-test shall assert the gate rejects an unpinned ref, a short SHA, a missing
  comment, a lying comment, and a nonexistent version.
- **AC-5d.** The gate shall reference no third-party action other than
  `actions/checkout`, and CI shall not run pinact.
- **AC-6.** `.github/dependabot.yml` shall declare a `github-actions` update entry
  for `/.github/actions/setup` in addition to the existing `/` entry.
- **AC-7.** When Dependabot next runs its weekly `github-actions` check, it shall
  raise updates for the four pins inside `.github/actions/setup/action.yml`.
- **AC-8.** The gate workflow's own `uses:` entries shall themselves be SHA-pinned.
- **AC-9.** The gate workflow shall declare `permissions: contents: read` and no
  write scope.
- **AC-10.** `docs/contributing.md` shall contain the pinning rule, name `pinact` as
  the local generator, and give the command that checks the same way CI does.
- **AC-11.** `CLAUDE.md` → `## Invariants to preserve` shall contain the SHA-pinning
  invariant.
- **AC-12.** `README.md` shall remain byte-identical.

## Out of Scope

- **First-party `@v1` floating refs** in `examples/` and the `platform-ref` input —
  that is issue #60, a different problem with a different blast radius.
- **`persist-credentials` hardening** in `ci.yml` / `deploy.yml` — that is issue #82.
- **Dependabot cooldown / minimum-release-age policy** — pinact supports it; not
  discussed, not adopted here.
- **Org-level allowed-actions policy** — complementary per the issue, not a
  substitute, and out of this repo's control.

## Edge Cases + Error Handling

| # | Scenario | Source | Handling |
|---|---|---|---|
| 1 | pinact rewrites the first-party `@v1` refs in `examples/` | [inferred] | `.pinact.yaml` scopes the file set to `.github/**`; step 1 and step 2 both assert an empty diff under `examples/` |
| 2 | `release-please.yml` uses the `- uses:` dash form, which a naive `^\s*uses:` grep misses | [inferred] | pinact parses YAML rather than regex; verify both L19 and L25 are pinned in the diff |
| 3 | A Dependabot PR now has to pass the new gate | [inferred] | Dependabot updates the SHA **and** its trailing comment, so the gate passes; a read-only `GITHUB_TOKEN` is sufficient for the gate's API reads |
| 4 | A fork PR runs the gate with a read-only token | [inferred] | The repo is public and the gate needs no secrets; `contents: read` is enough |
| 5 | The `anthropics/claude-code-action` pin goes stale on its fast-moving release line | [from issue] | Accepted under D-1: Dependabot moves it weekly and the release process makes the move deliberate rather than silent |
| 6 | A future composite action under `.github/actions/` gets no Dependabot entry and silently stops being updated | [from issue discussion] | Cannot be automated — `dependabot-core#7495` is closed as not planned. Recorded as a manual duty in `docs/dependabot.md`, and `check-dependabot-coverage.sh` fails the PR when the entry is missing |
| 7 | The gate exhausts GitHub API rate limits resolving refs | [inferred] | 9 unique `(repo, version)` pairs, memoized, against a 5000/hr authenticated limit. `GH_TOKEN` via `env:` keeps it off the anonymous limit |
| 8 | A composite action nested deeper than one level (`.github/actions/vercel/deploy/`) escapes the coverage check | [found in review] | Both scripts walk `.github/actions/` with `find` at any depth. A one-level glob reported "all covered" and exited 0 — the silent failure the check exists to prevent |
| 9 | A version comment names a release that does not exist | [found in implementation] | GitHub answers **422**, not 404. Classified as a verdict about the pin, not an outage: no retry, and the message blames the comment |
| 10 | `git ls-remote` used instead of the API returns the tag *object* for an annotated tag | [found in design] | Four pins use annotated tags, so that comparison red-fails correct pins. `gh api .../commits/<version>` peels in one call |
| 11 | The gate's own fixtures get scanned as production input, or executed as workflows | [inferred] | Fixtures live in `.github/scripts/fixtures/pin-check/` — outside `.github/workflows/` and outside the gate's scan globs |

## Done Criteria per Feature

| Feature | Done when |
|---|---|
| Pin the 22 third-party call sites | AC-1, AC-2 |
| PR enforcement gate | AC-3, AC-4, AC-5, AC-5a, AC-5b, AC-5c, AC-5d, AC-8, AC-9 |
| Dependabot coverage of the composite action | AC-6, AC-7 |
| Documentation of the convention | AC-10, AC-11, AC-12 |

## Risks

- **A wrong SHA breaks every consumer repo simultaneously.** The `@v1` tag is
  force-moved on release, so a bad pin propagates org-wide with no further merge.
  → Pins are *generated* by `pinact run`, never hand-typed; the gate independently
  resolves each version and rejects a comment that disagrees with its SHA.
- **The gate is net-new CI surface in a repo that has never run PR checks.**
  → `permissions: contents: read` only, no secrets, no third-party action but
  `actions/checkout`.
- **The gate is now our code, so its bugs are our bugs.** A broken gate that passes
  everything is indistinguishable from a healthy one.
  → `--self-test` runs in CI ahead of the real check, against fixtures that must be
  rejected. Both scripts were also exercised under macOS bash 3.2, not only the
  runner's bash 5.
- **pinact is a 1.2k-star third-party dependency doing security-relevant work.**
  → Accepted (D-5), but narrowed by the revision: it runs **locally only**, where a
  compromise reaches a working tree under review rather than CI. The 22 pins are inert
  YAML and keep working if the tool disappears, and since the gate resolves versions
  itself, bad output from pinact is caught rather than trusted.
- **A misconfigured `.pinact.yaml` silently rewrites `examples/`,** breaking the
  caller templates every consumer repo copies. → Steps 1 and 2 both assert an empty
  diff under `examples/`.
- **Runtime-generated files:** none. Nothing needs adding to `.gitignore`;
  `.cothinker/` is already ignored (`.gitignore:4`). No directory needs a `.gitkeep`.

## Test Strategy

- **Local, black-box via CLI:** `./.github/scripts/check-action-pins.sh` exits 0, and
  `--no-api` exits 0 without network. `pinact run --check` also exits 0, since pinact
  still owns generation.
- **The gate's own test suite:** `./.github/scripts/check-action-pins.sh --self-test`
  → 8/8 fixtures. Under `--no-api` the two network-dependent cases skip rather than fail.
- **Inventory assertion:** all 22 third-party refs are 40-hex with a version comment;
  the 4 local `./` refs and everything under `examples/` are untouched.
- **Gate proven locally, not assumed:** a planted `uses: actions/checkout@v7` and a
  planted lying comment each produce a finding with the correct line number, and
  removing them returns exit 0. Verified in both plain and `GITHUB_ACTIONS` annotation
  output.
- **Coverage check proven:** a synthetic `.github/actions/vercel/deploy/action.yml`
  fails `check-dependabot-coverage.sh` and prints the block to paste.
- **Gate proven in CI:** push a throwaway commit adding `uses: foo/bar@v3`, confirm the
  PR goes red, then revert. A gate that has never failed is not a gate — and local
  runs cannot prove the workflow wiring.
- **Real-run verification** (per `CLAUDE.md`, a reusable cannot execute in this repo):
  point one low-stakes consumer repo at
  `refokus-agency/platform/.github/workflows/ci.yml@beogip/feat-workflows-pin-third-party-actions-by-commit`
  and confirm a green run before merge. This is the only way to prove the composite
  action's four new pins actually resolve.
- **Post-merge:** confirm Dependabot's next weekly run raises updates touching
  `.github/actions/setup/action.yml` (AC-7).
