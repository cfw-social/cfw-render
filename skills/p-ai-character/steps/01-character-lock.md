# Lock the character and write the story arc

Audit the character description against the six attributes (hard gate), then write the story
arc: one scene per act with a visual description, emotion, camera angle and motion cue.
Nothing is generated here.

## You receive

- `inputs/story_concept/story_concept.md` — the one-paragraph story concept.
- `inputs/character_description/character_description.md` — the visual character description.
- `inputs/character_type/character_type.md` — optional; `human` (default) or `plush`.
- `inputs/num_scenes/num_scenes.md` — optional; one of `3`,`4`,`5`,`6`. Default `5`.
- `brief.json` — `intent`, `brand` (name, brief, `imageStyle` when present).

No prior saves: this is the first step.

## You must produce

- `saves/character_lock.json`:

```json
{
  "type": "human",
  "attributes": {
    "1": "<face shape | body type/material>", "2": "<hair | face>", "3": "<eyes | ears/head>",
    "4": "<clothing | outfit>", "5": "<distinctive feature>", "6": "<palette primary + accent>"
  },
  "lock_prompt": "<all six attributes as one verbatim sentence, reused in every generation prompt>"
}
```

- `saves/story_arc.json`:

```json
{
  "num_scenes": 5,
  "scenes": [
    { "n": 1, "act": "establish", "visual": "<scene description>", "emotion": "<one word>",
      "camera": "<angle / framing>", "motion": "<1 short sentence, gentle words>" }
  ]
}
```

Acts in order: `establish`, `desire`, `obstacle`, `climax`, `resolution` (for 3 scenes:
establish, climax, resolution; 4: establish, desire, climax, resolution; 6: add `attempt`
between desire and obstacle).

## How

`mkdir -p work saves`.

### 1. Read the inputs

```bash
CONCEPT=$(cat inputs/story_concept/story_concept.md 2>/dev/null | tr -s '[:space:]' ' ')
DESC=$(cat inputs/character_description/character_description.md 2>/dev/null | tr -s '[:space:]' ' ')
TYPE=$(cat inputs/character_type/character_type.md 2>/dev/null | tr -d '[:space:]'); TYPE=${TYPE:-human}
N=$(cat inputs/num_scenes/num_scenes.md 2>/dev/null | tr -dc '0-9'); N=${N:-5}
```

### 2. Six-attribute audit (hard gate)

Map the description onto the six rows of the lock table for `TYPE`. Each attribute must be a
specific, visual phrase (colour + shape/material, not "nice hair"). If any attribute is missing
or vague, do NOT invent it — ask for `character_description` (below) naming the missing
attributes in plain words. If the concept has no character, no want and no payoff, ask for
`story_concept`.

### 3. Story arc

One scene per act. `visual` is a concrete, filmable description of what is in frame (place,
light, what the character is doing); `emotion` one word; `camera` an angle and framing (full
body / medium / close-up — the character fills the frame); `motion` one or two gentle
sentences. `plush`: keep the register toylike and playful, movements exaggerated and charming.

### 4. Write the saves and self-check

```bash
python3 - <<'PY'
import json
L = json.load(open('work/character_lock.json')); A = json.load(open('work/story_arc.json'))
assert L["type"] in ("human", "plush"), "type"
assert set(L["attributes"]) == {"1","2","3","4","5","6"} and all(len(v.split()) >= 2 for v in L["attributes"].values()), "six attributes"
assert all(v.lower() in L["lock_prompt"].lower() for v in L["attributes"].values()), "lock_prompt must contain every attribute verbatim"
n = int(A["num_scenes"]); S = A["scenes"]
assert n in (3,4,5,6) and len(S) == n and [s["n"] for s in S] == list(range(1, n+1)), "scene numbering"
assert S[0]["act"] == "establish" and S[-1]["act"] == "resolution", "arc bookends"
for s in S:
    for k in ("visual","emotion","camera","motion"): assert s.get(k, "").strip(), f"scene {s['n']} {k}"
json.dump(L, open('saves/character_lock.json','w'), indent=1); json.dump(A, open('saves/story_arc.json','w'), indent=1)
print(f"[character] lock ok ({L['type']}), {n} scenes")
PY
```

## If you cannot proceed

This step may ask for **`story_concept` or `character_description`**. Write `needs_input.json`
and stop (no save), e.g.
`{"inputId":"character_description","reason":"Add the character's eye colour and shape, and one distinctive feature (glasses, scar, accessory)."}`.
Missing `character_type` / `num_scenes` are not asks — use the defaults.

## Checks the harness runs

- `six_attributes` — `saves/character_lock.json` has `type` and six non-trivial attributes,
  each contained verbatim in `lock_prompt`.
- `arc_shape` — `saves/story_arc.json` has `num_scenes` scenes numbered 1…N from `establish`
  to `resolution`, each with non-empty `visual`, `emotion`, `camera`, `motion`.
