# Releasing Remora

Releases are Developer ID signed, notarized DMGs published on GitHub Releases. Sparkle reads
`appcast.xml` from the latest release. GitHub Actions builds the universal installer for macOS 26
or later. The maintainer tests the resulting installer and publishes the release.

## Set up GitHub signing

1. In Xcode, open **Settings → Accounts → your team (`CRL579ZN46`) → Manage Certificates**.
   Use a **Developer ID Application** certificate issued by the **G2** authority, with its
   private key. The original authority expires February 1, 2027. In Keychain Access → My
   Certificates, export the identity as a password-protected `.p12` outside the repository.
   [Apple certificate setup](https://developer.apple.com/help/account/certificates/create-developer-id-certificates) · [Apple's G2 migration instructions](https://developer.apple.com/help/account/certificates/replace-developer-id-certificates)
2. In App Store Connect → Users and Access → Integrations → App Store Connect API, create a
   Team Key for notarization. Save the downloaded `.p8`, Key ID and Issuer ID from the same team.
   [Apple API key setup](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)
3. After `make ci-build`, use the pinned Sparkle tools to generate or retrieve the Remora key.
   The key account `remora` gives this app its own key. If an earlier build already uses a
   Sparkle public key that users depend on, use that key and its original account instead.

   ```sh
   SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin
   "$SPARKLE_BIN/generate_keys" --account remora
   "$SPARKLE_BIN/generate_keys" --account remora -p
   (umask 077; "$SPARKLE_BIN/generate_keys" --account remora -x "$HOME/remora-sparkle-private.key")
   ```

   Commit the public key as `REMORA_SPARKLE_PUBLIC_KEY` in `Config/Updates.xcconfig`. Back up
   the private key securely so future releases can sign updates for installed copies.
4. Create the `release-signing` environment under Settings → Environments in `redox/remora`.
   Under deployment branches and tags, allow only the `main` branch. Add these environment
   secrets. [GitHub environment settings](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)

   | Secret | Value |
   | --- | --- |
   | `DEVELOPER_ID_P12_BASE64` | Base64 of the exported `.p12` |
   | `DEVELOPER_ID_P12_PASSWORD` | Password chosen for the `.p12` export |
   | `NOTARY_API_KEY` | Contents of the App Store Connect `.p8` file |
   | `NOTARY_KEY_ID` | App Store Connect Key ID |
   | `NOTARY_ISSUER_ID` | App Store Connect Issuer ID |
   | `SPARKLE_PRIVATE_KEY` | Contents of the exported Sparkle key file |

   The GitHub CLI can load the files without printing them. Edit the example paths first.

   ```sh
   base64 -i "$HOME/RemoraDeveloperID.p12" | gh secret set DEVELOPER_ID_P12_BASE64 -R redox/remora -e release-signing
   gh secret set NOTARY_API_KEY -R redox/remora -e release-signing < "$HOME/AuthKey.p8"
   gh secret set SPARKLE_PRIVATE_KEY -R redox/remora -e release-signing < "$HOME/remora-sparkle-private.key"
   ```

## First public push

Run `scripts/check-public.sh` and `scripts/check-public.sh --history` before publishing. If the
tree passes but the history contains personal data, you can publish a clean snapshot in a separate
checkout and keep the development history private. Commit all intended changes, including the
Sparkle public key, in the private checkout first. From the private checkout, set `PUBLIC_REPO`
to an absolute path for a new directory and `PUBLIC_NOREPLY` to your GitHub-provided noreply address.
These commands create a new local repository from the files in the release commit.

```sh
(
  set -e -o pipefail
  PRIVATE_REPO=$(git rev-parse --show-toplevel)
  : "${PUBLIC_NOREPLY:?Set your GitHub-provided noreply address}"
  mkdir "${PUBLIC_REPO:?Set the path for the public checkout}"
  git -C "$PRIVATE_REPO" archive HEAD | tar -x -C "$PUBLIC_REPO"
  cd "$PUBLIC_REPO"
  git init -b main
  git config user.name redox
  git config user.email "$PUBLIC_NOREPLY"
  git add .
  PUBLIC_DENYLIST="$PRIVATE_REPO/.public-denylist" scripts/check-public.sh
  git commit -m 'Initial public release'
  PUBLIC_DENYLIST="$PRIVATE_REPO/.public-denylist" scripts/check-public.sh --history
)
```

Once both scans pass, add `https://github.com/redox/remora.git` as `origin` in the public checkout
and push `main` from there. Use the public checkout for release tags.

## Build on GitHub and publish

1. Set `MARKETING_VERSION` (x.y.z) and `CURRENT_PROJECT_VERSION` in `Config/Version.xcconfig`.
   Each new release needs a build number greater than every published build. After the first
   release, use `gh release download -R redox/remora -p appcast.xml -O -` to check the latest
   appcast's `<sparkle:version>` and compare with any newer builds published as prereleases.
   Push the release commit to `main` and let the regular CI checks finish.
2. In GitHub Actions, select **Build release DMG → Run workflow** on `main`. The job signs the
   universal app and DMG, notarizes and staples the DMG, checks Gatekeeper, and signs the
   Sparkle update. It uploads a `remora-release-<attempt>` artifact containing `Remora-<version>.dmg`
   and `appcast/appcast.xml`.
3. Download the artifact from the successful run. Open the DMG on a fresh macOS account,
   drag Remora to Applications and launch it with Gatekeeper enabled. For later releases,
   test an update from the previous version using a test copy and feed.
4. From the public checkout, tag the exact commit built by the workflow. Set `RUN_ID` to the
   successful Actions run ID, `V` to its marketing version and `FILES` to the unpacked artifact.

   ```sh
   SHA=$(gh run view "$RUN_ID" -R redox/remora --json headSha --jq .headSha)
   git fetch origin main
   git tag -s "v$V" "$SHA" -m "Remora $V"
   git push origin "v$V"
   gh release create "v$V" "$FILES/Remora-$V.dmg" "$FILES/appcast/appcast.xml" \
     -R redox/remora --title "Remora $V" --generate-notes --verify-tag --latest
   ```

Publishing as Latest makes the update available to installed copies on their next check.

## Local release

To sign and notarize locally, use a Developer ID identity in your login Keychain and store the
notary credentials under `remora-notary` with `xcrun notarytool store-credentials remora-notary`.
The prompt accepts your Apple ID, team `CRL579ZN46` and an app-specific password. On the first
signing run, choose **Always Allow** if macOS requests Keychain access for `codesign`.
`make release` checks access by signing a throwaway copy of `/usr/bin/true` with a 30-second timeout.

If you generated the Sparkle key under `remora`, use `REMORA_SPARKLE_ACCOUNT=remora` for
`make appcast` or `make release-all`. The default account is Sparkle's `ed25519`.

The Sparkle version is pinned in `project.yml` (`exactVersion`); `make release` fails if the embedded framework differs.

1. Bump `Config/Version.xcconfig`: `MARKETING_VERSION` (x.y.z) and `CURRENT_PROJECT_VERSION` (an integer greater than every build in the published appcast). Commit.
2. For a signing rehearsal, use `make release DRY_RUN=1`. It still signs with the real Developer
   ID key and contacts Apple's timestamp service. It writes `dist/Remora-<version>-dryrun.dmg`
   without submitting it for notarization. With `DRY_RUN=1`, the individual `notarize`, `staple`
   and `appcast` targets print their planned actions.
3. `make release-all` (USER) runs, in order:
   - `make release`: universal Release build, inside-out Developer ID signing, verification (`codesign --verify --deep --strict` plus per-bundle checks of Sparkle's Autoupdate, Updater.app and any XPC service, hardened runtime, team id, entitlements, architectures, Gatekeeper verdict), signed DMG.
   - `make notarize`: uploads the DMG to Apple with `notarytool` profile `remora-notary`; result in `dist/notary-<version>.json`.
   - `make staple`: staples the ticket and checks Gatekeeper on the DMG and the mounted app.
   - `make appcast`: runs `generate_appcast` (may prompt for Keychain access) into `dist/appcast/appcast.xml`. The appcast is regenerated from the current DMG only, so it lists just this release; older versions are not carried over.
4. `make release-selftest` checks the script's helper functions offline.

Outputs: `dist/stage/Remora.app`, `dist/Remora-<version>.dmg`, `dist/notary-<version>.json`, `dist/appcast/appcast.xml`.

Follow the same installer checks and publishing steps for a local build. Use the local build
commit for `SHA`, and upload `dist/Remora-$V.dmg` and `dist/appcast/appcast.xml`.

## Pulling a bad release

`gh release edit v$V --prerelease`, so "latest" falls back to the previous release, whose appcast lists the older version.
Copies that already updated stay on it until a newer build ships.
