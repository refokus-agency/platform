---
issue_number: 90
issue_title: "ci(code-review): reusable should own review serialization — callers cannot do it correctly"
repo: "refokus-agency/platform"
labels: [bug]
plan_level: "full"
depth: "medium"
branch_name: "beogip/ci-code-review-reusable-should-own-review-serial"
created_at: "2026-09-14T00:00:00Z"
---

# Implementation Plan: #90 — ci(code-review): reusable should own review serialization

`code-review.yml` declares no `concurrency`, which pushes serialization onto every consumer repo.
Consumers cannot implement it correctly: `concurrency` cannot read the reusable's
`inputs.trigger-phrase`, so a caller-side group takes in every `issue_comment` in the repo, not
just trigger-phrase comments — and GitHub cancels a *pending* run in a group unconditionally,
regardless of `cancel-in-progress: false`. The result is a genuine queued review dying silently
when any unrelated comment lands.

This moves serialization into the reusable, where `inputs.trigger-phrase` is in scope, and caps
review runtime so the new concurrency group cannot be held for six hours by a hung review.

## Files

| # | Action | Path | Purpose |
|---|---|---|---|
| 1 | modify | `.github/workflows/code-review.yml` | New `timeout-minutes` input; `concurrency` + `timeout-minutes` on `jobs.review:` |
| 2 | modify | `examples/comment-code-review.yml` | Remove the caller `concurrency:` block (lines 27-35), replace with a comment explaining why there is none |
| 3 | modify | `docs/architecture.md` | Replace the section at lines 114-120 with one stating the reusable owns serialization |

## Codebase Context

- `jobs.review:` starts at line 254 of `code-review.yml` (was 234 before this change); the
  job-level `if:` is at 262-265, `runs-on: ubuntu-latest` at 266, and `steps:` at 298. There is
  deliberately **no** `permissions:` block — the job inherits the caller's grants, and declaring a
  scope would force every caller to grant it.
  *Post-implementation:* the new `concurrency:` block sits at 272-287 and `timeout-minutes:` at 288,
  both between `runs-on` and the `permissions` rationale comment.
- Input house style: `description: |` with multi-paragraph prose explaining the *why* and the
  gotchas, then `required: false`, `type:`, `default:`. See `platform-ref` (174-184) and
  `fetch-depth` (185-189) as the closest models.
  *Post-implementation:* the new `timeout-minutes` input sits at 190-204, between `fetch-depth`
  and `allowed-bots` (now 205).
- **No reusable in this repo declares `concurrency` today.** Every existing `concurrency:` block
  lives in a caller (`examples/*.yml`) or in the repo's own `release-please.yml`. This is the
  first reusable to own it.
- There is **no actionlint gate and no workflow validation in CI**, and no pre-commit hooks.
  actionlint must be run by hand.
- **The actionlint baseline is NOT clean** (verified during implementation against `HEAD`).
  `code-review.yml` on `main` already emits 3 errors: `anthropic_federation_rule_id` and
  `anthropic_organization_id` are unknown to actionlint's bundled schema for
  `anthropics/claude-code-action@v1`, and `steps.review.outputs.conclusion` is not in that action's
  declared outputs. All three are pre-existing and unrelated to this change, so **"actionlint exits
  0" is not a usable gate on this file** — compare the error count against the baseline instead.
  Cleaning the baseline belongs to a separate PR.
- `docs/contributing.md#option-a-test-against-your-branch-in-a-real-repo`: for `code-review.yml`
  the external-repo test is the *only* option — GitHub runs an `issue_comment` workflow from the
  default branch, so this repo's own dogfood caller exercises `code-review.yml` as it exists on
  `main`, never the version on the branch under test.
- `docs/architecture.md:114` (`#### Why the caller sets cancel-in-progress: false`) is the only
  existing section about concurrency. It is referenced from `examples/comment-code-review.yml:34`,
  which this change deletes — so the anchor can be renamed without leaving a dangling reference.
  *Post-implementation:* the replacement section, `#### Why serialization lives in the reusable, not
  the caller`, occupies `docs/architecture.md:114-140`.
- `docs/contributing.md` breaking-change checklist: breaking means removing/renaming an input,
  changing a default's behavior, adding a `required: true` input/secret, or changing existing
  input semantics. This change matches none of them.

