# AB-RNDR-WORKER — Implementation Plan

**Architect pass, 2026-07-09.** Code-authoring only — nothing here touches hst.
Sources studied: `cfw-social/docs/cfw-render-worker-plan.md` (§2–§9),
`cfw-social/docs/render-worker-auth.md`, `~/ecosystem/ab-hustler/ab-hustler.sh`
(marketing lane, lines ~1452–1900), `~/ecosystem/ab-hustler/ab-lib.sh:76-140`
(`claude_ollama_failover` / `claude_native_or_ollama_quota_fallback`),
`~/ecosystem/ab-hustler/ab-lock.sh`, and the live cfw-social surfaces:
`src/lib/mcp/tools/render-order-worker.ts`, `src/lib/mcp/contracts.ts:384-431`,
`src/app/api/v1/render/upload/route.ts`, `src/app/api/v1/mcp/route.ts`.

---

## 0. Ground truths that shape the design

1. **The 4 worker tools are plain HTTP JSON-RPC.** `/api/v1/mcp` with the
   `cfw-render-key` header uses a *stateless* streamable-HTTP transport with
   `enableJsonResponse: true` (`route.ts:52-58`), so a bare
   `curl -X POST … -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{…}}'`
   works with no initialize handshake — verified pattern in
   `cfw-social/docs/mcp-brand-context-smoke.md` ("Manual curl reference").
   Tool results come back as `result.content[0].text` containing JSON — parse twice.
   Exact input shapes (from `contracts.ts:384-431`):
   - `claim_render_order {workerId}` → `{order: {id, brandId, workspaceId, kind, recipe, status, taskOrder, priority, attempts} | null}`
   - `append_render_event {orderId, workerId, kind, stage?, message, pct?, model?}` — extends lease +30 min; first `kind:"stage"` bumps claimed→rendering
   - `complete_render_order {orderId, workerId, outputUrl, models?{director,fanout[],escalated}}` — outputUrl must contain `brands/<brandId>/renders/<orderId>/`
   - `block_render_order {orderId, workerId, reason}`

2. **`cfw-upload` cannot be reused as-is.** The provisioned helper
   (`cfw-provisioner/src/lib/tmpl/cfw-upload.sh`) posts to `/api/v1/media/upload`
   with the **brand** `x-api-key` — the render worker holds neither. The worker
   uploads to **`POST /api/v1/render/upload`** (multipart `files` + `orderId` +
   `workerId`, header `cfw-render-key`), response `{assets:[{cdnUrl,mimeType}]}`
   (`render/upload/route.ts:36`). We *model* our upload helper on cfw-upload.sh
   (concurrent curls, mime map, ERROR marker, never-fallback) but point it at the
   render route. This is the AC's "via cfw-upload" honored at the pattern level —
   the credential makes literal reuse impossible.

3. **Box-local lock ≠ ab-lock.sh.** `ab-lock.sh` is sqlite + zsh and lives in
   `~/ecosystem` on the Mac; hst won't have it and order-level mutual exclusion is
   already provided server-side (claim is a DB CAS + 30-min lease). The only thing
   the box lock must prevent is **two overlapping drainer ticks**. A portable
   `mkdir`-based tick lock with a stale-age self-heal (same shape as ab-hustler's
   batch lock) is sufficient. Reuse rung 3 (coreutils), not a vendored sqlite tool.

