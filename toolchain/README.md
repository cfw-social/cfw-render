# toolchain/ — the private worker toolchain (M3-07)

One checksummed download gives a Mac with no Homebrew every binary the render
worker needs. This directory is the bundle *definition*; the binaries are built
in CI and uploaded to R2 (later slices).

## Layout

- `manifest.json` — bundle version, pinned tool versions/licences, archive names
  (`sha256`/`sizeBytes` are `null` until the CI build fills them).
- `LICENSES.md` — redistribution table. No GPL; ffmpeg is the LGPL build; Claude
  Code is not bundled.
- `scripts/make-sums.sh <dir>` — writes `SHA256SUMS` for an unpacked bundle.
- `scripts/verify.sh <dir>` — checks `SHA256SUMS` and that no Mach-O links to or
  rpaths into `/opt/homebrew` or `/usr/local`. Falls back to `strings` when
  `otool` is missing (or `CFW_VERIFY_FORCE_STRINGS=1`).

## How the app installs it

Unpacked bundle layout: `bin/`, `lib/`, `share/`, `SHA256SUMS`, `manifest.json`.
The desktop app downloads the archive for the host arch, checks `sha256` against
the manifest, unpacks to `~/CFW Render/app/tools/<version>/`, runs the
equivalent of `verify.sh`, and only then repoints the `tools/current` symlink —
atomically (`ln -sfn` to a temp name + `mv`), as the very last step. A failed
install never changes `current`.

## How the worker picks it up

`cr_resolve_worker_path` (`bin/cfw-render-lib.sh`) prepends
`${CFW_RENDER_TOOLS_DIR:-${CFW_RENDER_HOME:-$HOME/CFW Render}/app/tools}/current/bin`
when that directory exists, so bundled tools win over Homebrew/system copies.
When it is absent the PATH is byte-identical to before — nothing changes for
existing boxes. `cr_preflight` notes "(not in <tools_bin> either)" for a missing
tool when the dir exists.

## Build / verify

CI builds per-arch tarballs from `manifest.json` (later slice). Locally:
`scripts/make-sums.sh <bundle>` then `scripts/verify.sh <bundle>`.
Signing/notarisation (G0) and the R2 upload are owner release steps, not CI.
