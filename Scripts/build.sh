#!/usr/bin/env bash
# Builds CleanLocal. Usage: Scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/xcode-env.sh
CONFIGURATION="${1:-Debug}"
xcodebuild -project CleanLocal.xcodeproj -scheme CleanLocal -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build
echo "Built: build/DerivedData/Build/Products/$CONFIGURATION/CleanLocal.app"
