#!/bin/bash
# Assemble Plume.app from the SwiftPM build.
#
# Plume MUST run as a bundle. A shell-launched binary creates a system-audio tap that
# reports success at every step and records full-length digital silence, because TCC
# attributes the request to the responsible process — the terminal. Measured in
# spikes/responsible-process/RESULTS.md. `swift run` is not a valid way to test capture.
#
# Usage:
#   ./build-app.sh                   debug build
#   ./build-app.sh release           release build
#   ./build-app.sh release run       build, install to /Applications, launch
#   ./build-app.sh release notarize  build, notarize, staple, package for release

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
ACTION="${2:-}"

# Assemble and sign OUTSIDE the project directory.
#
# This repo lives under ~/Documents, which iCloud's file provider stamps with
# com.apple.FinderInfo and com.apple.fileprovider.* — exactly the attributes
# codesign refuses as "resource fork, Finder information, or similar detritus".
# Stripping them loses a race with the provider, which re-applies them between
# the strip and the signature. Staging in /tmp sidesteps the whole class.
STAGE="$(mktemp -d)/Plume.app"
APP="$STAGE"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT

echo "▸ building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/plume"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/plume"

# Stamp CFBundleVersion from the commit count, into the staged copy only.
#
# CFBundleShortVersionString is the user-facing number and stays hand-set in
# Resources/Info.plist. CFBundleVersion must be a *monotonic build number*, and
# v0.1.0 shipped with it stuck at 1 precisely because nothing enforced that:
# codesign, notarization and Gatekeeper are all indifferent to it, so the mistake
# surfaces much later and somewhere else — as LaunchServices declining to treat
# a newer build as newer, and as an update check with nothing to compare.
# `git rev-list --count` is monotonic by construction, needs no state file and no
# discipline at release time. Skipped when git can't answer, so a source tarball
# still builds; the plist's own value stands in.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || true)"
if [ -n "$BUILD_NUMBER" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
        "$APP/Contents/Info.plist" >/dev/null
    echo "▸ build number $BUILD_NUMBER (CFBundleVersion)"
fi

# com.apple.provenance rides along on everything macOS 14+ writes and is NOT
# removable (xattr -c reports success and leaves it). codesign tolerates it.
xattr -cr "$APP" 2>/dev/null || true

# Prefer a real signing identity over ad-hoc, and Developer ID over Development.
#
# An ad-hoc signature's Designated Requirement is the cdhash, which changes with every
# build — so macOS treats each rebuild as a different app and re-prompts for microphone
# and system-audio permission. A certificate-backed signature keys the DR on the
# certificate plus bundle ID instead, and TCC grants survive rebuilds.
#
# Developer ID first: it is the only identity Gatekeeper accepts on someone else's Mac,
# and it is what notarization requires. Apple Development works on this machine alone.
# Switching between the two changes the DR, so expect one permission re-prompt.
#
# Override with PLUME_SIGN_ID, or set it to "-" to force ad-hoc.
if [ -z "${PLUME_SIGN_ID:-}" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    PLUME_SIGN_ID="$(echo "$IDENTITIES" | grep -m1 'Developer ID Application' \
        | sed -E 's/.*\) ([A-F0-9]{40}) .*/\1/')"
    if [ -z "$PLUME_SIGN_ID" ]; then
        PLUME_SIGN_ID="$(echo "$IDENTITIES" | grep -m1 'Apple Development' \
            | sed -E 's/.*\) ([A-F0-9]{40}) .*/\1/')"
    fi
fi
if [ -n "${PLUME_SIGN_ID:-}" ] && [ "$PLUME_SIGN_ID" != "-" ]; then
    echo "▸ signing (identity ${PLUME_SIGN_ID:0:12}…)"
else
    PLUME_SIGN_ID="-"
    echo "▸ signing (ad-hoc — expect a permission re-prompt after each build)"
fi

# --options runtime is the Hardened Runtime: mandatory for notarization, and it
# denies microphone access unless the entitlement file grants it. Signed in on
# every build, not just release ones, so a capture regression it causes shows up
# here rather than in the one build that goes out.
#
# --timestamp is deliberately NOT used here: it needs a round-trip to Apple on
# every build. The notarize path re-signs with a secure timestamp, which is what
# keeps a shipped release valid after the certificate expires.
codesign --force --sign "$PLUME_SIGN_ID" \
    --options runtime \
    --entitlements Resources/Plume.entitlements \
    --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "▸ built $(basename "$APP")"

if [ "$ACTION" = "notarize" ]; then
    # Release path: re-sign with a secure timestamp, notarize, staple, package.
    #
    # Order is not negotiable. The ticket is stapled to the .app and a zip cannot
    # carry one, so the app must be stapled *before* it is zipped for release —
    # zip, submit, staple, re-zip.
    NOTARY_PROFILE="${PLUME_NOTARY_PROFILE:-plume-notary}"
    DIST="$(pwd)/dist"

    case "$(security find-identity -v -p codesigning | grep "$PLUME_SIGN_ID" || true)" in
        *"Developer ID Application"*) ;;
        *)
            echo "✗ notarization needs a Developer ID Application identity."
            echo "  Gatekeeper refuses Apple Development on any machine but this one."
            exit 1
            ;;
    esac

    echo "▸ re-signing with a secure timestamp"
    codesign --force --sign "$PLUME_SIGN_ID" \
        --options runtime \
        --entitlements Resources/Plume.entitlements \
        --timestamp "$APP"

    UPLOAD="$(dirname "$STAGE")/upload.zip"
    /usr/bin/ditto -c -k --keepParent "$APP" "$UPLOAD"

    echo "▸ notarizing (a few minutes)"
    if ! xcrun notarytool submit "$UPLOAD" \
        --keychain-profile "$NOTARY_PROFILE" --wait; then
        echo
        echo "✗ notarization failed. The reason is only in the log:"
        echo "    xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
        echo
        echo "  No credentials yet? Store them once:"
        echo "    xcrun notarytool store-credentials $NOTARY_PROFILE \\"
        echo "      --apple-id <your-apple-id> --team-id 324ZRWQHHV --password <app-specific>"
        exit 1
    fi

    echo "▸ stapling"
    xcrun stapler staple "$APP"

    # What a stranger's Mac will conclude. "source=Notarized Developer ID" is the
    # only acceptable answer; anything else means it would be blocked on launch.
    echo "▸ verifying as Gatekeeper sees it"
    spctl -a -vvv -t install "$APP" 2>&1 | sed 's/^/    /'

    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
    mkdir -p "$DIST"
    RELEASE="$DIST/Plume-$VERSION.zip"
    rm -f "$RELEASE"
    /usr/bin/ditto -c -k --keepParent "$APP" "$RELEASE"

    echo "▸ release artifact"
    echo "    $RELEASE"
    echo "    sha256: $(shasum -a 256 "$RELEASE" | cut -d' ' -f1)"
    echo
    echo "  Verify on a Mac that has never seen Plume before shipping it —"
    echo "  and run Settings → Run Diagnostics there: the Hardened Runtime denies"
    echo "  microphone access silently if the entitlement is wrong (invariant 5)."
    exit 0
fi

if [ "$ACTION" = "run" ]; then
    echo "▸ installing to /Applications and launching"
    pkill -x plume 2>/dev/null || true
    # Wait for the old instance to actually exit. Replacing the bundle while it
    # is still shutting down makes LaunchServices fail the relaunch with -600.
    for _ in $(seq 1 20); do
        pgrep -x plume >/dev/null || break
        sleep 0.25
    done
    rm -rf "/Applications/Plume.app"
    cp -R "$APP" /Applications/
    # LaunchServices caches the old bundle briefly after it is replaced; opening
    # immediately can fail with -600. Register the new one, then retry.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "/Applications/Plume.app" 2>/dev/null || true
    for attempt in 1 2 3; do
        open "/Applications/Plume.app" 2>/dev/null && break
        sleep 1
    done
    echo "  running — look for the feather in the menu bar"
else
    cat <<EOF

Signed bundle staged at:
    $APP

Install and launch it in one step (staging is discarded on exit):

    ./build-app.sh release run
EOF
fi
