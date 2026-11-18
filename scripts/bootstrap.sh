#!/bin/zsh
# One-time setup for building AirPlay Splitter from source on an Apple Silicon Mac.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"

command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
xcode-select -p >/dev/null || { echo "Install the Xcode command-line tools: xcode-select --install"; exit 1; }
brew install cmake pkgconf libplist openssl@3 gstreamer go

git submodule update --init vendor/UxPlay

# UxPlay's newest FairPlay code doesn't find Homebrew's OpenSSL headers on its own.
OSSL=$(brew --prefix openssl@3)
cmake -S vendor/UxPlay -B vendor/UxPlay/build \
      -DCMAKE_C_FLAGS="-I$OSSL/include" -DCMAKE_CXX_FLAGS="-I$OSSL/include"
cmake --build vendor/UxPlay/build -j 8

echo "Ready. Build the app with: app/build-app.sh   (add --dmg for a disk image)"
