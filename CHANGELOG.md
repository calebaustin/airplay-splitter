# Changelog

## 0.7.1 · Unreleased

### Fixed
- TVs wouldn't connect if an older copy of the streaming engine was still running (after an update or a
  crash). The app now clears any leftover engine when it starts.
- Refresh really refreshes: TVs that don't answer within a few seconds (another building's TVs, unplugged
  ones) drop off the list. Only a switched-on TV that dropped out stays, so you can see it reconnecting.
- When a TV doesn't answer, the message says so in plain words: turn it on (not just standby) and check Wi-Fi.

## 0.7.0 · November 22, 2026

### Added
- **Extended Screen (1920×1080).** Choose it under Show › Second screen and your Mac gets a second screen,
  exactly TV-shaped, as if you'd plugged in a TV. Drag slides, ProPresenter, Keynote or a browser onto it and
  every TV shows that screen, while your own screen stays private for notes. No black bars on 16:9 TVs. It
  appears in System Settings › Displays while in use and goes away when you pick another source.

### Fixed
- Screen Recording permission now survives updates. Before, each new version looked like a different app to
  macOS, so sharing your screen stopped working even though System Settings still showed the switch on.
  After installing 0.7.0, remove AirPlay Splitter from Screen & System Audio Recording (−) and allow it once
  more; future updates keep it.
- The app notices a newly granted permission when you open the menu, instead of only at launch.

### Changed
- Swiping between TVs, Content and Places now slides the pages side by side under your fingers, like panels
  already waiting to the right. No more fade or shrink; letting go settles on the nearest page.
- The menu looks like Control Center, matching Church Studio's menu bar panel: no background at all, just
  Liquid Glass tiles floating under the menu bar that settle in one after another when it opens. A Now Showing
  tile with the preview, a wide Sound tile with round Blank and Stop All buttons, and TV icons in circles that
  turn white when switched on. Quit is the power button at the top right. The menu is now its own panel, so it
  always sits right under the menu bar and closes on a click elsewhere or Escape.
- The whole menu feels more alive, following the Modern UI Jumpstart rules:
  - Switches feel physical: the knob stretches while held, springs across with a little overshoot, can be
    dragged, and taps the trackpad when it flips.
  - Swipes carry your finger's speed into the landing, stretch like a rubber band at the first and last page
    (with a tap you can feel), and the page pill glides along as you swipe.
  - One hover and press style for small buttons: a soft pill and a 1pt lift on hover, a quick sink on press.
  - TV rows highlight under the pointer; a TV's status light gives one small pop when it changes.
  - Nothing animates while the menu sits idle, and Reduce Motion calms all of it.
- Local builds install to /Applications (one copy only), so Finder and Launchpad always open the latest.

## 0.6.1 · November 19, 2026

### Fixed
- The menu stays attached to the menu bar on every page. TVs, Content and Places now share one height, so
  switching pages never resizes the menu; each page scrolls inside it.

## 0.6.0 · November 19, 2026

### Added
- **Places.** Save the TVs for a room ("Sanctuary", "Youth Room") and connect them all with one click. When
  most of a place's TVs are on the network, the TVs page asks "At Sanctuary?" with a Connect button. It
  recognizes the place by the TVs it can see, so it needs no Wi-Fi name or location permission.
- **Schedule.** Run things at set times on chosen days while the app is open: connect a place, start a
  countdown, show the holding screen or the main screen, blank the TVs, or stop all.
- A third page, **Places**, holds both.

### Fixed
- After swiping to a taller page, the menu could be cut off at the top and bottom. It now resizes to fit,
  never grows past the screen, and stays attached to the menu bar.

## 0.5.0 · November 19, 2026

### Added
- **Video.** Drop a video onto the Content page (or choose one) and it plays on every TV, with play, pause,
  start over and loop. It also plays on the Mac as usual, and with Sound on its soundtrack goes to the TVs.
- **Web page.** Type an address and it shows full-screen on the TVs: dashboards, web slides, signage. A local
  page works too (for example `~/Signage/index.html`).
- **Countdown to a time.** Pick an end time ("Until 10:30 AM") instead of a length. The 5, 10 and 15 minute
  buttons stay.
- **Trackpad swipe.** Swipe left or right with two fingers to switch between TVs and Content. The arrows are
  still there if you want them.

### Fixed
- Text boxes on the Content page no longer flash gray when the page opens.
- The Content page scrolls within the menu instead of making it taller than the screen.

## 0.4.0 · November 19, 2026

### Added
- **Content page.** Put things on the TVs without sharing your screen:
  - **Image:** drop a picture onto the menu (or choose one) and show it on every TV.
  - **Holding screen:** a title, subtitle, logo and background color, remembered between services.
  - **Countdown:** 5, 10, 15 and 30 minute presets or your own time, in sync on every TV.
- **Pages.** What's live stays at the top; arrows (or a drag) switch between the TVs and Content pages.

### Fixed
- The menu always hangs from the menu bar. It no longer slides down when it gets shorter, such as during
  Refresh, and Refresh keeps the TV list in place while it looks again.

## 0.3.0 · November 19, 2026

### Added
- **Area outline.** When you share part of a screen, a dashed line stays around it so you always know what
  the TVs show. It sits just outside the area, so it never appears on the TVs.
- **Smart reconnect.** If a switched-on TV drops, the app reconnects it by itself and shows “Reconnecting”.
- **Remembers your TVs.** TVs you've used stay in the list even before they're found, and **Last time**
  switches your last group of TVs back on in one click. The chosen screen is remembered too.
- **Blank.** Send black (and silence) to every TV without disconnecting, then bring the picture back.
- **Refresh** looks for TVs again.
- **Keeps the Mac awake** while sending, so the TVs don't go dark mid-service.

### Changed
- The app's own windows are left out of screen captures.

## 0.2.1 · November 19, 2026

### Added
- **Update check.** Once a day the app quietly checks GitHub. When a new version is out, the menu shows it with
  a Download button for the new DMG and how to replace the app. A dot on the menu-bar icon says one is waiting.

### Fixed
- Permission prompts now say “AirPlay Splitter” instead of “doubletake” or “uxplay”.

## 0.2.0 · November 19, 2026

### Added
- **Nothing else to install.** GStreamer now ships inside the app, so Homebrew isn't needed.
- **Sound.** A switch sends the Mac's audio to the TVs. Off by default. iPhone and iPad sound comes through too.
- **Share one window** with Apple's window picker, or **select an area** of a screen by dragging.
- **Live preview** of what the TVs are showing.
- New app and menu-bar icon.

### Changed
- The TV list scrolls once there are more than will fit, so the menu always hangs from the menu bar.
  Switched-on TVs stay at the top.
- TVs that only accept AAC-ELD audio now connect with video only instead of failing.

## 0.1.0 · November 18, 2026

### Added
- Menu-bar app: pick a screen, switch TVs on, enter each TV's PIN right under its name.
- Sends one hardware-encoded stream to several AirPlay TVs at once.
- iPhone or iPad source through the built-in “AirPlay Splitter” receiver.
- Test pattern source for checking TVs.
- Liquid Glass design on macOS 26.
