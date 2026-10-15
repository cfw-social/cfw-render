# Recipe manifests (format v1)

Every recipe can declare, in one machine-readable file, its ordered steps and
the inputs it needs from the user. CFW uses it to show "step 3 of 7", to ask
for missing inputs before a computer ever connects, and to resume a run at a
step. This page is for recipe authors. The contract is
`plans/m1/CONTRACTS.md` sections 2–3 and the additive local-checkpoint
contract in `plans/m2/CONTRACTS.md` section 10 in the cfw-social repo.

- **File:** `skills/<recipe>/manifest.json` (source of truth, one per recipe).
- **Schema:** `schemas/recipe-manifest.v1.schema.json` (JSON Schema 2020-12).
- **Validator:** `python3 scripts/validate-manifests.py` (also run by `scripts/lint.sh`).
- **Reference manifest:** `skills/p-reels-spotlight/manifest.json` (Spotlight reel).
- **Recipes without a manifest** keep today's behaviour exactly (Director prompt, five generic stages).

## Reporting ownership and readiness

Read [Recipe stage reporting](RECIPE-STAGE-REPORTING.md) for managed versus
standalone execution, single-owner MCP reporting, failed gates and interruption
handling. Declared checks and catalog diagrams are not proof of executable
validators. See [coverage](RECIPE-REPORTING-COVERAGE.md) for tested boundaries and
blocked recipes. No display manifest is enabled by these documents.

## Fields

| Field | Rule |
|---|---|
| `manifestFormat` | Integer. `1` for this spec. |
| `recipe` | Matches the skill folder name. |
| `recipeVersion` | Bumped on any change to steps, inputs, checks or saves. CFW stores it per attempt. This is the version CFW matches at claim (CONTRACTS.md section 3). `config/recipes.json` `version` is informational only. |
| `label` | Owner-facing recipe name. |
| `deliverable` | What the recipe makes: `kind`, `aspect`, `width`, `height`, `durationSec {min,max}`. |
| `needs.os` | Operating systems the computer must run (`macos`). |
| `needs.engines` | Values: `codex`, `claude-code`, `api-key`. |
| `needs.tools` | Command-line tools the computer must have (`ffmpeg`, `node>=22`, …). |
| `needs.providers` | Provider ids from the brand vault (`heygen`, `elevenlabs`, `gemini`, …). Empty means none. |
| `inputs[].id` | `snake_case`, unique in the manifest. |
| `inputs[].kinds` | Any of `video`, `audio`, `image`, `link`, `text`, `choice`. A `link` is always copied into CFW Media before use (D31). |
| `inputs[].count.max` | `null` means no upper limit. |
| `inputs[].constraints` | Optional: `durationSec {min,max}`, `orientation` (`portrait`, `landscape`, `square`, `any`), `maxBytes`. Applied to each item. |
| `inputs[].neededAt` | `"start"` (claim waits until filled, D41) or `{ "step": "<stepId>" }`. |
| `inputs[].alternatives` | Optional other ways to satisfy a required input. `runsSteps` lists server or computer steps that produce it. |
| `inputs[].default` | Optional. `"brand"` means use the brand-context value when the user gives none. For `cta`, CFW resolves it at claim as `{ "text": <brand CTA text or none>, "brandName": Brand.name, "handle": PlatformConnection.accountName of the request's target platform }`; when there is no connection for that platform the handle is absent and the recipe prints no handle line (M1-00 behaviour). No new brand column (G1 decision, 2026-10-11). |
| `inputs[].prompt`, `choices` | For `text` and `choice` inputs: the question and options. |
| `steps[].id` | `snake_case`, unique. Order in the array is run order. |
| `steps[].weight` | Integer ≥ 0. Progress = sum of finished weights ÷ total weight of steps that run. `0` means not counted in the progress bar. |
| `steps[].runsOn` | `computer` or `server` (`server` steps can also run on a computer under D43; M1 runs them on the server only). |
| `steps[].when` | `"always"`, `{ "inputPresent": "<inputId>" }` or `{ "alternative": "<alternativeId>" }`. A step whose condition is false is reported `step_skipped`. |
| `steps[].instructions` | Path relative to the skill folder. Holds only this step's instructions (D45). Required for `computer` steps; the file must exist. |
| `steps[].saves` | Declared outputs. Legacy mode uploads them to CFW Media for cross-computer recovery. Negotiated local mode keeps bytes on the assigned computer and reports metadata only; `preview: true` does not make a file a final deliverable or a web preview. |
| `finalOutputs` | Optional explicit `{stepId, saveId, role}` references, required for local mode. `role` is `deliverable`, `poster`, or `captions`. The first reference is the primary deliverable; up to 30 distinct references. Poster (image) and captions (JSON) each occur at most once. Deliverables are video/image/audio. All referenced saves belong to unconditional computer stages. A QA-only last stage can reference earlier saves. |
| `steps[].checks` | Run by the harness after the step. The step only completes when every check passes. |
| `steps[].maxCheckRetries` | How many times the harness reruns the step after a failed check before failing the attempt. |
| `steps[].canAsk` | Input ids this step may raise a mid-run ask for. |

