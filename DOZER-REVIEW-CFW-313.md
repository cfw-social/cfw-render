VERDICT: PASS

## Scope check

CFW-313's title ("HeyGen step must use the v1 remote MCP ... and take provider
credentials from the brand's account settings, never the worker's vault") spans
three ownership domains. The design doc backs this with concrete evidence rather
than assertion: `grep -rn "heygen-remote" ~/ecosystem` returns nothing (zero
integration of the v1 remote MCP today), `docs/render-worker-auth.md` §3
documents the render-worker MCP surface as deliberately four tools only, and
`lib/director-prompt.md` explicitly forbids the Director from making any live
credential lookup. Given those constraints, confining this repo's change to
"gate + propagate a credential that arrives pre-embedded in taskOrder, fail
closed if absent" — and recommending two companion issues for the cfw-social
OAuth connection and the c-heygen recipe's MCP-tier switch — is the correct call,
not scope-dodging. This mirrors the CFW-312 precedent (partial, evidenced scope
cut, explicitly flagged) that already merged to develop.

## Design-vs-build fidelity

- `cr_recipe_needs_heygen` (bin/cfw-render-lib.sh) matches the design's
  hand-maintained 3-recipe list, correctly excluding `p-longform`/`p-clone-reel`
  per the documented open question (no finer per-order signal exists yet).
- `spawn_director()`'s new gate (bin/cfw-render.sh) sits exactly where designed —
  after order.json is written, before the integrity gate — reads
  `taskOrder.credentials.heygen`, fails closed on missing/wrong-mode/expired
  token (unparsable `expiresAt` also treated as expired), and calls
  `block_render_order` with `needs: "decision"` (a value `bin/cfw-render-report.sh`
  already defines as valid) and an owner-actionable reason — **no fallback to
  any worker-local key anywhere in the diff**.
- On the happy path it exports `HEYGEN_OAUTH_TOKEN` / `HEYGEN_CREDIT_POOL` /
  `HEYGEN_TOKEN_EXPIRES_AT` — deliberately not `HEYGEN_API_KEY` — into the
  Director's subprocess env, never logging the token value itself.
- New static guard `scripts/check-no-worker-heygen-credential.sh` matches the
  CFW-312 gate's shape (dependency-free bash+grep, scoped to bin/lib/config,
  explicitly excluding the vendored `skills/` tree) and is picked up
  automatically by `scripts/lint.sh`'s existing `scripts/*.sh` glob — no edit
  needed there, consistent with the empty diff on that file.
- README.md and config/cfw-render.env.example additions accurately describe the
  shipped behavior and warn against reintroducing a worker-vault HEYGEN_API_KEY.

## Verification performed

Read the full diff and the current state of `bin/cfw-render.sh`,
`bin/cfw-render-lib.sh`, `scripts/check-no-worker-heygen-credential.sh`,
`scripts/lint.sh`, and `test/mock-server.py`'s `block_render_order` handler to
confirm the `needs`/`reason` contract matches. Ran `./test/run-tests.sh`
end-to-end (not just read): **90 PASS, 0 FAIL**, including all three new CFW-313
cases (credential present+valid → exported correctly, HEYGEN_API_KEY never set;
absent → blocked with `needs: decision`, Director never spawned; expired →
treated identically to absent) plus the full pre-existing suite (Cases 1-12, P,
F) and lint/shellcheck, with no regressions.

## Minor non-blocking observations

- The design's open questions (piece A token refresh timing, piece B's 1080p
  override path, finer per-order HeyGen-scene signal) are correctly left
  unresolved rather than guessed at, and are the right content for the two
  companion issues the design recommends filing.
- Companion issues are *recommended* in the design doc but not shown as
  created in this diff — that's outside this repo's worktree and not a defect
  in the build itself, but worth confirming they actually get filed so pieces
  A and B don't silently stall.
