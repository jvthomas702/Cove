# Signed app updates

Cove embeds Sparkle 2.10.0 using its official SwiftPM binary archive and published checksum. The packaged framework and nested helpers are signed before Cove.app is signed. `SUPublicEDKey` is the public Ed25519 key; the private seed is never included in source or app bundles. Both archives and the appcast must pass signature validation.

The feed is hosted at `https://raw.githubusercontent.com/jvthomas702/Cove/updates/appcast.xml`. Sparkle checks daily, supports manual checks from the menu and About settings, and stores its own preferences. Automatic installation is opt-in. Downloaded updates are verified before extraction. The first installation of the new updater-enabled Cove still requires replacing the older Cove.app.

GitHub Actions uses the repository secret `COVE_UPDATE_ED25519_KEY`. Keep a secure backup of the private seed; losing it prevents signing future releases for existing installations. Never commit the private key or put it in a release asset. It is used through a protected temporary file and removed after publishing.

To publish: increment both version fields in `Resources/Info.plist`, update `RELEASE_NOTES.md`, push a `v` version tag for the reviewed commit, and wait for all required build, unit, native UI, signature and actual-installation checks. The release job builds a universal macOS app, uploads its archive, signs the appcast, and updates only the `updates` branch.

Tests use an independent temporary key and a disposable app. They verify archive/feed tampering rejection and perform a real download, installation and relaunch into the next fixture version. They never replace a user's installed Cove.
