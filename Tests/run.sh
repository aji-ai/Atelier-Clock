#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
  -framework Cocoa -framework ScreenSaver Tests/AtelierClockTests.m -o build/AtelierClockTests
./build/AtelierClockTests "$@"