## Cross-reference rules the validator enforces

Beyond the schema, `scripts/validate-manifests.py` checks that:

- `recipe` equals the folder name;
- `inputs[].id`, `steps[].id` and `alternatives[].id` are unique;
- every `steps[].canAsk[]` and `steps[].when.inputPresent` names an existing input;
- every `inputs[].alternatives[].runsSteps[]` and `inputs[].neededAt.step` names an existing step;
- every `steps[].when.alternative` names an existing alternative;
- every `steps[].instructions` file exists inside the skill folder;
- `finalOutputs`, when present, references distinct unconditional computer saves of the right kind, with the primary deliverable first;
- `count.min ≤ count.max` and `durationSec.min ≤ durationSec.max`.

Each error names the offending step or input and, for a missing instructions
file, the path that was looked up.

## Bumping `recipeVersion`

Bump it whenever you change anything in `steps`, `inputs`, `checks`, `saves` or `finalOutputs`
(ids, order, weights, conditions, constraints). Label-only wording changes do
not need a bump. The value is a date-based string — `YYYY.M.N`, e.g.
`2026.10.1`, then `2026.10.2` for the next change in the same month. CFW only
hands a request to a worker whose `recipeVersion` matches CFW's vendored copy
of the manifest, so after a bump the copy in cfw-social must be re-synced
(`node scripts/sync-recipe-manifests.mjs` there, see CONTRACTS.md section 3)
or requests wait with "No connected computer has the current … recipe".

## Running the validator

```sh
python3 scripts/validate-manifests.py                      # every skills/*/manifest.json
python3 scripts/validate-manifests.py skills/p-reels-spotlight/manifest.json
python3 scripts/validate-manifests.py --skills-dir /some/other/skills
scripts/lint.sh                                            # runs it as one of the lint gates
```

Exit `0` means every manifest is valid; `1` lists each error as
`<path>: <message>`. The validator is standard-library Python; if the
`jsonschema` package happens to be installed it is used as an extra layer, but
every rule is also hand-checked so the result is the same without it.

## Same-computer local recovery (`local-checkpoints-v1`)

A recipe stays one job and one RenderOrder. Stages are progress/checkpoint
boundaries, not independently scheduled jobs. Only Spotlight `2026.10.4` is
eligible initially; a manifest alone does not enable another recipe.

Updated workers advertise `capabilities.checkpointProtocols` containing
`local-checkpoints-v1`. A local claim contains
`checkpoint: {mode: "local-v1", generation, action}` where action is `start`,
`resume`, or `finalize-only`. No `savedOutputs` cloud download list is sent.
Absent `checkpoint` means the existing legacy upload/restore behavior.

