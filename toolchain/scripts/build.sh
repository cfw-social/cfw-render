#!/usr/bin/env bash
# build.sh <arm64|x86_64> <out-dir> — M3-07b. Builds the private toolchain
# bundle on a macOS runner from toolchain/manifest.json:
#   <out-dir>/cfw-toolchain-<version>-<arch>/{bin,lib,share,LICENSES.md,manifest.json,SHA256SUMS}
#   <out-dir>/cfw-toolchain-<version>-<arch>.tar.zst  (+ .sha256, .SHA256SUMS)
# Every source download is pinned by manifest tools[].sha256; a "TODO-*" pin
# aborts unless CFW_TOOLCHAIN_ALLOW_UNPINNED=1 (first CI run prints PIN lines).
# Env: CFW_TOOLCHAIN_MANIFEST (override manifest path, tests), CFW_TOOLCHAIN_WORK
# (scratch dir, default <out-dir>/.work), CFW_TOOLCHAIN_JOBS (make -j).
# Needs: Xcode CLT, curl, tar with --zstd (brew zstd), pkg-config/nasm for ffmpeg.
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

version="$(mf 'm["version"]')"
tools="$(mf '" ".join(t["name"] for t in m["tools"])')"

# --- pin gate: refuse early, naming every unpinned tool -----------------------
if [[ "${CFW_TOOLCHAIN_ALLOW_UNPINNED:-0}" != "1" ]]; then
  unpinned="$(mf '" ".join(t["name"] for t in m["tools"] if str(t.get("sha256","TODO")).startswith("TODO") or not t.get("sha256"))')"
  if [[ -n "$unpinned" ]]; then
    tc_die "unpinned sha256 (TODO-*) for tool(s): $unpinned — run once with CFW_TOOLCHAIN_ALLOW_UNPINNED=1, paste the printed PIN hashes into manifest.json"
  fi
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

build_freetype() {
  local ver tgz
  ver="$(tool_field freetype version)"
  tgz="freetype-${ver}.tar.xz"
  tc_fetch "https://download.savannah.gnu.org/releases/freetype/${tgz}" "$(tool_field freetype sha256)" "$dl/$tgz"
  rm -rf "$src/freetype"; untar "$dl/$tgz" "$src/freetype"
  configure_make "$src/freetype" --disable-static --with-harfbuzz=no --with-brotli=no --with-png=no --with-bzip2=no
}

build_fontconfig() {
  local ver tgz
  ver="$(tool_field fontconfig version)"
  tgz="fontconfig-${ver}.tar.xz"
  tc_fetch "https://www.freedesktop.org/software/fontconfig/release/${tgz}" "$(tool_field fontconfig sha256)" "$dl/$tgz"
  rm -rf "$src/fontconfig"; untar "$dl/$tgz" "$src/fontconfig"
  # sysconfdir/datadir inside the stage so fonts.conf ships with the bundle.
  configure_make "$src/fontconfig" --disable-static --disable-docs \
    --sysconfdir="$stage/etc" --datadir="$stage/share"
}

build_imagemagick() {
  local ver tgz
  ver="$(tool_field imagemagick version)"
  tgz="ImageMagick-${ver}.tar.gz"
  tc_fetch "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${ver}.tar.gz" "$(tool_field imagemagick sha256)" "$dl/$tgz"
  rm -rf "$src/imagemagick"; untar "$dl/$tgz" "$src/imagemagick"
  configure_make "$src/imagemagick" --disable-static --without-x --with-freetype --with-fontconfig \
    --without-perl --without-magick-plus-plus --disable-docs
}

build_ffmpeg() {
  local ver tgz
  ver="$(tool_field ffmpeg version)"
  tgz="ffmpeg-${ver}.tar.xz"
  tc_fetch "https://ffmpeg.org/releases/${tgz}" "$(tool_field ffmpeg sha256)" "$dl/$tgz"
  rm -rf "$src/ffmpeg"; untar "$dl/$tgz" "$src/ffmpeg"
  # LGPL-pure: no external codec libs at all in this first build (native
  # h264 decode, native aac encode; libx264/x265 absent). See README.
  configure_make "$src/ffmpeg" --disable-gpl --disable-nonfree \
    --disable-libx264 --disable-libx265 --enable-shared --disable-static \
    --install-name-dir=@rpath --disable-doc --disable-debug
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

# --- run ----------------------------------------------------------------------
for t in $tools; do
  echo "== $t =="
  case "$t" in
    node) build_node ;;
    python) build_python ;;
    freetype) build_freetype ;;
    fontconfig) build_fontconfig ;;
    imagemagick) build_imagemagick ;;
    ffmpeg) build_ffmpeg ;;
    codex) build_codex ;;
    gemini) build_gemini ;;
    *) tc_die "no build recipe for tool '$t'" ;;
  esac
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

"$SELF_DIR/make-sums.sh" "$bundle"
"$SELF_DIR/verify.sh" "$bundle"

echo "== archive =="
tar --zstd -cf "$out/$name.tar.zst" -C "$out" "$name"
sum="$(tc_sha256 "$out/$name.tar.zst")"
size="$(stat -f %z "$out/$name.tar.zst" 2>/dev/null || stat -c %s "$out/$name.tar.zst")"
echo "$sum  $name.tar.zst" >"$out/$name.tar.zst.sha256"
cp "$bundle/SHA256SUMS" "$out/$name.SHA256SUMS"
echo "build: $name.tar.zst sha256=$sum sizeBytes=$size"
