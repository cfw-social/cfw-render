#!/usr/bin/env bash
# build.sh <arm64|x86_64> <out-dir> — M3-07b / WI17.3.3. Builds the private
# toolchain bundle on a macOS runner from toolchain/manifest.json:
#   <out-dir>/cfw-toolchain-<version>-<arch>/{bin,lib,share,LICENSES.md,manifest.json,SHA256SUMS}
#   <out-dir>/cfw-toolchain-<version>-<arch>.tar.zst  (+ .sha256, .SHA256SUMS)
# A tool with "arch" is built only for that archive. No arch field means both.
# Every source download is pinned by manifest tools[].sha256; a "TODO-*" pin
# aborts unless CFW_TOOLCHAIN_ALLOW_UNPINNED=1 (first CI run prints PIN lines).
# The pin gate names every unpinned tool, including tools for the other arch.
# Env: CFW_TOOLCHAIN_MANIFEST (override manifest path, tests), CFW_TOOLCHAIN_WORK
# (scratch dir, default <out-dir>/.work), CFW_TOOLCHAIN_JOBS (make -j),
# CFW_TOOLCHAIN_PLAN=1 (print the selected steps and exit; no download, no compile).
# CFW_TOOLCHAIN_ALLOW_UNPINNED=1 is capture mode: every manifest tool prints
# "PIN <url> <sha256>" and the script exits before configure or compile.
# libx264 with no commit is fetched at the README commit 31e19f92.
# Needs: Xcode CLT, curl, tar with --zstd (brew zstd), pkg-config, nasm,
# cmake (libjpeg-turbo), meson and ninja (harfbuzz, fribidi). The macOS SDK
# supplies libexpat for fontconfig. See toolchain/README.md known limits.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=toolchain/scripts/lib.sh
source "$SELF_DIR/lib.sh"

arch="${1:-}"
out="${2:-}"
if [[ -z "$arch" || -z "$out" ]]; then
  echo "usage: build.sh <arm64|x86_64> <out-dir>" >&2
  exit 2
fi
# Manifest arch values are arm64 and x86_64. Accept the triple aliases
# tc_arch_triple already allows, and store the manifest vocabulary.
case "$arch" in
  aarch64) arch=arm64 ;;
  amd64) arch=x86_64 ;;
esac
triple="$(tc_arch_triple "$arch")"
MANIFEST="${CFW_TOOLCHAIN_MANIFEST:-$SELF_DIR/../manifest.json}"
[[ -f "$MANIFEST" ]] || tc_die "manifest not found: $MANIFEST"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

# --- manifest helpers (python3, no jq) ---------------------------------------
mf() { # mf <python expr over m>  — prints the result
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$MANIFEST" "$1"
}
tool_field() { # tool_field <name> <field> [default]
  python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
t=[t for t in m["tools"] if t["name"]==sys.argv[2]]
print(t[0].get(sys.argv[3], sys.argv[4] if len(sys.argv)>4 else "") if t else "")' "$MANIFEST" "$@"
}
tool_provides() { # comma-joined provides[] for one tool
  python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
t=[t for t in m["tools"] if t["name"]==sys.argv[2]]
if not t:
    sys.exit(1)
print(",".join(t[0].get("provides") or []))' "$MANIFEST" "$1"
}
tools_for_this_arch() {
  # Missing arch, or arch equal to this build, in manifest order.
  python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
arch=sys.argv[2]
names=[]
for t in m["tools"]:
    want=t.get("arch")
    if want in (None, "", arch):
        names.append(t["name"])
print(" ".join(names))' "$MANIFEST" "$arch"
}

version="$(mf 'm["version"]')"

# --- pin gate: refuse early, naming every unpinned tool -----------------------
if [[ "${CFW_TOOLCHAIN_ALLOW_UNPINNED:-0}" != "1" ]]; then
  unpinned="$(mf '" ".join(t["name"] for t in m["tools"] if str(t.get("sha256","TODO")).startswith("TODO") or not t.get("sha256"))')"
  if [[ -n "$unpinned" ]]; then
    tc_die "unpinned sha256 (TODO-*) for tool(s): $unpinned — run once with CFW_TOOLCHAIN_ALLOW_UNPINNED=1, paste the printed PIN hashes into manifest.json"
  fi
fi

