#!/bin/bash
# Assemble Plume.app from the SwiftPM build.
#
# Plume MUST run as a bundle. A shell-launched binary creates a system-audio tap that
# reports success at every step and records full-length digital silence, because TCC
# attributes the request to the responsible process — the terminal. Measured in
# spikes/responsible-process/RESULTS.md. `swift run` is not a valid way to test capture.
#
# Usage:
#   ./build-app.sh              debug build
#   ./build-app.sh release      release build
#   ./build-app.sh release run  build, install to /Applications, launch

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
ACTION="${2:-}"
APP="Plume.app"

echo "▸ building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/plume"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/plume"

# SwiftPM's build directory carries extended attributes (com.apple.provenance and
# friends) that codesign rejects as "resource fork, Finder information, or similar
# detritus". Learned the hard way in Spike A.
xattr -cr "$APP"

# Prefer a real signing identity over ad-hoc.
#
# An ad-hoc signature's Designated Requirement is the cdhash, which changes with every
# build — so macOS treats each rebuild as a different app and re-prompts for microphone
# and system-audio permission. A certificate-backed signature keys the DR on the
# certificate plus bundle ID instead, and TCC grants survive rebuilds.
#
# Override with PLUME_SIGN_ID, or set it to "-" to force ad-hoc.
if [ -z "${PLUME_SIGN_ID:-}" ]; then
    PLUME_SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -m1 'Apple Development' \
        | sed -E 's/.*\) ([A-F0-9]{40}) .*/\1/')"
fi
if [ -n "${PLUME_SIGN_ID:-}" ] && [ "$PLUME_SIGN_ID" != "-" ]; then
    echo "▸ signing (identity ${PLUME_SIGN_ID:0:12}…)"
else
    PLUME_SIGN_ID="-"
    echo "▸ signing (ad-hoc — expect a permission re-prompt after each build)"
fi
codesign --force --sign "$PLUME_SIGN_ID" --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "▸ built $APP"

if [ "$ACTION" = "run" ]; then
    echo "▸ installing to /Applications and launching"
    pkill -x plume 2>/dev/null || true
    # Wait for the old instance to actually exit. Replacing the bundle while it
    # is still shutting down makes LaunchServices fail the relaunch with -600.
    for _ in $(seq 1 20); do
        pgrep -x plume >/dev/null || break
        sleep 0.25
    done
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    # LaunchServices caches the old bundle briefly after it is replaced; opening
    # immediately can fail with -600. Register the new one, then retry.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "/Applications/$APP" 2>/dev/null || true
    for attempt in 1 2 3; do
        open "/Applications/$APP" 2>/dev/null && break
        sleep 1
    done
    echo "  running — look for the feather in the menu bar"
else
    cat <<EOF

Launch it through LaunchServices, never from the shell:

    open $APP

Or install and run in one step:

    ./build-app.sh release run
EOF
fi
