---
task-id: "AB-RNDR-WORKER"
epic: "AB-RNDR"
title: "cfw-render drainer: claim → headless Claude CD + GLM/Kimi fan-out → CFW Media → writeback"
status: coding_done
priority: high
story-points: 5
model: sonnet
effort: high
progress: 100%
depends-on:
  - AB-RNDR-TOOLS   # landed (CFW-218) — worker MCP surface exists
  - AB-RNDR-AUTH    # landed (CFW-217) — scoped cfw_render_ credential exists
assignee: claude
tags: [cfw-render, hermes, render, box]
---

## DECISIONS LOCKED (2026-07-09, Vasanth)

- **Home:** this NEW `Code/cfw/cfw-render/` repo (not inside cfw-provisioner). Author everything here; merges to `cfw-render/develop`.
- **Hermes enforcement (sibling task AB-RNDR-HERMES):** soft playbook rule only — informational context for this worker; no change here.
- **Concurrency ceiling on hst:** start at **1** parallel Director subprocess, made a config knob (`CFW_RENDER_CONCURRENCY`, default 1). Conservative so it never starves the 9 live brand gateways.

## ⚠️ SCOPE FOR THIS UNATTENDED RUN — CODE AUTHORING ONLY

This task runs through the unattended AB dev lane. It must **NOT** touch the live prod VPS
`hst` (31.97.140.100) — that box runs 9 production brand gateways. **Do not SSH to hst, do not
install a launchd/systemd timer on it, do not run a live cook.** Author the code + installer +
docs in this repo only. Box deployment and the live Bujji cook are a **SUPERVISED FOLLOW-UP
GATE** (see bottom), done by a human/attended session.

## Source of truth (READ FIRST — absolute paths, other repo)

- `/Users/vasanth/Code/cfw/cfw-social/docs/cfw-render-worker-plan.md` — §2 architecture, §3 execution model (mirror `~/ecosystem/ab-hustler/ab-hustler.sh` marketing lane), §4 media rule, §8 lifecycle, §9 scratch folder.
- `/Users/vasanth/Code/cfw/cfw-social/docs/render-worker-auth.md` — the scoped `cfw_render_…` credential shape, the 4 worker MCP tools, brand+order-namespaced upload route, zombie-lease semantics.
- Model the drainer after `~/ecosystem/ab-hustler/ab-hustler.sh` + `ab-lib.sh` (claim/lease/watchdog/writeback patterns) and `ab-lock.sh` (box-local mutex).

## Acceptance Criteria (code deliverables in THIS repo)