# --- node --------------------------------------------------------------------
build_node() {
  local ver nodearch tgz shas upstream
  ver="$(tool_field node version)"
  nodearch=x64; [[ "$arch" == arm64 ]] && nodearch=arm64
  tgz="node-v${ver}-darwin-${nodearch}.tar.gz"
  shas="$dl/node-SHASUMS256-$ver.txt"
  curl -fsSL --retry 3 -o "$shas" "https://nodejs.org/dist/v${ver}/SHASUMS256.txt"
  upstream="$(awk -v f="$tgz" '$2==f{print $1}' "$shas")"
  [[ -n "$upstream" ]] || tc_die "node: $tgz not in upstream SHASUMS256.txt"
  tc_fetch "https://nodejs.org/dist/v${ver}/${tgz}" "$(tool_field node sha256)" "$dl/$tgz"
  [[ "$(tc_sha256 "$dl/$tgz")" == "$upstream" ]] || tc_die "node: archive does not match upstream SHASUMS256.txt"
  rm -rf "$src/node"; untar "$dl/$tgz" "$src/node"
  cp "$src/node/bin/node" "$bundle/bin/node"
  mkdir -p "$bundle/lib/node_modules"
  cp -R "$src/node/lib/node_modules/npm" "$bundle/lib/node_modules/npm"
  ln -sfn ../lib/node_modules/npm/bin/npm-cli.js "$bundle/bin/npm"
  ln -sfn ../lib/node_modules/npm/bin/npx-cli.js "$bundle/bin/npx"
}

# --- python (python-build-standalone, install_only) ---------------------------
build_python() {
  local ver tag tgz
  ver="$(tool_field python version)"
  tag="$(tool_field python pbsTag)"
  [[ -n "$tag" ]] || tc_die "python: manifest entry needs pbsTag (python-build-standalone release tag)"
  tgz="cpython-${ver}+${tag}-${triple}-install_only.tar.gz"
  tc_fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${tag}/${tgz}" \
    "$(tool_field python sha256)" "$dl/$tgz"
  rm -rf "$src/python"; mkdir -p "$src/python"
  tar -xf "$dl/$tgz" -C "$src/python"        # top-level dir is "python/"
  cp -R "$src/python/python/bin/." "$bundle/bin/"
  cp -R "$src/python/python/lib/." "$bundle/lib/"
}

# --- autotools helper ---------------------------------------------------------
configure_make() { # configure_make <srcdir> <configure args...>
  local d="$1"; shift
  (cd "$d" && ./configure --prefix="$stage" "$@" && make -j"$jobs" && make install)
}

require_cmd() { # require_cmd <command> <error>
  command -v "$1" >/dev/null 2>&1 || tc_die "$2"
}

# GitHub tag archive. The tag argument is the manifest version plus the
# project's own tag prefix (libpng and openai-whisper use "v"). Bytes are
# pinned by tools[].sha256. GitHub has changed archive compression before;
# a later mismatch means the pin must be refreshed, not a silent re-fetch.
fetch_github_tag() { # <tool> <tag> <dest-dir>
  local tool="$1" tag="$2" dest="$3" origin file
  origin="$(tool_field "$tool" source)"
  origin="${origin%/}"
  case "$origin" in
    https://github.com/*/*) ;;
    *) tc_die "$tool: source is not a GitHub repository URL: $origin" ;;
  esac
  file="${dest}-${tag}.tar.gz"
  tc_fetch "${origin}/archive/refs/tags/${tag}.tar.gz" "$(tool_field "$tool" sha256)" "$dl/$file"
  rm -rf "${src:?}/${dest:?}"
  untar "$dl/$file" "$src/$dest"
}

fetch_github_release() { # <tool> <tag> <filename> <dest-dir>
  local tool="$1" tag="$2" file="$3" dest="$4" origin
  origin="$(tool_field "$tool" source)"
  origin="${origin%/}"
  case "$origin" in
    https://github.com/*/*) ;;
    *) tc_die "$tool: source is not a GitHub repository URL: $origin" ;;
  esac
  tc_fetch "${origin}/releases/download/${tag}/${file}" "$(tool_field "$tool" sha256)" "$dl/$file"
  rm -rf "${src:?}/${dest:?}"
  untar "$dl/$file" "$src/$dest"
}

build_libpng() {
  local ver
  ver="$(tool_field libpng version)"
  # The v1.6.44 tag tree ships ./configure (no GitHub Release asset).
  fetch_github_tag libpng "v${ver}" libpng
  [[ -x "$src/libpng/configure" ]] || tc_die "libpng: tag archive has no configure script"
  configure_make "$src/libpng" --disable-static
}

build_libjpeg() {
  local ver
  ver="$(tool_field libjpeg version)"
  # libjpeg-turbo dropped autotools. CMake is a host build tool.
  require_cmd cmake "libjpeg: cmake is required to build libjpeg-turbo (host build tool, not a bundle library; see toolchain/README.md known limits)"
  fetch_github_release libjpeg "${ver}" "libjpeg-turbo-${ver}.tar.gz" libjpeg
  cmake -S "$src/libjpeg" -B "$src/libjpeg/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$stage" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_NAME_DIR=@rpath \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    -DENABLE_SHARED=ON \
    -DENABLE_STATIC=OFF
  cmake --build "$src/libjpeg/build" --parallel "$jobs"
  cmake --install "$src/libjpeg/build"
}

