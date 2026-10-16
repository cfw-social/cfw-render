# CFW-316 — timeout budgets and retained delivery recovery

## Original proposal (historical, not a passing verification)

The original design was committed at `40a7c5bc0ee1c968e718fbf7dcc9b2be62cbe38f`
on `dozer/CFW-316`. Its unpublished implementation and tests are preserved in
workspace `.gg/evidence/render-app-consolidation/snapshots/1/` with restoration
instructions. That design proposed recipe budgets, excluded provider waits,
finish grace based on inspecting `final/`, and automatic rescue delivery using
`complete final/*` after a watchdog kill.

The rescue proposal's claim that missing `.outcome` proves no server completion
occurred is incorrect: the server can commit before the client writes that file.
A stable cover or contact sheet also does not prove that a full ordered carousel
exists. Those proposed predicates, rescue calls and success assertions are not
implemented. Their historical source remains recoverable, not silently deleted.

## Consolidated behavior

- Both the legacy Director and manifest engine invocations use bounded budgets.
  Dedicated HeyGen video recipes, or local index metadata declaring HeyGen,
  receive `CFW_RENDER_PROVIDER_BUDGET_HEYGEN` local processing seconds. Image
  recipes do not. Optional-provider recipes are not newly declared HeyGen-only.
- `provider-wait-start/end heygen` writes only to a worker-issued, contained,
  per-invocation log. Overlapping windows are merged and clipped to that
  invocation. Missing/malformed logs provide no exclusion. An absolute ceiling
  of budget plus `CFW_RENDER_PROVIDER_WAIT_CAP` remains enforceable.
- Manifest cancellation/supersession interrupts a wait; revocation retains its
  existing stop-after-step semantics. A killed step cannot pass merely because
  some saves exist. Its artifacts are retained and the attempt fails.
- A legacy Director already inside an explicit `complete <ordered files...>`
  call gets one bounded `CFW_RENDER_FINISH_GRACE_SECS` window. Enumerating files
  in `final/` never grants grace and never creates an output list. Manifest
  engine steps do not deliver; their harness owns ordered completion.
- Before uploading, completion atomically reserves `.delivery-started/` and
  records its explicit argument order. A later call cannot automatically retry
  uploads or completion. Side files such as captions are excluded from media.
  Known attempt identity is sent using Social's existing optional `attemptId`
  for legacy running attempts and negotiated stage ranges. Ordinary manifests
  retain their existing no-attemptId completion contract: Social currently
  rejects their already-completed attempt at that door.
- Completion transport is single-shot. `.outcome` is written immediately on an
  accepted response, before optional local copying. If that acknowledgement is
  lost, the marker protects the uncertainty window: no rescue, no conflicting
  block, no automatic new engine run over that scratch directory.
- A synchronous upload failure records that completion was never submitted.
  That attempt may report a block, but cannot repeat delivery. A new admitted
  claim can reset a positively acknowledged block; uncertainty is never reset.
- Acknowledged nonlocal completion removes scratch. Local checkpoint success
  keeps scrubbed saves for the normal two-day stopped-job retention window.
  The janitor retains uncertain delivery markers and timed-out artifacts. A person must
  reconcile an uncertain result against CFW and explicitly choose recovery;
  this change does not implement a recovery UI or claim exactly-once delivery.
  The marker protects this local scratch directory, not a deleted/reinstalled
  computer. Cancellation/revocation data-removal rules remain authoritative.

## Compatibility and limits

Inspected Social `src/lib/mcp/tools/render-order-worker.ts` rejects duplicate
completion through its claimed-order guard and supports optional attempt IDs;
it does not provide a successful retry acknowledgement contract. Accordingly,
we fail closed instead of claiming that transport retries are idempotent.
No Social code, catalog, recipe version or provider credential contract changed.
Historical provider metadata for optional `p-longform` / `p-clone-reel` is not
promoted to a required provider declaration.

Verification is recorded against the assembled candidate in the workspace
consolidation handoff. This document itself is not evidence of a test pass.