## Steps

1. **Add the `timeout-minutes` input** to `on.workflow_call.inputs` in `code-review.yml`, in house
   style. The prose must say why it exists — the concurrency group added in step 2 is what turns a
   hung review from a self-contained annoyance into a blocker for everything queued behind it —
   and that a caller can raise it.
   **Done when:** `rg -n "timeout-minutes" .github/workflows/code-review.yml` shows the input
   declared with `required: false`, `type: number`, `default: 30`.

2. **Add `concurrency` and `timeout-minutes` to `jobs.review:`**:
   ```yaml
   concurrency:
     group: >-
       code-review-${{ github.repository }}-${{ github.event.issue.number }}-${{
       inputs.trigger-phrase != '' && contains(github.event.comment.body, inputs.trigger-phrase)
       && 'request' || github.event.comment.id }}
     cancel-in-progress: false
   timeout-minutes: ${{ inputs.timeout-minutes }}
   ```
   Matching comments collapse to the shared `-request` key and serialize. Non-matching comments
   fall to `github.event.comment.id` and are therefore alone in their own group, which makes the
   behaviour identical whether the job-level `if:` is evaluated before or after the group is
   joined — the ordering is undocumented and this removes the need to know it.
   **Done when:** `actionlint .github/workflows/code-review.yml` reports **no more errors than the
   pre-change baseline** — 3 before, 3 after — **with the `${{ inputs.timeout-minutes }}`
   expression in place**, not merely with a literal. Exit code is NOT the signal: the baseline is
   already dirty (see Codebase Context), so this file exits 1 either way. Compare finding COUNTS:

   ```bash
   git show HEAD:.github/workflows/code-review.yml > /tmp/base.yml
   B=$(actionlint /tmp/base.yml            2>&1 | rg -c ':[0-9]+:[0-9]+: ')
   N=$(actionlint .github/workflows/code-review.yml 2>&1 | rg -c ':[0-9]+:[0-9]+: ')
   echo "baseline=$B now=$N"; [ "$N" -le "$B" ] && echo PASS || echo FAIL
   ```

   Count on the `path:line:col:` shape, **not** on a path prefix: actionlint prints paths relative
   to the cwd, so a copy under `/tmp` is reported as `../../../tmp/base.yml` and a `rg "^/tmp"`
   filter silently counts 0 — which reads as "clean baseline" and inverts the result.

3. **Remove lines 27-35 of `examples/comment-code-review.yml`** and put a comment in their place:
   serialization is owned by the reusable; a caller-side `concurrency` applies *on top of* the
   job-level one and reintroduces the bug.
   **Done when:** the file declares no `concurrency` **key** — assert on the parsed YAML, not on a
   word count, because the replacement comment mentions the word more than once:
   `python3 -c "import yaml;assert 'concurrency' not in yaml.safe_load(open('examples/comment-code-review.yml'))"`
   exits 0, and `actionlint examples/comment-code-review.yml` exits 0 (this file's baseline *is*
   clean).

