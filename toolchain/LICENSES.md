# cfw-toolchain — third-party licences

Every binary in the private toolchain bundle (`toolchain/manifest.json`) and the
licence it is redistributed under. **ffmpeg is the GPL build** (`--enable-gpl
--enable-libx264 --enable-libass --enable-libfreetype`). **Claude Code is NOT
bundled** — the desktop app installs it from Anthropic's own installer under
Anthropic's terms.

## GPL terms

ffmpeg and ffprobe in this bundle are **GPL-2.0-or-later**. The build enables
GPL and links x264, which is GPL-2.0-or-later, so the LGPL build is not what
ships. libass (ISC) is linked into that same binary for the `ass` filter. The
combined ffmpeg and ffprobe binaries are GPL-2.0-or-later even though libass,
freetype, harfbuzz, libpng and libjpeg keep their own licences when used on
their own.

If you receive these binaries you may use, copy, modify and share them under
GPL-2.0-or-later. You must:

- keep the copyright notices and ship this statement with the bundle
- ship `COPYING.GPLv2` from the ffmpeg source next to the binaries
- make the Corresponding Source available to anyone who gets the binaries, for
  at least three years, at no more than the cost of distribution

The Corresponding Source for this build is the versions and URLs in the table
below, configured with the `buildFlags` on the ffmpeg entry in
`toolchain/manifest.json`.

Where that source is:

- ffmpeg 7.1.1: https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz
- x264 (libx264) 0.164.3108: https://code.videolan.org/videolan/x264
- libass 0.17.3: https://github.com/libass/libass/releases/tag/0.17.3
- fribidi 1.0.16: https://github.com/fribidi/fribidi
- harfbuzz 10.0.1: https://github.com/harfbuzz/harfbuzz
- freetype 2.13.3: https://freetype.org/download.html
- libpng 1.6.44: https://github.com/pnggroup/libpng
- libjpeg-turbo 3.0.4: https://github.com/libjpeg-turbo/libjpeg-turbo

x265 is not enabled. Non-free codecs are not enabled (`--disable-nonfree`).
No other GPL program is added by this bundle.

| Component   | Version    | Licence (SPDX)       | Source                                                   | Redistribution note |
|-------------|------------|----------------------|----------------------------------------------------------|---------------------|
| node        | 22.20.0    | MIT                  | https://nodejs.org/dist/                                 | Official darwin tarball, unmodified. Ship `LICENSE` from the tarball. |
| python      | 3.12.11    | PSF-2.0              | https://github.com/astral-sh/python-build-standalone     | `install_only_stripped` build; bundled third-party libs listed in its `PYTHON.json`. |
| libpng      | 1.6.44     | libpng-2.0           | https://github.com/pnggroup/libpng                       | zlib-style licence. ImageMagick png delegate. Ship `LICENSE`. |
| libjpeg     | 3.0.4      | BSD-3-Clause         | https://github.com/libjpeg-turbo/libjpeg-turbo           | libjpeg-turbo. Some files remain under the IJG licence. ImageMagick jpeg delegate. Ship `LICENSE.md`. |
| freetype    | 2.13.3     | FTL                  | https://freetype.org/                                    | FreeType License (BSD-style with attribution); ship `FTL.TXT`; credit "Portions of this software are copyright © The FreeType Project". Also linked by libass and the GPL ffmpeg build. |
| harfbuzz    | 10.0.1     | MIT                  | https://github.com/harfbuzz/harfbuzz                     | MIT-style; ship `COPYING`. Library dependency of libass. |
| fribidi     | 1.0.16     | LGPL-2.1-or-later    | https://github.com/fribidi/fribidi                       | Library dependency of libass. Ship `COPYING`. |
| fontconfig  | 2.16.0     | MIT                  | https://gitlab.freedesktop.org/fontconfig/fontconfig     | MIT-style; ship `COPYING`. |
| libass      | 0.17.3     | ISC                  | https://github.com/libass/libass                         | ISC; ship `COPYING`. Linked into GPL ffmpeg for the `ass` filter. Needs fribidi, harfbuzz and freetype. |
| libx264     | 0.164.3108 | GPL-2.0-or-later     | https://code.videolan.org/videolan/x264                  | GPL build of x264 (not the commercial licence). Linked into ffmpeg. Ship `COPYING` from the x264 source. |
| imagemagick | 7.1.1-47   | ImageMagick          | https://github.com/ImageMagick/ImageMagick               | Apache-2.0-derived; ship `LICENSE`. Delegates limited to png/jpeg/webp/freetype/fontconfig (libpng and libjpeg rows above). |
| ffmpeg/ffprobe | 7.1.1   | GPL-2.0-or-later     | https://ffmpeg.org/releases/                             | Built in CI with `--enable-gpl --enable-libx264 --enable-libass --enable-libfreetype`. No x265, no nonfree. Ship `COPYING.GPLv2` + build flags. Source URL above. |
| whisper        | 0.4.2    | MIT                  | https://github.com/ml-explore/mlx-examples               | mlx-whisper, Apple silicon (`arm64`) only. The bundled command is `mlx_whisper`. Recipes use `mlx-community/whisper-small-mlx`, which downloads on first use into the Hugging Face cache and is not in the archive. Ship `LICENSE`. |
| openai-whisper | 20240930 | MIT                  | https://github.com/openai/whisper                        | openai-whisper for Intel (`x86_64`). The bundled command is `whisper`. Recipes call `whisper <file> --model small --output_dir <dir> --output_format <fmt>`. The speech model downloads on first use into `~/.cache/whisper` and is not in the archive. Ship `LICENSE`. |
| chromium    | 1.64.1     | BSD-3-Clause, Apache-2.0 | https://github.com/microsoft/playwright              | Chromium is BSD-3-Clause. Playwright is Apache-2.0. Pinned Playwright browser: Playwright 1.64.1, chromium revision 1248 and chromium_headless_shell revision 1248 (`config/playwright-pin.json`). Ship Chromium's `LICENSE` and Playwright's `LICENSE`. |
| codex       | 0.45.0     | Apache-2.0           | https://github.com/openai/codex                          | Official release binary; ship `LICENSE` + `NOTICE`. |
| gemini      | 0.9.0      | Apache-2.0           | https://github.com/google-gemini/gemini-cli              | `@google/gemini-cli` via bundled npm; ship `LICENSE`. |

Versions marked `pinNote` in the manifest are provisional until the CI build
confirms them; keep this table and `manifest.json` in lockstep.

## How to update

Bump the component in `toolchain/manifest.json` (version + source URL), update the
matching row here, and re-check the licence file inside the new upstream archive
(a licence change is a blocker, not a note). Rebuild via the CI workflow (later
M3-07 slice), run `toolchain/scripts/make-sums.sh` then `verify.sh` on the
unpacked bundle, and bump `manifest.version` (calendar `YYYY.MM.N`). Never add a
component without an SPDX identifier and a redistribution note in this table.
A new GPL component, or a configure flag that turns on GPL, must be stated in
the GPL terms section above, with the source URL.
