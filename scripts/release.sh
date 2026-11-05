#!/bin/sh
# Publishes the version in VERSION as a GitHub release with a notarized Toma.dmg.
# Run on the Mac that holds the Developer ID certificate and the notarytool profile, from main.
# The website downloads releases/latest/download/Toma.dmg, so it serves the new version as soon
# as this finishes. Needs the gh CLI, logged in with write access.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
TAG="v$VERSION"

[ "$(git branch --show-current)" = main ] || { echo "Run from main."; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Uncommitted changes."; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main differs from origin/main."; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then echo "$TAG already exists. Bump VERSION."; exit 1; fi

NOTES=$(awk -v v="$VERSION" '
  $0 ~ "^## \\[" v "\\]" { found = 1; next }
  found && /^## \[/ { exit }
  found { print }' CHANGELOG.md)
[ -n "$NOTES" ] || { echo "CHANGELOG.md has no [$VERSION] section."; exit 1; }

./build.sh dmg
# A DMG that is not notarized would fail Gatekeeper for every visitor: never publish one.
xcrun stapler validate Toma.dmg

gh release create "$TAG" Toma.dmg --target main --title "Toma $VERSION" --notes "$NOTES"
echo "Publicado: $TAG"
