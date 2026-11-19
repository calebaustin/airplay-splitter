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

## Done in 0.3.0

- Smart reconnect, connection memory with “Last time”, Refresh, Blank, keep the Mac awake, and an outline
  around a shared area.

## Done in 0.4.0

- Paged layout (TVs and Content), quick image, holding screen and countdown. The menu stays anchored to the
  menu bar.

## Done in 0.5.0

- Video playback with sound, web pages (including local files), countdown to an end time, and trackpad
  swiping between pages.

## Next: bigger pieces

| Feature | Notes and trade-offs |
|---|---|
| **Places (Wi-Fi presets)** | Church Wi-Fi shows Sanctuary, Lobby, Classrooms; home shows Living Room, Bedroom. macOS only reveals the Wi-Fi name to apps with **Location** permission, so this needs one more permission prompt. Matching by the TVs that are visible is a fallback that needs none. |
| **Schedules** | Connect to certain TVs at set times, or switch what's shown on a timer (for example, at 7:00 PM switch to the holding screen). Runs only while the app is open. |
| **Different content per TV** | Sanctuary shows the slides while the lobby shows the countdown. Each extra source needs its own encoder, so it costs more CPU per source; TVs on the same source still share one. |
| **Audio routing** | Choose where sound plays: on the TVs, on the Mac, or both. |

## Not planned

Display arrangement, resolution management, color calibration and other system display settings. macOS
already does these, and they'd turn the app into something it isn't meant to be.
