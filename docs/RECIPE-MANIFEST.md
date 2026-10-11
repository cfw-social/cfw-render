# Recipe manifests (format v1)

Every recipe can declare, in one machine-readable file, its ordered steps and
the inputs it needs from the user. CFW uses it to show "step 3 of 7", to ask
for missing inputs before a computer ever connects, and to resume a run at a
step. This page is for recipe authors. The contract is
`plans/m1/CONTRACTS.md` sections 2–3 in the cfw-social repo; this page copies
it and does not add fields.

- **File:** `skills/<recipe>/manifest.json` (source of truth, one per recipe).
- **Schema:** `schemas/recipe-manifest.v1.schema.json` (JSON Schema 2020-12).
- **Validator:** `python3 scripts/validate-manifests.py` (also run by `scripts/lint.sh`).
- **Reference manifest:** `skills/p-reels-spotlight/manifest.json` (Spotlight reel).
- **Recipes without a manifest** keep today's behaviour exactly (Director prompt, five generic stages).

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
| `steps[].saves` | Outputs uploaded to CFW Media when the step completes, so another computer can resume after it (D30). `preview: true` shows it in run details. |
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
- `count.min ≤ count.max` and `durationSec.min ≤ durationSec.max`.

Each error names the offending step or input and, for a missing instructions
file, the path that was looked up.

## Bumping `recipeVersion`

Bump it whenever you change anything in `steps`, `inputs`, `checks` or `saves`
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

## Adding a manifest to another recipe

1. Copy `skills/p-reels-spotlight/manifest.json` and edit it.
2. Create one `steps/NN-<name>.md` per computer step and point `instructions` at it.
3. Run `python3 scripts/validate-manifests.py` and `test/run-tests.sh`.
4. Re-sync CFW's vendored copy (cfw-social) so claims match.