- [x] `bin/cfw-render.sh` — host-agnostic bash drainer: on each tick calls `claim_render_order(workerId)` via the scoped `cfw_render_…` credential; box-local lock prevents double-run; lease heartbeats via `append_render_event`.
- [x] `bin/cfw-render-ctl.sh` — `status | run-now | unblock <orderId> | logs`.
- [x] **Director spawn:** per claimed order, one headless `claude -p` Creative Director (Claude subscription OAuth), Sonnet primary + GLM quota-failover (reuse `claude_ollama_failover`). Watchdog kill ~25–30 min (video) / shorter (image), driven by `kind`.
- [x] **Fan-out:** Director uses GLM + Kimi subagents (Ollama Cloud key, `~/.gsai/secrets/zai.env`) for per-clip renders / ffmpeg / per-slide HTML. Record per-stage model → `append_render_event(kind:subagent, model:…)` + final `models` rollup on `complete_render_order`.
- [x] **Self-contained:** reads ONLY the task order JSON + recipe/skill files. NEVER reads the brain or brand DB. Fetches all ingredients from the CFW Media URLs in the order.
- [x] **Scratch structure** (plan §9): `<scratch root>/<brandSlug>/<orderId>/{order.json,ingredients,clips,work,scorecard.json,final}` — ephemeral, wiped after upload.
- [x] **Eval gate:** run the recipe's `acceptance.json` (`c-shorts-qa-gate` video / `c-vision-qa` image); author→render→fix loop until PASS or fail-cap; 2× FAIL → `block_render_order("gate: …")`.
- [x] **Upload + writeback:** upload final to brand-namespaced CFW Media via `cfw-upload`, then `complete_render_order(orderId, outputUrl, models)`. Timeout/crash → lease expiry reclaim/`blocked`.
- [x] **Concurrency:** `CFW_RENDER_CONCURRENCY` config, default 1.
- [x] **install/** — an `install.sh` + a launchd plist template (`com.cfw.render.plist`) + a systemd unit, PLUS a provisioner-template snippet so the timer survives box reprovision (do NOT run any of these against hst here).
- [x] `docs/deploy.md` — the supervised deploy runbook (below), including scratch-root + CFW Media path confirmation steps against the live box.
- [x] `pnpm`/bash lint clean; a dry-run mode (`--once --dry`) that claims nothing but validates config + credential presence.

## SUPERVISED FOLLOW-UP GATE (NOT this unattended run)

After code lands + review: a human/attended session (1) installs on hst as a separate service
pool decoupled from the gateways, (2) confirms scratch root + CFW Media render path against the
live box, (3) flips `render_fleet_enabled=true` on **one** brand (Bujji first per plan), (4) runs
one real reel end-to-end. Only then fleet-wide.

## Implementation To-Dos

> Full design: `backlog/attachments/AB-RNDR-WORKER/implementation-plan.md` (read §0 first —
> ground truths incl. the curl JSON-RPC pattern, the cfw-upload credential mismatch, and the
> server-side requeue gap). All scripts are **bash** (`#!/usr/bin/env bash`), python3 for all
> JSON handling, no new runtime dependencies.

- [x] **1. Core lib** — `bin/cfw-render-lib.sh`: `cr_load_config` (env cascade `/etc/cfw-render.env` → `$CFW_RENDER_ENV` → process env; fail fast on missing `CFW_API_BASE`/`CFW_RENDER_WORKER_KEY`, key shape `^cfw_render_`), `cr_log`, `cr_mcp_call` (curl JSON-RPC per plan §3 — headers `cfw-render-key` + accept json/SSE, python3 unwraps `result.content[0].text`), `cr_event` (best-effort), bash ports of `claude_ollama_failover` + `claude_native_or_ollama_quota_fallback` from `~/ecosystem/ab-hustler/ab-lib.sh:76-140` (cite provenance; served-model written to a state file), mkdir-based tick lock with stale self-heal. *(AC: drainer claim/heartbeat via scoped credential; box-local lock)*
- [x] **2. Config example** — `config/cfw-render.env.example` with every knob from plan §2, incl. `CFW_RENDER_CONCURRENCY` default **1**, per-kind watchdogs (`CFW_RENDER_TIMEOUT_VIDEO=1800`, `CFW_RENDER_TIMEOUT_IMAGE=900`), `CFW_RENDER_SKILLS_DIR`, `CFW_RENDER_FANOUT_MODELS`, `CFW_RENDER_DIRECTOR_CMD` test seam. *(AC: concurrency config, default 1)*
- [x] **3. Drainer** — `bin/cfw-render.sh` (one tick per invocation): `--dry` validation mode (binaries, dirs, key shape, ollama keys, live `tools/list` check that asserts the 4 worker tools WITHOUT claiming — plan §4); tick lock; 48-h scratch janitor; claim loop up to `$CFW_RENDER_CONCURRENCY`; `spawn_director` per claimed order (scratch layout `<scratch>/<brandSlug>/<orderId>/{order.json,ingredients,clips,work,final}`, sanitized slug, prompt from template, watchdog TERM→KILL by `kind`); post-mortem via `.outcome` marker (143/137→"render exceeded the time budget", crash→"render failed unexpectedly", owner-safe words only); journal.tsv row per order. *(AC: drainer, scratch structure, watchdog by kind, dry-run)*
- [x] **4. Director prompt** — `lib/director-prompt.md` per plan §6: order.json + recipe/skills ONLY (never brain/brand DB), ingredients fetched from CFW Media URLs, canonical stages, gate from `taskOrder.acceptance.gate` (fallback video→`c-shorts-qa-gate`, image→`c-vision-qa`), author→render→fix loop with fail-cap 2 → block `"gate: …"`, final action exactly one complete/block, owner-safe event language. *(AC: self-contained, eval gate, fan-out)*
- [x] **5. Report helper** — `bin/cfw-render-report.sh {stage|complete|block}`: stage events = lease heartbeat; `complete` uploads local file(s) via the upload helper, builds `models` rollup (director from failover state file + deduped `work/.models-fanout`), calls `complete_render_order`, verifies `ok:true`, writes `.outcome`; `block` mirrors. Ids come from `CFW_ORDER_ID`/`CFW_WORKER_ID` env. *(AC: upload + writeback, models rollup)*
- [x] **6. Subagent helper** — `bin/cfw-render-subagent.sh <model> …`: validate against `CFW_RENDER_FANOUT_MODELS`, run ollama failover (goofy→pike, `~/.gsai/secrets/ollama-keys.env` — note the task-text `zai.env` discrepancy in README per plan §0.7), append model to `work/.models-fanout`, emit `append_render_event(kind:subagent, model:…)`. *(AC: GLM/Kimi fan-out with per-stage model recording)*
- [x] **7. Upload helper** — `bin/cfw-render-upload.sh`: modeled on `cfw-provisioner/src/lib/tmpl/cfw-upload.sh` (mime map, concurrent curls, ordered output, ERROR marker, no fallback host) but targeting `POST /api/v1/render/upload` with `cfw-render-key` + `orderId`/`workerId` form fields; parse `assets[].cdnUrl`. *(AC: brand-namespaced CFW Media upload)*
- [x] **8. Ctl** — `bin/cfw-render-ctl.sh status|run-now|unblock <orderId>|logs` per plan §7. `unblock` calls `requeue_render_order` and, while the server tool doesn't exist, exits 1 with the follow-up task pointer + exact admin SQL — no silent no-op. *(AC: ctl verbs)*
- [x] **9. File the server-side gap** — create a follow-up task file `AB-RNDR-REQUEUE` (cfw-social: extend worker-claim CAS to reclaim expired-lease orders + add `requeue_render_order`) OR flag it in completion notes as PARTIAL for the "lease expiry reclaim" clause; document in `docs/deploy.md`. Do NOT claim reclaim works today. *(AC: timeout/crash → lease expiry reclaim — honesty contract)*
- [x] **10. Install assets** — `install/install.sh` (OS-detect, prefix/env-file flags, runs `--dry` at the end, root guard; never executed here), `install/com.cfw.render.plist` (15-min StartCalendarInterval offset from the hustler), `install/cfw-render.service` + `install/cfw-render.timer` (`OnCalendar=*:0/15`, `Persistent=true`, hardening), `install/provisioner-snippet.md` for reprovision survival. **Do not run any of it against hst.** *(AC: install/ bundle)*
- [x] **11. Deploy runbook** — `docs/deploy.md` per plan §9 incl. REQUIRED scratch-root + CFW Media render-path confirmation steps against the live box, Bujji-first flip, rollback, requeue-gap note. *(AC: docs/deploy.md)*
- [x] **12. Lint + tests** — `scripts/lint.sh` (`bash -n` + shellcheck-if-present), `package.json` with `lint`/`test` scripts, `test/mock-server.py` + `test/fake-director.sh` + `test/run-tests.sh` covering: dry-run makes zero tool calls, happy path (claim→stages→subagent→upload→complete, scratch wiped), gate-fail block (scratch kept), watchdog kill→block, empty queue, tick-lock exclusion — all against the mock, no live services. Run both clean before commit. *(AC: lint clean + validated behavior)*
- [x] **13. README refresh** — usage, knobs table pointer, workerId semantics, ollama-keys vs zai.env note, "supervised gate" warning.

## Completion Notes (2026-07-09, unattended AB run)

Code-authoring only, per the task's own scope note — nothing was run against
`hst`. `pnpm lint` and `pnpm test` both exit 0 (21/21 assertions,
`test/run-tests.sh`, re-verified twice for flakiness). Evidence table:

| criterion | status | artifact |
|---|---|---|
| drainer claim/heartbeat via scoped credential + box-local lock | MET | `bin/cfw-render.sh:1-260`, `bin/cfw-render-lib.sh` (`cr_tick_lock_acquire`/`cr_mcp_call`); `test/run-tests.sh` Case 2, Case 6 |
| `cfw-render-ctl.sh` status/run-now/unblock/logs | MET | `bin/cfw-render-ctl.sh` |
| Director spawn: Sonnet primary + GLM quota-failover, watchdog by `kind` | MET | `bin/cfw-render.sh` `spawn_director()`; `claude_native_or_ollama_quota_fallback` ported in `bin/cfw-render-lib.sh:170-205` (provenance comment cites `ab-lib.sh:76-140`); `test/run-tests.sh` Case 4 (watchdog) |
| GLM/Kimi fan-out + per-stage model recording | MET | `bin/cfw-render-subagent.sh`; `test/run-tests.sh` Case 2 asserts `kind:subagent` event + `fanout:["glm-5.2"]` in the `models` rollup |
| Self-contained (order.json + skills only, CFW Media fetch) | MET (by construction/prompt) | `lib/director-prompt.md`; not independently enforced at runtime — the Director is trusted to follow the prompt, same as the plan's design |
| Scratch structure, ephemeral, wiped after upload | MET | `bin/cfw-render.sh` `spawn_director()` (mkdir layout + `rm -rf` on `.outcome=complete`); `test/run-tests.sh` Case 2 (wiped) / Case 3 (retained on block) |
| Eval gate / fail-cap 2 → block | MET (mechanism); gate content is recipe-owned | `lib/director-prompt.md` fail-cap instructions; `bin/cfw-render-report.sh block`; `test/run-tests.sh` Case 3 |
| Upload + writeback (`complete_render_order` w/ models) | MET | `bin/cfw-render-upload.sh`, `bin/cfw-render-report.sh complete`; `test/run-tests.sh` Case 2 |
| Timeout/crash → lease expiry reclaim / blocked | **PARTIAL** | Timeout/crash **while the drainer is alive** is fully handled (`bin/cfw-render.sh` post-mortem → `block_render_order`, Case 4). **Drainer process death** has no reclaim path today — no `requeue_render_order` tool exists server-side (gap documented, not papered over: `docs/deploy.md` §8, `README.md`, `implementation-plan.md` §0.4). Per the to-do's own "OR" clause this is flagged here rather than filing a cross-repo (cfw-social) task file, since this run is scoped to this worktree only. |
| `CFW_RENDER_CONCURRENCY` default 1 | MET | `config/cfw-render.env.example`, `bin/cfw-render-lib.sh:cr_load_config` |
| `install/` bundle (never run against hst) | MET | `install/install.sh`, `install/com.cfw.render.plist`, `install/cfw-render.service`, `install/cfw-render.timer`, `install/provisioner-snippet.md` — none executed by this run |
| `docs/deploy.md` supervised runbook | MET | `docs/deploy.md` |
| `pnpm`/bash lint clean + `--dry` mode | MET | `scripts/lint.sh` (bash -n + shellcheck -S warning, both clean), `bin/cfw-render.sh --dry`; `test/run-tests.sh` Case 1 |

**Out of pipeline (per the task's own SUPERVISED FOLLOW-UP GATE — not this run):** installing on `hst`, confirming the live scratch root + CFW Media path, flipping `render_fleet_enabled`, and running one real reel end-to-end. These are explicitly deferred to a human/attended session (`docs/deploy.md`).

**Not independently tested:** a real `claude` spawn, real Ollama Cloud failover, and the live cfw-social endpoint — `test/run-tests.sh` uses `CFW_RENDER_DIRECTOR_CMD` + a stubbed `claude` + a stdlib mock server by design (plan §10), consistent with "no live services" for this unattended lane.

Status left at `coding_done` (not `complete`) because of the one PARTIAL criterion above — a human/QA pass should review before merge-to-main promotion.