build_freetype() {
  local ver tgz
  ver="$(tool_field freetype version)"
  tgz="freetype-${ver}.tar.xz"
  tc_fetch "https://download.savannah.gnu.org/releases/freetype/${tgz}" "$(tool_field freetype sha256)" "$dl/$tgz"
  rm -rf "$src/freetype"; untar "$dl/$tgz" "$src/freetype"
  # harfbuzz is built later and links this freetype. Do not link the other way.
  configure_make "$src/freetype" --disable-static --with-harfbuzz=no --with-brotli=no --with-png=no --with-bzip2=no
}

build_harfbuzz() {
  local ver
  ver="$(tool_field harfbuzz version)"
  require_cmd meson "harfbuzz: meson is required (host build tool; see toolchain/README.md known limits)"
  require_cmd ninja "harfbuzz: ninja is required (host build tool; see toolchain/README.md known limits)"
  fetch_github_release harfbuzz "${ver}" "harfbuzz-${ver}.tar.xz" harfbuzz
  meson setup "$src/harfbuzz/build" "$src/harfbuzz" \
    --prefix="$stage" \
    --libdir="$stage/lib" \
    --buildtype=release \
    --default-library=shared \
    -Dtests=disabled \
    -Ddocs=disabled \
    -Dintrospection=disabled \
    -Dglib=disabled \
    -Dgobject=disabled \
    -Dcairo=disabled \
    -Dutilities=disabled \
    -Dfreetype=enabled \
    -Dcoretext=enabled
  ninja -C "$src/harfbuzz/build" install
}

build_fribidi() {
  local ver
  ver="$(tool_field fribidi version)"
  require_cmd meson "fribidi: meson is required (host build tool; see toolchain/README.md known limits)"
  require_cmd ninja "fribidi: ninja is required (host build tool; see toolchain/README.md known limits)"
  # Upstream tags this release v<version>. The asset name has no "v".
  fetch_github_release fribidi "v${ver}" "fribidi-${ver}.tar.xz" fribidi
  meson setup "$src/fribidi/build" "$src/fribidi" \
    --prefix="$stage" \
    --libdir="$stage/lib" \
    --buildtype=release \
    --default-library=shared \
    -Ddocs=false \
    -Dtests=false \
    -Dbin=false
  ninja -C "$src/fribidi/build" install
}

build_fontconfig() {
  local ver tgz
  ver="$(tool_field fontconfig version)"
  tgz="fontconfig-${ver}.tar.xz"
  tc_fetch "https://www.freedesktop.org/software/fontconfig/release/${tgz}" "$(tool_field fontconfig sha256)" "$dl/$tgz"
  rm -rf "$src/fontconfig"; untar "$dl/$tgz" "$src/fontconfig"
  # The release tarball ships src/fcobjshash.h, so gperf is not required.
  # A git checkout would need gperf; this script does not clone fontconfig.
  [[ -f "$src/fontconfig/src/fcobjshash.h" ]] || tc_die "fontconfig: src/fcobjshash.h is missing. gperf is not a manifest tool; use the freedesktop release tarball (see toolchain/README.md known limits)"
  # macOS SDK provides expat.h and libexpat. There is no expat manifest entry,
  # so this step does not download one. pkg-config will not see a brew expat
  # because PKG_CONFIG_LIBDIR is the stage dir; configure then falls back to -lexpat.
  if ! printf '%s\n' '#include <expat.h>' | cc -E - >/dev/null 2>&1; then
    tc_die "fontconfig: expat.h is not on the compiler path. expat is not a manifest tool (see toolchain/README.md known limits)"
  fi
  # sysconfdir/datadir inside the stage so fonts.conf ships with the bundle.
  configure_make "$src/fontconfig" --disable-static --disable-docs \
    --sysconfdir="$stage/etc" --datadir="$stage/share"
}

build_libass() {
  local ver
  ver="$(tool_field libass version)"
  fetch_github_release libass "${ver}" "libass-${ver}.tar.xz" libass
  # fribidi, harfbuzz and freetype are already in the stage. Core Text is the
  # macOS font provider, so fontconfig is not required for the ass filter.
  configure_make "$src/libass" --disable-static --enable-shared
}

build_libx264() {
  local ver origin commit file
  ver="$(tool_field libx264 version)"
  origin="$(tool_field libx264 source)"
  origin="${origin%/}"
  commit="$(tool_field libx264 commit)"
  # 0.164.3108 is an x264 point version, not a git tag. A real build does not
  # guess a snapshot. Capture mode fetches LIBX264_KNOWN_COMMIT before this
  # function runs. See toolchain/README.md known limits.
  if [[ -z "$commit" ]]; then
    tc_die "libx264: manifest version ${ver} has no commit field, and ${ver} is not a git tag on ${origin}. Add tools[].commit (see toolchain/README.md known limits). Refusing to guess a snapshot."
  fi
  file="x264-${commit}.tar.gz"
  tc_fetch "${origin}/-/archive/${commit}/${file}" "$(tool_field libx264 sha256)" "$dl/$file"
  rm -rf "$src/libx264"
  untar "$dl/$file" "$src/libx264"
  # x264 ships its own configure script.
  (cd "$src/libx264" && ./configure --prefix="$stage" --enable-shared --disable-static --enable-pic --disable-cli \
    && make -j"$jobs" && make install)
}

