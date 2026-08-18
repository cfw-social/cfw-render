---
task-id: "AB-RNDR-WORKER"
epic: "AB-RNDR"
title: "cfw-render drainer: claim → headless Claude CD + GLM/Kimi fan-out → CFW Media → writeback"
status: complete
priority: high
story-points: 5
model: sonnet
effort: high
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

- [ ] `bin/cfw-render.sh` — host-agnostic bash drainer: on each tick calls `claim_render_order(workerId)` via the scoped `cfw_render_…` credential; box-local lock prevents double-run; lease heartbeats via `append_render_event`.
- [ ] `bin/cfw-render-ctl.sh` — `status | run-now | unblock <orderId> | logs`.
- [ ] **Director spawn:** per claimed order, one headless `claude -p` Creative Director (Claude subscription OAuth), Sonnet primary + GLM quota-failover (reuse `claude_ollama_failover`). Watchdog kill ~25–30 min (video) / shorter (image), driven by `kind`.
- [ ] **Fan-out:** Director uses GLM + Kimi subagents (Ollama Cloud key, `~/.gsai/secrets/zai.env`) for per-clip renders / ffmpeg / per-slide HTML. Record per-stage model → `append_render_event(kind:subagent, model:…)` + final `models` rollup on `complete_render_order`.
- [ ] **Self-contained:** reads ONLY the task order JSON + recipe/skill files. NEVER reads the brain or brand DB. Fetches all ingredients from the CFW Media URLs in the order.
- [ ] **Scratch structure** (plan §9): `<scratch root>/<brandSlug>/<orderId>/{order.json,ingredients,clips,work,scorecard.json,final}` — ephemeral, wiped after upload.
- [ ] **Eval gate:** run the recipe's `acceptance.json` (`c-shorts-qa-gate` video / `c-vision-qa` image); author→render→fix loop until PASS or fail-cap; 2× FAIL → `block_render_order("gate: …")`.
- [ ] **Upload + writeback:** upload final to brand-namespaced CFW Media via `cfw-upload`, then `complete_render_order(orderId, outputUrl, models)`. Timeout/crash → lease expiry reclaim/`blocked`.
- [ ] **Concurrency:** `CFW_RENDER_CONCURRENCY` config, default 1.
- [ ] **install/** — an `install.sh` + a launchd plist template (`com.cfw.render.plist`) + a systemd unit, PLUS a provisioner-template snippet so the timer survives box reprovision (do NOT run any of these against hst here).
- [ ] `docs/deploy.md` — the supervised deploy runbook (below), including scratch-root + CFW Media path confirmation steps against the live box.
- [ ] `pnpm`/bash lint clean; a dry-run mode (`--once --dry`) that claims nothing but validates config + credential presence.

## SUPERVISED FOLLOW-UP GATE (NOT this unattended run)

After code lands + review: a human/attended session (1) installs on hst as a separate service
pool decoupled from the gateways, (2) confirms scratch root + CFW Media render path against the
live box, (3) flips `render_fleet_enabled=true` on **one** brand (Bujji first per plan), (4) runs
one real reel end-to-end. Only then fleet-wide.
