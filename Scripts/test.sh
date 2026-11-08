#!/usr/bin/env bash
# Runs the CleanLocal unit test suite. Tests only touch temporary directories.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/xcode-env.sh
xcodebuild -project CleanLocal.xcodeproj -scheme CleanLocal -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData test "$@"
