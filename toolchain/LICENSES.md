# cfw-toolchain — third-party licences

Every binary in the private toolchain bundle (`toolchain/manifest.json`) and the
licence it is redistributed under. **No GPL component ships.** ffmpeg is the
LGPL build (`--disable-gpl --disable-libx264 --disable-libx265`). **Claude Code
is NOT bundled** — the desktop app installs it from Anthropic's own installer
under Anthropic's terms.

| Component   | Version    | Licence (SPDX)       | Source                                                   | Redistribution note |
|-------------|------------|----------------------|----------------------------------------------------------|---------------------|
| node        | 22.20.0    | MIT                  | https://nodejs.org/dist/                                 | Official darwin tarball, unmodified. Ship `LICENSE` from the tarball. |
| python      | 3.12.11    | PSF-2.0              | https://github.com/astral-sh/python-build-standalone     | `install_only_stripped` build; bundled third-party libs listed in its `PYTHON.json`. |
| ffmpeg/ffprobe | 7.1.1   | LGPL-2.1-or-later    | https://ffmpeg.org/releases/                             | Built in CI without `--enable-gpl`; no x264/x265/nonfree. Ship `COPYING.LGPLv2.1` + build flags. |
| imagemagick | 7.1.1-47   | ImageMagick          | https://github.com/ImageMagick/ImageMagick               | Apache-2.0-derived; ship `LICENSE`. Delegates limited to png/jpeg/webp/freetype/fontconfig. |
| fontconfig  | 2.16.0     | MIT                  | https://gitlab.freedesktop.org/fontconfig/fontconfig     | MIT-style; ship `COPYING`. |
| freetype    | 2.13.3     | FTL                  | https://freetype.org/                                    | FreeType License (BSD-style with attribution); ship `FTL.TXT`; credit "Portions of this software are copyright © The FreeType Project". |
| codex       | 0.45.0     | Apache-2.0           | https://github.com/openai/codex                          | Official release binary; ship `LICENSE` + `NOTICE`. |

Versions marked `pinNote` in the manifest are provisional until the CI build
confirms them; keep this table and `manifest.json` in lockstep.

## How to update

Bump the component in `toolchain/manifest.json` (version + source URL), update the
matching row here, and re-check the licence file inside the new upstream archive
(a licence change is a blocker, not a note). Rebuild via the CI workflow (later
M3-07 slice), run `toolchain/scripts/make-sums.sh` then `verify.sh` on the
unpacked bundle, and bump `manifest.version` (calendar `YYYY.MM.N`). Never add a
component without an SPDX identifier and a redistribution note in this table.