build_imagemagick() {
  local ver tgz delegate cfg
  ver="$(tool_field imagemagick version)"
  tgz="ImageMagick-${ver}.tar.gz"
  tc_fetch "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${ver}.tar.gz" "$(tool_field imagemagick sha256)" "$dl/$tgz"
  rm -rf "$src/imagemagick"; untar "$dl/$tgz" "$src/imagemagick"
  # PNG and JPEG are required delegates. =yes makes configure fail when the
  # stage libpng / libjpeg is missing. webp is not a manifest tool.
  configure_make "$src/imagemagick" --disable-static --without-x --with-freetype --with-fontconfig \
    --with-png=yes --with-jpeg=yes --with-webp=no \
    --without-perl --without-magick-plus-plus --disable-docs
  cfg="$src/imagemagick/MagickCore/magick-baseconfig.h"
  for delegate in PNG JPEG; do
    grep -q "#define MAGICKCORE_${delegate}_DELEGATE 1" "$cfg" \
      || tc_die "imagemagick: ${delegate} delegate is not enabled in ${cfg}"
  done
}

build_ffmpeg() {
  local ver tgz flag need seen f
  local -a flags
  ver="$(tool_field ffmpeg version)"
  tgz="ffmpeg-${ver}.tar.xz"
  tc_fetch "https://ffmpeg.org/releases/${tgz}" "$(tool_field ffmpeg sha256)" "$dl/$tgz"
  # Capture mode already hashed this archive and must not configure. configure
  # needs libx264 in the prefix, and a missing prefix stops the run before
  # whisper and openai-whisper print PIN lines.
  if [[ "${CFW_TOOLCHAIN_ALLOW_UNPINNED:-0}" == "1" ]]; then
    return 0
  fi
  rm -rf "$src/ffmpeg"; untar "$dl/$tgz" "$src/ffmpeg"
  # WI17.3.2: pass manifest buildFlags through. They must include
  # --enable-gpl --enable-libx264 --enable-libass --enable-libfreetype.
  # libx264, libass and freetype are built earlier in this same prefix.
  flags=()
  while IFS= read -r flag; do
    [[ -n "$flag" ]] || continue
    flags+=("$flag")
  done < <(python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
t=[t for t in m["tools"] if t["name"]=="ffmpeg"]
if not t:
    sys.exit("ffmpeg tool missing")
for flag in t[0].get("buildFlags") or []:
    print(flag)' "$MANIFEST")
  [[ ${#flags[@]} -gt 0 ]] || tc_die "ffmpeg: manifest buildFlags are empty"
  for need in --enable-gpl --enable-libx264 --enable-libass --enable-libfreetype; do
    seen=0
    for f in "${flags[@]}"; do
      [[ "$f" == "$need" ]] && seen=1
    done
    [[ "$seen" == 1 ]] || tc_die "ffmpeg: manifest buildFlags missing $need"
  done
  configure_make "$src/ffmpeg" "${flags[@]}" \
    --install-name-dir=@rpath --disable-doc --disable-debug
}

# Relocatable pip install. The venv holds the wheels. The wrapper uses the
# bundled python plus that venv's site-packages, so the archive can move.
# pyvenv.cfg stays absolute and is not used at runtime.
py_venv_from_artifact() { # <venv-dir> <artifact> <wrapper-path> <python -c body>
  local venv="$1" artifact="$2" wrapper="$3" body="$4"
  local py py_mm sp rel wheels
  py="$bundle/bin/python3"
  [[ -x "$py" ]] || tc_die "python: bundled python must be built before a pip step"
  "$py" -m pip --version >/dev/null 2>&1 || tc_die "python: bundled python has no pip module"
  rm -rf "$venv"
  "$py" -m venv "$venv"
  wheels="$work/wheels/$(basename "$venv")"
  rm -rf "$wheels"
  mkdir -p "$wheels" "$work/pip-cache"
  PIP_CACHE_DIR="$work/pip-cache" PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$venv/bin/python" -m pip wheel --wheel-dir "$wheels" "$artifact"
  PIP_CACHE_DIR="$work/pip-cache" PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$venv/bin/python" -m pip install --no-index --find-links "$wheels" "$artifact"
  py_mm="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  sp="$venv/lib/python${py_mm}/site-packages"
  [[ -d "$sp" ]] || tc_die "python: site-packages missing at $sp"
  rel="${sp#"$bundle/"}"
  cat >"$wrapper" <<EOF
#!/bin/sh
here="\$(cd "\$(dirname "\$0")" && pwd)"
export PYTHONPATH="\$here/../${rel}\${PYTHONPATH:+:\$PYTHONPATH}"
exec "\$here/python3" -c '${body}' "\$@"
EOF
  chmod +x "$wrapper"
}

build_mlx_whisper() {
  local ver url file base
  # Manifest tool name is "whisper". The command it provides is mlx_whisper.
  # There is no pipPackage field; the PyPI project is mlx-whisper (README).
  ver="$(tool_field whisper version)"
  [[ -n "$ver" ]] || tc_die "whisper: manifest version is empty"
  url="$(python3 -c 'import json,sys,urllib.request
project, version = sys.argv[1], sys.argv[2]
page = "https://pypi.org/pypi/%s/%s/json" % (project, version)
with urllib.request.urlopen(page) as fh:
    data = json.load(fh)
sdists = [item["url"] for item in data.get("urls") or [] if item.get("packagetype") == "sdist"]
if not sdists:
    sys.exit("no sdist on PyPI for %s==%s" % (project, version))
sys.stdout.write(sdists[0])' mlx-whisper "$ver")"
  base="${url##*/}"
  file="$dl/$base"
  tc_fetch "$url" "$(tool_field whisper sha256)" "$file"
  py_venv_from_artifact "$bundle/lib/mlx-whisper-venv" "$file" "$bundle/bin/mlx_whisper" \
    'import sys; from mlx_whisper.cli import main; sys.exit(main())'
}

build_openai_whisper() {
  local ver file
  ver="$(tool_field openai-whisper version)"
  [[ -n "$ver" ]] || tc_die "openai-whisper: manifest version is empty"
  # Tag is v + the manifest version (v20240930). The tarball is the pin.
  # pip wheel then installs that pin and its PyPI dependencies into the venv.
  fetch_github_tag openai-whisper "v${ver}" openai-whisper
  file="$dl/openai-whisper-v${ver}.tar.gz"
  [[ -f "$file" ]] || tc_die "openai-whisper: pinned tarball was not saved at $file"
  py_venv_from_artifact "$bundle/lib/openai-whisper-venv" "$file" "$bundle/bin/whisper" \
    'import sys; from whisper.transcribe import cli; sys.exit(cli())'
}

build_chromium() {
  local pin_file pw crev hrev manifest_pw manifest_crev manifest_hrev browsers bin_path rel
  pin_file="$SELF_DIR/../../config/playwright-pin.json"
  [[ -f "$pin_file" ]] || tc_die "chromium: pin file missing: $pin_file"
  pw="$(python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["playwright"])' "$pin_file")"
  crev="$(python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["chromiumRevision"])' "$pin_file")"
  hrev="$(python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["chromiumHeadlessShellRevision"])' "$pin_file")"
  [[ -n "$pw" && -n "$crev" && -n "$hrev" ]] || tc_die "chromium: $pin_file is missing playwright or a revision"
  manifest_pw="$(tool_field chromium playwright)"
  manifest_crev="$(tool_field chromium chromiumRevision)"
  manifest_hrev="$(tool_field chromium chromiumHeadlessShellRevision)"
  if [[ "$pw" != "$manifest_pw" || "$crev" != "$manifest_crev" || "$hrev" != "$manifest_hrev" ]]; then
    tc_die "chromium: manifest does not match ${pin_file} (pin ${pw} / ${crev} / ${hrev}, manifest ${manifest_pw} / ${manifest_crev} / ${manifest_hrev})"
  fi
  [[ -x "$bundle/bin/npx" ]] || tc_die "chromium: bundled node must be built first"
  browsers="$bundle/share/ms-playwright"
  rm -rf "$browsers"
  mkdir -p "$browsers" "$work/npm-cache"
  # Version and revisions come only from the pin file. Playwright fetches the
  # matching chromium and chromium_headless_shell zips. Manifest sha256 is the
  # pin gate (same as codex): there is no single archive for tc_fetch.
  PLAYWRIGHT_BROWSERS_PATH="$browsers" \
    npm_config_cache="$work/npm-cache" \
    PATH="$bundle/bin:$PATH" \
    "$bundle/bin/npx" --yes "playwright@${pw}" install chromium
  [[ -f "$browsers/chromium-${crev}/INSTALLATION_COMPLETE" ]] \
    || tc_die "chromium: pinned chromium-${crev} did not finish installing"
  [[ -f "$browsers/chromium_headless_shell-${hrev}/INSTALLATION_COMPLETE" ]] \
    || tc_die "chromium: pinned chromium_headless_shell-${hrev} did not finish installing"
  bin_path=""
  while IFS= read -r rel; do
    bin_path="$rel"
    break
  done < <(find "$browsers/chromium-${crev}" -type f \( -name 'Chromium' -o -name 'chrome' \) -perm -111)
  [[ -n "$bin_path" ]] || tc_die "chromium: no Chromium binary under chromium-${crev}"
  rel="${bin_path#"$bundle/"}"
  cat >"$bundle/bin/chromium" <<EOF
#!/bin/sh
here="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\$here/../${rel}" "\$@"
EOF
  chmod +x "$bundle/bin/chromium"
}

build_codex() {
  local ver
  ver="$(tool_field codex version)"
  [[ -x "$bundle/bin/node" ]] || tc_die "codex: bundled node must be built first"
  rm -rf "$bundle/codex"
  # npm verifies the registry tarball's own integrity (sha512); the manifest
  # sha256 for codex is the pin gate only (nothing is tc_fetch'ed here).
  PATH="$bundle/bin:$PATH" "$bundle/bin/node" "$bundle/lib/node_modules/npm/bin/npm-cli.js" \
    install -g --prefix "$bundle/codex" --no-fund --no-audit "@openai/codex@${ver}"
  cat >"$bundle/bin/codex" <<'WRAP'
#!/bin/sh
here="$(cd "$(dirname "$0")" && pwd)"
PATH="$here:$PATH" exec "$here/../codex/bin/codex" "$@"
WRAP
  chmod +x "$bundle/bin/codex"
}

build_gemini() {
  local ver
  ver="$(tool_field gemini version)"
  [[ -x "$bundle/bin/node" ]] || tc_die "gemini: bundled node must be built first"
  rm -rf "$bundle/gemini"
  # Same as codex: npm checks the registry tarball's sha512.
  PATH="$bundle/bin:$PATH" "$bundle/bin/node" "$bundle/lib/node_modules/npm/bin/npm-cli.js" \
    install -g --prefix "$bundle/gemini" --no-fund --no-audit "@google/gemini-cli@${ver}"
  cat >"$bundle/bin/gemini" <<'WRAP'
#!/bin/sh
here="$(cd "$(dirname "$0")" && pwd)"
PATH="$here:$PATH" exec "$here/../gemini/bin/gemini" "$@"
WRAP
  chmod +x "$bundle/bin/gemini"
}

# x264 0.164.3108 is a point version, not a git tag. toolchain/README.md
# records the distributors' commit. Capture fetches that archive when
# tools[].commit is empty. build_libx264 still refuses a real build that
# has no commit, so a pinned build cannot guess a snapshot.
LIBX264_KNOWN_COMMIT="31e19f92f00c7003fa115047ce50978bc98c3a0d"

tools_in_manifest_order() {
  python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
print(" ".join(t["name"] for t in m["tools"]))' "$MANIFEST"
}

# PyPI sdist URL for mlx-whisper. curl (not urllib) so a fixture can answer
# with no network. The JSON body is not a pin; tc_fetch pins the sdist.
whisper_sdist_url() {
  local ver="$1" json url
  json="$dl/whisper-pypi.json"
  curl -fsSL --retry 3 -o "$json" "https://pypi.org/pypi/mlx-whisper/${ver}/json"
  url="$(python3 -c 'import json,sys
data=json.load(open(sys.argv[1]))
sdists=[item["url"] for item in data.get("urls") or [] if item.get("packagetype")=="sdist"]
if not sdists:
    sys.exit("no sdist on PyPI for mlx-whisper")
sys.stdout.write(sdists[0])' "$json")"
  [[ -n "$url" ]] || return 1
  printf '%s\n' "$url"
}

# Archive URL for one manifest tool. Same URL the real recipe downloads.
# chromium, codex and gemini have no tc_fetch archive in the build; capture
# pins the npm tarball those steps install. One URL, nothing else, on stdout.
capture_pin_url() {
  local t="$1" ver origin commit tag nodearch pkg pw pin_file
  case "$t" in
    node)
      ver="$(tool_field node version)"
      [[ -n "$ver" ]] || return 1
      nodearch=x64; [[ "$arch" == arm64 ]] && nodearch=arm64
      printf '%s\n' "https://nodejs.org/dist/v${ver}/node-v${ver}-darwin-${nodearch}.tar.gz"
      ;;
    python)
      ver="$(tool_field python version)"
      tag="$(tool_field python pbsTag)"
      [[ -n "$ver" && -n "$tag" ]] || return 1
      printf '%s\n' "https://github.com/astral-sh/python-build-standalone/releases/download/${tag}/cpython-${ver}+${tag}-${triple}-install_only.tar.gz"
      ;;
    libpng)
      ver="$(tool_field libpng version)"
      origin="$(tool_field libpng source)"; origin="${origin%/}"
      [[ -n "$ver" && -n "$origin" ]] || return 1
      printf '%s\n' "${origin}/archive/refs/tags/v${ver}.tar.gz"
      ;;
    libjpeg)
      ver="$(tool_field libjpeg version)"
      origin="$(tool_field libjpeg source)"; origin="${origin%/}"
      [[ -n "$ver" && -n "$origin" ]] || return 1
      printf '%s\n' "${origin}/releases/download/${ver}/libjpeg-turbo-${ver}.tar.gz"
      ;;
    freetype)
      ver="$(tool_field freetype version)"
      [[ -n "$ver" ]] || return 1
      printf '%s\n' "https://download.savannah.gnu.org/releases/freetype/freetype-${ver}.tar.xz"
      ;;
    harfbuzz)
      ver="$(tool_field harfbuzz version)"
      origin="$(tool_field harfbuzz source)"; origin="${origin%/}"
      [[ -n "$ver" && -n "$origin" ]] || return 1
      printf '%s\n' "${origin}/releases/download/${ver}/harfbuzz-${ver}.tar.xz"
      ;;
    fribidi)
      ver="$(tool_field fribidi version)"
      origin="$(tool_field fribidi source)"; origin="${origin%/}"
      [[ -n "$ver" && -n "$origin" ]] || return 1
      printf '%s\n' "${origin}/releases/download/v${ver}/fribidi-${ver}.tar.xz"
      ;;
    fontconfig)
      ver="$(tool_field fontconfig version)"
      [[ -n "$ver" ]] || return 1
      printf '%s\n' "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${ver}.tar.xz"
      ;;
    libass)
      ver="$(tool_field libass version)"
      origin="$(tool_field libass source)"; origin="${origin%/}"
      [[ -n "$ver" && -n "$origin" ]] || return 1
      printf '%s\n' "${origin}/releases/download/${ver}/libass-${ver}.tar.xz"
      ;;
    libx264)
      origin="$(tool_field libx264 source)"; origin="${origin%/}"
      [[ -n "$origin" ]] || return 1
      commit="$(tool_field libx264 commit)"
      if [[ -z "$commit" ]]; then
        commit="$LIBX264_KNOWN_COMMIT"
      fi
      printf '%s\n' "${origin}/-/archive/${commit}/x264-${commit}.tar.gz"
      ;;
    imagemagick)
      ver="$(tool_field imagemagick version)"
      [[ -n "$ver" ]] || return 1
      printf '%s\n' "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${ver}.tar.gz"
      ;;
    ffmpeg)
      ver="$(tool_field ffmpeg version)"
      [[ -n "$ver" ]] || return 1
      printf '%s\n' "https://ffmpeg.org/releases/ffmpeg-${ver}.tar.xz"
      ;;
    whisper)
      ver="$(tool_field whisper version)"
      [[ -n "$ver" ]] || return 1
      whisper_sdist_url "$ver"
      ;;
    openai-whisper)
      ver="$(tool_field openai-whisper version)"
      origin="$(tool_field openai-whisper source)"; origin="${origin%/}"
      [[ -n "$ver" && -n "$origin" ]] || return 1
      printf '%s\n' "${origin}/archive/refs/tags/v${ver}.tar.gz"
      ;;
    chromium)
      pin_file="$SELF_DIR/../../config/playwright-pin.json"
      [[ -f "$pin_file" ]] || return 1
      pw="$(python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["playwright"])' "$pin_file")"
      [[ -n "$pw" ]] || return 1
      printf '%s\n' "https://registry.npmjs.org/playwright/-/playwright-${pw}.tgz"
      ;;
    codex)
      ver="$(tool_field codex version)"
      [[ -n "$ver" ]] || return 1
      printf '%s\n' "https://registry.npmjs.org/@openai/codex/-/codex-${ver}.tgz"
      ;;
    gemini)
      ver="$(tool_field gemini version)"
      pkg="$(tool_field gemini npmPackage)"
      [[ -n "$ver" && -n "$pkg" ]] || return 1
      printf '%s\n' "https://registry.npmjs.org/${pkg}/-/${pkg##*/}-${ver}.tgz"
      ;;
    *)
      return 1
      ;;
  esac
}

