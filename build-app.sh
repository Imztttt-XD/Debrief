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
# Experimental speaker separation: sherpa-onnx dylibs, loaded at runtime (see scripts/fetch-sherpa.sh).
if [[ -d Vendor/sherpa-onnx/lib ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp Vendor/sherpa-onnx/lib/*.dylib "$APP/Contents/Frameworks/"
else
  echo "Note: Vendor/sherpa-onnx not found; speaker separation will be unavailable (run scripts/fetch-sherpa.sh)."
fi
# Signing. macOS ties Microphone / Screen Recording permission to the code signature.
# An ad-hoc signature (-) changes on every build, so every rebuild silently invalidates the
# permissions (System Settings may still show them as on). A fixed certificate keeps them across builds.
IDENTITY="${SIGN_IDENTITY:-Debrief Dev}"
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
  # Release signing (CI): notarization requires the hardened runtime and a secure timestamp.
  # The entitlement lets the hardened runtime still use the microphone.
  for lib in "$APP"/Contents/Frameworks/*.dylib(N); do codesign --force --options runtime --timestamp --sign "$IDENTITY" "$lib"; done
  codesign --force --options runtime --timestamp --entitlements Resources/Debrief.entitlements --sign "$IDENTITY" "$APP"
  echo "Signed with \"$IDENTITY\" (hardened runtime, ready for notarization)"
elif security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  for lib in "$APP"/Contents/Frameworks/*.dylib(N); do codesign --force --sign "$IDENTITY" "$lib"; done
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with \"$IDENTITY\" (permissions persist across rebuilds)"
else
  for lib in "$APP"/Contents/Frameworks/*.dylib(N); do codesign --force --sign - "$lib"; done
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
