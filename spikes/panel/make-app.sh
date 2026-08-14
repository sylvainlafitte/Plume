#!/bin/bash
# Assemble SpikeB.app.
#
# Must be run as a bundle: LSUIElement and non-activating panel behaviour only mean
# anything for a real app, and Spike A established that shell-launched binaries are not a
# faithful test context.
#
# Usage:  ./make-app.sh && open SpikeB.app

set -euo pipefail
cd "$(dirname "$0")"

APP="SpikeB.app"

echo "▸ building release binary"
swift build -c release

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp "$(swift build -c release --show-bin-path)/SpikeB" "$APP/Contents/MacOS/SpikeB"

# SwiftPM's build dir carries extended attributes that codesign rejects as
# "resource fork, Finder information, or similar detritus". Learned in Spike A.
xattr -cr "$APP"

echo "▸ signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

cat <<'EOF'

Built SpikeB.app  —  open SpikeB.app

Two panels appear top-right. No Dock icon (LSUIElement), quit from the panel or with:
    pkill SpikeB

TEST 1 — typing while another app is frontmost
  Open a video call (or any app). Click into Panel A's text field and type.
  Watch the readout:
    "keystrokes landed" climbing  -> the panel receives input
    "frontmost app" still the call -> the call kept frontmost status  ✅
    "frontmost app" became SpikeB  -> we stole focus at the app level  ⚠️

TEST 2 — screen share
  Record the desktop (QuickTime > File > New Screen Recording), then play it back.
  Look for the two markers:
    PLUME-SPIKE-B-HIDDEN   (Panel A, sharingType = .none)
    PLUME-SPIKE-B-CONTROL  (Panel B, sharingType = .readOnly)

  Both visible -> .none is dead against ScreenCaptureKit; PLAN.md B2 confirmed.
  Only CONTROL -> .none still works; revise B2 and the Phase 5 design.

EOF
