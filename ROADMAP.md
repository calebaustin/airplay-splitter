# Roadmap

**Aim:** the fastest, smartest way to get content onto multiple screens. A tiny menu-bar utility that works
like a pocket AV control system, not a full display-management app.

**Rule for every feature:** it has to make getting something onto the screens faster or more reliable. If it
mostly adds settings, it waits.

## Done in 0.2.0

- Everything inside the app (no Homebrew), sound on/off, live preview, window and area sharing, and a
  scrolling TV list with switched-on TVs pinned to the top.

## Layout: pages, not a bigger menu

The menu stays the same size. The **active TVs stay pinned at the top**, and the area below swipes left and
right (with arrows) between pages:

1. **Send:** what to show (screen, window, phone, content) and which TVs
2. **Content:** image, holding screen, countdown, video, web page
3. **Schedule and places:** presets, Wi-Fi locations, timed changes
4. **Settings:** audio, sleep, reconnect

## Next: reliability (small, high value)

| Feature | Notes |
|---|---|
| **Smart reconnect** | If a TV drops, retry on its own with backoff, and show "Reconnecting" on that row. |
| **Connection memory** | Remember each TV's name, address, pairing and preferred settings. Pairing is already saved by doubletake; this adds the rest. |
| **Refresh** | A button to look for new TVs now. |
| **Blank displays** | Send black to selected TVs. Same mechanism as the test pattern, so it's cheap. |
| **Keep the Mac awake** | Block sleep while sending. One system call. |

## Then: content sources (what sets this apart)

These all plug into the same path the test pattern uses. The app draws frames and every selected TV gets
them, so every screen stays in sync by design.

| Feature | Notes |
|---|---|
| **Quick image** | Drag an image onto the menu-bar icon or the Content page; it shows on the selected TVs. Announcements, instructions, holding slides. |
| **Holding screen** | Logo, background and a line of text, saved as a reusable design. |
| **Countdown** | 5, 10, 15 and 30 minute presets, plus a custom time. Identical on every TV because it's one stream. |
| **Quick video** | Drop a video file and play it on the selected TVs with play, pause and loop. No presentation app needed. |
| **Web page** | Enter a URL and show it full-screen. Dashboards, web slides, signage. |

## Later: bigger pieces

| Feature | Notes and trade-offs |
|---|---|
| **Places (Wi-Fi presets)** | Church Wi-Fi shows Sanctuary, Lobby, Classrooms; home shows Living Room, Bedroom. macOS only reveals the Wi-Fi name to apps with **Location** permission, so this needs one more permission prompt. Matching by the TVs that are visible is a fallback that needs none. |
| **Schedules** | Connect to certain TVs at set times, or switch what's shown on a timer (for example, at 7:00 PM switch to the holding screen). Runs only while the app is open. |
| **Different content per TV** | Sanctuary shows the slides while the lobby shows the countdown. Each extra source needs its own encoder, so it costs more CPU per source; TVs on the same source still share one. |
| **Audio routing** | Choose where sound plays: on the TVs, on the Mac, or both. |

## Not planned

Display arrangement, resolution management, color calibration and other system display settings. macOS
already does these, and they'd turn the app into something it isn't meant to be.
