# Changelog

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
