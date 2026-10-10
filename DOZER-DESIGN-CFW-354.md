# DOZER-DESIGN-CFW-354

## Task

M1-00 — Spotlight end card shows another brand's handle (live fix).

## Root cause

`skills/p-reels-spotlight/SKILL.md`, in the "Set up variables" block (lines 99-100), hardcodes
its CTA fallback defaults to a **real brand's actual copy**, not a generic placeholder:

```bash
CTA_TEXT="${CTA_TEXT:-FOLLOW FOR DAILY AI BUILDS}"
CTA_HANDLE="${CTA_HANDLE:-@mr.growthguide}"
```

`@mr.growthguide` / `"Follow for daily AI builds"` are lifted verbatim from the
`vasanth-sek8tv` brand's own config (`skills/p-reels-faceless/brand-overrides/vasanth-sek8tv/brand.json`,
`cta.line` / `cta.handle`).

Nothing in the repo (`bin/`, `scripts/`, `config/`, `lib/`) sets `CTA_HANDLE`/`CTA_TEXT` from a
brand's own `brand-overrides/<slug>/brand.json` automatically — grepped and confirmed empty. The
recipe is a markdown instruction set executed step-by-step by an agent; resolving per-brand values
is the executing agent's job, cued by the doc. `p-reels-spotlight` never cues it for the CTA card:
there's no instruction anywhere in the file telling the executor to pull `cta.line`/`cta.handle`
from the active brand's config before Step 8. So whenever a spotlight reel is rendered for *any*
brand other than `vasanth-sek8tv` and the caller doesn't happen to export `CTA_HANDLE`/`CTA_TEXT`
explicitly, the bash default silently fires — and the end card ships `vasanth-sek8tv`'s real
handle on someone else's video.

Confirmed this is isolated to `p-reels-spotlight`:
- `p-reels-split` (SKILL.md:786) and `p-reels-pip` (SKILL.md:762) use an obviously-fake generic
  placeholder default: `CTA_HANDLE="${CTA_HANDLE:-@handle}"`, `CTA_TEXT="${CTA_TEXT:-FOLLOW FOR MORE}"`.
  A placeholder that looks fake is self-flagging — nobody ships `@handle` by accident without
  noticing.
- `p-reels-spotlight` is the only file in the repo containing the literal string `growthguide`
  (repo-wide grep, excluding `.hub/` vendor copies and generated `DOZER-*` docs) — the leak is a
  single copy-paste of one real brand's CTA into a shared recipe's "default" line.
- `p-reels-spotlight-heygen` (the HeyGen wrapper that delegates into `p-reels-spotlight`) does not
  duplicate or override these defaults — confirmed by grep. No second file to patch.
- `skills/p-reels-spotlight/acceptance.json` / `examples.json` carry no handle references — no
  generated-output assertions to update.

## Fix

Two edits, both inside `skills/p-reels-spotlight/SKILL.md`, no other files touched:

### 1. Kill the dangerous default (the actual live fix)

Replace lines 99-100:

```bash
CTA_TEXT="${CTA_TEXT:-FOLLOW FOR DAILY AI BUILDS}"
CTA_HANDLE="${CTA_HANDLE:-@mr.growthguide}"
```

with the same neutral, self-evidently-fake placeholder convention already proven in
`p-reels-split` / `p-reels-pip`:

```bash
CTA_TEXT="${CTA_TEXT:-FOLLOW FOR MORE}"
CTA_HANDLE="${CTA_HANDLE:-@handle}"
```

This alone stops the cross-brand leak: worst case after this change is a visibly-generic
`@handle` card (fail-loud), never another brand's real identity (fail-silent).

### 2. Close the actual gap — cue the executor to resolve the brand's own CTA

The reason the dangerous default existed is that nothing told the executing agent to pull
`CTA_TEXT`/`CTA_HANDLE` from the active brand's own config before Step 8. Add a short mandatory
note, matching the existing "Per-brand variables ONLY" callout pattern used in `p-reels-split`
(SKILL.md:29-55), directly above the "Set up variables" block (before line 90):

