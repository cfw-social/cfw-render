# cfw-provisioner snippet — reprovision survival for cfw-render

**Status: documentation only.** This is not wired into cfw-provisioner by this
task (AB-RNDR-WORKER is code-authoring only in `cfw-render/`, not
`cfw-provisioner/`). It's the block a follow-up provisioner task should adopt
so a reprovision of `hst` reinstalls the render worker the same way
`cfw-gw@<slug>` gateway units survive today (`cfw-provisioner/src/core/gateway.ts`).

## What to add to the box-provision flow

1. **Clone/sync `cfw-render`** to the box (same pattern as other provisioned
   repos under `cfw-provisioner/src/lib/tmpl/`). The checkout includes the
   pinned `skills/` bundle — cloning the repo is sufficient to get both the
   worker and its recipe closure; `install.sh` copies `skills/` into
   `$PREFIX/skills` alongside `bin/`/`lib/` automatically (see
   `cfw-render/README.md` "Bundled skills"). Updating skills = `git pull` this
   repo + restart the timer (below); there is no separate skills download.
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

## Skills update = git pull + restart (old pull cron retired)

The old hourly `cfw-skills-pull.sh` cron — which pulled the standalone public
`cfw-social/cfw-skills` checkout into `/data/shared/cfw-skills/cfw` — is
**retired** for cfw-render. cfw-render reads **only** its own in-repo `skills/`
bundle; it no longer touches `/data/shared/cfw-skills/cfw` (that path was a
Hermes-assistant bundle, never cfw-render's). Provisioning should **not** install
`cfw-skills-pull.sh` for the render worker.

To refresh a box's recipes, update the repo and restart the worker timer:

```bash
git -C <cfw-render-checkout> pull
install/install.sh --mode <server|byoa>   # re-copies skills/ into $PREFIX/skills
systemctl restart cfw-render.timer
```

> If a box still runs `cfw-skills-pull.sh` for the **Hermes assistant** (a
> separate consumer of `/data/shared/cfw-skills/cfw`), that is out of scope here
> — decouple it under the Hermes profile, not this worker.

## Reference

- Gateway unit survival pattern: `cfw-provisioner/src/core/gateway.ts`.
- Worker install script this snippet wraps: `cfw-render/install/install.sh`.
- Full deploy runbook (human-run, supervised): `cfw-render/docs/deploy.md`.
