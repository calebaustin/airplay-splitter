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

## Done in 0.6.0

- Places (saved TV groups, recognized by the TVs on the network, no location permission) and schedules.

## Steady stream on every TV (planned Nov 23, 2026)

Goal: every TV gets a smooth, even flow of video whether it's on wired Ethernet, busy church Wi-Fi or a
peer-to-peer Apple TV, and a slow TV never disconnects or holds back the others.

1. **Never disconnect a slow TV.** *(Done in 0.7.3.)* Each TV has a one-second cushion; a TV that falls
   further behind skips to the next keyframe (every half second) instead of hanging up and reconnecting.
2. **Smooth the bursts at the source.** *(Partly done in 0.7.3: one keyframe per second instead of two,
   about 38% less data on slides. The encoder ignores data-rate limits when run through GStreamer, so the
   rest needs the pass-through below, where the app's own encoder can apply Apple's rate limits.)* A slide change makes one frame many times larger than the rest,
   which is what overwhelms Wi-Fi TVs. Cap the encoder's peak data rate (VideoToolbox data-rate limits,
   about 1.5× the average over any half second) so a slide change spreads over a few frames instead of one
   spike. Send the app's own encoded stream straight through instead of encoding twice.
3. **Pace the packets.** Send each frame's packets spread across the frame time instead of all at once, so
   routers and TVs see a steady trickle rather than bursts.
4. **Slides-aware mode.** *(Manual version done in 0.7.4: Settings › Stream with Slides, Balanced and
   Video. Automatic switching by source is still to do.)* When the picture is still (slides, holding screen, countdown), send fewer frames
   with high quality and a keyframe right after each change; go back to full motion for video.
5. **Measure each TV's link.** Track how fast each TV takes data. Show "Weak connection" on its row, and
   if one TV is persistently slow, give it its own lower-bitrate stream (one extra hardware encoder) so the
   rest keep full quality.
6. **Prefer the best path.** When a TV is reachable both over the network and peer-to-peer, pick the one
   with better throughput.

## Next: bigger pieces

| Feature | Notes and trade-offs |
|---|---|
| **Different content per TV** | Sanctuary shows the slides while the lobby shows the countdown. Each extra source needs its own encoder, so it costs more CPU per source; TVs on the same source still share one. |
| **Audio routing** | Choose where sound plays: on the TVs, on the Mac, or both. |
| **Wi-Fi name for places** | Optional extra signal for recognizing a place. Needs Location permission, so only if visible-TV matching isn't enough. |

## Not planned

Display arrangement, resolution management, color calibration and other system display settings. macOS
already does these, and they'd turn the app into something it isn't meant to be.
