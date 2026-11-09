#!/bin/bash
# Builds build/MeetingNotes.app from the Swift package and signs it.
#
# Signs with your "Apple Development" identity when there is one: a stable identity
# keeps the Microphone grant alive across rebuilds. Otherwise signs ad hoc,
# which works but makes macOS ask for Microphone again after every build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/MeetingNotes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MeetingNotes .build/release/meeting-diarize "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/meeting Resources/diarize.py Resources/engine.py Resources/summarize.py Resources/mcp_server.py Resources/widget.html Resources/AppIcon.icns "$APP/Contents/Resources/"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/meeting-diarize"   # nested helper first
codesign --force --sign "${IDENTITY:--}" "$APP"

echo "Built $APP (signed with ${IDENTITY:-ad-hoc identity})"
