# QuitLite

**Close an app's last window — QuitLite quits the app for you. In about 3 MB of RAM.**

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)
![Universal](https://img.shields.io/badge/Universal-Apple%20Silicon%20%2B%20Intel-555555)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
[![Download](https://img.shields.io/badge/%E2%AC%87%20Download-latest-2ea44f)](https://github.com/Tumelo00/QuitLite/releases/latest)

*Bu sayfayı [Türkçe](README.tr.md) okuyun.*

![QuitLite settings](images/settings.png)

QuitLite is an ultra-lightweight macOS background utility. When you close the
last window of an app, QuitLite quietly quits that app — so nothing keeps
running in the background with no window on screen.

It is built like embedded firmware: tiny, silent, and stable for weeks at a
time. No dock icon, no window of its own, no noise — just a background helper
that uses around **3 MB of RAM**.

## Features

- **Automatic quit** — when an app's last window closes, QuitLite quits the app.
- **Blacklist or whitelist** — manage every app except the ones you exclude, or
  only the ones you pick.
- **Adjustable delay** — set a 0–30 second grace period before an app is quit.
- **Reliable detection** — works correctly with apps that only hide their window
  when you close it, and treats minimized windows as still open.
- **Accidental-quit protection** — a delay plus double verification prevents
  quitting an app during normal window or desktop transitions.
- **Optional menu bar icon** — reach settings or quit QuitLite from the menu bar.
- **Universal** — runs natively on both Apple Silicon and Intel Macs.
- **Private & offline** — no telemetry, no analytics, no network access. Ever.

## Light by design

![QuitLite memory usage in Activity Monitor](images/activity-monitor.png)

QuitLite's background helper idles at roughly **3 MB of RAM** with near-zero
CPU. It is event-driven rather than constantly polling, so it barely wakes your
Mac and won't dent your battery — even running 24/7.

## Installation

1. Download `QuitLite.dmg` from the
   [latest release](https://github.com/Tumelo00/QuitLite/releases/latest).
2. Open the DMG and drag **QuitLite** onto the **Applications** shortcut.
3. Open `QuitLite` from your Applications folder. QuitLite is distributed
   without a paid Apple Developer certificate, so macOS blocks it the first
   time — you only need to allow it once:
   - **macOS 15+:** System Settings → Privacy & Security → scroll down →
     "QuitLite blocked" → **Open Anyway**.
   - **Older macOS:** right-click QuitLite → **Open** → **Open**.
   - The DMG also includes `Open_If_macOS_Blocks.command`, a transparent helper
     script for this step.
4. Grant **Accessibility** permission when prompted (System Settings → Privacy &
   Security → Accessibility) — QuitLite needs it to detect when windows close.

Each release ships a `QuitLite.dmg.sha256` checksum so you can verify the
download: `shasum -a 256 -c QuitLite.dmg.sha256`.

## Usage

Open `QuitLite` any time to change settings: choose blacklist or whitelist mode,
pick apps, set the quit delay, or toggle the menu bar icon. Close the window and
QuitLite keeps working silently in the background. It starts automatically at
login.

## Uninstall

Open QuitLite and click **"QuitLite'ı Bilgisayardan Kaldır"** (Remove QuitLite
from this Mac). It cleanly removes everything — the background helper, the login
item, all settings and caches — and moves the app to the Trash. No leftovers.

## Requirements

macOS 13 (Ventura) or later. Apple Silicon or Intel.

## Build from source

```bash
./build.sh
```

Produces `QuitLite.app` and a distributable, universal `QuitLite.dmg`. Requires
Swift 5.9+ and the Xcode command-line tools.

## License

[MIT](LICENSE)
