#!/usr/bin/env bash
# verify.sh <bundle-dir> — M3-07a. Verifies a cfw-toolchain bundle directory:
#   (a) every regular file matches SHA256SUMS (written by make-sums.sh);
#   (b) no Mach-O file links against, or carries an LC_RPATH into,
#       /opt/homebrew or /usr/local — a bundle must be relocatable to a Mac
#       with no Homebrew at all.
# Exit 1 listing every offender; exit 0 with a count line otherwise.
# Set CFW_VERIFY_FORCE_STRINGS=1 to force the `strings` fallback used when
# `otool` is unavailable.
set -euo pipefail

bundle="${1:-}"
if [[ -z "$bundle" || ! -d "$bundle" ]]; then
  echo "usage: verify.sh <bundle-dir>" >&2
  exit 2
fi
bundle="$(cd "$bundle" && pwd)"

offenders=()
note() { echo "  $*"; }

# --- (a) checksums ----------------------------------------------------------
if [[ ! -f "$bundle/SHA256SUMS" ]]; then
  offenders+=("SHA256SUMS: missing")
else
  sums_out=""
  if command -v sha256sum >/dev/null 2>&1; then
    sums_out="$(cd "$bundle" && sha256sum -c --quiet SHA256SUMS 2>&1)" || true
  else
    sums_out="$(cd "$bundle" && shasum -a 256 -c --quiet SHA256SUMS 2>&1)" || true
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      *": FAILED"*|*"No such file"*) offenders+=("checksum: $line") ;;
    esac
  done <<<"$sums_out"
  # Files present but not listed in SHA256SUMS are offenders too.
  while IFS= read -r f; do
    rel="${f#"$bundle"/}"
    [[ "$rel" == "SHA256SUMS" ]] && continue
    if ! grep -qF -- "  $rel" "$bundle/SHA256SUMS"; then
      offenders+=("checksum: $rel: not listed in SHA256SUMS")
    fi
  done < <(find "$bundle" -type f | LC_ALL=C sort)
fi

# --- (b) Mach-O link / rpath scan -------------------------------------------
use_strings=0
if [[ "${CFW_VERIFY_FORCE_STRINGS:-0}" == "1" ]] || ! command -v otool >/dev/null 2>&1; then
  use_strings=1
  note "otool unavailable or CFW_VERIFY_FORCE_STRINGS=1 — using 'strings' fallback for Mach-O scan"
fi
macho_count=0
while IFS= read -r f; do
  file -b "$f" 2>/dev/null | grep -q 'Mach-O' || continue
  macho_count=$((macho_count + 1))
  rel="${f#"$bundle"/}"
  hits=""
  if (( use_strings )); then
    # stdin, not a path: macOS strings parses Mach-O headers for a path
    # argument and refuses odd/truncated files; raw-byte scan is what we want.
    hits="$(strings -a - <"$f" 2>/dev/null | grep -E '^/(opt/homebrew|usr/local)/' || true)"
  else
    libs="$(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -E '^/(opt/homebrew|usr/local)/' || true)"
    rpaths="$(otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r && /path /{print $2; r=0}' | grep -E '^/(opt/homebrew|usr/local)/' || true)"
    hits="$(printf '%s\n%s\n' "$libs" "$rpaths" | sed '/^$/d')"
  fi
  if [[ -n "$hits" ]]; then
    while IFS= read -r h; do
      offenders+=("macho: $rel -> $h")
    done <<<"$hits"
  fi
done < <(find "$bundle" -type f | LC_ALL=C sort)

if (( ${#offenders[@]} > 0 )); then
  echo "verify: FAILED (${#offenders[@]} offender(s)) in $bundle" >&2
  for o in "${offenders[@]}"; do
    echo "  $o" >&2
  done
  exit 1
fi
total="$(find "$bundle" -type f | wc -l | tr -d ' ')"
echo "verify: OK — $total file(s) checksummed, $macho_count Mach-O file(s) clean of /opt/homebrew and /usr/local"
exit 0
