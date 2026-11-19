#!/bin/zsh
# Command-line build of Dynisland.xcodeproj into ./Dynisland.app (same result as Product > Build in Xcode).
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -project Dynisland.xcodeproj -target Dynisland -configuration Release SYMROOT="$PWD/build" -quiet
rm -rf Dynisland.app && mv build/Release/Dynisland.app . # move, not copy: one app on disk
echo "Built $PWD/Dynisland.app"
