#!/usr/bin/env bash
# lib.sh — M3-07b. Shared helpers for toolchain/scripts/build.sh and
# release.sh. Source it; do not execute. bash + python3 + Xcode CLT only.
#
#   tc_arch_triple <arm64|x86_64>   -> aarch64-apple-darwin | x86_64-apple-darwin
#   tc_sha256 <file>                -> hex digest
#   tc_fetch <url> <sha256> <dest>  -> curl + pin check. sha256 "TODO-*" fails
#                                      unless CFW_TOOLCHAIN_ALLOW_UNPINNED=1,
#                                      in which case the real hash is printed
#                                      as "PIN <url> <sha256>" to paste back.
#   tc_rpath_fix <stage-dir>        -> make every Mach-O under <stage> relocatable.

tc_die() { echo "toolchain: ERROR: $*" >&2; exit 1; }

tc_arch_triple() {
  case "${1:-}" in
    arm64|aarch64) echo "aarch64-apple-darwin" ;;
    x86_64|amd64) echo "x86_64-apple-darwin" ;;
    *) tc_die "unknown arch '${1:-}' (expected arm64|x86_64)" ;;
  esac
}

tc_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

tc_fetch() {
  local url="$1" want="$2" dest="$3" got
  mkdir -p "$(dirname "$dest")"
  if [[ ! -f "$dest" ]]; then
    echo "fetch: $url"
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  got="$(tc_sha256 "$dest")"
  if [[ "$want" == TODO-* || -z "$want" ]]; then
    if [[ "${CFW_TOOLCHAIN_ALLOW_UNPINNED:-0}" != "1" ]]; then
      tc_die "unpinned source $url (sha256='$want'); set CFW_TOOLCHAIN_ALLOW_UNPINNED=1 for a first build, then pin"
    fi
    echo "PIN $url $got"
    return 0
  fi
  if [[ "$got" != "$want" ]]; then
    rm -f "$dest"
    tc_die "sha256 mismatch for $url: want $want got $got"
  fi
}

# tc_rpath_fix <stage>: for every Mach-O file under <stage>:
#   - dylibs get `-id @rpath/<basename>`
#   - any load command pointing into <stage>/lib/... (or brew) becomes @rpath/<basename>
#   - LC_RPATH @loader_path/../lib is added (ignore "already exists" errors)
tc_rpath_fix() {
  local stage="$1" f dep base
  stage="$(cd "$stage" && pwd)"
  while IFS= read -r f; do
    file -b "$f" 2>/dev/null | grep -q 'Mach-O' || continue
    chmod u+w "$f"
    case "$f" in
      *.dylib|*.so)
        install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null || true ;;
    esac
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      base="$(basename "$dep")"
      install_name_tool -change "$dep" "@rpath/$base" "$f" 2>/dev/null || true
    done < <(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -E "^($stage|/opt/homebrew|/usr/local)/" || true)
    install_name_tool -add_rpath "@loader_path/../lib" "$f" 2>/dev/null || true
    # re-sign ad hoc so the modified binary still launches (G0 replaces this).
    codesign -f -s - "$f" >/dev/null 2>&1 || true
  done < <(find "$stage" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) | LC_ALL=C sort)
}