4. **Server-side gap — no requeue surface (FLAG, do not paper over).**
   Nothing on either MCP surface can flip `blocked → queued` or reclaim an
   expired-lease `claimed/rendering` row: both claim tools take only
   `status='queued'` (`render-order-worker.ts:102-119`, `render-orders.ts:419-422`)
   and `requireClaimedOrder` 403s expired leases *even for the original workerId*
   (auth doc §6). Consequences:
   - Director timeout/crash **while the drainer is alive** → fully handled
     (drainer holds a live lease and calls `block_render_order`). This is the
     dominant failure mode and it works today.
   - **Drainer death mid-render** (rare: power loss, SIGKILL) → the order strands
     in `claimed` with an expired lease. Requeue needs a ~5-line cfw-social change
     (extend the worker-claim CAS WHERE to also take
     `status IN ('claimed','rendering','gating') AND lease_expires_at < now()`),
     or a `requeue_render_order` worker tool. **Out of scope for this repo** —
     the dev must file a follow-up task (suggested id `AB-RNDR-REQUEUE`, repo
     cfw-social) and document the gap in `docs/deploy.md`.
   - `cfw-render-ctl.sh unblock <orderId>` ships as a verb that **calls
     `requeue_render_order` via the worker MCP** (forward-compatible), and until
     that tool lands it must exit non-zero with a precise error naming the
     follow-up task + the manual SQL an admin can run. Fail fast, no silent no-op.

