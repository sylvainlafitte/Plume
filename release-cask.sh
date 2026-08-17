#!/bin/bash
# Update Casks/plume.rb for a published release, and copy it into the tap.
#
# Run this AFTER `./build-app.sh release notarize` and after the release exists
# on GitHub with its asset attached. The sha256 is computed from the asset
# downloaded back from the release, never from dist/: a local zip can be stale
# (it was, once — docs/PROGRESS.md 2026-08-16), and a cask whose sha256 does not
# match what a stranger downloads fails at install time with a checksum error
# that looks like tampering.
#
# Usage:
#   ./release-cask.sh                 # version from Resources/Info.plist
#   ./release-cask.sh 0.1.1           # explicit
#   PLUME_TAP=~/src/homebrew-tap ./release-cask.sh
#
# The tap is a separate repo (Homebrew requires the homebrew-* name). Create it
# from somewhere that is NOT this working tree — `--clone` run from here leaves an
# empty nested repo, and git then refuses to stage anything in Plume at all with
# "does not have a commit checked out" (.gitignore now absorbs a repeat):
#   cd ~/src && gh repo create sylvainlafitte/homebrew-tap --public --clone \
#     --description "Homebrew tap for Plume"

set -euo pipefail
cd "$(dirname "$0")"

CASK="Casks/plume.rb"
REPO="sylvainlafitte/Plume"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
URL="https://github.com/$REPO/releases/download/v$VERSION/Plume-$VERSION.zip"
TAP="${PLUME_TAP:-$HOME/src/homebrew-tap}"

echo "▸ downloading the published asset"
echo "    $URL"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Unauthenticated on purpose: this is exactly what a stranger's brew will fetch,
# and an authenticated 200 proves nothing about a public download (the release
# looked shipped for a day while returning 404 to everyone but the owner).
if ! curl -fsSL --output "$TMP/Plume.zip" "$URL"; then
    echo "✗ could not download the asset. Is the release published with the zip attached?"
    echo "  gh release view v$VERSION --repo $REPO"
    exit 1
fi

SHA="$(shasum -a 256 "$TMP/Plume.zip" | cut -d' ' -f1)"
SIZE="$(du -h "$TMP/Plume.zip" | cut -f1)"
echo "▸ $SIZE, sha256 $SHA"

# Sanity-check the thing we are about to publish a hash for. A zip that does not
# contain Plume.app, or one Gatekeeper would refuse, must not reach a tap.
/usr/bin/ditto -x -k "$TMP/Plume.zip" "$TMP/unpacked"
if [ ! -d "$TMP/unpacked/Plume.app" ]; then
    echo "✗ the asset does not contain Plume.app at its root"
    exit 1
fi
echo "▸ verifying as Gatekeeper sees it"
spctl -a -vvv -t install "$TMP/unpacked/Plume.app" 2>&1 | sed 's/^/    /'

/usr/bin/sed -i '' \
    -e "s/^  version \".*\"$/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"$/  sha256 \"$SHA\"/" \
    "$CASK"
echo "▸ updated $CASK"
grep -E '^  (version|sha256) ' "$CASK" | sed 's/^/    /'

if [ -d "$TAP/.git" ]; then
    mkdir -p "$TAP/Casks"
    cp "$CASK" "$TAP/Casks/plume.rb"
    echo "▸ copied into $TAP"
    cat <<EOF

Next, in the tap:

    cd $TAP
    git add Casks/plume.rb && git commit -m "plume $VERSION" && git push

Then verify the way a stranger would — from the tap, not from this file:

    brew untap sylvainlafitte/tap 2>/dev/null; brew tap sylvainlafitte/tap
    brew install --cask plume
EOF
else
    cat <<EOF

No tap clone at $TAP, so nothing was copied. Either clone it:

    git clone https://github.com/sylvainlafitte/homebrew-tap $TAP

or point this script at one:

    PLUME_TAP=/path/to/homebrew-tap ./release-cask.sh $VERSION
EOF
fi
