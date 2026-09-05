# brand-overrides/ — per-brand tokens the headless Director can read

**Convention (CFW-128, 2026-09-04).** `<recipe>/brand-overrides/<cfw-brand-slug>/` may hold:

| file | read by | purpose |
|---|---|---|
| `acceptance.json` | `c-eval-runner` (`--brand <slug>`) | tighten/override gate checks (same id wins, new ids appended) — pre-existing convention |
| `brand.json` | the Director (and any recipe step that needs `brand.json`) | palette, fonts, ElevenLabs voice pin, caption style, outro asset, CTA line/handle |
| `template.html` | `p-carousel` Step 3 | brand-authored slide template replacing the recipe's generic `template.html` |

**Key = the cfw-social brand slug** — the only brand identifier the fleet Director receives (`order.json → brand.slug`). Aliases: `vasanth-sek8tv` = Mr Growth Guide (`mgg`), `b-vasanth` = Vasanth Subramanyam.

**Precedence:** `order.json` `brand.*` / `directives` > `brand-overrides/<slug>/brand.json` > recipe defaults (`#0F172A / #F97316`, `$ELEVENLABS_DEFAULT_VOICE_ID`, …). Never hard-code a palette or voice in a recipe body when an override exists.

**Usage in a recipe step:** `BRAND_JSON="$SKILL_DIR/brand-overrides/$BRAND_SLUG/brand.json"`; `p-reels-*` steps that expect `$W/brand.json` should seed it from `.palette` (`bg`, `accent`, `fg`) + `.fonts`.
