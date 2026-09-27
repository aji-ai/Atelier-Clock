#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! /bin/bash ./build.sh; then
  echo "Build did not finish. See the message above."
  read -r -p "Press Return to close. " _reply
  exit 1
fi
echo "Opening the macOS screensaver installer. Choose installation for this user."
open "build/Atelier Clock.saver"
echo "Then select Atelier Clock in System Settings > Screen Saver."
echo "On macOS 26, look under Wallpaper > Screen Saver."
echo "The standalone desktop clock is in the build folder."
read -r -p "Press Return to close. " _reply
