#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$PROJECT_DIR/build/development"
APP="$DERIVED_DATA/Build/Products/Debug/VoiceBridge.app"
DESTINATION="/Applications/VoiceBridge.app"

# Bound the build and keep the existing application running until it succeeds.
/usr/bin/perl -e 'alarm 600; exec @ARGV' xcodebuild \
    -project "$PROJECT_DIR/VoiceBridge.xcodeproj" -scheme VoiceBridge \
    -configuration Debug -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" build -quiet
codesign --verify --deep --strict "$APP"

if [ -e "$DESTINATION" ]; then
    BACKUP_DIR="$(mktemp -d "$PROJECT_DIR/build/install-backup.XXXXXX")"
    ditto "$DESTINATION" "$BACKUP_DIR/VoiceBridge.app"
    echo "Previous application: $BACKUP_DIR/VoiceBridge.app"
fi
pkill -x VoiceBridge 2>/dev/null || true
ditto "$APP" "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
open "$DESTINATION"
