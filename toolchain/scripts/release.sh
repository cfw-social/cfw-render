#!/usr/bin/env bash
# release.sh <dist-dir> — M3-07b. Publishes built toolchain archives to R2.
# For each <dist>/*.tar.zst: sha256 + size, `aws s3 cp` to
#   s3://$R2_TOOLCHAIN_BUCKET/toolchain/<version>/<file>
# then writes <dist>/toolchain-manifest.json
#   { version, minAppVersion, archives: {arm64:{url,sha256,sizeBytes}, x86_64:{...}}, publishedAt }
# and uploads it to toolchain/manifest.json (current pointer) and
# toolchain/<version>/manifest.json.
# Env: R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_TOOLCHAIN_BUCKET
#      R2_TOOLCHAIN_PUBLIC_BASE (url prefix; default https://<bucket>.r2.dev)
#      CFW_RELEASE_DRY_RUN=1 — print the aws commands instead of running them.
#      CFW_TOOLCHAIN_MANIFEST — manifest path override (tests).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=toolchain/scripts/lib.sh
source "$SELF_DIR/lib.sh"

dist="${1:-}"
if [[ -z "$dist" || ! -d "$dist" ]]; then
  echo "usage: release.sh <dist-dir>" >&2
  exit 2
fi
dist="$(cd "$dist" && pwd)"
MANIFEST="${CFW_TOOLCHAIN_MANIFEST:-$SELF_DIR/../manifest.json}"
dry="${CFW_RELEASE_DRY_RUN:-0}"

if [[ "$dry" != "1" ]]; then
  for v in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_TOOLCHAIN_BUCKET; do
    [[ -n "${!v:-}" ]] || tc_die "release: $v is not set"
  done
  export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION=auto
fi
bucket="${R2_TOOLCHAIN_BUCKET:-cfw-toolchain}"
account="${R2_ACCOUNT_ID:-ACCOUNT}"
endpoint="https://${account}.r2.cloudflarestorage.com"
public_base="${R2_TOOLCHAIN_PUBLIC_BASE:-https://${bucket}.r2.dev}"
public_base="${public_base%/}"

read -r version min_app < <(python3 -c 'import json,sys
m=json.load(open(sys.argv[1])); print(m["version"], m.get("minAppVersion","1.0.0"))' "$MANIFEST")

s3cp() { # s3cp <local> <key>
  if [[ "$dry" == "1" ]]; then
    echo "DRY: aws s3 cp --endpoint-url $endpoint $1 s3://$bucket/$2"
  else
    aws s3 cp --endpoint-url "$endpoint" "$1" "s3://$bucket/$2"
  fi
}

entries=()   # "<arch> <file> <sha256> <size>"
shopt -s nullglob
for f in "$dist"/*.tar.zst; do
  base="$(basename "$f")"
  case "$base" in
    *-arm64.tar.zst) a=arm64 ;;
    *-x86_64.tar.zst) a=x86_64 ;;
    *) echo "release: skipping unrecognised archive $base" >&2; continue ;;
  esac
  sum="$(tc_sha256 "$f")"
  size="$(stat -f %z "$f" 2>/dev/null || stat -c %s "$f")"
  echo "release: $base sha256=$sum sizeBytes=$size"
  s3cp "$f" "toolchain/$version/$base"
  entries+=("$a $base $sum $size")
done
shopt -u nullglob
(( ${#entries[@]} > 0 )) || tc_die "release: no *.tar.zst in $dist"

out="$dist/toolchain-manifest.json"
printf '%s\n' "${entries[@]}" | python3 -c 'import json,sys,datetime
version, min_app, base = sys.argv[1], sys.argv[2], sys.argv[3]
archives = {}
for line in sys.stdin:
    a, f, s, n = line.split()
    archives[a] = {"url": f"{base}/toolchain/{version}/{f}", "sha256": s, "sizeBytes": int(n)}
doc = {"version": version, "minAppVersion": min_app, "archives": archives,
       "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
json.dump(doc, open(sys.argv[4], "w"), indent=2); open(sys.argv[4], "a").write("\n")' \
  "$version" "$min_app" "$public_base" "$out"
echo "release: wrote $out"
s3cp "$out" "toolchain/$version/manifest.json"
s3cp "$out" "toolchain/manifest.json"
echo "release: done — $public_base/toolchain/manifest.json now points at $version"
