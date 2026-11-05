# toolchain/ — the private worker toolchain (M3-07)

One checksummed download gives a Mac with no Homebrew every binary the render
worker needs. This directory is the bundle *definition*; the binaries are built
in CI and uploaded to R2 (later slices).

## Layout

- `manifest.json` — bundle version, pinned tool versions/licences, archive names
  (`sha256`/`sizeBytes` are `null` until the CI build fills them).
- `LICENSES.md` — redistribution table. ffmpeg is the GPL build (libx264 and
  libass); Claude Code is not bundled. The GPL terms and source URLs are there.
- `scripts/make-sums.sh <dir>` — writes `SHA256SUMS` for an unpacked bundle.
- `scripts/verify.sh <dir>` — checks `SHA256SUMS` and that no Mach-O links to or
  rpaths into `/opt/homebrew` or `/usr/local`. Falls back to `strings` when
  `otool` is missing (or `CFW_VERIFY_FORCE_STRINGS=1`).

## How the app installs it

Unpacked bundle layout: `bin/`, `lib/`, `share/`, `config/playwright-pin.json`,
`SHA256SUMS`, `manifest.json`, `bin/cfw-render-preflight.sh` and
`bin/cfw-render-lib.sh`. Chromium browsers land in `share/ms-playwright`.
The preflight is the same script as the WI17.3.1 worker check. It sources
`cfw-render-lib.sh` beside it. `build.sh` copies both scripts and
`config/playwright-pin.json` into the bundle before `make-sums.sh`. A bundle
without those two scripts is refused with "no preflight".

Before any download, the desktop app compares the manifest `minAppVersion`
with this build (`CARGO_PKG_VERSION`). A higher minimum stops the install
with `This toolchain needs CFW Render <version> or newer. Update the app first.`
and leaves `tools/current` unchanged.

Otherwise the app downloads the archive for the host arch, checks `sha256`
against the manifest, and unpacks into a temp dir beside
`~/CFW Render/app/tools/<version>/`. It then runs the equivalent of `verify.sh`
and, still before the swap, runs `bin/cfw-render-preflight.sh --bundle` from
that unpacked tree with `bin/` first on `PATH`. `--bundle` checks the bundled
binaries and the pinned Chromium under `share/ms-playwright` (or `browsers/`
when that directory is the one present). It reads the bundle's
`config/playwright-pin.json`. It does not need the claude CLI,
`CFW_RENDER_DIRECTOR_CMD`, or the HOME Playwright cache. A missing script or a
non-zero exit
refuses the bundle, deletes the temp dir, and does not move `current`. Only a
passing preflight renames the tree into `tools/<version>/` and repoints the
`tools/current` symlink — atomically (`ln -sfn` to a temp name + `mv`), as the
very last step. A failed install never changes `current`.

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
   builds `arm64` on `macos-14` and `x86_64` on `macos-15-intel` via
   `scripts/build.sh <arch> dist/` (`workflow_dispatch` with `arch` also works
   for a build-only run). Pin-capture mode is the `capture_pins` input on
   `workflow_dispatch`: that run sets `CFW_TOOLCHAIN_ALLOW_UNPINNED=1` and
   uploads the printed `PIN` lines as the `toolchain-pins-<arch>` artifact.
   It does not publish. After the build, the job runs the unpacked bundle's
   `bin/cfw-render-preflight.sh --bundle` with that bundle's `bin/` first on
   `PATH`. That check uses the bundle's own pin and browsers, not the runner's
   claude CLI or HOME Playwright cache.
   Brew packages are build-time only and are installed in CI only. They are
   not part of user setup: zstd, pkg-config, autoconf, automake, libtool,
   nasm, cmake, meson, ninja and gperf. `verify.sh` runs inside `build.sh`
   and fails the job if any Mach-O links to `/opt/homebrew` or `/usr/local`.
3. The `release` job waits for the owner to approve the `toolchain-release`
   GitHub environment, then runs `scripts/release.sh dist/` with the R2
   secrets (`R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
   R2_TOOLCHAIN_BUCKET`, plus the `R2_TOOLCHAIN_PUBLIC_BASE` variable).
   Developer ID signing / notarisation (G0) slots into that job before
   `release.sh` once the identity exists; it is not wired yet.

### Source pins

Every `tools[].sha256` in `manifest.json` pins the exact source archive
`build.sh` downloads (`lib.sh` `tc_fetch`). A `TODO-*` value makes `build.sh`
refuse to run before any download, naming every unpinned tool, including a
tool whose `arch` is the other Mac. For the very first build set the repo
variable `CFW_TOOLCHAIN_ALLOW_UNPINNED=1` (or the env var locally): the job
prints `PIN <url> <sha256>` lines — paste them into the manifest, unset the
variable, rebuild. Node is additionally checked against nodejs.org's
`SHASUMS256.txt`; python comes from python-build-standalone release
`pbsTag`; codex is installed with the bundled node via `npm install -g`.

