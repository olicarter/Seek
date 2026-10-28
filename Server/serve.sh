#!/bin/zsh
# Builds the site and the server, then runs Seek on the web at http://localhost:8765.
# Pass --lan to let other devices on this network reach it (there's no sign-in to the site).
set -e
cd "$(dirname "$0")/.."
(cd web && { [ -d node_modules ] || npm ci --no-audit --no-fund; } && npm run build)
xcodebuild build -quiet -project Seek.xcodeproj -scheme SeekServer -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/server
exec build/server/Build/Products/Release/seek-server --site "$PWD/web/dist" "$@"
