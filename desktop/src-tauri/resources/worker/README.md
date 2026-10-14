`desktop/scripts/release.sh` copies the worker (bin/, install/, config/, lib/,
scripts/, skills/, AGENTS.md, CLAUDE.md, VERSION) here before `tauri build`;
`tauri.conf.json` ships this folder as `<Resources>/worker/`. Only this README
is committed.