# One case list for the plan and the real build. An unknown tool dies here,
# before any download, when CFW_TOOLCHAIN_PLAN=1.
recipe_for() {
  case "$1" in
    node) echo build_node ;;
    python) echo build_python ;;
    libpng) echo build_libpng ;;
    libjpeg) echo build_libjpeg ;;
    freetype) echo build_freetype ;;
    harfbuzz) echo build_harfbuzz ;;
    fribidi) echo build_fribidi ;;
    fontconfig) echo build_fontconfig ;;
    libass) echo build_libass ;;
    libx264) echo build_libx264 ;;
    imagemagick) echo build_imagemagick ;;
    ffmpeg) echo build_ffmpeg ;;
    whisper) echo build_mlx_whisper ;;
    openai-whisper) echo build_openai_whisper ;;
    chromium) echo build_chromium ;;
    codex) echo build_codex ;;
    gemini) echo build_gemini ;;
    *) return 1 ;;
  esac
}

selected="$(tools_for_this_arch)"
[[ -n "$selected" ]] || tc_die "no manifest tools selected for arch ${arch}"

if [[ "${CFW_TOOLCHAIN_PLAN:-0}" == "1" ]]; then
  for t in $selected; do
    if ! fn="$(recipe_for "$t")"; then
      tc_die "no build recipe for tool '$t'"
    fi
    echo "step $t recipe=$fn provides=$(tool_provides "$t")"
  done
  echo "plan-ok arch=$arch"
  exit 0
