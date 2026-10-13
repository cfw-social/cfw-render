# Releasing CFW Render (macOS)

Everything is built; the only missing pieces are the owner's secrets (gate G0).
Until step 3 is done, the updater stays off (`plugins.updater.pubkey` is the
placeholder `REPLACE_WITH_MINISIGN_PUBKEY`), so dev and unsigned builds never update.

## One-time owner steps (G0)

1. **Developer ID Application certificate** (CFW's Apple Developer org account):
   developer.apple.com → Certificates → "+" → *Developer ID Application*. Install
   it, then in Keychain Access export it with its private key as `cert.p12`
   (set a password). Note the identity name, e.g.
   `Developer ID Application: CFW Inc (TEAMID1234)` (`security find-identity -v -p codesigning`).
2. **App Store Connect API key** (for notarization): appstoreconnect.apple.com →
   Users and Access → Integrations → App Store Connect API → "+" (role
   *Developer*). Download `AuthKey_<KEYID>.p8` (once only); note the Key ID and Issuer ID.
3. **Updater signing key:** in `desktop/`, run
   `pnpm tauri signer generate -w ~/.tauri/cfw-render.key` (choose a password).
   Put the **public** key (contents of `~/.tauri/cfw-render.key.pub`) into
   `desktop/src-tauri/tauri.conf.json` → `plugins.updater.pubkey`, replacing the
   placeholder, and commit that. Never commit the private key.
4. **GitHub:** repo Settings → Environments → create `desktop-release` (add
   yourself as required reviewer) and add these secrets:

   | Secret | Value |
   |---|---|
   | `APPLE_SIGNING_IDENTITY` | identity name from step 1 |
   | `APPLE_CERT_P12_BASE64` | `base64 -i cert.p12` |
   | `APPLE_CERT_PASSWORD` | the p12 password |
   | `APPLE_API_KEY_P8_BASE64` | `base64 -i AuthKey_<KEYID>.p8` |
   | `APPLE_API_KEY_ID` / `APPLE_API_ISSUER` | from step 2 |
   | `TAURI_SIGNING_PRIVATE_KEY` | contents of `~/.tauri/cfw-render.key` |
   | `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | its password |
   | `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | an R2 API token with write access to the bucket |
   | `R2_DESKTOP_BUCKET` | the bucket cfw-social serves `/api/v1/desktop/*` from |
   | `DESKTOP_RELEASE_BASE_URL` | public base URL of that bucket (files live under `desktop/<version>/`) |

## Each release

1. Bump `version` in `desktop/src-tauri/tauri.conf.json` (and `Cargo.toml`), merge to `develop`.
2. Tag and push: `git tag desktop-v<version> && git push origin desktop-v<version>`.
3. The `release` job in `.github/workflows/desktop.yml` builds the universal
   `.app`, signs (hardened runtime), notarizes and staples the app and the
   `.dmg`, signs the updater archive and uploads the dmg, archive, `.sig` and
   `latest.json` to R2 at `desktop/<version>/`, then `desktop/latest.json`.
4. Check: `spctl -a -vv "/Applications/CFW Render.app"` says *Notarized Developer ID*.

## Running locally instead of CI

Export the same variables (with `APPLE_API_KEY_PATH` pointing at the `.p8`
instead of the base64 secret; the certificate in your login keychain), then run
`desktop/scripts/release.sh`. `--dry-run` prints every command with
placeholders and needs no secrets. Output lands in `desktop/dist-release/`.
