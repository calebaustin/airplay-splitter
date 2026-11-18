# AirPlay Splitter — Build Plan

**Goal:** A macOS menu-bar app that creates an "AirPlay Splitter" display on the Mac. Whatever is on that display (a Keynote/Proclaim/Google Slides deck) is mirrored to 3–4 AirPlay receivers on the local network (Apple TVs or AirPlay-capable smart TVs) at the same time.

**Fidelity target:** Slide decks. 1080p, 15–30 fps, no audio required. Latency under ~0.5 s and screens roughly in sync are good enough.

---

## 1. Key finding: the hard part already exists

The difficult piece is *sending* AirPlay mirroring to an Apple TV. That needs Apple's FairPlay SAP handshake, and for years only paid tools (AirParrot, AirMyPC) could do it. Since 2025–26 there are open-source senders that do it, and one of them already does multi-target fan-out.

| Repo | What it is | Language / License | Why it matters |
|---|---|---|---|
| **[omarroth/doubletake](https://github.com/omarroth/doubletake)** | AirPlay 2 mirroring **sender** for Linux | Go, LGPL-3.0+ | **The core.** Full mirroring protocol, FairPlay SAP in pure Go, PIN pairing, and a **daemon mode that streams to multiple receivers** while sharing one capture and one encoder. Tested on Apple TV 3, Apple TV 4K (2nd/3rd gen), Roku, and Samsung/TCL/Hisense TVs. Encoding goes through GStreamer. Linux only today. |
| [parsakhaz/open-airplay](https://github.com/parsakhaz/open-airplay) | Windows sender + receiver (Rust/Tauri + Go CLI) | GPL-3.0 | Port of doubletake's protocol core to another OS. A useful reference for how someone else did the port. |
| [lgbtnewsradio-sudo/airwing](https://github.com/lgbtnewsradio-sudo/airwing) | Windows AirParrot clone (Electron/Node) | GPL-3.0 | Encode-once/fan-out-to-many architecture, written in TypeScript. Its Apple TV path uses HLS, not FairPlay mirroring, so it is **not** the right core for Apple TVs. Reference only. |
| [FDH2/UxPlay](https://github.com/FDH2/UxPlay) | AirPlay mirroring **receiver** (C, GStreamer) | GPL-3.0 | Optional front door, so iPhones/iPads (and maybe the Mac itself) can see "AirPlay Splitter" in Screen Mirroring. Runs on macOS. |
| [Stengo/DeskPad](https://github.com/Stengo/DeskPad) | macOS virtual display | Swift, MIT | Reference code for creating a virtual display with the private `CGVirtualDisplay` API. |
| [xocialize/VirtualDisplayKit](https://github.com/xocialize/VirtualDisplayKit) | Swift package wrapping `CGVirtualDisplay` + capture | Swift (macOS 13+) | Possibly drop-in for the virtual-display piece. |
| [postlund/pyatv](https://github.com/postlund/pyatv) | Python Apple TV client library | Python, MIT | Fallback only: `play_url` (HLS) and discovery. Delay is several seconds. |
| [openairplay/airplay-spec](https://openairplay.github.io/airplay-spec/) | Unofficial protocol spec | — | Reference for discovery, pairing, and the legacy `/photo` endpoint. |

**Licensing note:** doubletake is LGPL, UxPlay is GPL. That's fine for personal and church use, and fine to share as open source. It would only matter if this were ever sold as a closed-source product.

**Maturity note:** doubletake's author says most of the code was written by LLMs and recommends against production or security-sensitive use. Test it thoroughly before relying on it on a Sunday.

---

## 2. Architecture (recommended)

```
┌──────────────────────── Mac ─────────────────────────┐
│                                                      │
│  Menu-bar app (SwiftUI MenuBarExtra)                 │
│    ├─ creates virtual display "AirPlay Splitter"     │
│    │     (CGVirtualDisplay, 1920×1080)               │
│    └─ controls doubletake daemon via doubletake-ctl  │
│                                                      │
│  Keynote / Proclaim presents on "AirPlay Splitter"   │
│                    │                                 │
│        capture (GStreamer avfvideosrc / SCK)         │
│                    │                                 │
│        encode ONCE (vtenc_h264_hw, VideoToolbox)     │
│                    │                                 │
│        doubletake daemon: per-target AirPlay session │
└───────┬──────────────┬──────────────┬────────────────┘
        ▼              ▼              ▼
   Apple TV 1     Apple TV 2     Smart TV 3   (each paired once with PIN)
```

**Why a virtual display instead of AirPlaying to ourselves:** it gives the same user experience ("present to the AirPlay Splitter screen") with no AirPlay round-trip on the Mac. That means less delay, no port conflict with macOS's own AirPlay Receiver, and no question of whether macOS will list itself in Control Center. The Control Center version is Phase 5, as an add-on.

---

## 3. Phased plan

### Phase 0 — De-risk with spikes (1 evening)
Prove each risky piece works before writing app code.

1. **Validate receivers on Linux first.** Run doubletake as-is on any Linux box (an old laptop, a Pi 5, or a Linux VM with bridged networking) and confirm:
   - It discovers the building's Apple TVs/TVs.
   - PIN pairing works on each one.
   - `doubletake -daemonize` plus `doubletake-ctl connect` to **3 targets at once** works, with `-no-audio`.
   - Note the delay and drift between screens.
   - If this fails, stop here. The fallback is HDMI distribution (see §6).
2. **GStreamer screen capture on macOS:**
   `brew install gstreamer` (or the official GStreamer.framework), then
   `gst-launch-1.0 avfvideosrc capture-screen=true device-index=1 ! videoconvert ! vtenc_h264_hw ! fakesink`
   Confirm it captures a chosen display and hardware-encodes.
3. **Virtual display:** build DeskPad or a VirtualDisplayKit sample. Confirm a 1920×1080 virtual display appears in System Settings → Displays, and that GStreamer from step 2 can capture it by index.

### Phase 1 — Port doubletake to macOS (the main engineering work)
Fork doubletake. Expected changes:
- **Capture source:** replace the PipeWire/X11 source with `avfvideosrc capture-screen=true` (a display index or ID chosen by flag). If that's unreliable, use a small Swift ScreenCaptureKit helper that pushes frames into an `appsrc`.
- **Encoder:** add VideoToolbox (`vtenc_h264_hw`) to the encoder auto-selection list.
- **Paths:** Unix socket default (`$XDG_RUNTIME_DIR` doesn't exist on macOS; use `~/Library/Application Support/AirPlaySplitter/`) and credential storage (file, or macOS Keychain).
- **mDNS:** confirm discovery coexists with macOS's mDNSResponder on UDP 5353. If not, switch discovery to `dns-sd` or the Bonjour `NWBrowser` API through the Swift app.
- **Build tags:** keep Linux-only code behind `//go:build linux`, and add `_darwin.go` files.
- **Firewall:** document the UDP port range (`-port-range`, 3 ports per target) and the macOS firewall prompt.
- **Slide-deck defaults:** `-no-audio`, 1080p, about 4–6 Mbps, 30 fps.

Done when: on the Mac, `doubletake -daemonize` mirrors one chosen display to 3 receivers.

### Phase 2 — Virtual display helper
- A small Swift module (DeskPad / VirtualDisplayKit as reference) that creates and destroys a display named **"AirPlay Splitter"** at 1920×1080 (HiDPI optional).
- Expose its `CGDirectDisplayID` / index so the capture pipeline can target it.
- Handle cleanup: releasing the `CGVirtualDisplay` object removes the display.

### Phase 3 — Menu-bar app (SwiftUI)
- `MenuBarExtra` with:
  - **Splitter on/off** (creates the virtual display and starts the daemon).
  - **Receivers list** from `doubletake-ctl discover`, with checkboxes, status dots, and per-target connect/disconnect.
  - **Pair** flow: when a receiver needs pairing, show a sheet asking for the PIN displayed on the TV, then pass it to `doubletake-ctl pin`.
  - **Saved groups** (e.g., "Youth Room + Fellowship Hall") for one-click connect.
  - **Mirror main display instead** toggle, for when you don't want the virtual display.
- Bundle the doubletake binary and GStreamer runtime inside the `.app` (GStreamer.framework relocation is the fiddly part; budget time for it).
- Distribute signed/notarized outside the App Store. The private `CGVirtualDisplay` API rules out the App Store.

### Phase 4 — Reliability polish
- Auto-reconnect a dropped target without disturbing the others (doubletake already detaches stalled targets).
- Keep-alive so the TVs don't time out during long pauses on a static slide.
- Optional "freeze" button that holds the current frame while you fiddle with the deck.
- Logs view for Sunday-morning debugging.

### Phase 5 (optional) — Show up in Control Center / iPhone Screen Mirroring
Run **UxPlay** on the Mac with the name "AirPlay Splitter" and display its window full-screen on the virtual display. Anything mirrored *to* the Mac (an iPad, a phone, possibly the Mac itself) then gets fanned out automatically, with no changes to the pipeline.
- macOS's own AirPlay Receiver (System Settings → General → AirDrop & Handoff) uses the same ports. Either turn it off or run UxPlay on alternate ports (`-p`).
- **Unknown, test early:** whether macOS will list a receiver running on the same Mac in its own Screen Mirroring menu. iPads and phones will definitely see it.
- Each extra hop adds roughly 100–300 ms of delay. That's acceptable for slides.

---

## 4. Instructions for Claude Code

Paste or adapt as `CLAUDE.md` in the fork:

- This is a fork of doubletake (Go, LGPL-3.0+). Keep the license headers and attribution.
- Target: macOS 14+ on Apple Silicon. Linux behavior must keep working, so isolate macOS code with `_darwin.go` files and build tags.
- Use case is slide decks: prioritize stability and multi-target sync over frame rate or quality. Default to no audio.
- Work phase by phase from `AIRPLAY_SPLITTER_PLAN.md`. Don't start Phase 3 until Phase 1's acceptance test passes against real receivers.
- Never commit pairing credentials or `credentials.json`.

---

## 5. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A receiver model (especially a non-Apple TV) rejects doubletake | Medium | Phase 0 tests the actual TVs in the building first |
| Apple changes FairPlay or pairing in a tvOS update | Low–medium | Keep the HDMI fallback; follow doubletake upstream |
| `CGVirtualDisplay` breaks in a macOS update | Low–medium | "Mirror main display" toggle as a fallback |
| GStreamer bundling into a `.app` is painful | High (annoying, not blocking) | Ship v1 as "requires Homebrew GStreamer," bundle later |
| Screens drift out of sync | Low for slides | Same-room screens only need to be within ~100 ms, which is hard to notice on a static slide |
| LLM-written upstream code has bugs | Medium | Don't rely on it for Sunday until it has run for a few midweek services |

---

## 6. Fallbacks if the AirPlay path doesn't work out

1. **HDMI distribution:** one Apple TV or the Mac into an HDMI splitter or HDBaseT extender. Boring, cheap, rock-solid, and perfectly in sync.
2. **HLS to Apple TVs via pyatv `play_url`:** encode once to HLS on the Mac and tell each Apple TV to play the URL. Works without FairPlay mirroring, but runs 3–8 s behind. Tolerable for slides you advance ahead of the speaker, bad for anything live.
3. **Legacy `/photo` endpoint:** push a JPEG of each slide on advance. It's the simplest of all, but it's an old AirPlay 1 feature and may not work on current tvOS. Untested; try it in Phase 0 with `curl -X PUT --data-binary @slide.jpg http://<appletv>:7000/photo` if curious.
