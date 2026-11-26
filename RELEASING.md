# Releasing Dynisland

Dynisland ships as a direct download: a `.dmg` on the GitHub Releases page, signed with a Developer ID and notarised by
Apple, so it opens without warnings. (The Mac App Store isn't possible: it requires the App Sandbox, which would remove
Accessibility features, session-file reading and the music bridge.)

**What notarisation is:** you upload the build to Apple, an automated scan checks it for malware (no human review, no
feature rules), and Apple issues a ticket. `release.sh` staples that ticket to the app and the disk image, so a downloaded
copy opens normally, even offline.

## One-time setup

1. **Join the Apple Developer Program** ($99/year) at <https://developer.apple.com/programs/> with the Apple ID of team
   `V3VQ48386G`. A free account can't create Developer ID certificates.
2. **Create the certificate.** Xcode → Settings → Accounts → select the team → *Manage Certificates…* → **+** →
   *Developer ID Application*. Check it with:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
3. **Store notary credentials.** Make an app-specific password at <https://account.apple.com> → Sign-In and Security →
   App-Specific Passwords, then run this and paste the password when asked (it's saved in your keychain):
   ```bash
   xcrun notarytool store-credentials dynisland-notary --apple-id YOUR_APPLE_ID --team-id V3VQ48386G
   ```
4. **Sign the GitHub CLI in** (only needed to publish from the script):
   ```bash
   gh auth login
   ```

## Every release

1. Raise the version in Xcode (target → General → Version / Build), which sets `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION`, and add a "What's New" entry in `Settings.swift`.
2. Commit and push.
3. Build, notarise and publish:
   ```bash
   PUBLISH=1 ./release.sh
   ```
   Without `PUBLISH=1` it stops after making `build/release/Dynisland-<version>.dmg`, which you can upload by hand on
   GitHub → Releases → *Draft a new release*.

`TEST=1 ./release.sh` makes the same DMG with your development certificate and no notarisation, to try the packaging.
If Apple rejects a build, the script prints where the details are (`build/release/notary-*.json`).
