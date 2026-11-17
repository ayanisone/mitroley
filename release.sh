#!/bin/zsh
# Makes a release: sets the version, builds, zips the app and tags the commit.
#   ./release.sh 0.2.0            build build/mitroley-0.2.0.zip and tag v0.2.0 locally
#   ./release.sh 0.2.0 --publish  also push the tag and attach the zip to a GitHub release (needs the gh tool)
# mitroley. Copyright © 2026 Ayan Mitra. All rights reserved.
set -e
cd "$(dirname "$0")"
V="$1"
if [[ ! "$V" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then echo "Usage: ./release.sh 0.2.0 [--publish]"; exit 1; fi
if [[ -n "$(git status --porcelain)" ]]; then echo "Commit your changes first."; exit 1; fi
BUILD=$(git rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" -c "Set :CFBundleVersion $BUILD" Support/Info.plist
./build.sh
ZIP="build/mitroley-$V.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/mitroley.app "$ZIP"
git commit -qam "Version $V"
git tag "v$V"
echo "Built $ZIP and tagged v$V."
if [[ "$2" == "--publish" ]]; then
  git push origin HEAD "v$V"
  gh release create "v$V" "$ZIP" --title "mitroley $V" --generate-notes
else
  echo "To publish: git push origin HEAD v$V, then attach $ZIP to a release on GitHub."
fi
