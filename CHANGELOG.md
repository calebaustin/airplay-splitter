# Changelog

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
