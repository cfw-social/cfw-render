# Design — CFW-289: cfw-render points at the retired `~/.gsai/secrets` vault

## Bug

`~/.gsai/secrets` is a retired credential location. The current vault (per the
ecosystem's vault-first doctrine) is `~/ecosystem/vault/<app>.env` — and the
live, actively-rotated credentials for this repo already sit there:
`~/ecosystem/vault/cfw-render.env` (679 B, last written 2026-09-28, plus three
timestamped `.bak-*` rotations) and `~/ecosystem/vault/ollama-keys.env`. The
`cfw-render.env` file's own header comment even says so: `"prod API +
render-worker key from ~/ecosystem/vault/cfw-render.env"`. Meanwhile
`~/.gsai/secrets/` on this box holds exactly one unrelated file
(`sten-sten.env`) — no cfw-render credentials have lived there for some time.

But `bin/cfw-render-lib.sh` still hardcodes `~/.gsai/secrets/*` as the default
path for three separate credential loads:

| Default var | Line | Retired default |
|---|---|---|
| `CFW_RENDER_ENV` | `cr_load_config` (line 164) | `~/.gsai/secrets/cfw-render.env` |
| `CFW_RENDER_ADMIN_ENV` | `cr_load_admin_config` (line 382) | `~/.gsai/secrets/cfw-render-admin.env` |
| `CFW_RENDER_OLLAMA_KEYS_FILE` | `cr_load_config` (line 187) / used at line 543 | `~/.gsai/secrets/ollama-keys.env` |

**Why this is a *silent* miss, not just a wrong path:** `cr_load_config`'s
cascade is "process env wins over both files" (by design — see the comment at
`bin/cfw-render-lib.sh:136-138`). If a shell/profile/systemd unit already
exports a stale `CFW_RENDER_WORKER_KEY`/`CFW_API_BASE` (e.g. from before a
rotation), the retired-path env file never gets read (it doesn't exist), the
"missing required var" check never fires because the stale value *is*
present, and the worker runs against the wrong/expired credential with zero
error — the rotation recorded in `~/ecosystem/vault/cfw-render.env` (and its
`.bak-*` history) is invisible to it. The ollama-keys path is a quieter
variant: `[[ -f "$keysfile" ]] && source` silently no-ops if the retired path
doesn't exist, and `claude_ollama_failover` degrades to "no working account"
without ever naming the real reason (wrong default path).

`install/provisioner-snippet.md:28` shows how this drifted: it literally
writes *"Pull it from the vault (`~/.gsai/secrets/cfw-render.env`)"* —
conflating the retired path with "the vault" by name.

This is a documentation-plus-defaults bug, not a logic bug: the cascade,
fail-fast validation, and "never print values" behavior in
`cr_load_config`/`cr_load_admin_config` are all correct and untouched. Only
the hardcoded default path *strings* (in code, example config, and docs) are
wrong.

## Approach

Repoint every retired-vault default to the real one, and add a regression
test so it can't silently drift back.

1. **Code — `bin/cfw-render-lib.sh`.** Change the three defaults:
   - `$HOME/.gsai/secrets/cfw-render.env` → `$HOME/ecosystem/vault/cfw-render.env`
   - `$HOME/.gsai/secrets/cfw-render-admin.env` → `$HOME/ecosystem/vault/cfw-render-admin.env`
   - `$HOME/.gsai/secrets/ollama-keys.env` → `$HOME/ecosystem/vault/ollama-keys.env`

   Also update the three doc-comments directly above each (lines ~136-138,
   ~370-373, and the `claude_ollama_failover` docstring at ~505) that spell
   out the old path in prose, plus the "SECURITY — READ THIS" block in
   `bin/cfw-render-fleet.sh` (line 18) which repeats the admin-env default.

   No behavioral/cascade change — same `[[ -r ]]`/`[[ -f ]]` checks, same
   process-env-wins precedence, same fail-fast error format (the error
   already interpolates `$env_file`, so the printed message self-corrects
   once the default does).

2. **Shipped example config — `config/cfw-render.env.example`.** Update the
   header's load-order comment and the "copy this file to..." instruction to
   point at `~/ecosystem/vault/cfw-render.env`.

3. **Docs in this repo** (all prose-only, same substitution):
   - `README.md` — the skills-dir override aside, the "Env from the vault"
     step-2 walkthrough, the `cp config/cfw-render.env.example ...` usage
     line, the operator fleet-enable comment, the "Load order" sentence, and
     the Ollama-keys section (keep the *contrast* with the historical
     `~/.gsai/secrets/zai.env` mistake — that's explaining a past task-text
     error about the wrong *file*, not the retired *directory* — but fix the
     "proven production recipe" path itself to the vault).
   - `docs/deploy.md` — prerequisites (§0), pre-flight checklist (§1), the
     fleet-enable operator instructions (§6.1), and the rotation runbook
     (§9).
   - `docs/PACKAGING-DESIGN.md` — the two mentions of the load cascade and
     the ollama-keys fan-out helper.
   - `install/provisioner-snippet.md` — fix the line that mislabels
     `~/.gsai/secrets/cfw-render.env` as "the vault"; it should say
     `~/ecosystem/vault/cfw-render.env`.

4. **Out of scope — leave untouched:**
   - `/etc/cfw-render.env` (the Linux-box file) and anything in
     `install/install.sh` that manipulates it — that's a box-local file
     populated *by copying values out of* the vault; it was never the vault
     path itself and isn't part of this bug.
   - `backlog/queue/AB-RNDR-WORKER.md`, `backlog/done/2026-07/AB-RNDR-WORKER.md`,
     and `backlog/attachments/AB-RNDR-WORKER/implementation-plan.md` — these
     are dated historical task records of decisions made when
     `~/.gsai/secrets` *was* the live convention. Rewriting history in a
     backlog record would misrepresent what was actually decided at the
     time; the correction belongs in the live code/docs, not the archive.
   - `~/ecosystem/vault/cfw-render-admin.env` does not exist yet (only
     `cfw-render.env` and `ollama-keys.env` are currently seeded). That's an
     operator action (mint the master key into the vault under its new
     expected filename), not a code change — `cr_load_admin_config` already
     fails fast with a clear "checked $admin_env" message if it's absent, and
     per the vault-first secret-capture rule, whoever next needs
     `CFW_MASTER_API_KEY` for the fleet-enable helper writes it to
     `~/ecosystem/vault/cfw-render-admin.env` at that point. Flagging this
     for Vasanth in the eventual PR/board note, not fixing it in code.

## Files to touch

- `bin/cfw-render-lib.sh` (3 default-path constants + their doc-comments)
- `bin/cfw-render-fleet.sh` (1 doc-comment)
- `config/cfw-render.env.example` (header comment)
- `README.md` (6 mentions)
- `docs/deploy.md` (4 mentions)
- `docs/PACKAGING-DESIGN.md` (2 mentions)
- `install/provisioner-snippet.md` (1 mention)
- `test/run-tests.sh` (new regression case, see below)

## Edge cases

- **Process-env-wins precedence must survive untouched.** The fix only
  changes the *fallback literal*, not the cascade logic — a caller that
  already exports `CFW_RENDER_ENV`/`CFW_RENDER_ADMIN_ENV`/
  `CFW_RENDER_OLLAMA_KEYS_FILE` (every existing test case does this) is
  unaffected either way.
- **No live cfw-render file actually exists under `~/.gsai/secrets` today**
  (confirmed: only `sten-sten.env` is there) — so there is no migration
  window to protect; nothing currently depends on the old default resolving.
  No dual-path fallback should be added (checking old-path-then-new-path
  silently would reintroduce exactly the "silent fallback" failure mode
  CLAUDE.md's Fail Fast rule forbids) — this is a clean cutover, not a
  compat shim.
- **`/etc/cfw-render.env` (the box path) is untouched** — verify the diff
  doesn't accidentally touch install.sh's `ENV_FILE="/etc/cfw-render.env"`
  default; that one is correct as-is and out of scope.
- **The admin-env file doesn't exist in the vault yet.** After the path
  fix, `cfw-render-fleet.sh` on an operator machine with no
  `CFW_MASTER_API_KEY` exported will fail fast naming the *new* (still
  absent) path — correct behavior, just needs the operator to seed it once.
  Not a code defect to fix here.
- **Don't touch dated backlog/implementation-plan records** — they're a
  historical log of what was true when written, not live documentation.

## How it gets tested

`test/run-tests.sh` never actually exercises default-path resolution today —
every existing case explicitly overrides `CFW_RENDER_ENV` /
`CFW_RENDER_OLLAMA_KEYS_FILE` / `CFW_RENDER_ADMIN_ENV` to fixture/nonexistent
paths (e.g. line 94, line 98, line 538), so none of them will catch a wrong
*default*. Two additions close that gap:

1. **New behavioral case — "default credential paths resolve into
   `~/ecosystem/vault`, not `~/.gsai/secrets` (CFW-289)".** Added after the
   existing Case 7 (fleet-enable), following the same `run_case`-adjacent
   style used for one-off assertions (Case 7 already calls
   `cr_load_admin_config`/`cfw-render-fleet.sh` directly rather than through
   `run_case`). Plan:
   - Unset `CFW_RENDER_ENV`, `CFW_RENDER_ADMIN_ENV`, and
     `CFW_RENDER_OLLAMA_KEYS_FILE` in a subshell, leave `CFW_API_BASE`/
     `CFW_RENDER_WORKER_KEY` unset too, and invoke `cr_load_config` (source
     `bin/cfw-render-lib.sh`, call the function directly — it's already
     designed to be sourced, see how `bin/cfw-render.sh` uses it) with the
     real `$HOME` in effect.
   - Assert the resulting stderr ("missing required config var(s) ...
     checked ... <path> ...") contains `ecosystem/vault/cfw-render.env` and
     does **not** contain `.gsai`.
   - Do the same for `cr_load_admin_config` (expect
     `ecosystem/vault/cfw-render-admin.env`, no `.gsai`) and for the
     ollama-keys warn row surfaced by `cfw-render.sh --dry`'s `--dry` health
     table (`bin/cfw-render.sh:82-85`) (expect
     `ecosystem/vault/ollama-keys.env`, no `.gsai`).
2. **Static guard.** A one-line grep assertion in the suite (or a small new
   case) that `grep -rn '\.gsai/secrets' bin/ lib/ config/ install/*.md
   README.md docs/` (explicitly excluding `backlog/`, which is intentionally
   left as historical record) returns nothing, exit non-zero for the whole
   suite if it does. Cheap, and directly prevents this class of drift from
   being reintroduced by a future doc edit that copies old prose.

Both additions run inside the existing `set -u`, `pass`/`fail` counter
harness already in `test/run-tests.sh` — no new test infra needed. Full
suite re-run (`test/run-tests.sh`) must still finish clean end-to-end (per
the CFW-292 fix that unblocked the 900 s test-gate budget) with the two new
cases passing.
