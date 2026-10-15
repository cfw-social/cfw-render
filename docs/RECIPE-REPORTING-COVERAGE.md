# Recipe reporting coverage — 2026-10-15

This is a readiness record, **not an enablement or rollout declaration**. The
13 bundled manifests are not the database-backed owner catalog. Private additions
and unknown catalog recipes remain explicitly undescribed. No live-map or local
checkpoint eligibility was expanded by this work.

## Separate boundaries

- UI/discovery: all 13 manifests describe stable stage IDs, conditions, declared
  check IDs/labels and live-versus-display capability. Unknown recipes get no
  invented stages. An automatic check is not human approval.
- Instructions: every `SKILL.md` points to the reporting guide; every managed
  prompt includes `steps/_shared.md` plus its selected instruction. The harness
  owns stage reports; the worker owns final delivery. Catalog assistants gain no
  worker privileges. Standalone work does not report into Social.
- Validation: only Spotlight has a central recipe adapter. The other recipes
  have no `checks/<id>.sh` implementations. Prose and an eval runner's exit 0 do
  not establish coverage. Server stages are not computer checks.
- Legacy transport still has a nonempty-save fallback and can continue while
  reports are buffered. It is **blocked for an all-gates-verified readiness
  claim**, including already queued orders. This document does not change old
  workers or silently migrate queued requests to a new contract.
- Local checkpoints remain independently restricted to the existing Spotlight
  policy. Synthetic tests do not certify provider quality or perceptual judgment.

## Per-recipe acceptance matrix

All entry points are `skills/<recipe>/SKILL.md`; the linked manifests are the
source of the exact stage IDs, required inputs, conditions, saves and checks.
Every manifest-selected computer instruction exists and carries shared reporting
rules. Counts below are declared **computer-stage check occurrences**, not proof
of runnable validators. Detailed source inventory is also retained in the parent
workspace's `.gg/evidence/recipe-workflows/inventory.md`.

| Recipe / manifest | UI/report map | Computer checks | Required start inputs | Final output / readiness |
|---|---|---:|---|---|
| [p-reels-spotlight](../skills/p-reels-spotlight/manifest.json) | Live-map; reporting-tested in synthetic local mode | 19; central adapter | talking_head | Explicit final_video deliverable, cover poster, captions; local harness/evidence/recovery tested. Legacy gating not certified. |
| [p-reels-spotlight-heygen](../skills/p-reels-spotlight-heygen/manifest.json) | Live-map; **blocked** | 21; no scripts | script | No finalOutputs; validators and final-delivery integration missing. |
| [p-reels-pip](../skills/p-reels-pip/manifest.json) | Live-map; **blocked** | 16; no scripts | talking_head | No finalOutputs; validators and final-delivery integration missing. |
| [p-reels-pip-heygen](../skills/p-reels-pip-heygen/manifest.json) | Live-map; **blocked** | 18; no scripts | script | No finalOutputs; validators and final-delivery integration missing. |
| [p-reels-split](../skills/p-reels-split/manifest.json) | Live-map; **blocked** | 23; no scripts | talking_head | No finalOutputs; validators and final-delivery integration missing. |
| [p-reels-split-heygen](../skills/p-reels-split-heygen/manifest.json) | Live-map; **blocked** | 25; no scripts | script | No finalOutputs; validators and final-delivery integration missing. |
| [p-reels-faceless](../skills/p-reels-faceless/manifest.json) | **Display-only**; tracked gates blocked | 22; no scripts | script | No finalOutputs; validators and final-delivery integration missing. |
| [p-longform](../skills/p-longform/manifest.json) | **Display-only**; tracked gates blocked | 31; no scripts | script, format | No finalOutputs; video/poster/chapters/captions need explicit delivery semantics and validators. |
| [p-clone-reel](../skills/p-clone-reel/manifest.json) | **Display-only**; tracked gates blocked | 17; no scripts | source_reel | No finalOutputs; validators and final-delivery integration missing. |
| [p-carousel](../skills/p-carousel/manifest.json) | **Display-only**; tracked delivery blocked | 7; no scripts | topic | Terminal captions stage is not the image set. Ordered individual slides from render_slides need an output contract. |
| [p-gfx-image](../skills/p-gfx-image/manifest.json) | **Display-only**; tracked delivery blocked | 6; no scripts | topic | Authored four-step entry point replaces scaffold. Selected final/preview and sheet are not ordered cards. |
| [p-ai-image](../skills/p-ai-image/manifest.json) | **Display-only**; tracked delivery blocked | 5; no scripts | prompt | Selected final/preview and sheet are not ordered generated images. |
| [p-ai-character](../skills/p-ai-character/manifest.json) | **Display-only**; tracked delivery blocked | 10; no scripts | story_concept, character_description | Cover and scene_sheet are not ordered individual scenes. |