5. **hst is Linux (systemd), dev box is macOS (launchd)** — gateway units on hst
   are `cfw-gw@<slug>` systemd units (`cfw-provisioner/src/core/gateway.ts`), the
   hustler runs from `~/Library/LaunchAgents/com.gsai.ab-hustler.plist` locally.
   Ship both unit templates; scripts are **bash** (`#!/usr/bin/env bash`), not zsh
   (AC says "host-agnostic bash"; zsh isn't guaranteed on the VPS). The two
   failover functions vendored from `ab-lib.sh:76-140` must be **ported to bash**
   (they use `emulate -L zsh` / `typeset -ga` today) — cite provenance in a comment.

6. **Skills/recipes on the box** live at `/data/shared/cfw-skills/cfw`
   (`cfw-provisioner/src/lib/tmpl/config.yaml.hbs:88-90`); local source is
   `Code/cfw/cfw-skills-pack`. Make it a knob: `CFW_RENDER_SKILLS_DIR`
   (default `/data/shared/cfw-skills/cfw`, overridable for local dev).

7. **Ollama Cloud keys**: the *working production recipe* is
   `~/.gsai/secrets/ollama-keys.env` (`OLLAMA_KEY_GOOFY_HUGLE_463_B`,
   `OLLAMA_KEY_RECURSING_PIKE_357`) via `ANTHROPIC_BASE_URL=https://ollama.com` +
   `ANTHROPIC_AUTH_TOKEN` — exactly `claude_ollama_failover`. The task text says
   `zai.env`; that file holds z.ai creds (`ZAI_API_KEY`). Default to
   `CFW_RENDER_OLLAMA_KEYS_FILE=~/.gsai/secrets/ollama-keys.env` (the proven
   path) and let the env file override — both files get sourced if present.
   Note the discrepancy in README so nobody chases a "missing" zai key.

8. **`~/.gsai/secrets/cfw-render.env` does not exist yet** (checked). `install.sh`
   and `--dry` must treat "key file missing" as a first-class, clearly-reported
   condition (per AB-RNDR-AUTH §5.2 it is created at deploy time by a human).

---

## 1. Repo layout (all new files — this repo is an empty scaffold)

```
bin/
  cfw-render.sh            # the drainer — one tick per invocation
  cfw-render-lib.sh        # sourced lib: config, log, mcp_call, failover (bash port)
  cfw-render-ctl.sh        # status | run-now | unblock <orderId> | logs
  cfw-render-report.sh     # Director-facing: stage | complete | block
  cfw-render-subagent.sh   # Director-facing: GLM/Kimi fan-out wrapper
  cfw-render-upload.sh     # Director-facing: upload → /api/v1/render/upload
lib/
  director-prompt.md       # Director dispatch prompt template (placeholder-substituted)
config/
  cfw-render.env.example   # every knob, commented
install/
  install.sh               # macOS+Linux installer (guard-railed, never auto-targets hst)
  com.cfw.render.plist     # launchd template (macOS)
  cfw-render.service       # systemd oneshot unit (Linux)
  cfw-render.timer         # systemd timer, 15-min cadence
  provisioner-snippet.md   # block for cfw-provisioner so reprovision reinstalls the timer
docs/
  deploy.md                # SUPERVISED deploy runbook (gate at bottom of task)
test/
  mock-server.py           # stdlib-only mock of /api/v1/mcp + /api/v1/render/upload
  fake-director.sh         # scripted director: events → upload → complete/block
  run-tests.sh             # lint + behavioral suite against the mock
scripts/
  lint.sh                  # bash -n everything + shellcheck when available
package.json               # {"scripts":{"lint":"scripts/lint.sh","test":"test/run-tests.sh"}}
README.md                  # update: usage, knobs, zai.env note (file exists — extend)
```

New-file justifications (reuse ladder): every component either *cannot* be reused
(§0.2 credential mismatch, §0.3 zsh/sqlite, §0.5 zsh→bash port) or doesn't exist
anywhere (drainer, ctl, director prompt, units, runbook). No new runtime
dependency: bash + curl + python3 (for JSON, same choice as ab-hustler) + coreutils.
`shellcheck` is a dev-only nicety, `jq` deliberately avoided (not on the box).

---

## 2. Config surface (`config/cfw-render.env.example`)

| Var | Default | Meaning |
|---|---|---|
| `CFW_API_BASE` | — (required) | cfw-social base, e.g. `https://app.cfw.social` |
| `CFW_RENDER_WORKER_KEY` | — (required) | the scoped `cfw_render_…` key |
| `CFW_RENDER_ENV` | `~/.gsai/secrets/cfw-render.env` | env file loaded first (then `/etc/cfw-render.env` on Linux) |
| `CFW_RENDER_CONCURRENCY` | `1` | max parallel Director subprocesses per tick (DECISION LOCKED) |
| `CFW_RENDER_SCRATCH` | `$HOME/cfw-render-scratch` | scratch root (§9 layout; confirm on box at deploy) |
| `CFW_RENDER_STATE_DIR` | `$HOME/.cfw-render` | tick lock, journal.tsv, runs/ output logs |
| `CFW_RENDER_SKILLS_DIR` | `/data/shared/cfw-skills/cfw` | recipes + gate skills root |
| `CFW_RENDER_DIRECTOR_MODEL` | `sonnet` | Director primary model |
| `CFW_RENDER_FANOUT_MODELS` | `glm-5.2,kimi-k2` | models the subagent helper accepts |
| `CFW_RENDER_TIMEOUT_VIDEO` | `1800` | watchdog secs, `kind=video` (≤ server 30-min lease) |
| `CFW_RENDER_TIMEOUT_IMAGE` | `900` | watchdog secs, `kind=image` |
| `CFW_RENDER_GATE_FAIL_CAP` | `2` | gate FAILs before block (AC) |
| `CFW_RENDER_OLLAMA_KEYS_FILE` | `~/.gsai/secrets/ollama-keys.env` | fan-out + quota-failover keys |
| `CFW_RENDER_DIRECTOR_CMD` | (empty = real `claude` spawn) | test seam — command run instead of the Director |

`workerId` is computed, not configured: `"$(hostname -s):$$"` (host+pid, per auth
doc §2 — hygiene, not security).

---

## 3. `bin/cfw-render-lib.sh` — the shared core

- `cr_load_config` — source `/etc/cfw-render.env` (if readable), then
  `$CFW_RENDER_ENV`, then process env wins. Validate required vars; key must match
  `^cfw_render_`. Fail fast with exact missing-var names (never print values).
- `cr_log` — `date '+%F %T' [cfw-render] …` append to
  `$CFW_RENDER_STATE_DIR/cfw-render.log` (mirror `ab-lib.sh:63`).
- `cr_mcp_call <tool> <json-args>` — the single curl JSON-RPC wrapper (pattern:
  `mcp-brand-context-smoke.md`): headers `cfw-render-key`, `content-type:
  application/json`, `accept: application/json, text/event-stream`,
  `--max-time 30`, 2 retries with backoff on curl-level failure. Pipe through a
  python3 one-liner that unwraps `result.content[0].text` (or `error`) and prints
  the inner JSON; non-zero exit on JSON-RPC error / `isError`. All JSON built with
  `python3 -c 'import json…'` (never string-interpolated — order messages contain
  quotes).
- `cr_event <orderId> <kind> <stage> <message> <pct> [model]` — thin
  `append_render_event` wrapper; **never fails the caller** (progress is
  best-effort; log on error).
- `claude_ollama_failover` + `claude_native_or_ollama_quota_fallback` — **bash
  ports** of `ab-lib.sh:76-140` (provenance comment). Same account order
  goofy_hugle → recursing_pike, same rate-limit regex, same "non-quota failure
  does not burn the 2nd account" rule. The native-first variant additionally
  echoes which model actually served (`sonnet` vs `glm-5.2`) to a caller-supplied
  state file so the Director-model rollup is truthful.
- `cr_tick_lock_acquire / _release` — `mkdir "$STATE_DIR/tick.lock"`; on EEXIST
  read its `pid+ts` file: stale when older than `TIMEOUT_VIDEO + 600` **or** pid
  dead → remove + retake (ab-hustler batch-lock semantics, no sqlite — §0.3).

## 4. `bin/cfw-render.sh` — the drainer (one tick per invocation)

```
parse flags: --once (default behavior; accepted for AC compat) | --dry
cr_load_config
[--dry] → validation only:
    binaries: curl, python3, claude (warn-only: ffmpeg, shellcheck)
    dirs: scratch writable, skills dir exists (warn), state dir
    keys: CFW_RENDER_WORKER_KEY shape, ollama keys file presence (warn)
    live check WITHOUT claiming: cr_mcp_call tools/list → assert the 4 worker
      tools are present (proves key + route, claims nothing)
    print PASS/FAIL table, exit 0/1.  ← AC "claims nothing but validates config
                                        + credential presence"
cr_tick_lock_acquire || exit 0        # another tick is live — quiet no-op
janitor: rm -rf scratch/*/* older than 48h (leftover forensics from failed runs)
for slot in 1..$CFW_RENDER_CONCURRENCY:
    order_json=$(cr_mcp_call claim_render_order {workerId})
    order == null → break             # queue empty or lost CAS race
    spawn_director "$order_json" &    # background; collect pid + orderId
wait all; per-order post-mortem; cr_tick_lock_release
```

`spawn_director` (mirrors `ab-hustler.sh:1720-1742` spawn+watchdog):
1. Parse `id, brandId, kind, recipe, taskOrder` (python3). Sanitize
   `brandSlug=[a-z0-9-]` from `taskOrder.brand.slug` (fallback `brandId`).
   Malformed/missing `taskOrder.brand` → `block_render_order "order was
   underspecified — missing brand context"` and return (owner-safe words, plan §6
   rule of thumb).
2. Scratch per §9: `$SCRATCH/<brandSlug>/<orderId>/{order.json,ingredients,clips,work,final}`;
   write `order.json`.
3. Build the Director prompt from `lib/director-prompt.md` (python3 template
   substitution — NOT shell interpolation) with: order path, helper names, skills
   dir, gate id (`taskOrder.acceptance.gate`, fallback by kind:
   video→`c-shorts-qa-gate`, image→`c-vision-qa`), fail cap, timeout budget.
4. Emit `cr_event … stage fetch-assets "Gathering ingredients" 5`.
5. Spawn: `cd <scratch order dir>` and either `$CFW_RENDER_DIRECTOR_CMD` (test
   seam) or `claude_native_or_ollama_quota_fallback "<orderId>" \
   "$CFW_RENDER_DIRECTOR_MODEL" "$RUNS_DIR/<orderId>-<ts>.out" -- -p "$PROMPT" \
   --dangerously-skip-permissions --output-format text` with env:
   `CFW_ORDER_ID, CFW_WORKER_ID, CFW_API_BASE, CFW_RENDER_WORKER_KEY,
   CFW_RENDER_SCRATCH_DIR, CFW_RENDER_STATE_DIR, CFW_RENDER_OLLAMA_KEYS_FILE,
   CFW_RENDER_FANOUT_MODELS`, and `PATH=<repo bin>:$PATH` so the Director calls
   helpers by bare name. Watchdog: `( sleep $timeout_by_kind; kill -TERM $pid;
   sleep 30; kill -KILL $pid ) &` (ab-hustler pattern + KILL escalation).
6. Post-mortem (Director exited; drainer's lease is still live because helper
   calls heartbeat):
   - `.outcome` file exists (written by report helper) → trust it; on `complete`
     wipe the whole order scratch dir (AC "ephemeral, wiped after upload"); on
     `block` keep scratch for the 48-h janitor.
   - exit 143/137, no `.outcome` → `block_render_order "render exceeded the time
     budget"`.
   - any other exit, no `.outcome` → `block_render_order "render failed
     unexpectedly"` (raw error stays in the runs log, never in the reason —
     owner-safe contract).
   - if the block call itself fails → log loudly; lease expiry is the (flagged,
     §0.4) backstop.
   - append journal line: `ts orderId brandSlug kind outcome exit model` to
     `$STATE_DIR/journal.tsv`.

## 5. Director-facing helpers (what the headless CD actually calls)

- **`bin/cfw-render-report.sh stage <stage> <pct> <message>`** →
  `append_render_event {kind:"stage", …}` (doubles as the lease heartbeat — every
  stage +30 min, `render-order-worker.ts:177-188`).
  **`… complete <fileOrUrl>`** → if arg is a local file, upload via
  `cfw-render-upload.sh` first; build `models` rollup: director model from the
  failover state file, fanout list from `work/.models-fanout` (deduped), then
  `complete_render_order`; verify returned `ok:true`; write `.outcome=complete`.
  **`… block <reason>`** → `block_render_order` + `.outcome=block`.
  Reads `CFW_ORDER_ID`/`CFW_WORKER_ID` from env — the Director never handles ids.
- **`bin/cfw-render-subagent.sh <model> -p <prompt> [claude args…]`** — validates
  model ∈ `CFW_RENDER_FANOUT_MODELS`, runs the bash-ported
  `claude_ollama_failover` (goofy→pike), appends the model to
  `work/.models-fanout`, and emits `append_render_event {kind:"subagent",
  model:<model>, message:"Prep station working", stage:<caller-supplied|fanout>}`
  — AC "record per-stage model" satisfied mechanically, not by trusting the
  Director's memory.
- **`bin/cfw-render-upload.sh <file…>`** — modeled on cfw-upload.sh (mime map,
  concurrent curls, ordered output, ERROR marker, non-zero if any fail, never a
  fallback host) but: `POST $CFW_API_BASE/api/v1/render/upload`, header
  `cfw-render-key`, extra form fields `orderId` + `workerId` from env; parse
  `assets[i].cdnUrl`.

## 6. `lib/director-prompt.md` — the Creative Director dispatch

Contents (template placeholders in `{{…}}`): you are the Creative Director for
render order `{{orderId}}`; **read ONLY `order.json` + recipe/skill files under
`{{skillsDir}}` — never the brain, never any brand DB, never the network except
CFW Media URLs in the order** (AC "self-contained"); fetch every ingredient URL
into `ingredients/` (curl, retry once; any 4xx/5xx after retry →
`cfw-render-report.sh block "ingredients unavailable"`); follow recipe
`{{recipe}}`; delegate grunt work (per-clip renders, ffmpeg passes, per-slide
HTML) to `cfw-render-subagent.sh glm-5.2|kimi-k2 -p "…"`; report every stage via
`cfw-render-report.sh stage <stage> <pct> "<kitchen-safe message>"` using the
canonical stages `fetch-assets → render-clips → assemble → grade → vision-qa`;
run the acceptance gate `{{gate}}` per the recipe's `acceptance.json`, writing
`scorecard.json` to the order dir; on FAIL fix and re-render — after
`{{failCap}}` FAILs call `cfw-render-report.sh block "gate: <dimension> below
floor"`; on PASS put the deliverable in `final/` and call `cfw-render-report.sh
complete final/<file>`; your **last action must be exactly one** `complete` or
`block`; you have `{{timeoutMin}}` minutes total; messages you send to events are
owner-visible — kitchen language, never model names, errors, or costs.

## 7. `bin/cfw-render-ctl.sh` (mirrors `ab-hustler-ctl.sh` verb style)

- `status` — tick-lock state (+age), live Director pids (from journal + `kill -0`),
  last 10 journal rows, timer status (`launchctl print` / `systemctl status
  cfw-render.timer` — whichever exists), `--dry` validation summary.
  All **local** — the narrow key has no read tool (deliberate; noted in help).
- `run-now` — `cfw-render.sh --once` in the foreground (respects the tick lock).
- `logs [n]` — tail the drainer log + newest runs/*.out.
- `unblock <orderId>` — attempts `cr_mcp_call requeue_render_order {orderId}`;
  when the server answers "tool not found" (the current reality, §0.4) exit 1
  with: the follow-up task id to land it (`AB-RNDR-REQUEUE` in cfw-social), and
  the exact admin SQL (`UPDATE render_orders SET status='queued', claimed_by=NULL,
  claimed_at=NULL, lease_expires_at=NULL WHERE id='…' AND status='blocked';`).
  Forward-compatible, fail-fast, zero pretending.

## 8. `install/` (authoring only — NOTHING here executes against hst)

- `install.sh` — flags `--user <u> --prefix <dir> --env-file <path>`; copies
  `bin/ lib/` to the prefix, installs the right unit for the detected OS
  (launchd: render `com.cfw.render.plist` with paths, `launchctl bootstrap`;
  systemd: install `cfw-render.{service,timer}`, `systemctl enable --now
  cfw-render.timer`), then runs `cfw-render.sh --dry` and prints its table.
  **Guard rail:** refuses to run as root without `--yes-really`, and README/deploy
  docs state it is only ever run by the supervised gate.
- `com.cfw.render.plist` — `StartCalendarInterval` every 15 min (matches plan §2
  cadence; ab-hustler uses :22/:52 — we use :05/:20/:35/:50 to avoid stacking
  with the hustler on the Mac), `StandardOut/ErrPath` under `~/Library/Logs`.
- `cfw-render.service` — `Type=oneshot`, `ExecStart=<prefix>/bin/cfw-render.sh
  --once`, `EnvironmentFile=/etc/cfw-render.env`, `User=` templated, hardening
  (`NoNewPrivileges=yes`, `PrivateTmp=yes`).
- `cfw-render.timer` — `OnCalendar=*:0/15`, `Persistent=true`, `RandomizedDelaySec=60`.
- `provisioner-snippet.md` — the block cfw-provisioner's box-provision flow should
  adopt (copy units, enable timer, verify `--dry` passes) so a reprovision of hst
  reinstalls the worker — mirrors how `cfw-gw@<slug>` units survive today
  (`cfw-provisioner/src/core/gateway.ts`). Snippet is documentation for the
  follow-up provisioner task, not executed here.

## 9. `docs/deploy.md` — the supervised runbook (verbatim gate from the task)

1. Pre-flight from the operator's machine (never unattended): mint/verify the key
   per `render-worker-auth.md` §5; confirm Vercel env + `~/.gsai/secrets/cfw-render.env`.
2. **Confirm scratch root on the live box** (`df -h`, pick the volume; set
   `CFW_RENDER_SCRATCH` in `/etc/cfw-render.env`) and **confirm the CFW Media
   render path** by uploading a probe file through `/api/v1/render/upload` against
   a throwaway claimed order — both marked as REQUIRED CHECKS (AC).
3. Install as a **separate service pool** decoupled from the 9 gateways
   (`install.sh` — new unit names, no shared tmux/units).
4. `cfw-render.sh --dry` on the box → all PASS.
5. Flip `render_fleet_enabled=true` on **Bujji only**; submit one real reel via
   Hermes; watch `ctl status` + the brand UI event stream end-to-end.
6. Rollback: `systemctl disable --now cfw-render.timer` (orders re-strand as
   queued; nothing else touched).
7. Known gap: expired-lease/blocked requeue needs `AB-RNDR-REQUEUE` (§0.4).

## 10. Test strategy (committed, runnable, no live services)

- **Lint (AC):** `scripts/lint.sh` = `bash -n` every `bin/ install/ test/*.sh` +
  `shellcheck -S warning` when installed (skip with a notice otherwise);
  `package.json` maps `pnpm lint` / `pnpm test` to the scripts, satisfying the
  "pnpm/bash lint clean" AC without inventing a JS toolchain.
- **Behavioral suite:** `test/run-tests.sh` boots `test/mock-server.py`
  (python3 stdlib `http.server`) implementing `/api/v1/mcp` (JSON-RPC:
  `tools/list`, the 4 tools, recording every call to a JSONL) and
  `/api/v1/render/upload` (returns a properly namespaced fake cdnUrl). Cases:
  1. `--dry` passes against the mock and **makes zero `tools/call`s** (assert).
  2. Happy path: mock queues 1 video order; `CFW_RENDER_DIRECTOR_CMD=test/fake-director.sh`
     emits stages → subagent event → uploads `final/out.mp4` → complete. Assert:
     claim→events→upload→complete sequence, `models` rollup contains the fanout
     model, scratch dir wiped, journal row `outcome=complete`.
  3. Gate-fail path: fake director blocks with `gate: …` → assert
     `block_render_order` received + scratch retained.
  4. Watchdog: fake director sleeps > tiny `CFW_RENDER_TIMEOUT_VIDEO=3`; assert
     TERM/KILL + `block` with the time-budget reason.
  5. Empty queue: claim returns `order:null` → clean exit 0, no spawn.
  6. Tick lock: second concurrent invocation exits 0 without claiming.
- **What is NOT claimed as tested:** real `claude` spawn, real Ollama failover,
  the live cfw-social endpoint, anything on hst — supervised-gate territory; say
  so in the completion notes (evidence contract).

## 11. Edge cases (checklist for the dev)

- Order JSON containing quotes/emoji/newlines everywhere → all JSON via python3,
  never shell string-built.
- `taskOrder.brand.slug` missing/hostile → sanitize or fall back to `brandId`;
  scratch path never takes raw order input.
- Upload of >1 final file (image carousel: `kind=image`, N slides) →
  `complete` helper accepts N files, uploads all, `outputUrl` = first (the dish
  anchor), remaining URLs listed in a final `stage` event message.
- `complete_render_order` returns `ok:false` (namespace mismatch) → treat as
  fatal, block with owner-safe reason, keep scratch.
- Zombie 403 on complete/block (lease expired while drainer was frozen) → log +
  journal `outcome=zombie`; do NOT retry (auth doc §6: requeue wins by design).
- Two finals raced into `final/` → helper uploads the newest by mtime, warns.
- Ollama keys file absent → subagent helper fails fast with the file path; the
  Director may still finish Sonnet-only (fanout list then empty — legal).
- `--dry` with unreachable `CFW_API_BASE` → FAIL row, exit 1 (fail fast; no
  "probably fine").

## 12. Suggested commit slicing

1. `bin/cfw-render-lib.sh` + `config/cfw-render.env.example` (core + config)
2. `bin/cfw-render.sh` + `lib/director-prompt.md` (drainer + spawn)
3. Director helpers (`report`, `subagent`, `upload`)
4. `bin/cfw-render-ctl.sh`
5. `install/` + `docs/deploy.md`
6. `test/` + `scripts/lint.sh` + `package.json` + README update
