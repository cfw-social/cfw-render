#!/usr/bin/env bash
# make-sums.sh <bundle-dir> — M3-07a. Writes <bundle-dir>/SHA256SUMS covering
# every regular file under the dir (format: `<sha256>  <relative path>`),
# the file verify.sh checks against. Uses sha256sum where present, else
# macOS shasum -a 256.
set -euo pipefail

bundle="${1:-}"
if [[ -z "$bundle" || ! -d "$bundle" ]]; then
  echo "usage: make-sums.sh <bundle-dir>" >&2
  exit 2
fi
bundle="$(cd "$bundle" && pwd)"

if command -v sha256sum >/dev/null 2>&1; then
  hasher=(sha256sum)
else
  hasher=(shasum -a 256)
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
(
  cd "$bundle"
  find . -type f ! -name SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do
    "${hasher[@]}" "$f"
  done
) >"$tmp"
mv "$tmp" "$bundle/SHA256SUMS"
trap - EXIT
echo "make-sums: wrote $(wc -l <"$bundle/SHA256SUMS" | tr -d ' ') entries to $bundle/SHA256SUMS"
