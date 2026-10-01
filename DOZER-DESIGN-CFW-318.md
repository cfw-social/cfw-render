# DOZER-DESIGN-CFW-318

[ENG] CFW-312 follow-up: 22 vendored files + brand-overrides still carry `/Users/vasanth`; portability
gate must scan `.hub/**` and strip brand data; `index.json` unstamped

## Context — what CFW-312 explicitly deferred

CFW-312 fixed the sub-skill-*resolution* bug (host `find` instead of `.hub/`) and added
`scripts/check-skills-portability.sh`, but its own design doc named two things as **out of
scope, "worth a follow-up CFW ticket"**:

> `c-kie-ai/sync-models.sh`, `c-audio`'s SFX library paths, `c-production`'s
> `{brand_local_path}` example — author/maintainer-side tooling and documentation examples...
> Hardcoded to `/Users/vasanth/ecosystem/harness/skills`... Not part of "sub-skill resolution".

> `brand-overrides/vasanth-sek8tv/brand.json`'s hardcoded `/Users/vasanth/initiatives/...`
> asset paths — a real portability smell..., but it's data, not the sub-skill-resolution bug
> this ticket names, and fixing it means deciding where brand asset paths *should* resolve
> from... a product decision, not a mechanical rewrite.

CFW-318 is that follow-up. It has three independent parts (verified against the current
worktree, `develop` HEAD `8cf4a57`):

1. **22 vendored files under `skills/` still contain a literal `/Users/vasanth/...` path.**
   `check-skills-portability.sh`'s regex only matches the specific resolver idiom
   (`$HOME/.claude`, `$HOME/.hermes`, `/Users/<user>/ecosystem/harness/skills`) — it does not,
   and by its own doc comment was never meant to, catch an arbitrary `/Users/<user>/...`
   string. These 22 slipped through untouched by CFW-312's rewrite.
