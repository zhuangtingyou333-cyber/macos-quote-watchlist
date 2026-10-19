#!/bin/sh
set -eu
cd "$(dirname "$0")"
TASK_BUILD_DIR="${TASK_BUILD_DIR:-.build}"
mkdir -p "$TASK_BUILD_DIR/MU 行情.app/Contents/MacOS" "$TASK_BUILD_DIR/MU 行情.app/Contents/Resources"
swiftc -parse-as-library -swift-version 5 -O -framework Cocoa \
  Main.swift InstrumentSelection.swift WatchlistSettingsController.swift \
  -o "$TASK_BUILD_DIR/MU 行情.app/Contents/MacOS/MUMenuBar"
cp Info.plist "$TASK_BUILD_DIR/MU 行情.app/Contents/Info.plist"
printf '%s\n' "Built: $TASK_BUILD_DIR/MU 行情.app"
