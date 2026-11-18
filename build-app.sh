#!/bin/zsh
# Builds build/Debrief.app. The app must run from the bundle: macOS reads the
# privacy usage strings in Info.plist and kills a process that asks for mic access without them.
set -euo pipefail
cd "${0:A:h}"
swift build -c release --product Debrief
APP=build/Debrief.app
rm -rf "$APP" build/InterviewRecorder.app   # old name, before the rename
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Debrief "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Localizations (zh-Hans is the default; see Resources/Info.plist and scripts/gen_strings.py)
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # regenerate: see scripts/make_icon.swift
# Signing. macOS ties Microphone / Screen Recording permission to the code signature.
# An ad-hoc signature (-) changes on every build, so every rebuild silently invalidates the
# permissions (System Settings may still show them as on). A fixed certificate keeps them across builds.
IDENTITY="${SIGN_IDENTITY:-Debrief Dev}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with \"$IDENTITY\" (permissions persist across rebuilds)"
else
  codesign --force --sign - "$APP"
  cat <<MSG
⚠️  Ad-hoc signed: this build has a new signature, so previously granted permissions no longer apply.
   Reset them, then grant them again on the next recording:
     tccutil reset ScreenCapture dev.local.InterviewRecorder
     tccutil reset Microphone dev.local.InterviewRecorder
   To avoid this, create a code-signing certificate named "$IDENTITY" (see README).
MSG
fi
echo "Built $APP  →  open $APP"