## Precise output-contract blocker

`finalOutputs` names fixed `(stepId, saveId, role)` declarations. It can order
multiple declared media saves, but these four manifests save only one full-size
preview, a sheet and JSON metadata for a variable-size set. Referencing the sheet
or JSON does not deliver its individual images. The enclosing delivery path must
also preserve every deliverable rather than choose one video/image by extension.

A follow-up contract decision must choose fixed, individually declared image slots
with defined requested-count handling, or a validated ordered collection save.
It must cover variable count, contained member paths, media kinds, bytes/checksums,
per-member QA, metadata-only checkpoints, resume, upload retry and Social's ordered
final-media ingestion. QA/captions terminal steps must reference earlier media;
no first-preview guessing. No such contract is invented or enabled here.

## Evidence and remaining acceptance

`test/run-tests.sh --local-checkpoints` exercises real prompt assembly for all
13 recipes, every real computer stage's missing-evidence rejection, missing
validators despite an omitted caller check list, and rejection of absent local
final-output contracts. These negative cases are **not successful recipe runs**.

The existing Spotlight synthetic test runs its seven real computer stages through
the harness/checks/checkpoints/report boundary, with a synthetic reviewer, declared
output mapping, failure/resume, lost acknowledgement, no intermediate transfers
and final-upload retry without engines. It also rejects corrupt media/JSON,
invalid timing/plans, stale/missing/failed/pending QA and unrelated review frames.
The generic harness fixtures cover bounded retry, conditions, cancellation and
single-owner event sequences; they are not recipe validator implementations.

### Recorded verification (2026-10-15)

Evidence index: parent workspace `.gg/evidence/recipe-workflows/verification.md`.
This records passing implementation checks separately from open acceptance gates.

- `python3 scripts/validate-manifests.py`: all 13 manifests valid. Social's
  explicit-Render-source manifest sync check: all 13 in sync (six live-map,
  seven display-only). No map promotion or checkpoint-policy expansion.
- `bash test/run-tests.sh --local-checkpoints`: passed, including the real-manifest
  negative cases for every matrix row and Spotlight's synthetic positive path
  described above. `bash test/run-tests.sh`: **281 passes, 0 failures**.
- Social TypeScript passed; scoped ESLint had zero errors and one ignored-E2E-file
  warning. Affected suites passed in 8 primary runner groups and 4 consumer groups,
  using a newly created disposable local database for DB tests. These are runner
  group counts, not individual test counts or a full Social suite claim.
- Actual settings UI: 14 fixture entries (13 authored diagrams plus one explicitly
  undescribed private fixture), no assignment controls/mutations, keyboard modal
  containment/focus return, stage selection, reduced motion and 1440/768/390/320px
  layouts passed. Empty/error/retry checks passed; one Playwright regression passed.
- Light/dark sampled text, nodes and focus contrast passed; focus outlines were
  2px with ratios 5.70/6.04. At 320px with a 200% root font, there was no page
  overflow and the last stage and Escape focus return remained keyboard-reachable.
  Text wraps heavily. This font-size test is not a native browser-zoom certification.
- Screen-reader testing and comparison against the original supplied reference
  images remain unverified. Loading-state browser evidence is not recorded.
  Screenshots are local evidence, not an accessibility certification.

The shared/live catalog and private additions were not queried; synthetic catalog
fixtures do not establish current customer rows. No installed distribution or
provider quality was verified. Earlier recovery evidence remains limited to its
recorded revision and scope, not a byte-identity claim for these later edits.

All-recipe completion remains blocked: twelve recipes lack runnable validators
and delivery integration; legacy fail-closed reporting/validation is unresolved.
No paid provider invocation, deployment, publishing, shared-data operation or
historical-migration certification is included.
