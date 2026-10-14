#!/usr/bin/env bash
# desktop/scripts/release.sh — [M3-05a] build, sign, notarize, staple and
# package CFW Render for macOS, sign the updater archive and write
# dist/latest.json (Tauri updater format). Every secret comes from the
# environment; none is ever printed. See desktop/RELEASE.md.
#
#   release.sh [--dry-run]
#   release.sh --unsigned [--target <rust target>] [--dry-run]
#
# --dry-run prints each command (secrets as <NAME> placeholders) and runs
# nothing; it needs no secrets. Without it, a missing secret → exit 2.
#
# --unsigned builds a tester .dmg with no Apple account and no secrets: the
# worker is bundled, the app is ad-hoc signed (so it runs on Apple Silicon),
# nothing is notarized and no updater files or latest.json are written.
# Testers open it once via System Settings → Privacy & Security → Open Anyway
# (desktop/TESTERS.md). --target picks the build (default
# universal-apple-darwin; aarch64-apple-darwin builds without the Intel
# toolchain). Never publish this build as the public download.
set -euo pipefail

DESKTOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/.." && pwd)"
DRY=0
UNSIGNED=0
TARGET=""
while (( $# )); do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --unsigned) UNSIGNED=1; shift ;;
    --target)
      [[ $# -ge 2 ]] || { echo "release.sh: --target needs a value" >&2; exit 2; }
      TARGET="$2"; shift 2 ;;
    *) echo "release.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$TARGET" ]] && (( ! UNSIGNED )); then
  # The signed feed maps both Mac kinds to one archive, so it must be universal.
  echo "release.sh: --target is only for --unsigned tester builds" >&2
  exit 2
fi
TARGET="${TARGET:-universal-apple-darwin}"
case "$TARGET" in
  universal-apple-darwin) ARCH_LABEL="universal" ;;
  aarch64-apple-darwin) ARCH_LABEL="apple-silicon" ;;
  x86_64-apple-darwin) ARCH_LABEL="intel" ;;
  *) echo "release.sh: unsupported --target $TARGET (universal-apple-darwin, aarch64-apple-darwin, x86_64-apple-darwin)" >&2; exit 2 ;;
esac

REQUIRED=(APPLE_SIGNING_IDENTITY APPLE_API_KEY_PATH APPLE_API_KEY_ID APPLE_API_ISSUER
  TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD DESKTOP_RELEASE_BASE_URL)
(( UNSIGNED )) && REQUIRED=() # a tester build needs no secrets at all

if (( UNSIGNED )); then
  : # nothing to check
elif (( DRY )); then
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
BUNDLE_DIR="$DESKTOP_DIR/src-tauri/target/$TARGET/release/bundle"
APP="$BUNDLE_DIR/macos/$APP_NAME.app"
DIST="$DESKTOP_DIR/dist-release"
DMG="$DIST/CFW-Render-$VERSION.dmg"
ARCHIVE="$DIST/CFW-Render-$VERSION.app.tar.gz"
APP_ZIP="$DIST/CFW-Render-$VERSION-notarize.zip"
WORKER_DST="$DESKTOP_DIR/src-tauri/resources/worker"

if (( UNSIGNED )); then
  echo "== CFW Render $VERSION — UNSIGNED tester build ($ARCH_LABEL) =="
else
  echo "== CFW Render $VERSION =="
fi

echo "== 1. bundle the worker into the app =="
run mkdir -p "$WORKER_DST" "$DIST"
for item in bin install config lib scripts skills AGENTS.md CLAUDE.md VERSION; do
  run rm -rf "${WORKER_DST:?}/$item"
  run cp -a "$REPO_DIR/$item" "$WORKER_DST/$item"
done

if (( UNSIGNED )); then
  echo "== 2. build the .app, ad-hoc signed =="
  # "-" = ad-hoc: no certificate, but Apple Silicon will run it.
  (cd "$DESKTOP_DIR" && run env APPLE_SIGNING_IDENTITY=- pnpm tauri build --target "$TARGET" --bundles app)
  run codesign --force --deep --sign - "$APP"
  run codesign --verify --deep --strict "$APP"

  echo "== 3. package the tester .dmg (not notarized, no updater files) =="
  TESTER_DMG="$DIST/CFW-Render-$VERSION-unsigned-$ARCH_LABEL.dmg"
  run hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$TESTER_DMG"
  if (( DRY )); then
    echo "+ write $TESTER_DMG.sha256"
  else
    (cd "$DIST" && shasum -a 256 "$(basename "$TESTER_DMG")" > "$(basename "$TESTER_DMG").sha256")
    cat "$TESTER_DMG.sha256"
  fi
  echo "release.sh: done — $TESTER_DMG (unsigned; testers follow desktop/TESTERS.md)"
  exit 0
fi

NOTARY=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
CODESIGN=(codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY")

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