fi

# Capture mode: one run, every manifest tool, in manifest order (both arches'
# speech tools included). tc_fetch prints "PIN <url> <sha256>". No configure
# and no compile, so ffmpeg does not require libx264 in the prefix and later
# tools still print. A pinned build (this variable unset) is unchanged.
if [[ "${CFW_TOOLCHAIN_ALLOW_UNPINNED:-0}" == "1" ]]; then
  work="${CFW_TOOLCHAIN_WORK:-$out/.work}"
  dl="$work/dl"
  mkdir -p "$dl"
  capture_names="$(tools_in_manifest_order)"
  [[ -n "$capture_names" ]] || tc_die "no manifest tools to capture"
  for t in $capture_names; do
    if ! url="$(capture_pin_url "$t")"; then
      tc_die "no pin url for tool '$t'"
    fi
    [[ -n "$url" ]] || tc_die "no pin url for tool '$t'"
    base="${url##*/}"
    tc_fetch "$url" "$(tool_field "$t" sha256)" "$dl/${t}--${base}"
  done
  echo "capture-ok arch=$arch"
  exit 0
fi

name="cfw-toolchain-${version}-${arch}"
bundle="$out/$name"
work="${CFW_TOOLCHAIN_WORK:-$out/.work}"
dl="$work/dl"
src="$work/src"
stage="$work/stage"       # autotools --prefix; later copied into bundle
jobs="${CFW_TOOLCHAIN_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
rm -rf "$bundle" "$stage"
mkdir -p "$bundle/bin" "$bundle/lib" "$bundle/share" "$dl" "$src" "$stage/bin" "$stage/lib"
export PKG_CONFIG_PATH="$stage/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$stage/lib/pkgconfig"   # never resolve brew .pc files
export CPPFLAGS="-I$stage/include"
export LDFLAGS="-L$stage/lib"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"

