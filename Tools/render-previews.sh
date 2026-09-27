#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build docs/previews
icon_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/atelier-icons.XXXXXX")"
trap 'rm -rf "$icon_work_dir"' EXIT
mkdir "$icon_work_dir/AtelierClock.iconset"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
  -framework Cocoa -framework ScreenSaver Tools/render-previews.m -o build/RenderPreviews
./build/RenderPreviews "$PWD/docs/previews" "$PWD/Resources" "$icon_work_dir/AtelierClock.iconset"
iconutil -c icns "$icon_work_dir/AtelierClock.iconset" -o Resources/AtelierClock.icns