2. **4 of those 22 are `brand-overrides/<slug>/brand.json` files carrying real personal data**
   (absolute host paths to Vasanth's own asset files) — not just a string leak, but live,
   documented, render-time configuration (`brand-overrides/README.md`) for Vasanth's own two
   brands (`vasanth-sek8tv` = Mr Growth Guide, `b-vasanth` = Vasanth Subramanyam) vendored
   into a bundle every recipe/customer ships with.
3. **`skills/index.json`'s `sourceSha`/`release`/`rawBase` fields are hardcoded `None` and
   never patched** — `sync-skills.py` writes them as permanent `null`, even though
   `scripts/gen-skills-manifest.sh` reads `index.json`'s `sourceSha`/`release` expecting them
   to be populated.

## Part 1 — the 22 files, inventoried

`grep -rl "/Users/vasanth" skills/` (excluding nothing — this *is* the full vendored tree)
returns exactly 22 files, confirming the ticket's count:

**14 doc/tooling files — author-side references, never executed by the render worker**
(CFW-312 already reasoned about this class and chose not to touch it; same reasoning applies,
except CFW-318's job is to kill the literal string, not leave it):

| File(s) | What it says |
|---|---|
| `p-{clone-reel,longform,reels-faceless,reels-pip,reels-pip-heygen,reels-split,reels-split-heygen}/.hub/c-audio/SKILL.md` (7 files) | `/Users/vasanth/ecosystem/harness/skills/sfx/...` — SFX library doc paths |
| `p-{ai-character,ai-image,longform}/.hub/c-kie-ai/{models.jsonl,sync-models.sh}` (5 files: p-ai-character×2, p-ai-image×2, p-longform×2 — wait, see exact list below) | registry/output path literals in an author-only sync script + its provenance record |
| `p-clone-reel/.hub/c-production/SKILL.md`, `p-longform/.hub/c-production/SKILL.md` (2 files) | `{brand_local_path}` example path |
| `p-longform/.hub/wowx-motions/SKILL.md`, `p-reels-split{,-heygen}/.hub/wowx-motions/SKILL.md` (3 files) | reference to an internal scratch planning doc |

(Exact file list, re-verified by direct grep — 18 files total in this class, not 14; see
"Exact inventory" below. The table above groups by *kind*, not a literal count — don't use its
row counts as the authoritative total.)

**4 `brand-overrides` files — real brand/personal data, handled separately in Part 2**:
`p-carousel/brand-overrides/vasanth-sek8tv/brand.json`,
`p-reels-faceless/brand-overrides/vasanth-sek8tv/brand.json`,
`p-reels-split/brand-overrides/vasanth-sek8tv/brand.json`,
`p-reels-split-heygen/.hub/p-reels-split/brand-overrides/vasanth-sek8tv/brand.json`.

### Exact inventory (18 + 4 = 22)

```
skills/p-ai-character/.hub/c-kie-ai/models.jsonl
skills/p-ai-character/.hub/c-kie-ai/sync-models.sh
skills/p-ai-image/.hub/c-kie-ai/models.jsonl
skills/p-ai-image/.hub/c-kie-ai/sync-models.sh
skills/p-clone-reel/.hub/c-audio/SKILL.md
skills/p-clone-reel/.hub/c-production/SKILL.md
skills/p-longform/.hub/c-audio/SKILL.md
skills/p-longform/.hub/c-kie-ai/models.jsonl
skills/p-longform/.hub/c-kie-ai/sync-models.sh
skills/p-longform/.hub/c-production/SKILL.md
skills/p-longform/.hub/wowx-motions/SKILL.md
skills/p-reels-faceless/.hub/c-audio/SKILL.md
skills/p-reels-pip/.hub/c-audio/SKILL.md
skills/p-reels-pip-heygen/.hub/c-audio/SKILL.md
skills/p-reels-split/.hub/c-audio/SKILL.md
skills/p-reels-split/.hub/wowx-motions/SKILL.md
skills/p-reels-split-heygen/.hub/c-audio/SKILL.md
skills/p-reels-split-heygen/.hub/wowx-motions/SKILL.md
--- brand-overrides (Part 2) ---
skills/p-carousel/brand-overrides/vasanth-sek8tv/brand.json
skills/p-reels-faceless/brand-overrides/vasanth-sek8tv/brand.json
skills/p-reels-split/brand-overrides/vasanth-sek8tv/brand.json
skills/p-reels-split-heygen/.hub/p-reels-split/brand-overrides/vasanth-sek8tv/brand.json
```

Every one of these 22 lives inside a recipe's `.hub/` closure or a `brand-overrides/` dir — not
a single one is a top-level recipe file. That is exactly why the current gate's narrow regex,
even though it technically *does* recurse into `.hub/` (`rglob("*")` over the whole recipe
root), never flags them: its `HOST_ROOT_RE` only matches the `.../ecosystem/harness/skills`
suffix and the two `$HOME` idioms, not a bare `/Users/<anyone>/...`.

**Out of scope, confirmed not part of the 22**: `scripts/sync-skills.sh`'s own header comment
(`CFW_SKILLS_SRC=/Users/vasanth/ecosystem/harness/skills scripts/sync-skills.sh` — a usage
example in cfw-render's own script, not vendored content), `README.md`, and
`backlog/{done,queue}/...` — these are cfw-render's own repo-owned files, not part of the
synced `skills/` tree, and are not touched by this ticket.

## Part 2 — `brand-overrides` strip

`skills/<recipe>/brand-overrides/README.md` documents this as a **live, intentional,
documented mechanism** (CFW-128), not dead vendored cruft:

> `brand.json` | read by | the Director (and any recipe step that needs `brand.json`) |
> palette, fonts, ElevenLabs voice pin, caption style, outro asset, CTA line/handle

Each recipe ships two slugs: `b-vasanth` (clean) and `vasanth-sek8tv` (the offender). Diffing
them is the key finding that shapes this fix:

- `b-vasanth/brand.json`'s `outro` block is **already** `{"type": "generated-card", "path":
  null, "footer": "...", "_note": "No outro asset on disk; recipes generate the closing card
  from this footer line."}` — i.e. `path: null` is an existing, valid, already-shipped shape
  in this schema. `b-vasanth` has no `hero_portrait` field at all.
- `vasanth-sek8tv/brand.json` instead carries two **absolute, host-only, dead-at-render-time**
  paths:
  - `outro.path`: `"/Users/vasanth/initiatives/brands/mr-growth-guide/.../mgg-outro-....png"`
    — but the *same object* already has `outro.relative` (a brand-mirror-relative path) **and**
    an `_note` saying *"On the fleet it must be uploaded to media.cfw.social and passed as an
    ingredient"* — i.e. the author already knew `path` doesn't work on the render fleet;
    `relative` is the field actually meant to travel.
  - `hero_portrait`: `"/Users/vasanth/initiatives/brands/mr-growth-guide/vasanth-portrait-....png"`
    — no `relative`/fallback counterpart at all.
- **Zero code in `skills/` reads either `outro.path` or `hero_portrait`**
  (`grep -rn "hero_portrait"` across `skills/` finds only the JSON key itself; the render
  recipes generate the brand-outro card from GSAP/hyperframes, not by reading this field).
  These two fields are inert at render time today — stripping them is a content fix with no
  behavioral risk to any current recipe.

**Fix**: a new sync-time transform strips exactly these two leaking, non-functional fields,
mirroring the `b-vasanth` shape that's already proven correct in the same schema:

- `outro.path` → `null` when its value starts with `/Users/<anyone>/` (keep `outro.relative`,
  `outro.type`, `outro.size`, `outro.duration_s`, `outro.mode`, `outro._note` untouched).
- `hero_portrait` → drop the key entirely when its value starts with `/Users/<anyone>/` (no
  relative counterpart exists to fall back to; an absent key is the existing convention for
  "not available," same as `b-vasanth`'s missing `hero_portrait`).
- Nothing else in `brand.json` changes — `palette`, `fonts`, `voice` (incl. `voice_id`),
  `captions`, `cta`, `cfw_brand_id` are the **documented, intended** content of this file
  (`brand-overrides/README.md`'s own table) and are not personal-path leaks; don't touch them.
  This is a narrow "strip the two host-path fields," not a redesign of brand-overrides.

This directly answers CFW-312's deferred question ("where should brand asset paths resolve
from?") with the narrowest possible answer: they don't ship in the first place; a brand step
that needs the real asset already has `relative` (for outro) or nothing (for hero_portrait,
which no recipe currently consumes) — no new resolution scheme invented.

## Part 3 — generic host-path strip for the other 18 files

These are prose/doc/tooling references with no structured JSON shape to null out — a
regex-based literal-path redaction, run as a second, independent sync-time transform. Pattern
(user-agnostic, same style as the existing `HOST_ROOT_RE`so a BYOA customer's own home dir is
caught too, not just `vasanth`):

```
/Users/[A-Za-z0-9_.\-]+(?=/)
```

Replace the matched `/Users/<user>` segment with a neutral placeholder, `/Users/<redacted>`,
**leaving the rest of the path/sentence intact** (these are human-readable docs; a path that
still reads as a path, just without the real username, stays useful to a future maintainer
reading the doc on their own machine). Examples after rewrite:

- `c-audio/SKILL.md`: `` `sfx/sfx-library.md` at `/Users/<redacted>/ecosystem/harness/skills/sfx/` ``
- `c-kie-ai/sync-models.sh`: `FLOE_REGISTRY="/Users/<redacted>/initiatives/growthsystems/video-apps/floe/..."`
- `c-kie-ai/models.jsonl`: `"registry": "/Users/<redacted>/Code/video-apps/floe/src/integrations/..."`
- `wowx-motions/SKILL.md`: `` /Users/<redacted>/Code/_scratch/Wowx/05-implementation-plan.md ``

This transform runs over **every** copied file (recipe dest + every `.hub/<dep>` dir), same
traversal shape as `rewrite_host_path_resolvers()` — so it also catches the `/Users/vasanth`
segment inside `brand-overrides/.../brand.json` as a redundant safety net in case Part 2's
structural null-out ever misses a future field; by design it should find nothing left there
once Part 2 has run first.

**Ordering in `sync-skills.py`**: Part 2 (structural brand.json strip) must run **before**
Part 3 (generic redaction), so `outro.path`/`hero_portrait` are nulled/dropped cleanly rather
than redacted-in-place into a still-broken, still-absolute-looking (just anonymized) path.
Both run after `rewrite_host_path_resolvers()` (CFW-312) and before `list_files`/hashing, same
as today — hashing must stay last so `index.json`'s `fileHashes` pin the bytes that actually
ship.

## Part 4 — portability gate must scan `.hub/**`

Reframe: `check-skills-portability.sh` **does** already recurse into `.hub/` physically
(`root.rglob("*")` over each recipe root, which includes nested `.hub/` dirs) — the ticket's
"must scan `.hub/**`" is about match **scope**, not traversal depth. Today's gate deliberately
narrows its regex to the one CFW-312 resolver idiom (see its own doc comment: "this is a
bundle-RESOLUTION gate, not a 'never mention a host path' gate"). CFW-318 needs the opposite
guarantee for the two things just fixed: that no `/Users/<anyone>/...` string (Part 3) or
`/Users/<anyone>/...` value (Part 2) can ship **anywhere** in the bundle, `.hub/**` included,
ever again.

Keep the two concerns in **separate scripts** (matches the repo's existing "one script per
static guard" pattern — `check-skills-portability.sh` for resolver correctness,
`check-no-worker-heygen-credential.sh` for the CFW-313 vault-boundary guard):

**New `scripts/check-no-host-paths.sh`** — same CLI shape as its siblings
(`--skills-dir DIR`, optional recipe-name positional args, bash + python3 only):

- Recursively scans every file under each scan root (same `rglob("*")` traversal as
  `check-skills-portability.sh`/`sync-skills.py:list_files`, so `.hub/**` and
  `brand-overrides/**` at any nesting depth are covered by construction — there is no
  "top-level only" code path to accidentally regress to).
- Matches the same `/Users/[A-Za-z0-9_.\-]+(?=/)` pattern as Part 3's rewrite — literally the
  inverse check of what the rewrite is supposed to guarantee.
- Tiny explicit allowlist, same shape as `check-skills-portability.sh`'s
  (`ALLOWLIST_PATH_SUFFIX`/`ALLOWLIST_TEXT`): expect **zero entries** after Parts 2+3 ship: if
  this gate ever needs an allowlist entry, that's a signal the rewrite missed a case, not a
  reason to grow the list (same philosophy CFW-312 already established).
- Exit codes mirror `check-skills-portability.sh`: 0 clean, 1 found (prints every offending
  `file:line`), 2 usage error.

**Wire it in the same three places CFW-312 wired its gate** (`scripts/sync-skills.sh`,
immediately after the existing `check-skills-portability.sh` call, aborting the sync on
failure; `test/run-tests.sh`, a new fixture-based case + a new static-guard case against the
real `skills/` tree — see Testing). Do **not** fold this into
`check-skills-portability.sh` itself — different failure semantics (a resolver-idiom match
means "this recipe will break on the render box"; a bare host-path match means "this bundle
leaks the author's identity/filesystem layout," a correctness-vs-portability-hygiene
distinction worth keeping legible in separate scripts and separate test cases).

## Part 5 — `index.json` unstamped

`scripts/sync-skills.py` (`main()`, ~line 243):

```python
index = {
    "generatedAt": None,  # filled by caller-visible timestamp below
    "release": None,
    "sourceSha": None,
    "rawBase": None,
    "recipes": {},
}
```

Only `generatedAt` is ever patched afterward (line 251). `sourceSha`/`release`/`rawBase` ship
as permanent `null` in the real, committed `skills/index.json` today (verified: `cat
skills/index.json` shows `"sourceSha": null` on current HEAD). Meanwhile
`scripts/gen-skills-manifest.sh` **reads** `index.json`'s `sourceSha`/`release` expecting them
populated (`idx.get("release", existing.get("sourceRelease"))`, `idx.get("sourceSha",
existing.get("sourceSha"))`) when rolling them into `config/skills-version.json` — it only
*looks* correct today because `scripts/sync-skills.sh` separately overwrites
`skills-version.json["sourceSha"]` with its own freshly-computed `git rev-parse HEAD` **after**
`gen-skills-manifest.sh` runs (line 159), papering over the fact that `index.json` itself never
carried the real value. Anyone/anything that reads `index.json` directly instead of
`skills-version.json` — the actual published artifact for external consumers — gets `null`
provenance.

**Fix**: `sync-skills.py` already has `args.src` (the source repo root) in scope — compute
`sourceSha` itself instead of relying on the caller (`sync-skills.sh`) to patch it in after the
fact:

```python
def git_head_sha(repo: Path) -> str | None:
    try:
        out = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except Exception:
        return None  # not a git checkout (e.g. a test fixture dir) — leave sourceSha null, don't fail the sync
...
index["sourceSha"] = git_head_sha(src_root)
```

placed right after `index["generatedAt"]` is set. This makes `index.json` self-describing on
its own, independent of `sync-skills.sh`'s separate `skills-version.json` patch (which stays,
unchanged — it's the one that already works correctly and nothing here should disturb it).

**`release` / `rawBase`**: confirmed dead. `rawBase` has no reader anywhere in the repo
(`grep -rn rawBase` finds only its own `None` assignment) — a vestige of the retired
raw.githubusercontent.com fetch-mode pipeline (`921c5b9 refactor(skills): self-contain
cfw-render — drop cfw-skills-pack, cfw-skills, fetch mode`). `release` is read defensively by
`gen-skills-manifest.sh` but `sync-skills.sh`'s own patch step explicitly *pops*
`sourceRelease` back out of `skills-version.json` right after (`m.pop("sourceRelease", None)`)
— i.e. the one caller that reads it immediately discards it. Recommendation: **leave both as
explicit, documented `None`** in `sync-skills.py` (add a one-line comment: "vestigial from the
retired git-subtree/fetch-mode pipeline — `rawBase` has no reader; `release` is read
defensively by gen-skills-manifest.sh but immediately discarded again by sync-skills.sh;
intentionally left null rather than removed to avoid an index.json schema change no consumer
asked for") rather than deleting the keys outright. This is the lower-risk call — no consumer
iterates `index.json`'s keys expecting a fixed set, and removing them is unrelated to the
actual bug (`sourceSha` is the field anything would plausibly want and is the one actually
documented as read). If the implementer disagrees and wants to delete `release`/`rawBase`
outright, that's a reasonable alternative — just confirm no external tooling outside this repo
(the fleet worker image, a dashboard) parses `index.json` expecting those keys to exist, which
is outside this worktree's visibility to verify.

## Files to touch

- `scripts/sync-skills.py` — three additions, all inside `main()`'s per-recipe loop /
  index-building, after the existing `rewrite_host_path_resolvers()` call and before
  `list_files`/hashing:
  1. New `strip_brand_override_host_paths(directory)` — structural JSON null-out (Part 2),
     targeted at `**/brand-overrides/*/brand.json` under the just-copied recipe dir.
  2. New `redact_literal_host_paths(directory)` — generic regex redaction (Part 3), run over
     every file in the just-copied recipe dir (mirrors `rewrite_host_path_resolvers`'s
     traversal, called once for the top-level recipe copy and once per `.hub/<dep>` copy, same
     two call sites `rewrite_host_path_resolvers` already has).
  3. `index["sourceSha"] = git_head_sha(src_root)` (Part 5), plus the one-line vestigial
     comment for `release`/`rawBase`. Needs `import subprocess` at top of file.
- **New `scripts/check-no-host-paths.sh`** (Part 4) — new file, sibling to
  `check-skills-portability.sh` and `check-no-worker-heygen-credential.sh`.
- `scripts/sync-skills.sh` — one new line calling `check-no-host-paths.sh` right after the
  existing `check-skills-portability.sh` call (~line 129), same abort-on-nonzero behavior.
- `test/run-tests.sh` — new fixture-based case(s) for the two new transforms + the new gate
  (next free numeric slot after the existing `Case 13c`, e.g. `Case 14`), and a new
  static-guard case against the real committed `skills/` tree (mirrors Case 11's shape for
  `check-no-host-paths.sh`).
- `test/fixtures/skills-src/` — extend the existing CFW-312 fixture tree (or add a sibling
  fixture) with: a `brand-overrides/<slug>/brand.json` carrying `outro.path`/`hero_portrait`
  set to a fake `/Users/testuser/...` path (+ `outro.relative` present, to assert it survives
  untouched), and a doc file with a bare `/Users/testuser/...` string with no resolver idiom
  around it (to exercise Part 3 independent of Part 2/CFW-312's existing fixture).
- **Real bundle regen**: after the code changes, re-run `CFW_SKILLS_SRC=<path> \
  scripts/sync-skills.sh` against the actual private source
  (`~/ecosystem/harness/skills`, per the script's own usage comment) to regenerate the real
  `skills/` tree + `skills/index.json` + `config/skills-version.json` with all three fixes
  applied, then verify `scripts/verify-skills-bundle.sh` (no args = full sweep) and the new
  `scripts/check-no-host-paths.sh` (no args) both exit 0 against the regenerated bundle. This
  step requires the private source repo to exist on the build host — same precondition
  CFW-312's own real-bundle regen had.

## Edge cases

- **A recipe's `brand-overrides/` has a slug directory with no `outro` key at all, or
  `outro.path` already `null`** (e.g. `b-vasanth`) — `strip_brand_override_host_paths` must be
  a no-op on a file it doesn't need to touch; don't rewrite-and-rewrite-identically (keeps the
  "changed files" count from the transform meaningful for a future audit, and avoids
  needlessly perturbing file mtimes/hashes for untouched recipes).
- **`outro.path` is a *relative* path already** (shouldn't happen in the current source, but
  don't assume) — only null it out when the value actually matches `^/Users/[^/]+/`; a
  relative or already-null `path` must survive untouched.
- **A future brand slug adds a *third* absolute-host-path field** beyond `outro.path` /
  `hero_portrait` — Part 3's generic redaction (which runs after Part 2, over the whole file
  including `brand-overrides/`) is the safety net that still catches it as a string, even
  though Part 2 won't structurally null it. `check-no-host-paths.sh` will fail the sync if
  Part 3 somehow misses it too — belt and suspenders, same philosophy as CFW-312.
- **`/Users/<user>` appears as a *substring* of something else entirely** (e.g. a URL, an
  unrelated identifier that happens to contain the literal text) — low risk given the existing
  `HOST_ROOT_RE`/this ticket's pattern already requires the exact `/Users/<name>/` path shape
  (not a bare `vasanth` token), but worth a negative-case fixture (a line containing `vasanth`
  with no `/Users/` prefix must NOT be touched by Part 3 or flagged by the new gate) to prove
  the regex doesn't overreach into a "never say vasanth" gate, mirroring CFW-312's own
  "BYOA / non-`vasanth` home dirs" test intent.
- **`git_head_sha()` runs against a non-git fixture dir in tests** (`test/fixtures/skills-src/`
  is a plain directory, not a git checkout) — must fail soft (return `None` → `index["sourceSha"]`
  stays `null` for fixture syncs) rather than raising, so the existing Case 10/11 fixture-sync
  tests don't break. The `try/except` around the `subprocess.run` call handles this.
- **`.hub/` dependency copies get the redaction too, not just the top-level recipe** — both new
  transforms must be called at both `rewrite_host_path_resolvers` call sites in `main()` (the
  top-level `copy_tree(recipe_src, recipe_dest)` and the per-dependency
  `copy_tree(src_root / dep, hub_dir / dep)` loop) — this is the literal mechanism by which
  "scan/strip `.hub/**`" gets satisfied, not just the gate's scan scope.
- **Binary files under `skills/`** (if any ever ship) — both new transforms must skip
  non-UTF-8-decodable files the same way `rewrite_host_path_resolvers` already does
  (`try/except (UnicodeDecodeError, ValueError): continue`).

## Testing

1. **Fixture extension for Parts 2+3**: add a `brand-overrides/fixture-brand/brand.json` (with
   `outro.path`/`hero_portrait` set to a fake absolute path, `outro.relative` present) and a
   doc file with a bare host-path string to `test/fixtures/skills-src/p-fixture-recipe/` (or a
   new fixture recipe). After `sync-skills.sh --out-dir <scratch>` against the fixture source:
   assert `outro.path` is `null`, `outro.relative` is unchanged, `hero_portrait` key is absent,
   and the doc file's path reads `/Users/<redacted>/...` (or whatever placeholder is chosen).
2. **`check-no-host-paths.sh` fixture case**: assert exit 0 on the rewritten fixture bundle,
   and (separately) exit 1 with the right `file:line` when pointed at a *deliberately
   unrewritten* fixture copy (prove the gate actually detects the thing it's meant to catch,
   not just that it passes post-fix — same "red/green" discipline CFW-312's Case 10 used).
3. **Negative case**: a fixture line containing the token `vasanth` with no `/Users/` prefix
   must NOT be touched/flagged (see Edge cases).
4. **New static-guard case** (real `skills/` tree, mirrors Case 11): `check-no-host-paths.sh`
   with no args must exit 0 against the real committed bundle — this is the one that actually
   proves the 22 files are fixed, and is the one the Dozer test gate runs on every build.
5. **`index.json` stamping**: fixture-sync case asserts `index["sourceSha"]` is `null` when
   `CFW_SKILLS_SRC` is a non-git fixture dir (soft-fail path), and a *separate* assertion
   (either a fixture turned into a real git repo via `git init` in a `setUp`-style block, or a
   check against the real bundle regen) that `sourceSha` is a 40-char hex string matching `git
   -C <source> rev-parse HEAD` when the source *is* a git checkout. Real-bundle case: after
   regen, `python3 -c "import json; d=json.load(open('skills/index.json')); assert d['sourceSha']"`
   (or equivalent bash/jq) confirms the real `index.json` is no longer permanently null.
6. **Checksum gate still passes**: `scripts/verify-skills-bundle.sh` (full sweep) must exit 0
   after the real bundle regen — proves the new transforms ran *before* hashing (same ordering
   guarantee CFW-312 established) so `index.json`'s `fileHashes` match what's actually on disk.
7. **Full `pnpm test` / `test/run-tests.sh` stays green** — additive cases only, none of the
   ~33 existing cases (including CFW-312's Case 10/11 and CFW-313's Case 12/13) should need to
   change.
8. **Manual spot-check**: after the real regen, `grep -rn "/Users/vasanth" skills/` must return
   zero results, and `cat skills/index.json | python3 -c "import json,sys; print(json.load(sys.stdin)['sourceSha'])"`
   must print a real commit SHA, not `None`/`null`.

## Out of scope (flagged, not fixed here)

- **Deleting/removing the `brand-overrides` mechanism, or Vasanth's own two brand slugs,
  entirely.** It's live and documented (CFW-128); CFW-318's job is to strip the two leaking
  *fields*, not the feature or the brands it serves.
- **Inventing a new brand-asset resolution scheme** (e.g. pulling `hero_portrait` from
  `ecosystem.yaml` or `media.cfw.social` at render time) — CFW-312 already flagged this as "a
  product decision" and explicitly deferred it; this ticket's "strip brand data" directive is
  satisfied by removing the dead/leaking fields, not by building a replacement delivery
  mechanism for them. If a recipe later actually needs `hero_portrait` at render time, that's a
  new, separate ticket.
- **`scripts/lint.sh` wiring** — CFW-312's design doc noted `lint.sh` globs `bin/`, `install/`,
  `test/`, `scripts/` and never looks at `skills/`; still true, still not this ticket's problem
  (the sync-time gate + test-suite static guard are the enforcement points, same as CFW-312).
- **cfw-render's own repo-owned files** that happen to mention `/Users/vasanth` as a legitimate
  usage example (`scripts/sync-skills.sh`'s header comment, `README.md`, `backlog/**`) — not
  vendored content, not part of the "22 files," not touched.
- **The source library** (`~/ecosystem/harness/skills`) itself — a different repo/owner outside
  this worktree's scope, same boundary CFW-312 drew. The fix lives entirely in
  `sync-skills.py`'s copy step, consistent with `skills/README.md`'s "generated, pinned
  copy — any hand edit is overwritten on the next sync" rule.
