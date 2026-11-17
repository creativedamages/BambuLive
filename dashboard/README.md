# BambuLive dashboard

A read-only Bambu Lab MQTT dashboard with a web GUI for adding, editing, renaming and removing printers, plus browser-viewable RTSPS camera streams through FFmpeg. Designed for X2D; other Bambu models may have different camera protocols. No Docker.

## Upgrade from the previous ZIP

1. Quit the old server (Ctrl+C in its Terminal window).
2. Extract this ZIP to a **new folder**.
3. Copy your existing `printers.json` from the old folder into this new folder. **Do not share it**; it contains LAN access codes. The new version adds stable IDs automatically and retains your settings.
4. Install FFmpeg on your Mac: `brew install ffmpeg` (Homebrew: https://brew.sh). Node.js LTS is also required, as before.
5. Double-click `start.command`. The first launch installs npm dependencies if necessary.
6. Open http://localhost:8080 and select **Manage printers**. You can rename, edit, add and remove printers there. No server restart needed.

For a fresh installation, skip step 3 and add printers using Manage printers.

## Camera setup

On each X2D touchscreen, enable **LAN Only Liveview** in the network settings. This is not the same as enabling full LAN Only mode. The stream is accessed locally via RTSPS on TCP port 322 using the printer's LAN access code. Camera frames are converted to a low-bandwidth MJPEG feed for browsers (15 fps at up to 960 pixels wide). This targets 15 fps; actual camera frame delivery may be lower. Each browser viewer opens its own FFmpeg connection, so avoid many simultaneous viewers. If cameras are blank, ensure the setting is on, FFmpeg is installed, and other camera viewers are closed. The latest X2D firmware has not been tested with this specific package.

## Access and security

On the Mac: http://localhost:8080. On an iPhone connected to the same trusted network: `http://MAC-LAN-IP:8080`.

The server listens on all interfaces and **has no web authentication**. Anyone who can reach it can view feeds and edit printer settings, so do not forward port 8080 or expose it to the internet. Credentials are saved in `printers.json` (mode 0600), never returned by the settings API, and never intentionally displayed in the UI. FFmpeg is launched with an authenticated URL as a process argument; local administrators may be able to inspect process arguments. Use only on a trusted Mac/LAN.

MQTT uses the printer's local self-signed TLS certificate, with certificate verification disabled. The server does not publish printer-control commands.

## Troubleshooting

- **Stats work, video does not:** confirm LAN Only Liveview, port 322, and `brew install ffmpeg`; restart dashboard after installing FFmpeg.
- **FFmpeg installed but not found:** `start.command` searches `/opt/homebrew/bin` and `/usr/local/bin`; you can also set `FFMPEG_PATH`.
- **Old printers missing:** copy your existing `printers.json` to the same folder as `server.js`.
- **Port 8080 in use:** stop the old dashboard first.

This is an experimental local utility, not an official Bambu Lab integration.
