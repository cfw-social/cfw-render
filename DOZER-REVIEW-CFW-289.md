VERDICT: PASS

## What was checked

1. **Factual basis for the bug** — verified directly on disk:
   - `~/.gsai/secrets/` contains only `sten-sten.env` (unrelated); no cfw-render credentials live there.
   - `~/ecosystem/vault/cfw-render.env` (679 B) and `~/ecosystem/vault/ollama-keys.env` (2116 B) exist and are the live, current credentials.
   - `~/ecosystem/vault/cfw-render-admin.env` does not yet exist, matching the design's "out of scope — operator action" call.

2. **Code changes match the design exactly.** All three hardcoded defaults in `bin/cfw-render-lib.sh` were repointed from `~/.gsai/secrets/*` to `~/ecosystem/vault/*`:
   - `CFW_RENDER_ENV` default (line 164) — `cr_load_config`
   - `CFW_RENDER_ADMIN_ENV` default (line 382) — `cr_load_admin_config`
   - `CFW_RENDER_OLLAMA_KEYS_FILE` default (line 187, used at line 543) — `claude_ollama_failover`

   The cascade/precedence logic (process env wins over both files, fail-fast on missing vars, never-print-values) is untouched — only the literal fallback strings changed, as the design required. Doc-comments above each of the three defaults, plus the `cfw-render-fleet.sh` "SECURITY — READ THIS" block, were updated in lockstep.

3. **Out-of-scope items correctly left alone:**
   - `install/install.sh`'s `ENV_FILE="/etc/cfw-render.env"` default is untouched (grepped — no changes).
   - `backlog/` historical records are untouched (`git diff --stat -- backlog/` empty).
   - The one remaining `.gsai` mention in `README.md` ("The task text originally said `~/.gsai/secrets/zai.env`...") is the intentional historical note about a different past mistake (wrong file, not the retired directory), and is explicitly excluded by name in the Case 9 static guard.
   - No dual-path fallback was added — clean cutover, consistent with the Fail Fast doctrine.

4. **Docs updated consistently**: README.md (6 spots), docs/deploy.md, docs/PACKAGING-DESIGN.md, install/provisioner-snippet.md, config/cfw-render.env.example — all now point at `~/ecosystem/vault/`.

5. **Tests**: ran `test/run-tests.sh` end-to-end (real execution, not just reading the diff). **59/59 pass**, including the two new regression cases:
   - Case 8: `cr_load_config`, `cr_load_admin_config`, and `cfw-render.sh --dry`'s ollama-keys health row all resolve default paths into `~/ecosystem/vault/`, with no `.gsai` mention — run under an isolated throwaway `$HOME`/mock server, not the live vault.
   - Case 9: static grep guard confirms no live `.gsai/secrets` reference remains in `bin/lib/config/install/README/docs` (backlog correctly excluded).

   Suite completed in ~2 min with 0 orphans (consistent with the CFW-292 fix already merged into this branch's base). Full lint + shellcheck pass clean too.

## Minor, non-blocking note

Line 451 of the *pre-existing* test suite (Case 4c, `needs: command not found`) prints a harmless stray shell error unrelated to this diff — it isn't part of the CFW-289 changes and doesn't affect pass/fail counts (test still reports PASS). Not a regression introduced here; not blocking.

## Conclusion

Implementation faithfully follows the design: minimal, surgical default-path fix, explicit non-goals honored, new regression coverage that would have caught the original bug (a default resolving to the wrong path with no live symptom until something silently used stale creds). Verified against real on-disk vault state and a full green test run, not just diff inspection.
