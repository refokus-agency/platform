---
issue_number: 86
issue_title: "docs: examples recommend `secrets: inherit` to every consumer, including callers outside refokus-agency"
repo: "refokus-agency/platform"
labels: [documentation, enhancement]
plan_level: "full"
depth: "medium"
branch_name: "beogip/docs-examples-recommend-secrets-inherit-to-every"
created_at: "2026-09-14T11:58:01Z"
---

# Implementation Plan: #86 — docs: examples recommend `secrets: inherit` to every consumer, including callers outside refokus-agency

## Files

| # | Action | Path | Purpose |
|---|---|---|---|
| 1 | modify | `docs/secrets.md` | Fix the false "anything else is ignored" sentence (L38); add new `## Calling from outside \`refokus-agency\`` section after L38; rewrite the `code-review.yml` bullet (L137 pre-change; **L221 after the section insert**) to link to it instead of duplicating |
| 2 | modify | `docs/architecture.md` | Qualify `### Why \`secrets: inherit\`?` (L264–277) as the internal-caller default + fix its stale `required: true` sentence |
| 3 | modify | `docs/getting-started.md` | L9 prerequisite — say why the org membership is load-bearing for `secrets: inherit` |
| 4 | modify | `CLAUDE.md` | Two edits: qualify the invariant (L32) — `inherit` is the default *inside* the org — and add a one-line sync obligation for new secrets under "Common edits", next to the existing "New input on a reusable" bullet (authorised by Edge Case #5) |
| 5 | modify | `examples/pr-ci.yml` | Header-comment caveat + link |
| 6 | modify | `examples/pr-preview.yml` | Header-comment caveat + link |
| 7 | modify | `examples/main-stage.yml` | Header-comment caveat + link |
| 8 | modify | `examples/main-production.yml` | Header-comment caveat + link |
| 9 | modify | `examples/production-deploy.yml` | Header-comment caveat + link |
| 10 | modify | `examples/main-release.yml` | Header-comment caveat + link |
| 11 | modify | `examples/main-release-npm.yml` | Header-comment caveat + link |
| 12 | modify | `examples/comment-code-review.yml` | Header-comment caveat + link |

## Codebase Context

- **Header-comment convention in `examples/`** — L1 is a one-sentence purpose, L2 is `# Copy to .github/workflows/<name>.yml in your repo.`, then a `#` separator and any caveats. The new text belongs in that block. Do **not** annotate the 13 individual `secrets: inherit` lines (4-space indent, always the last line of a job block) — inline × 13 is noise for internal callers who need no warning.
- **Docs cross-link convention** — relative path plus a GitHub heading slug, e.g. `[architecture.md](architecture.md#why-fork-pull-requests-are-skipped)` (`docs/architecture.md:106`, `docs/secrets.md:127`). Same-file anchors are used too (`docs/secrets.md:15`). New anchor for this change: `secrets.md#calling-from-outside-refokus-agency`.
- **YAML comments cross-reference docs** by bare relative path + anchor — see `.github/workflows/code-review.yml:14` and `examples/comment-code-review.yml:7`.
- **Authoritative secret keys** (read from each `workflow_call` block; every one is `required: false`):
  - `ci.yml` → `CHECKOUT_TOKEN`
  - `deploy.yml` → `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`, `CHECKOUT_TOKEN`
  - `release.yml` → `RELEASE_APP_ID`, `RELEASE_APP_PRIVATE_KEY`
  - `code-review.yml` → `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`
- **Federation path** — `federation-rule-id` / `anthropic-org-id` are `workflow_call` **inputs** defaulting to `vars.ANTHROPIC_FEDERATION_RULE_ID` / `vars.ANTHROPIC_ORG_ID` (`code-review.yml:181-199`), already documented at `docs/secrets.md:77-91`. On that path there is no secret to map at all.
- **Existing external-consumer bullet** lives at `docs/secrets.md:137` with a fenced example at L139–151. Reuse its wording and rationale when writing the new section; do not introduce a second voice for the same argument.
- **Reference implementation for a qualified invariant** — `CLAUDE.md:32` already pairs a default with its rationale and its exception (`required: false` + the `transferred` gate). Follow that shape.

## Steps

1. **Fix the false sentence** → `docs/secrets.md:38`. Replace *"The reusable declares which ones it actually requires; anything else is ignored."* with the documented behaviour: under `inherit` the called workflow can reference any secret the caller holds, declared or not — the `secrets:` blocks document intent, not enforcement. Preserve the existing `GITHUB_TOKEN` clause.
   **Done when:** `rg -c 'anything else is ignored' docs/secrets.md` returns 0, and the replacement text contains the word `undeclared` and a link to GitHub's "Reusing workflows" documentation.

2. **Add the new section** → `docs/secrets.md`, inserted after L38 and before `## Configuring secrets` (L40). Heading: `## Calling from outside \`refokus-agency\``. Body covers: why (least privilege, floating `@v1`, `inherit` documented as same-org/enterprise), a per-reusable table of exactly which keys each reusable reads, a copy-paste explicit `secrets:` map per reusable, the renaming note, and the federation-variables note for `code-review.yml`.
   **Done when:** `rg -c '^## Calling from outside' docs/secrets.md` returns 1, and the section body names all 8 distinct secret keys and all 4 reusable filenames.

3. **Collapse the duplicate bullet** → `docs/secrets.md:137` (the new section pushes it to L221; the other referenced positions — L38, L40, `docs/architecture.md:264`, `CLAUDE.md:32` — are unaffected). Keep the `code-review.yml`-specific bullet but shorten it to point at the new section; its generic reasoning moves up into step 2 so there is one source of truth.
   **Done when:** that bullet contains a link to `#calling-from-outside-refokus-agency` and no longer restates the `@v1` floating-tag rationale.

4. **Qualify the architecture rationale** → `docs/architecture.md:264-277`. Add that `inherit` is the default for callers inside `refokus-agency`, pointing external callers at the new section. Also fix the stale final sentence ("The reusable declares which secrets are `required: true`, so a missing one fails with a clear error") — every declared secret is `required: false`.
   **Done when:** the section contains a link to `secrets.md#calling-from-outside-refokus-agency` and `rg -c 'required: true' docs/architecture.md` returns 0.

5. **Qualify the invariant** → `CLAUDE.md:32`. Insert the internal/external distinction into the existing bullet without dropping either load-bearing half. Then add the Edge Case #5 sync obligation as a sibling bullet under **Common edits and where they go**, after "New input on a reusable": a new secret on a reusable must update the per-reusable table in the new `docs/secrets.md` section in the same PR. Two edits to this file, both in the diff.
   **Done when:** the bullet still presents both `secrets: inherit` and `required: false` as the default, and additionally names the external-caller exception.

6. **Explain the prerequisite** → `docs/getting-started.md:9`. State that the org prerequisite is what makes the `secrets: inherit` line in the examples safe, linking to the new section.
   **Done when:** the L9 bullet links to `secrets.md#calling-from-outside-refokus-agency`.

7. **Annotate all 8 examples** → insert the shared header snippet into the existing `#` block of each `examples/*.yml`, before `name:`. Identical wording in all 8.
   **Done when:** `rg -l 'calling-from-outside-refokus-agency' examples/ | wc -l` equals 8, and `git diff --stat .github/` is empty.

## Interfaces

No executable code ships in this change, so there are no types. The one shared contract is the **example header snippet**, used verbatim in all eight files (`organization`, not `organisation` — the repo uses the American spelling throughout: `docs/secrets.md` "Organization secrets", `docs/getting-started.md:9`):

```yaml
#
# `secrets: inherit` below assumes your repo is in the refokus-agency org. Calling from
# another organization? Swap it for an explicit secrets map —
# see docs/secrets.md#calling-from-outside-refokus-agency.
```

The second shared contract is the **anchor** `calling-from-outside-refokus-agency`, derived by GitHub's slug rule from the heading `## Calling from outside \`refokus-agency\``. Every link written in steps 3, 4, 6 and 7 depends on it.

## Function Design

N/A — no executable code in this change.

## Acceptance Criteria (EARS)

- **AC-1.** `docs/secrets.md` shall state that under `secrets: inherit` the called workflow can reference any secret the caller holds, including secrets the reusable never declared.
- **AC-2.** `docs/secrets.md` shall contain a section covering explicit secret mapping for all four reusables — `ci.yml`, `deploy.yml`, `release.yml` and `code-review.yml`.
- **AC-3.** That section shall list, per reusable, exactly the secret keys that reusable declares and no others.
- **AC-4.** That section shall state that a caller may rename a secret on the right-hand side of an explicit map.
- **AC-5.** That section shall state that the `ANTHROPIC_FEDERATION_RULE_ID` / `ANTHROPIC_ORG_ID` variables path requires no secret at all for `code-review.yml`.
- **AC-6.** Each of the eight `examples/*.yml` files shall carry a comment pointing external callers at that section.
- **AC-7.** `docs/getting-started.md` shall state why the `refokus-agency` prerequisite is load-bearing for the `secrets: inherit` line.
- **AC-8.** `CLAUDE.md` shall retain `secrets: inherit` and `required: false` as the stated default while qualifying it as the default for callers inside `refokus-agency`.
- **AC-9.** `docs/architecture.md#why-secrets-inherit` shall carry the same qualification.
- **AC-10.** If a proposed edit would change any file under `.github/workflows/` or `.github/actions/`, then the change shall be rejected as out of scope.
- **AC-11.** When the `code-review.yml` external-consumer bullet is retained, it shall link to the new section rather than restate its rationale.
- **AC-12.** `docs/architecture.md` shall not claim that any reusable declares a `required: true` secret. *(Beyond the issue's own list — see Risks.)*

## Out of Scope

- Any change to `.github/workflows/*.yml` or `.github/actions/setup/action.yml`. Behaviour stays identical, so this change carries zero release blast radius (AC-10).
- Replacing `secrets: inherit` in the existing example files — explicitly rejected in the issue.
- Shipping a parallel `examples/external/` set with explicit maps — explicitly rejected in the issue as a sync-drift hazard.
- Adding, removing or renaming any declared secret on any reusable.
- README restructuring beyond adding a link if one becomes warranted.

## Edge Cases + Error Handling

| # | Scenario | Source | Handling |
|---|---|---|---|
| 1 | External caller omits a key they don't have | [from issue] | Every declared secret is `required: false`, so the run still starts. State this in the new section so the explicit map does not read as all-or-nothing. |
| 2 | `CHECKOUT_TOKEN` is declared by two reusables | [inferred] | The per-reusable table lists it under both `ci.yml` and `deploy.yml`. Do not dedupe into a flat list — a caller that maps it in only one job breaks the other. |
| 3 | External caller uses the federation path, so there is nothing to map | [from issue] | Called out in the `code-review.yml` row: federation needs Actions *variables*, not secrets. |
| 4 | Anchor slug is wrong, leaving 8 dead links in the examples | [inferred] | Slug derived by GitHub's rule from the written heading; verified by grepping the fragment against the slugified headings of `docs/secrets.md` before commit. |
| 5 | A new secret is added to a reusable later and the docs table goes stale | [inferred] | The new section names the reusables' `secrets:` blocks as the source of truth; add the sync obligation to `CLAUDE.md`'s "Common edits" if it fits in one line. |
| 6 | `GITHUB_TOKEN` is mistaken for a mappable secret | [inferred] | The existing L38 text already says it is automatic — preserve that clause when rewriting the sentence. |
| 7 | An inserted comment breaks a YAML file | [inferred] | Comments only, inserted inside the existing `#` block before `name:`. All 8 files are parse-checked. |

## Done Criteria per Feature

| Feature | Done when |
|---|---|
| Correct the false `inherit` claim | AC-1 |
| New external-consumer docs section | AC-2, AC-3, AC-4, AC-5, AC-11 |
| Example files point outward | AC-6 |
| Invariant qualified, not reversed | AC-8, AC-9, AC-12 |
| Zero blast radius | AC-7, AC-10 |

## Risks

- **AC-12 is an addition, not one of the issue's acceptance criteria.** `docs/architecture.md:277` claims reusables declare `required: true` secrets, which is false, and it sits inside the exact paragraph AC-9 requires editing. Leaving a known-false sentence inside a paragraph being rewritten is worse than the small scope creep. → Included as one sentence; trivially droppable if the diff should stay literal to the issue.
- **Over-qualifying `CLAUDE.md` could read as reversing the invariant.** → The bullet keeps `inherit` + `required: false` as the stated default, with the external case framed as a documented exception. AC-8 is written to catch a reversal.
- **Docs/reusable drift on the new per-reusable table.** → Mitigated by edge case #5: the `secrets:` blocks are named as the source of truth in the section itself.
- **Eight near-identical comment insertions invite copy-paste error.** → One verbatim snippet, verified by a single grep count of 8 (step 7).
- **Runtime-generated files:** none. No `.gitignore` or `.gitkeep` change is needed. The plan artifact itself lands in `docs/specs/`, which is tracked, consistent with the five existing specs.

## Test Strategy

This repo has no test suite, no build and no lint — verification is grep and parse, all local:

1. `rg -c 'anything else is ignored' docs/secrets.md` → 0. **Do not scope this to `docs/`** — this plan artifact lives in `docs/specs/` and quotes the deleted sentence four times, so `docs/` can never reach 0. Scoped to `docs/secrets.md` it matches the Step 1 Done-when.
2. `rg -l 'calling-from-outside-refokus-agency' examples/ | wc -l` → 8.
3. **Anchor integrity** — extract every `secrets.md#...` fragment written by this change, slugify every `##`/`###` heading in `docs/secrets.md` (lowercase, strip punctuation, spaces → hyphens), and assert each fragment resolves to a real heading.
4. `python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('examples/*.yml')]"` → all 8 parse without error.
5. `git diff --stat .github/` → empty output (AC-10, the blast-radius gate).
6. **Manual read-through** of the new section against the four `workflow_call` `secrets:` blocks, key by key, confirming AC-3 (exactly the declared keys, no extras, no omissions).