4. **Replace `docs/architecture.md:114-120`** with `#### Why serialization lives in the reusable,
   not the caller`. It must cover: why a caller cannot do it (it does not know the trigger phrase,
   and `concurrency` cannot read the reusable's `inputs`); why the group key is deliberately
   order-agnostic; and why silent cancellation of a pending run is acceptable once the group is
   correctly scoped.
   **Done when:** the section exists and
   `rg -n "why-the-caller-sets-cancel-in-progress-false" --glob '!docs/specs/**' .` returns no
   matches. The glob is mandatory, not optional tidiness: this plan file quotes the old anchor —
   including on this very line — so without it the command always matches itself and the criterion
   can never fail. A check that verifies itself verifies nothing.

5. **Commit** as `feat(code-review): own review serialization and cap review runtime`. `feat:` and
   not `fix:` because it adds an input to the `workflow_call` contract, which cuts a minor rather
   than a patch. Additive and default-preserving, so it stays on the v1.x line.
   **Done when:** `git log -1 --format=%s` starts with `feat(code-review):`.

6. **Live test against `refokus-agency/navigation`** — the only public repo of the five consumers,
   and the one `docs/contributing.md` names as the low-stakes target. Point its caller's `uses:` at
   `@beogip/ci-code-review-reusable-should-own-review-serial`, run the three cases in the Test
   Strategy, then revert the pin.
   **Done when:** cases A, B and C are observed and `navigation` is back on its original pin.

## Interfaces

The only contract surface is the `workflow_call` input block. One addition:

- **`timeout-minutes`** — `required: false`, `type: number`, `default: 30`. Caps the `review:`
  job's runtime, overridable by the caller. Additive: no input is removed, renamed or made
  required, so the change ships on the v1.x line.

`concurrency` is not part of the caller-facing contract — it is internal to the job — but it does
change observable runtime behaviour for callers, which is called out under Risks.

## Function Design

There are no functions; the units are workflow keys, each with one concern:

- `on.workflow_call.inputs.timeout-minutes` — declares the ceiling; caller-overridable.
- `jobs.review.concurrency` — serialization only. Deliberately order-agnostic with respect to the
  job-level `if:`, so it does not depend on an undocumented evaluation order.
- `jobs.review.timeout-minutes` — releases the concurrency group. It exists *because* the group can
  now hold a queue; before this change a hung review inconvenienced only itself.

## Acceptance Criteria (EARS)

- **AC-1.** The `code-review.yml` reusable shall declare `concurrency` on its `review:` job.
- **AC-2.** When two comments containing the trigger phrase are posted on the same pull request,
  the second review shall not start until the first has finished.
- **AC-3.** If a comment that does not contain the trigger phrase is posted while a review is
  running or queued, then the workflow shall not cancel or delay that review.
- **AC-4.** Each non-matching comment shall receive a distinct concurrency group key, so behaviour
  is identical whether the job-level `if:` is evaluated before or after the group is joined.
- **AC-5.** The reusable shall declare a `timeout-minutes` input, `required: false`, defaulting
  to 30.
- **AC-6.** When a caller supplies `timeout-minutes`, the `review:` job shall use that value
  instead of the default.
- **AC-7.** If a review exceeds the effective timeout, then the job shall be terminated rather than
  holding the concurrency group until GitHub's 360-minute default.
- **AC-8.** `examples/comment-code-review.yml` shall declare no `concurrency` block and shall carry
  a comment stating that serialization is owned by the reusable.
- **AC-9.** `docs/architecture.md` shall document that serialization is owned by the reusable and
  that callers must not declare their own `concurrency`.
- **AC-10.** The change shall be additive to the `workflow_call` contract — no input removed,
  renamed or made required — so it ships on the v1.x line.

**Dropped from the original issue:** *"a queued review is never cancelled without a visible
signal."* Discovery established that the signal cannot be emitted at all — not from the cancelled
run (a pending run never dispatches a job, so no step executes, not even `if: always()`), and not
from the run that displaced it (no native context, no REST API field distinguishing a concurrency
cancel from a manual one, no confirmed event). It was also established that once the group is
correctly scoped, nothing concrete is lost when a pending run dies: the contending runs are both
genuine review requests on the same pull request, and the newer one produces the review.

## Out of Scope

- **Tag-protection ruleset** for the repo — a separate issue, with no coupling to this change.
- **Step ordering when a pinned tag is deleted** — "Code review" posts at `code-review.yml:410`
  while "Checkout platform repo" is at `:431`, so the review publishes and *then* the job goes red.
  Ships with the ruleset issue.
- **Empirically testing the timeout** — it would require a review that hangs for 30 minutes. Not
  practical; explicitly excluded by decision.
- **Editing consumer repos' workflows directly** — handled by an issue in each repo, after the
  release.
- **`queue: max`** — GA per GitHub docs, but actionlint 1.7.12 rejects the `queue` key
  (rhysd/actionlint#657, still open), which would break consumers that lint their workflows.

## Edge Cases + Error Handling

| # | Scenario | Source | Handling |
|---|---|---|---|
| 1 | Comment with the phrase while a review is running | [from issue] | Joins the group, stays pending, starts when the first finishes |
| 2 | Comment without the phrase while a review is running | [from issue] | Unique key via `comment.id` — contends with nothing |
| 3 | A third genuine request with one running and one pending | [from issue] | The pending run is cancelled silently. Accepted: the newest run produces the review anyway |
| 4 | `trigger-phrase` set to the empty string | [inferred] | The job `if:` already disables the workflow; the group key falls to the `comment.id` branch |
| 5 | Caller keeps its own `concurrency` block | [from issue] | Independent groups — the caller's keeps killing its pending runs. Resolved by an issue in that repo |
| 6 | Review exceeds 30 minutes | [inferred] | Job terminated, group released |
| 7 | Caller pinned to an exact tag | [discovered during discovery] | Does not receive the fix until it bumps. The consumer issue asks for the bump first, removal second |
| 8 | Caller invokes the reusable from a trigger other than `issue_comment` | [inferred] | `github.event.comment.id` and `issue.number` are empty so the key collapses, but the `if:` requires `github.event.issue.pull_request` and the job skips |

## Done Criteria per Feature

| Feature | Done when |
|---|---|
| Reusable owns serialization | AC-1, AC-2, AC-3, AC-4 |
| Runtime ceiling | AC-5, AC-6, AC-7 |
| Example and docs | AC-8, AC-9 |
| v1.x compatibility | AC-10 |

## Risks

- **The ternary idiom `A && 'x' || B` is community-established, not officially documented by
  GitHub.** It works here because the middle operand (`'request'`) is a non-empty string and
  therefore truthy; a falsy middle operand would fall through to the third even when the condition
  holds. → Mitigated by a verified actionlint pass and by the live test exercising the real case.
- **The timeout cannot be tested.** → Accepted by decision. If it misfires the symptom is a job
  dying at 30 minutes — visible, and reversible by a caller-supplied input.
- **Consumers that do not bump stay broken.** → Issues in the four affected repos, with explicit
  ordering: bump the pin first, remove the block second.
- **The live test mutates an external repo (`navigation`).** → Step 6 includes reverting the pin as
  part of its done criterion.
- **Consumers that do bump see a behaviour change:** reviews that previously ran in parallel now
  serialize. → Intended; must be stated in the PR description, per `docs/contributing.md`'s
  requirement to name affected repos.

## Test Strategy

`act` is ruled out: it is not installed, its README is silent on `concurrency`, and closed upstream
issue nektos/act#2085 confirms it **ignores a job's `if:` when calling a reusable workflow and runs
it anyway** — precisely the gating mechanism `code-review.yml` depends on.

1. **Static:** run `actionlint` locally against the two real **workflow** files — `.github/workflows/code-review.yml`
   and `examples/comment-code-review.yml` (not synthetic fixtures). The third changed file,
   `docs/architecture.md`, is markdown and actionlint does not apply to it; check it by reading the
   rendered section and by the dangling-anchor grep in step 4. For `code-review.yml` judge against
   the 3-error baseline, not against exit code 0.
2. **Live, on `refokus-agency/navigation`** pointed at the branch:
   - **Case A** — two `@claude review` comments back to back: the second run starts only after the
     first finishes. Read via run timestamps (`created_at` vs `run_started_at`); the REST API
     exposes no "blocked on concurrency" status, so the reading is necessarily indirect.
   - **Case B** — `@claude review`, then a comment that does not match the phrase: the review is
     neither cancelled nor delayed.
   - **Case C** — a non-matching comment alone: nothing runs and nothing is held.
   - **Timeout** — not tested, by decision.
3. **Revert** `navigation` to its original pin.

## Follow-up (post-merge, outside this PR)

Open an issue in each consumer repo that still carries the caller-side block, asking it to bump the
pin to the new release **first** and then remove the `concurrency:` block:

| Repo | Pin | Caller `concurrency:` |
|---|---|---|
| `refokus-agency/meetmira-custom-code` | v1.10.3 | already removed — no issue needed |
| `refokus-agency/navigation` | v1.10.2 | yes |
| `refokus-agency/optik-ai-custom-code` | v1.10.3 | yes |
| `refokus-agency/time-to-refokus-ai-v2` | v1.10.3 | yes (own group name, file is `pr-code-review.yml`) |
| `beogip/kael.code` | v1 | yes (floating `@v1`, so it receives the reusable fix automatically) |
