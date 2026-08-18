# cfw-provisioner snippet — reprovision survival for cfw-render

**Status: documentation only.** This is not wired into cfw-provisioner by this
task (AB-RNDR-WORKER is code-authoring only in `cfw-render/`, not
`cfw-provisioner/`). It's the block a follow-up provisioner task should adopt
so a reprovision of `hst` reinstalls the render worker the same way
`cfw-gw@<slug>` gateway units survive today (`cfw-provisioner/src/core/gateway.ts`).

## What to add to the box-provision flow

1. **Clone/sync `cfw-render`** to the box (same pattern as other provisioned
   repos under `cfw-provisioner/src/lib/tmpl/`). As of CFW-HST-BUNDLE, this
   checkout now includes the pinned `skills/` subtree — cloning the repo is
   sufficient to get both the worker and its recipe closure; `install.sh`
   copies `skills/` into `$PREFIX/skills` alongside `bin/`/`lib/`
   automatically (see `cfw-render/README.md` "Bundled skills"). No separate
   step is needed to fetch skills for a box that's cutting over to the
   bundle — but see the note below before touching the existing hourly pull.
2. **Copy units:**
   ```bash
   cp cfw-render/install/cfw-render.service /etc/systemd/system/cfw-render.service
   cp cfw-render/install/cfw-render.timer /etc/systemd/system/cfw-render.timer
   # substitute {{PREFIX}}, {{ENV_FILE}}, {{USER}} the same way install.sh does
   ```
3. **Ensure the env file exists** at `/etc/cfw-render.env` — this is a secret
   and must NOT be templated into the provisioner repo. Pull it from the vault
   (`~/.gsai/secrets/cfw-render.env`) via whatever secret-sync mechanism the
   provisioner already uses for other per-box `.env` files.
4. **Enable + verify:**
   ```bash
   systemctl daemon-reload
   systemctl enable --now cfw-render.timer
   /opt/cfw-render/bin/cfw-render.sh --dry   # must report PASS
   ```
5. **Service pool isolation:** cfw-render must NOT share a unit name, tmux
   session, or working directory with any `cfw-gw@<slug>` gateway — it is a
   decoupled service pool per `cfw-render-worker-plan.md` §11's "Cutover"
   step and the task's SUPERVISED FOLLOW-UP GATE.

## Bundled-skills transition note (do not act on this without a human decision)

The box's existing hourly `cfw-skills-pull.sh` cron (`/data/shared/cfw-skills/cfw`,
the standalone public `cfw-social/cfw-skills` checkout) is **NOT retired by
this change** and this snippet does not touch it. Once a box is fully cut
over to the bundled `skills/` model (all brands' `CFW_RENDER_SKILLS_DIR`
pointing at the bundle, verified per `docs/deploy.md` §8b), a follow-up
provisioner task can drop the cron install step for that box. Until then,
provisioning should keep installing/enabling `cfw-skills-pull.sh` exactly as
today — this is a supervised, brand-by-brand rollout gate, not a default
behavior change.

## Reference

- Gateway unit survival pattern: `cfw-provisioner/src/core/gateway.ts`.
- Worker install script this snippet wraps: `cfw-render/install/install.sh`.
- Full deploy runbook (human-run, supervised): `cfw-render/docs/deploy.md`.
