#!/usr/bin/env bash
# desktop/scripts/release.sh — [M3-05a] build, sign, notarize, staple and
# package CFW Render for macOS, sign the updater archive and write
# dist/latest.json (Tauri updater format). Every secret comes from the
# environment; none is ever printed. See desktop/RELEASE.md.
#
#   release.sh [--dry-run]
#
# --dry-run prints each command (secrets as <NAME> placeholders) and runs
# nothing; it needs no secrets. Without it, a missing secret → exit 2.
set -euo pipefail

DESKTOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/.." && pwd)"
DRY=0
while (( $# )); do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    *) echo "release.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

REQUIRED=(APPLE_SIGNING_IDENTITY APPLE_API_KEY_PATH APPLE_API_KEY_ID APPLE_API_ISSUER
  TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD DESKTOP_RELEASE_BASE_URL)

if (( DRY )); then
  # Placeholders only — a dry run never sees (or prints) a real secret.
  for n in "${REQUIRED[@]}"; do
    printf -v "$n" '<%s>' "$n"
  done
else
  missing=()
  for n in "${REQUIRED[@]}"; do
    if [[ "$n" == TAURI_SIGNING_PRIVATE_KEY_PASSWORD ]]; then
      [[ -n "${!n+x}" ]] || missing+=("$n") # may be empty, must be set
    else
      [[ -n "${!n:-}" ]] || missing+=("$n")
    fi
  done
  if (( ${#missing[@]} )); then
    echo "release.sh: refusing to start — missing environment variables: ${missing[*]}" >&2
    exit 2
  fi
fi

# run <cmd...> — print the command; run it unless --dry-run.
run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  (( DRY )) || "$@"
}

VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$DESKTOP_DIR/src-tauri/tauri.conf.json")"
APP_NAME="CFW Render"
BUNDLE_DIR="$DESKTOP_DIR/src-tauri/target/universal-apple-darwin/release/bundle"
APP="$BUNDLE_DIR/macos/$APP_NAME.app"
DIST="$DESKTOP_DIR/dist-release"
DMG="$DIST/CFW-Render-$VERSION.dmg"
ARCHIVE="$DIST/CFW-Render-$VERSION.app.tar.gz"
APP_ZIP="$DIST/CFW-Render-$VERSION-notarize.zip"
WORKER_DST="$DESKTOP_DIR/src-tauri/resources/worker"
NOTARY=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
CODESIGN=(codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY")

echo "== CFW Render $VERSION =="

echo "== 1. bundle the worker into the app =="
run mkdir -p "$WORKER_DST" "$DIST"
for item in bin install config lib scripts skills AGENTS.md CLAUDE.md VERSION; do
  run rm -rf "${WORKER_DST:?}/$item"
  run cp -a "$REPO_DIR/$item" "$WORKER_DST/$item"
done

echo "== 2. build the universal .app =="
(cd "$DESKTOP_DIR" && run pnpm tauri build --target universal-apple-darwin --bundles app)

echo "== 3. sign, notarize and staple the .app =="
run "${CODESIGN[@]}" --deep "$APP"
run ditto -c -k --keepParent "$APP" "$APP_ZIP"
run xcrun notarytool submit "$APP_ZIP" --wait "${NOTARY[@]}"
run xcrun stapler staple "$APP"
run rm -f "$APP_ZIP"

echo "== 4. package, sign, notarize and staple the .dmg =="
run hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"
run "${CODESIGN[@]}" "$DMG"
run xcrun notarytool submit "$DMG" --wait "${NOTARY[@]}"
run xcrun stapler staple "$DMG"

echo "== 5. updater archive + signature =="
run tar -czf "$ARCHIVE" -C "$BUNDLE_DIR/macos" "$APP_NAME.app"
# The signer reads TAURI_SIGNING_PRIVATE_KEY(_PASSWORD) from the environment,
# so the key never lands on argv. Writes "$ARCHIVE.sig".
(cd "$DESKTOP_DIR" && run pnpm tauri signer sign "$ARCHIVE")

echo "== 6. dist/latest.json =="
URL="${DESKTOP_RELEASE_BASE_URL%/}/desktop/$VERSION/$(basename "$ARCHIVE")"
NOTES="${RELEASE_NOTES:-CFW Render $VERSION}"
if (( DRY )); then
  echo "+ write $DIST/latest.json (version $VERSION, url $URL)"
else
  python3 - "$VERSION" "$NOTES" "$URL" "$ARCHIVE.sig" "$DIST/latest.json" <<'PY'
import datetime, json, sys
version, notes, url, sig_path, out = sys.argv[1:6]
sig = open(sig_path).read().strip()
entry = {"signature": sig, "url": url}
doc = {
    "version": version,
    "notes": notes,
    "pub_date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "platforms": {"darwin-aarch64": entry, "darwin-x86_64": entry},
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY
fi
echo "release.sh: done — $DIST (dmg, updater archive, .sig, latest.json)"