echo "build: $name ($triple) -> $out"

untar() { # untar <archive> <dest-dir>  (strips top-level dir)
  mkdir -p "$2"
  tar -xf "$1" -C "$2" --strip-components=1
}

# --- run ----------------------------------------------------------------------
for t in $selected; do
  echo "== $t =="
  if ! fn="$(recipe_for "$t")"; then
    tc_die "no build recipe for tool '$t'"
  fi
  "$fn"
done

# Stage (autotools prefix) -> bundle, then make everything @rpath-relative.
echo "== stage -> bundle =="
for d in bin lib share etc; do
  [[ -d "$stage/$d" ]] || continue
  mkdir -p "$bundle/$d"
  cp -R "$stage/$d/." "$bundle/$d/"
done
rm -rf "$bundle/lib/pkgconfig" "$bundle/share/man" "$bundle/share/doc"
find "$bundle/lib" -name '*.la' -delete
tc_rpath_fix "$bundle"

cp "$SELF_DIR/../LICENSES.md" "$bundle/LICENSES.md"
cp "$MANIFEST" "$bundle/manifest.json"
# WI17.3.5 runs bin/cfw-render-preflight.sh --bundle from this unpacked tree.
# That script sources cfw-render-lib.sh beside it and reads
# config/playwright-pin.json from the bundle. Copy the scripts and the pin
# before make-sums.sh so they are in SHA256SUMS. Missing either script is
# "no preflight".
tc_install_bundle_scripts "$bundle" "$SELF_DIR/../../bin"

"$SELF_DIR/make-sums.sh" "$bundle"
"$SELF_DIR/verify.sh" "$bundle"

echo "== archive =="
tar --zstd -cf "$out/$name.tar.zst" -C "$out" "$name"
sum="$(tc_sha256 "$out/$name.tar.zst")"
size="$(stat -f %z "$out/$name.tar.zst" 2>/dev/null || stat -c %s "$out/$name.tar.zst")"
echo "$sum  $name.tar.zst" >"$out/$name.tar.zst.sha256"
cp "$bundle/SHA256SUMS" "$out/$name.SHA256SUMS"
echo "build: $name.tar.zst sha256=$sum sizeBytes=$size"
