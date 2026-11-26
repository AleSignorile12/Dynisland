# Releasing Dynisland

Dynisland ships as a direct download: a `.dmg` on the GitHub Releases page. (The Mac App Store isn't possible: it
requires the App Sandbox, which would remove Accessibility features, session-file reading and the music bridge.)

`release.sh` signs with the best certificate it finds in your keychain:

| Certificate | Cost | What downloaders see |
| --- | --- | --- |
| **Dynisland Self-Signed** (now) | free | First launch: "Apple could not verify…", then **Open Anyway** once per version |
| **Developer ID Application** (later) | $99/year Apple Developer Program, as Account Holder | Opens normally: signed and notarised by Apple |

Either way, use **the same certificate for every release**: macOS remembers permissions (Accessibility, Camera…) per
certificate, so a new certificate makes everyone grant them all again.

## One-time setup

1. **Create the self-signed certificate** (takes a minute):
   1. Open **Keychain Access** (Spotlight: "Keychain Access").
   2. Menu **Keychain Access → Certificate Assistant → Create a Certificate…**
   3. Name: `Dynisland Self-Signed` (exactly). Identity Type: **Self Signed Root**. Certificate Type: **Code Signing**.
   4. Click **Create**, then **Done**.

   Check it's there:
   ```bash
   security find-identity -p codesigning | grep "Dynisland Self-Signed"
   ```
   It shows as `CSSMERR_TP_NOT_TRUSTED`. That's expected and fine.

2. **Back it up.** In Keychain Access → *My Certificates*, right-click **Dynisland Self-Signed** → *Export…* → save the
   `.p12` with a password somewhere safe (not in this repo). If you lose it, the next release counts as a different app
   and everyone re-grants permissions.

3. **Sign the GitHub CLI in** (only needed to publish from the script):
   ```bash
   gh auth login
   ```

## Every release

1. Raise the version in Xcode (target → General → Version / Build), which sets `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION`, and add a "What's New" entry in `Settings.swift`.
2. Commit and push.
3. Build and publish:
   ```bash
   PUBLISH=1 ./release.sh
   ```
   The first time, macOS asks whether `codesign` may use the certificate's key: click **Always Allow**.
   Without `PUBLISH=1` it stops after making `build/release/Dynisland-<version>.dmg`, which you can upload by hand on
   GitHub → Releases → *Draft a new release*. Self-signed releases get the "Open Anyway" steps in their notes.

**Updates:** from 1.3 on, Dynisland checks <https://api.github.com/repos/AleSignorile12/Dynisland/releases/latest>
shortly after launch and then daily (Settings → General → *Check for updates automatically*, or *Check Now*). When the
tag (`v1.3`) is newer than its own version it offers to install the release's `.dmg`: it downloads it, checks the app inside
is signed with the same certificate, swaps it in place and relaunches. So a release needs a higher version than the last
one, a `vX.Y` tag and the DMG attached (`PUBLISH=1` does all of it). Drafts aren't seen until you publish them.

`TEST=1 ./release.sh` makes the same DMG with your development certificate, to try the packaging (can't be published).

## Later: notarised releases

Once you have your own Apple Developer Program membership (you must be the team's Account Holder):

1. Xcode → Settings → Accounts → your team → *Manage Certificates…* → **+** → *Developer ID Application*.
2. Make an app-specific password at <https://account.apple.com> → Sign-In and Security → App-Specific Passwords, then:
   ```bash
   xcrun notarytool store-credentials dynisland-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```
3. `PUBLISH=1 ./release.sh` now picks the Developer ID certificate and notarises automatically.

**What notarisation is:** the build is uploaded to Apple, an automated scan checks it for malware (no human review, no
feature rules), and Apple issues a ticket that the script staples to the app and the disk image, so it opens normally,
even offline. Switching from self-signed to Developer ID changes the certificate, so users grant permissions once more
after that update.
