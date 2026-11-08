#!/usr/bin/env bash
# Resolves a full Xcode installation without changing the system-wide `xcode-select` setting.
if ! xcodebuild -version >/dev/null 2>&1; then
  if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  else
    echo "error: a full Xcode installation is required (Command Line Tools alone cannot build macOS apps)." >&2
    exit 1
  fi
fi
