<p align="center"><img src="docs/icon.png" width="128" alt="AirPlay Splitter icon"></p>

<h1 align="center">AirPlay Splitter</h1>

<p align="center">Show one Mac screen on several AirPlay TVs at once, from the menu bar.</p>

---

macOS can only mirror to one AirPlay TV at a time. AirPlay Splitter sends the same picture to as many as you
like: Apple TVs and AirPlay-capable Samsung, LG, Roku and other smart TVs. It was built for slide decks in
church rooms and halls, where three or four screens need to show the same thing.

- **Pick a screen, switch TVs on.** Each TV has a switch. The first time, the TV shows a PIN; type it in once.
- **One encoder for every TV.** The Mac encodes the picture once with its hardware encoder and shares it.
- **iPhones and iPads too.** Choose *iPhone or iPad*, then mirror the phone to “AirPlay Splitter” from its
  Control Center. The app passes it on to the TVs.
- **Test pattern.** Check that every TV is working before a service without sharing your screen.

## Install

1. Install [Homebrew](https://brew.sh), then in Terminal: `brew install gstreamer`
2. Download the latest `AirPlay-Splitter-x.y.z.dmg` from
   [Releases](../../releases), open it, and drag **AirPlay Splitter** to **Applications**.
3. The first time, right-click the app and choose **Open** (the build isn't notarized yet).
4. Click the menu-bar icon. Allow **Local Network** when asked. To show your screen, allow
   **Screen Recording** too, then click **Relaunch**.

Requires an Apple Silicon Mac with macOS 14 or later. The menu uses Liquid Glass on macOS 26.

## Which Macs this is for

AirPlay Splitter is built for **Apple Silicon Macs (M1, M2, M3, M4, M5 and later)**. The download is an
`arm64` build, and it's only tested there. It won't run on Intel Macs as shipped.

**Ports are welcome.** Nothing in the design is tied to Apple Silicon. Every part already exists for other
processors, so a port is mostly build work:

| Target | What a port involves |
|---|---|
| **Intel Macs** | Everything used here runs on Intel too: Swift, ScreenCaptureKit, VideoToolbox, Go, UxPlay and Homebrew's GStreamer (in `/usr/local` instead of `/opt/homebrew`). Build each piece for `x86_64` (`swift build --arch x86_64`, `GOARCH=amd64`, UxPlay with CMake on Intel). The bundler script uses `brew --prefix`, so it already follows Homebrew's location. Joining both builds with `lipo` would give one universal app. |
| **Linux** | The sending engine, [doubletake](https://github.com/omarroth/doubletake), is a Linux program to begin with, and UxPlay runs there as well. The menu-bar app is Mac-only (SwiftUI and ScreenCaptureKit), so Linux would need its own small front end. doubletake already ships a KDE Plasma widget to start from. |
| **Windows** | UxPlay runs on Windows, and [open-airplay](https://github.com/parsakhaz/open-airplay) has ported doubletake's protocol code there. Like Linux, it would need its own front end. |

If you start a port, open an issue so others can find and help with it.

## How it works

```
Your screen (ScreenCaptureKit) ─┐
                                ├─► H.264 on localhost ─► doubletake ─► TV 1, TV 2, TV 3 …
iPhone/iPad ─► UxPlay ──────────┘                        (one encoder,
                                                          AirPlay sessions)
```

| Part | What it does |
|---|---|
| `app/` | SwiftUI menu-bar app. Captures the screen, finds TVs with Bonjour, controls doubletake. |
| `vendor/doubletake-main/` | [doubletake](https://github.com/omarroth/doubletake) AirPlay mirroring sender, ported to macOS (see below). |
| `vendor/UxPlay/` | [UxPlay](https://github.com/FDH2/UxPlay) AirPlay receiver (submodule), so phones can mirror in. |

### Changes to doubletake

doubletake targets Linux. This copy adds, in about 100 lines:
- `-relay-port`: read H.264 RTP from localhost instead of capturing the screen (`internal/airplay/relay_source.go`).
- VideoToolbox hardware encoding (`-hwaccel videotoolbox`), with SEI units dropped for strict receivers.
- A non-Linux process attribute so it builds on macOS (`proc_attr_*.go`).

## Build from source

```bash
scripts/bootstrap.sh        # once: Homebrew packages, UxPlay submodule and build
app/build-app.sh            # build and install to ~/Applications
app/build-app.sh --dmg      # also write dist/AirPlay-Splitter-<version>.dmg
```

Signing uses a *Developer ID Application* certificate if one is installed, otherwise ad-hoc. Set
`NOTARY_PROFILE` (from `xcrun notarytool store-credentials`) to notarize the DMG.

To publish a release: add a `## x.y.z · Month Day, Year` section to `CHANGELOG.md`, then run
`scripts/release.sh x.y.z`.

## Troubleshooting

- **Black screen on the TVs:** Screen Recording isn't allowed yet, or the app wasn't relaunched after allowing
  it. Try *Test pattern*: if that shows, the TVs are fine.
- **No TVs listed:** allow Local Network for AirPlay Splitter in System Settings › Privacy & Security.
- **Logs:** `~/Library/Application Support/AirPlaySplitter/`

## Credits and license

GPL-3.0-or-later (see `LICENSE`). Built on [doubletake](https://github.com/omarroth/doubletake) by Omar Roth
(LGPL-3.0-or-later) and [UxPlay](https://github.com/FDH2/UxPlay) by F. Duncanh and contributors (GPL-3.0).
doubletake's author notes much of its code was written with LLMs; test it before relying on it for a live event.
