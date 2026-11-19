#!/bin/zsh
# Builds AirPlay Splitter.app, installs it to ~/Applications, and optionally a DMG.
#
#   app/build-app.sh            build + install to ~/Applications
#   app/build-app.sh --dmg      also write dist/AirPlay-Splitter-<version>.dmg
#
# Signing: uses SIGN_IDENTITY if set (e.g. "Developer ID Application: Name (TEAMID)"),
# otherwise the first Developer ID on this Mac, otherwise ad-hoc. With a Developer
# ID and NOTARY_PROFILE set (xcrun notarytool store-credentials), the DMG is
# notarized and stapled, so it opens without warnings on other Macs.
#
# The app is assembled outside Documents because iCloud sync adds file metadata
# that breaks code signing.
set -euo pipefail
HERE=${0:A:h}
ROOT=${HERE:h}
VERSION=$(<"$ROOT/VERSION")
MAKE_DMG=0; [[ "${1:-}" == "--dmg" ]] && MAKE_DMG=1

UXPLAY="$ROOT/vendor/UxPlay/build/uxplay"
[[ -x "$UXPLAY" ]] || { echo "UxPlay isn't built yet. Run scripts/bootstrap.sh first."; exit 1; }

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
IDENTITY=${IDENTITY:--}
[[ "$IDENTITY" == "-" ]] && echo "Signing: ad-hoc (no Developer ID found)" || echo "Signing: $IDENTITY"
SIGN_OPTS=(--force --timestamp=none -s "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN_OPTS=(--force --timestamp --options runtime -s "$IDENTITY")

# 1. Build the pieces.
(cd "$HERE" && swift build -c release)
(cd "$ROOT/vendor/doubletake-main" && CGO_ENABLED=0 go build -trimpath -o bin/doubletake ./cmd/doubletake)

# 2. Assemble the bundle.
STAGE=$(mktemp -d)
APP="$STAGE/AirPlay Splitter.app"
# Helpers carry the app's name so macOS permission prompts say "AirPlay Splitter".
ENGINE="$APP/Contents/Helpers/engine/AirPlay Splitter"      # doubletake
RECEIVER="$APP/Contents/Helpers/receiver/AirPlay Splitter"  # UxPlay
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "${ENGINE:h}" "${RECEIVER:h}"
cp "$HERE/.build/release/AirPlaySplitter" "$APP/Contents/MacOS/AirPlay Splitter"
cp "$ROOT/vendor/doubletake-main/bin/doubletake" "$ENGINE"
cp "$UXPLAY" "$RECEIVER"
cp "$HERE/Icon/AppIcon.icns" "$HERE/Icon/MenuBarIcon.pdf" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AirPlay Splitter</string>
  <key>CFBundleDisplayName</key><string>AirPlay Splitter</string>
  <key>CFBundleIdentifier</key><string>local.airplaysplitter</string>
  <key>CFBundleExecutable</key><string>AirPlay Splitter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>SplitterUpdateRepo</key><string>${UPDATE_REPO:-calebaustin/airplay-splitter}</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0-or-later. Includes UxPlay (GPL-3.0) and doubletake (LGPL-3.0).</string>
  <key>NSLocalNetworkUsageDescription</key><string>Finds and streams to AirPlay TVs on your network.</string>
  <key>NSBonjourServices</key><array><string>_airplay._tcp</string><string>_raop._tcp</string></array>
</dict></plist>
PLIST

# Copy GStreamer inside the app so it needs nothing from Homebrew at runtime.
python3 "$ROOT/scripts/bundle_gstreamer.py" "$APP"

# 3. Sign: every library and tool first, then the app.
xattr -cr "$APP"
find "$APP/Contents/Resources/gst" -type f \( -name '*.dylib' -o -perm +111 \) -print0 |
  while IFS= read -r -d '' f; do codesign "${SIGN_OPTS[@]}" "$f"; done
codesign "${SIGN_OPTS[@]}" -i local.airplaysplitter.engine "$ENGINE"
codesign "${SIGN_OPTS[@]}" -i local.airplaysplitter.receiver "$RECEIVER"
codesign "${SIGN_OPTS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

# 4. Install locally.
DEST="$HOME/Applications/AirPlay Splitter.app"
mkdir -p "$HOME/Applications"
osascript -e 'quit app "AirPlay Splitter"' >/dev/null 2>&1 || true
[[ -d "$DEST" ]] && rm -r "$DEST"
ditto "$APP" "$DEST"
echo "Installed: $DEST"

# 5. DMG: the app plus an Applications shortcut to drag it onto.
if (( MAKE_DMG )); then
  mkdir -p "$ROOT/dist"
  DMG="$ROOT/dist/AirPlay-Splitter-$VERSION.dmg"
  SRC="$STAGE/dmg"; mkdir -p "$SRC"
  ditto "$APP" "$SRC/AirPlay Splitter.app"
  ln -s /Applications "$SRC/Applications"
  [[ -f "$DMG" ]] && rm "$DMG"
  hdiutil create -volname "AirPlay Splitter" -srcfolder "$SRC" -fs HFS+ -format UDZO -quiet "$DMG"
  codesign "${SIGN_OPTS[@]}" "$DMG"
  if [[ "$IDENTITY" != "-" && -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
  echo "DMG: $DMG"
fi