```markdown
> **CTA copy/handle is per-brand — never hard-code (CFW-354).** `CTA_TEXT` / `CTA_HANDLE` below
> are PLACEHOLDERS ONLY. Before running this skill, resolve both from the active brand's own
> `cta.line` / `cta.handle` in `brand-overrides/<brand-slug>/brand.json` and export them as
> `CTA_TEXT` / `CTA_HANDLE`. If the brand config has no `cta` block, ask rather than guessing or
> reusing another brand's copy.
```

Also add two rows to the existing `## Inputs` table (alongside the `brand` row at line 69, which
already carries the "Never hard-code" language for palette/typography) so the contract is visible
without reading the step body:

| Parameter | Required | Default | Description |
|---|---|---|---|
| `cta_text` | No | brand's `cta.line` | CTA headline on the end card. Resolved from the active brand's `brand-overrides/<slug>/brand.json`. Never hard-code another brand's copy. |
| `cta_handle` | No | brand's `cta.handle` | Handle/URL on the end card. Same resolution rule as `cta_text`. |

## Files touched

- `skills/p-reels-spotlight/SKILL.md` only — two localized edits (variable defaults + one new
  callout + two Inputs-table rows). No application code, no other skill files, no brand configs.

## Edge cases

- **Brand has no `cta` block at all.** Don't fall back silently to the placeholder without
  comment — the callout says "ask rather than guessing." The placeholder still exists as the
  bash-level safety net so the step never crashes, but the instruction tells the executor not to
  treat that as acceptable final output.
- **`cta_card` is explicitly `off`.** Unaffected — Step 8 is skipped entirely per the existing
  `cta_card` input; these variables are simply unused in that path.
- **`p-reels-spotlight-heygen` callers.** Verified it has no separate CTA defaults to fix; it
  delegates straight into `p-reels-spotlight`, so the fix there covers both entry points.
- **Already-published videos rendered before this fix** (i.e. any that shipped
  `vasanth-sek8tv`'s handle on a different brand's reel). Out of scope for this issue — this is a
  forward-looking recipe fix, not a reprocessing job. Worth a follow-up ops/content audit issue if
  Vasanth wants past renders checked, but not part of this live fix.
- **Future copy-paste risk.** Any *other* skill that later clones `p-reels-spotlight`'s CTA block
  should inherit the now-generic placeholder, not a real brand's handle — this fix also prevents
  the same leak from propagating to a new recipe via copy-paste.

## How this gets tested

There is no automated pixel/content assertion on the CTA end card today — `test/run-tests.sh`
only builds a synthetic `test-brand` order through the `p-reels-spotlight` / `p-reels-spotlight-heygen`
recipes and checks the pipeline runs; it does not assert on rendered text. That gap is pre-existing
and out of scope here, but it explains why this shipped unnoticed — noted for visibility, not
fixed in this pass.

Verification for this fix is manual/inspection-based, matching how these recipe-markdown skills
are validated elsewhere in the repo:

1. **Static check** — repo-wide grep for `growthguide` and for any other skill file containing a
   real, specific brand's `cta.handle`/`cta.line` value as a bash default (the same pattern that
   caused this bug) returns no hits outside brand config files themselves.
2. **Negative case (the actual regression test for this bug)** — dry-run the spotlight recipe for
   a brand other than `vasanth-sek8tv` (e.g. `b-vasanth`) *without* exporting `CTA_HANDLE`/`CTA_TEXT`.
   Confirm the end card now renders the obviously-generic `@handle` / `FOLLOW FOR MORE` placeholder,
   never `@mr.growthguide` — i.e. the leak is gone and any remaining miss is loud, not silent.
3. **Positive case** — dry-run the spotlight recipe for `vasanth-sek8tv` (or `b-vasanth`) with the
   executor following the new callout: read `brand-overrides/<slug>/brand.json`'s `cta` block,
   export `CTA_TEXT`/`CTA_HANDLE` accordingly. Confirm the end card shows that brand's own CTA
   (`"Follow for daily AI builds"` / `@mr.growthguide` for `vasanth-sek8tv`, or `"Which one bit you
   hardest in production?"` / `growthsystems.ai` for `b-vasanth`), not a mix of brands.
4. **Regression on existing suite** — `test/run-tests.sh` still passes unchanged, since it doesn't
   assert on CTA content and the default-variable syntax is unchanged (only the fallback values
   and an added doc callout/table rows).
