# c-composio — LEARNINGS

## Active Feedback

_No active feedback yet. The first live cook will populate this._

## History

- 2026-06-14 — Skill created (AB-INTEG-HERMES). Bridges connected Composio integrations
  (Google Drive first) to the Hermes cook runtime. Credentials arrive via the box JIT
  vault injector (same path as CFW_API_KEY / ELEVENLABS_API_KEY) — no manual vault calls
  in the recipe. The `composio-exec.mjs` Node shim performs the SDK call and normalizes
  the response. Two vault slugs are the cross-task contract: `composio` → `COMPOSIO_API_KEY`,
  `composio-entity-id` → `COMPOSIO_ENTITY_ID`. These must be stored by the CONNECT task
  (`set_brand_secret composio <key>` and `set_brand_secret composio-entity-id <entityId>`).
  Box-global install required before first use: `npm i -g @composio/core@0.10.0`.
