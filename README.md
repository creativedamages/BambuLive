# BambuLive for macOS

Requires macOS 13.5 or later and your existing working X2D dashboard folder. The app includes Node.js and uses AppKit for its menu-bar controls. The dashboard's own installed dependencies and any helper binaries it already uses must still be available.

## Install and switch over

1. Back up your working dashboard folder privately, including the config and existing phone page. The folder may contain printer access codes. Keep it out of GitHub and release artifacts.
2. Open the disk image for your Mac and drag BambuLive into Applications. Launch it from Applications. The preview is ad hoc signed and macOS may block a downloaded copy. For regular distribution, use the Developer ID and notarization steps below.
3. Stop the old monitor first. If it runs in Terminal, press Control-C in that session. If a previous login service is running, use the old installer's removal utility or disable that specific service. Keep the working dashboard folder and launcher for rollback. An occupied port is shown in the menu and the app will leave its owner alone.
4. Click BambuLive in the menu bar, choose **Choose Dashboard Folder…**, and select the working folder containing `server.js` and `printers.json`. The app remembers the folder and starts the existing server there. If your old launcher supplies environment variables, initializes dependencies, or runs additional commands, review that launcher before migration. This build directly runs `node server.js`.
5. Once the menu shows **Dashboard running**, select **Open Dashboard**. Confirm both printers show live status and test both cameras. On the same Wi-Fi, open `http://YOUR-MAC-IP:8080/phone.html` on your phone if that page already exists in the dashboard. Allow local network access if prompted.
6. Turn on **Start at Login** after verifying the dashboard. It starts when your macOS user signs in. Test by signing out and back in. An existing authenticated tunnel can continue pointing at the same port.

The app requests an idle-system-sleep assertion while its server is running. Your display can sleep. Closing the lid, manually sleeping, shutting down, or logging out can interrupt monitoring.

If the server stops, open **Open Service Log** from the menu and check the most recent launch. The log stays in your user Library and is replaced on each start. Review it for access codes before sharing it. To roll back, turn off Start at Login, quit the app, and start the original launcher.

## Build and release

With a native Node 24 distribution and its upstream LICENSE, run `./build.sh` on a Mac with Xcode Command Line Tools. Override `NODE_BINARY` and `NODE_LICENSE` if needed. The script builds a disk image under `dist/`.

Put this source in a GitHub repository with Actions enabled. Run **Build macOS disk images** manually from Actions to get test artifacts. Push a version tag such as `v1.0.0` to create a draft GitHub Release with Apple silicon and Intel disk images. Review and publish the draft when ready. The included workflow builds ad hoc previews.

For production, build each architecture with a Developer ID Application certificate and a notarytool keychain profile installed on the Mac. Set `SIGN_IDENTITY` and `NOTARY_PROFILE` when running the build script. It signs the embedded Node runtime and app with hardened runtime, signs the disk image, submits it for notarization, and staples the ticket. Upload those disk images to the GitHub draft and test a fresh downloaded copy on each supported architecture before publishing.

## Rename from X2D Monitor

BambuLive keeps the original `com.x2dmonitor.menu` bundle identifier so it continues using the saved dashboard folder and preferences. Quit the old app before installing BambuLive; keep only BambuLive enabled in Login Items. The new service log is at `~/Library/Application Support/BambuLive/service.log`.

The approved icon is stored in `assets/AppIcon.png`; the build creates all macOS icon sizes from it. The source under `dashboard/` includes the earlier camera patch, which still needs live testing. The app continues running the selected dashboard folder; installing the app does not replace that folder's files.

To apply the camera patch to an existing v3 dashboard, quit the app and back up the folder. Replace only `server.js` and `public/app.js` from the camera-update ZIP. Preserve `printers.json`, `node_modules`, `public/phone.html`, and other installed files. Reopen BambuLive and reload the dashboard. The main dashboard branding changes can be applied separately from `dashboard/public/index.html`.

Pushes to main run the two architecture builds. Successful builds provide DMGs and app ZIPs in Actions artifacts. A version tag creates a draft release; it does not publish publicly.
