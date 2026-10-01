VERDICT: PASS

## Summary

The build implements all 5 parts of DOZER-DESIGN-CFW-318.md faithfully and the real vendored bundle is now clean. Verified independently (not just trusting the diff):

- `grep -rl "/Users/vasanth" skills/` → **0 files** (was 22; all 18 generic files + 4 brand-overrides files fixed).
- `scripts/verify-skills-bundle.sh` → PASS, 14 recipes / 1150 files match `index.json` hashes — proves the new transforms ran *before* hashing, same ordering guarantee CFW-312 established.
- `skills/index.json`: `sourceSha` is now `4c247e1484fcf762ee647bfcf455b6a1e6738a9d` (a real SHA, matches `config/skills-version.json`'s `sourceSha`), `release`/`rawBase` intentionally left `null` with a documented rationale, as the design recommended.
- `test/run-tests.sh` → **116/116 PASS**, including all new CFW-318 cases (14, 14a, 14b, 14c) plus the pre-existing suite (CFW-312/313's Case 10-13, CFW-291's Case Q1-Q7, fan-out Case F) — nothing regressed.

## Design-vs-build check, part by part

- **Part 1 (inventory)**: all 22 files from the design's exact list appear in the diff; no extras, no omissions.
- **Part 2 (brand-overrides strip)**: `strip_brand_override_host_paths()` nulls `outro.path` and drops `hero_portrait` only when the value matches `^/Users/[^/]+/`; `outro.relative` and all other brand.json fields survive untouched in the real diff (verified: `b-vasanth/brand.json` is unchanged, `vasanth-sek8tv/brand.json` in all 4 locations shows exactly `path: null` + `hero_portrait` key removed, nothing else).
- **Part 3 (generic redaction)**: `redact_literal_host_paths()` uses the same `/Users/[A-Za-z0-9_.\-]+(?=/)` pattern as the gate, replaces with `/Users/<redacted>`, runs over every file including re-running over brand.json as a safety net (as designed). Call-site placement matches `rewrite_host_path_resolvers`'s two existing call sites (top-level recipe copy + per-`.hub/<dep>` loop).
- **Ordering**: Part 2 runs before Part 3 at both call sites, both after `rewrite_host_path_resolvers()` and before `list_files`/hashing — exactly as specified.
- **Part 4 (gate)**: new `scripts/check-no-host-paths.sh` is a separate script (not folded into `check-skills-portability.sh`), same CLI shape, same exit-code contract (0/1/2), wired into `sync-skills.sh` right after the existing portability check. Test Case 14a proves red/green discipline (fails on a deliberately unrewritten host path, not just passes post-fix).
- **Part 5 (index.json stamping)**: `git_head_sha()` is a best-effort `git -C <repo> rev-parse HEAD` with try/except → `None` on failure, exactly the soft-fail behavior the design and edge-cases section required for non-git fixture dirs. Case 14 confirms the soft-fail path (fixture copied *outside* the repo tree, confirming the test correctly avoids the "resolves to cfw-render's own HEAD" trap); Case 14c confirms the real-git-repo path with an actual `git init` fixture and asserts the stamped SHA matches `git rev-parse HEAD`.

## Minor observations (non-blocking)

- `release`/`rawBase` are left as documented vestigial `None` rather than removed — the design doc explicitly flagged this as the lower-risk, acceptable call, and the implementer followed that recommendation rather than the alternative.
- Out-of-scope items (cfw-render's own `sync-skills.sh` header comment, `README.md`, `backlog/**`, the source library) were correctly left untouched, consistent with the design's scope boundary.

No correctness, security, or scope issues found. Build matches the architect's plan.