- `checkpoint.json` contains order/brand, recipe version, generation, installation
  identity, relative file paths, sizes, SHA-256 checksums and completion state.
  The attempt-scoped report outbox survives process restarts and lost acknowledgements.
- Before running an engine, validate the completed prefix and required saves.
  Missing, changed, empty or unsafe files block recovery with an owner-safe
  restart message. Never fetch cloud checkpoints or silently rerun paid work.
- Resume requires both the same authenticated computer key and persisted worker
  installation ID. Offline computers keep their assignment. Key rotation,
  reinstall or another computer requires an explicit entire-recipe restart.
- A partial revision can reuse earlier stages only on that same computer with
  valid source-generation files. A restart elsewhere discards reuse, not feedback.
- After every stage passes, return only `finalOutputs` to the existing completion
  uploader. Caption JSON becomes platform caption data; intermediate media is
  never swept into final delivery. Final-upload failure preserves the local saves;
  a `finalize-only` claim retries upload/completion without running recipe stages.
- Ordinary failure, release and engine limits preserve non-secret local saves.
  Attempt-end cleanup removes transient claim/provider credentials. Revocation or
  supersession still stops work and removes access/files immediately.
- Stopped checkpoints may be removed after roughly 48 hours of inactivity. Active
  job locks protect running work. Web metadata is history, **not a backup or a
  guarantee that files still exist**; intermediate files have no web download link.

Social creates local jobs only with `CFW_LOCAL_RECIPE_CHECKPOINTS=1` (off by
default). Rollback turns that flag off for new jobs, leaving compatible workers
and the additive schema in place to finish existing pinned work. Do not convert
an existing attempt to legacy mode. Live migration, release and paid-provider /
two-computer smoke tests require separate rollout approval.

### Required checks and delivery in Spotlight 2026.10.4

`bin/cfw-render-checks.py` is installed alongside the checkpoint helper. Local
mode blocks before engine execution if the helper is missing, and missing or
unknown validators cannot turn into a file-exists success. Every declared save
is validated; successful reports contain only the manifest's declared check IDs.
Legacy mode retains its previous contract.

The Spotlight adapter checks real media geometry, brightness, duration and
loudness; transcript timing; edit/beat structure and contained b-roll windows;
and voice preservation. Its generated local-mode preparation instructions
normalize the voice bed once to **-14 LUFS**, matching the final gate. This
overrides the pinned instruction's -16 LUFS sample for local mode only; later
stages must not normalize the voice bed again.

Perceptual checks require `qa/review.json`, current output hashes, actual sampled
frames, a reviewer/observations, and passing verdicts. Missing, stale, unrelated,
PENDING, FAIL, SKIP or NEEDS_VISION evidence fails. The adapter independently
checks objective media/voice facts. This evidence format is not an automatic
vision model or a guarantee of aesthetic quality. The hermetic integration uses
explicitly synthetic reviews; live-provider quality remains rollout verification.

Completion accepts either legacy flat caption strings or Spotlight's nested
`caption`/`title`/`description`/`hashtags` objects per platform. It validates and
normalizes declared local captions **before uploads**, preserving their content
within the backend's limits. Missing, malformed or empty required captions block
delivery without deleting the files; missing legacy captions retain server
copy/intent fallback. Only declared final video/poster assets upload, not caption
JSON or other intermediates.

A stopped order on an older recipe version cannot resume under a different
version. Explicit full restart adopts the current validated manifest in a new
generation; old attempts remain history and old files are not reused. Successful
server-owned research/script events are carried across same-version restarts
with their preserved inputs, not attributed to the computer or rerun for money.

## Adding a manifest to another recipe

1. Copy `skills/p-reels-spotlight/manifest.json` and edit it.
2. Create one `steps/NN-<name>.md` per computer step and point `instructions` at it.
3. Run `python3 scripts/validate-manifests.py` and `test/run-tests.sh`.
4. Re-sync CFW's vendored copy (cfw-social) so claims match.
