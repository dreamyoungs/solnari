#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "${0:A}")/.." && pwd)"
signing_identity="${SOLNARI_CODESIGN_IDENTITY:-}"
notary_profile="${SOLNARI_NOTARY_KEYCHAIN_PROFILE:-}"
architecture="$(/usr/bin/uname -m)"

if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
  print -u2 "Set SOLNARI_CODESIGN_IDENTITY to a Developer ID Application identity."
  exit 64
fi
if [[ -z "$notary_profile" ]]; then
  print -u2 "Set SOLNARI_NOTARY_KEYCHAIN_PROFILE to a notarytool Keychain profile."
  exit 64
fi
if [[ "$architecture" != "arm64" ]]; then
  print -u2 "Public Solnari releases currently support Apple Silicon (arm64) only."
  print -u2 "Run this script on an Apple Silicon Mac."
  exit 69
fi

application_path="$("$repository_root/Scripts/build-app.sh" release | tail -n 1)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$application_path/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$application_path/Contents/Info.plist")"
release_directory="$repository_root/.build/release"
dmg_path="$release_directory/Solnari-$version-macos-arm64.dmg"
checksum_path="$dmg_path.sha256"

mkdir -p "$release_directory"
rm -f "$dmg_path" "$checksum_path"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$application_path"
app_architecture="$(/usr/bin/lipo -archs "$application_path/Contents/MacOS/Solnari")"
node_architecture="$(/usr/bin/lipo -archs \
  "$application_path/Contents/Resources/Node/bin/node")"
if [[ "$app_architecture" != "arm64" || "$node_architecture" != "arm64" ]]; then
  print -u2 "Release app and bundled Node runtime must both be arm64."
  print -u2 "Found app=$app_architecture node=$node_architecture."
  exit 65
fi

"$repository_root/Scripts/create-dmg.sh" \
  "$application_path" \
  "$dmg_path" \
  "Solnari $version"
"$repository_root/Scripts/verify-dmg.sh" "$dmg_path" >/dev/null
/usr/bin/codesign \
  --force \
  --sign "$signing_identity" \
  --timestamp \
  --identifier "com.dreamyoungs.solnari.dmg" \
  "$dmg_path"
/usr/bin/codesign --verify --verbose=2 "$dmg_path"
/usr/bin/xcrun notarytool submit "$dmg_path" \
  --keychain-profile "$notary_profile" \
  --wait
/usr/bin/xcrun stapler staple "$dmg_path"
/usr/bin/xcrun stapler validate "$dmg_path"
/usr/sbin/spctl --assess --type open --context context:primary-signature \
  --verbose=4 "$dmg_path"
(
  cd "$release_directory"
  /usr/bin/shasum -a 256 "${dmg_path:t}" > "${checksum_path:t}"
)

print "Solnari $version ($build_number)"
print "$dmg_path"
print "$checksum_path"
