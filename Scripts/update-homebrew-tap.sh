#!/bin/zsh
# Points the Homebrew cask at the release in dist/ and pushes it, so `brew upgrade` gets the new version.
# Run after the GitHub release is published (the cask downloads the DMG from it).
#
#   ./Scripts/update-homebrew-tap.sh            uses ~/Documents/homebrew-tap
#   HOMEBREW_TAP_DIR=/path ./Scripts/update-homebrew-tap.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/env.sh

TAP=${HOMEBREW_TAP_DIR:-$HOME/Documents/homebrew-tap}
CASK="$TAP/Casks/cablehop.rb"
DMG="dist/Cablehop-$VERSION.dmg"
[[ -f $CASK ]] || { echo "No cask at $CASK (set HOMEBREW_TAP_DIR)" >&2; exit 1; }
[[ -f $DMG ]] || { echo "No $DMG: run ./Scripts/release.sh first" >&2; exit 1; }

URL="https://github.com/negasonicteenagewarperson/Cablehop/releases/download/v$VERSION/Cablehop-$VERSION.dmg"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

# The published file must be the one built here, or Homebrew would refuse it as tampered.
PUBLISHED=$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1) || { echo "Release v$VERSION isn't published yet" >&2; exit 1; }
[[ $PUBLISHED == "$SHA" ]] || { echo "The published DMG differs from $DMG" >&2; exit 1; }

sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$TAP" diff --quiet && { echo "Cask is already at $VERSION"; exit 0; }
git -C "$TAP" add Casks/cablehop.rb
git -C "$TAP" commit -q -m "Cablehop $VERSION"
git -C "$TAP" push -q
echo "Homebrew tap updated to Cablehop $VERSION"