A tool with `"arch": "arm64"` is built only into the arm64 archive.
`"arch": "x86_64"` is only the Intel archive. No `arch` field means both.
`CFW_TOOLCHAIN_PLAN=1 scripts/build.sh <arch> <out-dir>` prints `step` lines
for that arch and exits before any download or compile. The pin gate still
runs first. `test/run-tests.sh` uses that plan with `CFW_TOOLCHAIN_MANIFEST`.

### ffmpeg codecs

The bundle builds GPL ffmpeg. `build.sh` passes the ffmpeg entry's
`buildFlags` to `./configure` and refuses to configure when `--enable-gpl`,
`--enable-libx264`, `--enable-libass` or `--enable-libfreetype` is missing.
Recipes call `-c:v libx264` and `-vf ass=`. x265 and nonfree codecs stay off.
libx264, libass, fribidi, harfbuzz, freetype, libpng and libjpeg are entries
in `manifest.json`. ImageMagick is configured with `--with-png=yes` and
`--with-jpeg=yes`, so the png and jpeg delegates link the staged libraries.
The GPL terms and the source URLs are in `LICENSES.md`.

### Speech to text

Apple silicon (`arm64`) ships `mlx_whisper` from mlx-examples. `mlx_whisper`
does not run on Intel. Reel recipes call it with the Hugging Face model
`mlx-community/whisper-small-mlx`. That model downloads on first use into the
Hugging Face cache. It is not in the toolchain archive.

Intel (`x86_64`) ships openai-whisper (MIT, version 20240930, GitHub tag
`v20240930`) as the `whisper` command. Recipes call
`whisper <file> --model small --output_dir <dir> --output_format <fmt>`.
The speech model downloads on first use into `~/.cache/whisper`. It is not in
the toolchain archive. This command is not whisper.cpp.

Both `sha256` values stay `TODO-fill-from-first-build` until CI.

### Known limits

`whisper-cli` (whisper.cpp) is not in this archive. p-longform's `transcribe.sh` needs that binary and a local ggml model file.

fontconfig needs the macOS SDK `libexpat` (`expat.h` and `-lexpat`). There is no `expat` manifest tool, so `build.sh` does not download one. The freedesktop release tarball already contains `src/fcobjshash.h`, so this script does not run `gperf` and does not clone fontconfig. CI still installs `gperf` with the other host build tools.

libjpeg-turbo is built with CMake. harfbuzz and fribidi are built with Meson and Ninja. `build.sh` calls `cmake`, `meson` and `ninja` (`require_cmd`). The CI workflow installs those, plus `gperf`, on the runner only. That `brew install` is CI only. It is not part of user setup, and those host tools are not files in the bundle.

libx264's manifest version `0.164.3108` is an x264 point version, not a git tag, and the entry has no `commit` field. `build.sh` refuses to guess a snapshot. Distributors record this version as git commit `31e19f92f00c7003fa115047ce50978bc98c3a0d`. Add `tools[].commit` with that commit (or the commit you actually pin) before a real x264 fetch can run. The fetch URL is `<source>/-/archive/<commit>/x264-<commit>.tar.gz`, and `sha256` pins that archive.

`openai-whisper` is installed from the pinned GitHub tag archive (`v` plus the manifest version) into a venv under `lib/openai-whisper-venv`. `pip wheel` builds that pin, then `pip install --no-index` installs it. Python dependencies of that package come from PyPI and are not separate manifest pins. The `bin/whisper` wrapper uses the bundled python and the venv's site-packages, so the archive can move. The speech model still downloads on first use into `~/.cache/whisper`.

The `whisper` manifest tool (command `mlx_whisper`, Apple silicon only) is the PyPI sdist for `mlx-whisper==<version>`, checked with that tool's `sha256`. The manifest has no `pipPackage` field; the pip project name is `mlx-whisper`. The same venv and wrapper pattern is used. The Hugging Face model is not in the archive.

Chromium is fetched with `npx playwright@<version> install chromium`. The version and the two revision numbers are read from `config/playwright-pin.json`. They must match the chromium manifest entry. `build.sh` does not invent a version. The browser zips are chosen by that Playwright release, so the manifest `sha256` is the pin gate only, same as codex and gemini. The browsers land in `share/ms-playwright`.

GitHub tag archives (`archive/refs/tags/<tag>.tar.gz`) are what libpng and openai-whisper pin. GitHub has changed the bytes of those archives before. A later sha256 mismatch means paste the new `PIN` line, not a second URL.

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
