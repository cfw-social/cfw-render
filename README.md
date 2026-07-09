# cfw-render

Decoupled render fleet for CFW Social — the async worker that drains `RenderOrder` rows
(Postgres, cfw-social system of record), spawns a headless Claude Creative Director with
GLM/Kimi fan-out, renders un-timeboxed, and writes the dish back via the narrow render-worker
MCP credential.

**Design source of truth:** `/Users/vasanth/Code/cfw/cfw-social/docs/cfw-render-worker-plan.md`
**Worker auth/credential:** `/Users/vasanth/Code/cfw/cfw-social/docs/render-worker-auth.md`

Status: scaffolding (AB-RNDR-WORKER). Not yet deployed to hst.
