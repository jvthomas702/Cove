# Signed app updates

Cove embeds Sparkle 2.10.0 from its official SwiftPM binary archive and published checksum. The framework and nested helpers are signed before Cove.app. `SUPublicEDKey` is the Ed25519 public key; the private seed is excluded from source and app bundles. Both archives and appcasts must pass signature validation.

The source repository stays private. Only signed app downloads, release notes and appcasts are published to https://github.com/jvthomas702/Cove-updates. The signed feed is https://raw.githubusercontent.com/jvthomas702/Cove-updates/updates/appcast.xml. Sparkle checks daily and supports manual checks from Cove's menu and About settings. Automatic installation is opt-in. The first updater-enabled installation requires replacing the older Cove.app manually.

`COVE_UPDATE_ED25519_KEY` is an encrypted Actions secret in the private source repository. A local backup remains in the owner's workspace `work/update-signing` folder, outside Git. Keep that backup secure; losing it prevents signing future releases for existing installations. Never commit the seed or include it in release assets. Publisher temporary key files have private permissions and are removed afterward.

For releases, increment both version fields in `Resources/Info.plist`, update `RELEASE_NOTES.md`, run required build/unit/native UI/signature/real-installation checks, and build a universal bundle (`COVE_UNIVERSAL=1 ./scripts/build-app.sh`). Zip `build/Cove.app` as `build/Cove.zip` with `ditto -c -k --keepParent`. Run `scripts/publish-updates.sh` with `GH_TOKEN` from an authenticated owner login and `COVE_UPDATE_ED25519_KEY` supplied securely. The script verifies the signed feed, uploads the archive and appcast to the public release, and updates its `updates` branch. `COVE_UPDATE_REPOSITORY` can override the default distribution repository.

Private source releases remain supported by GitHub Actions. Cross-repository public publishing can be automated by configuring a separate `COVE_UPDATE_PUBLISH_TOKEN` scoped only to Cove-updates; the existing private-repository Actions token cannot publish there. That separate token has not been stored. Local publishing already works with the owner's existing GitHub login.

Tests use an independent temporary key and a disposable app. They reject modified archives/feeds and perform a real download, installation and relaunch into the next fixture version without replacing the user's Cove.
