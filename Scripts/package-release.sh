#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "${0:A}")/.." && pwd)"
signing_identity="${SOLNARI_CODESIGN_IDENTITY:-}"
notary_profile="${SOLNARI_NOTARY_KEYCHAIN_PROFILE:-}"

if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
  print -u2 "Set SOLNARI_CODESIGN_IDENTITY to a Developer ID Application identity."
  exit 64
fi
if [[ -z "$notary_profile" ]]; then
  print -u2 "Set SOLNARI_NOTARY_KEYCHAIN_PROFILE to a notarytool Keychain profile."
  exit 64
fi

application_path="$("$repository_root/Scripts/build-app.sh" release | tail -n 1)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$application_path/Contents/Info.plist")"
architecture="$(/usr/bin/uname -m)"
release_directory="$repository_root/.build/release"
archive_path="$release_directory/Solnari-$version-macos-$architecture.zip"
checksum_path="$archive_path.sha256"

mkdir -p "$release_directory"
rm -f "$archive_path" "$checksum_path"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$application_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$application_path" "$archive_path"
/usr/bin/xcrun notarytool submit "$archive_path" \
  --keychain-profile "$notary_profile" \
  --wait
/usr/bin/xcrun stapler staple "$application_path"
/usr/bin/xcrun stapler validate "$application_path"
/usr/sbin/spctl --assess --type execute --verbose=4 "$application_path"

rm -f "$archive_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$application_path" "$archive_path"
(
  cd "$release_directory"
  /usr/bin/shasum -a 256 "${archive_path:t}" > "${checksum_path:t}"
)

print "$archive_path"
print "$checksum_path"
