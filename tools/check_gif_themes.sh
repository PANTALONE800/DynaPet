#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# make prepares this machine's SDK overlay and module cache where needed.
make package
xcrun swiftc -g -swift-version 5 -target arm64-apple-macos14.0 \
  -vfsoverlay IPCDemo/.build/app/arm64/toolchain-overlay.json \
  -module-cache-path IPCDemo/.build/app/arm64/module-cache \
  DynaPet/GifTheme.swift DynaPet/Motion.swift DynaPet/ThemeImport.swift \
  DynaPetNative/Sources/PetCore/PetLogic.swift \
  IPCDemo/MacPlatform/Tests/GifThemeChecks/main.swift \
  -o IPCDemo/.build/gif-theme-checks
IPCDemo/.build/gif-theme-checks "$PWD"
