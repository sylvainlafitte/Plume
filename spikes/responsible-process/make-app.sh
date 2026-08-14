#!/bin/bash
# Assemble SpikeA.app — the positive test for Spike A.
#
# A bare binary launched from a shell has no TCC identity of its own (the terminal is the
# responsible process). This wraps the same binary in a real .app so LaunchServices makes
# it its own responsible process, which is the thing under test.
#
# Usage:  ./make-app.sh && open SpikeA.app
# Result: an on-screen alert, plus ~/Library/Logs/plume-spike-a.log

set -euo pipefail
cd "$(dirname "$0")"

APP="SpikeA.app"

echo "▸ building release binary"
swift build -c release

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp "$(swift build -c release --show-bin-path)/SpikeA" "$APP/Contents/MacOS/SpikeA"

# Copying through SwiftPM's build dir carries extended attributes (com.apple.provenance
# and friends) that codesign rejects as "resource fork, Finder information, or similar
# detritus". Strip them first.
xattr -cr "$APP"

# Ad-hoc signature. Enough to give TCC a stable-ish identity for one test run; note the
# cdhash changes on every rebuild, so macOS may re-prompt after each `make-app.sh`.
echo "▸ signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

echo "▸ verifying"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
echo "    bundle id: $(defaults read "$PWD/$APP/Contents/Info" CFBundleIdentifier)"

cat <<'EOF'

Built SpikeA.app

Run it the way that matters — via LaunchServices, not the shell:

    open SpikeA.app

Expect a system-audio permission prompt naming "SpikeA" the first time. Granting it and
seeing real audio captured is the PASS condition. If it stays silent even when bundled and
granted, the .app packaging decision in docs/PLAN.md Phase 1 is invalid — stop and re-plan.

If macOS has already remembered a decision, reset it with:

    tccutil reset AudioCapture com.plume.spike-a

EOF
