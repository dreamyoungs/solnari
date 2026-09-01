#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "${0:A}")/.." && pwd)"
architecture="$(/usr/bin/uname -m)"
if [[ "$architecture" != "arm64" ]]; then
  print -u2 "Local Solnari DMGs currently support Apple Silicon (arm64) only."
  exit 69
fi

application_path="$("$repository_root/Scripts/build-app.sh" release | tail -n 1)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$application_path/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$application_path/Contents/Info.plist")"
app_architecture="$(/usr/bin/lipo -archs "$application_path/Contents/MacOS/Solnari")"
node_architecture="$(/usr/bin/lipo -archs \
  "$application_path/Contents/Resources/Node/bin/node")"
if [[ "$app_architecture" != "arm64" || "$node_architecture" != "arm64" ]]; then
  print -u2 "Local DMG app and bundled Node runtime must both be arm64."
  print -u2 "Found app=$app_architecture node=$node_architecture."
  exit 65
fi

release_directory="$repository_root/.build/release"
dmg_path="$release_directory/Solnari-$version-macos-arm64-unsigned.dmg"
checksum_path="$dmg_path.sha256"
mkdir -p "$release_directory"
/bin/rm -f "$dmg_path" "$checksum_path"

"$repository_root/Scripts/create-dmg.sh" \
  "$application_path" \
  "$dmg_path" \
  "Solnari $version"
/usr/bin/hdiutil verify "$dmg_path"
(
  cd "$release_directory"
  /usr/bin/shasum -a 256 "${dmg_path:t}" > "${checksum_path:t}"
)

print -u2 "This DMG is ad-hoc signed for local testing and is not notarized for public distribution."
print "Solnari $version ($build_number)"
print "$dmg_path"
print "$checksum_path"
