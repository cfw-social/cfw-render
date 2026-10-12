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

## Release flow (M3-07b)

1. Bump `manifest.json` `version` (and tool versions / `sha256` pins) on a branch; merge.
2. Tag `toolchain-v<version>` and push the tag. `.github/workflows/toolchain-build.yml`
   builds `arm64` on `macos-14` and `x86_64` on `macos-13` via
   `scripts/build.sh <arch> dist/` (`workflow_dispatch` with `arch` also works
   for a build-only run). Brew packages are build-time only; `verify.sh` runs
   inside `build.sh` and fails the job if any Mach-O links to `/opt/homebrew`
   or `/usr/local`.
3. The `release` job waits for the owner to approve the `toolchain-release`
   GitHub environment, then runs `scripts/release.sh dist/` with the R2
   secrets (`R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
   R2_TOOLCHAIN_BUCKET`, plus the `R2_TOOLCHAIN_PUBLIC_BASE` variable).
   Developer ID signing / notarisation (G0) slots into that job before
   `release.sh` once the identity exists; it is not wired yet.

### Source pins

Every `tools[].sha256` in `manifest.json` pins the exact source archive
`build.sh` downloads (`lib.sh` `tc_fetch`). A `TODO-*` value makes `build.sh`
refuse to run, naming the tool. For the very first build set the repo
variable `CFW_TOOLCHAIN_ALLOW_UNPINNED=1` (or the env var locally): the job
prints `PIN <url> <sha256>` lines — paste them into the manifest, unset the
variable, rebuild. Node is additionally checked against nodejs.org's
`SHASUMS256.txt`; python comes from python-build-standalone release
`pbsTag`; codex is installed with the bundled node via `npm install -g`.

### ffmpeg codecs

This first build is LGPL-pure with **no external codec libraries**: native
H.264/HEVC *decode*, native AAC encode, no libx264/x265 (GPL), no
libvpx/opus/mp3lame. Add codec libs in a later manifest version if a recipe
needs them (each one must be built into the stage and listed in LICENSES.md).

### R2 layout

```
toolchain/manifest.json                      # current pointer (toolchain-manifest.json shape)
toolchain/<version>/manifest.json            # frozen copy for that version
toolchain/<version>/cfw-toolchain-<version>-arm64.tar.zst
toolchain/<version>/cfw-toolchain-<version>-x86_64.tar.zst
```

`toolchain-manifest.json` = `{ version, minAppVersion, archives: { arm64: {url,
sha256, sizeBytes}, x86_64: {...} }, publishedAt }`; `url` is
`${R2_TOOLCHAIN_PUBLIC_BASE}/toolchain/<version>/<file>`. The desktop app
reads the pointer, picks its arch, verifies `sha256`, installs as described
above. `CFW_RELEASE_DRY_RUN=1 scripts/release.sh dist/` prints the `aws s3 cp`
commands instead of running them (used by `test/run-tests.sh`).
