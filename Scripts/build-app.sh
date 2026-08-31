#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "${0:A}")/.." && pwd)"
configuration="${1:-debug}"
case "$configuration" in
  debug|release) ;;
  *)
    print -u2 "usage: Scripts/build-app.sh [debug|release]"
    exit 64
    ;;
esac

cd "$repository_root"
swift build --configuration "$configuration" --product Solnari
binary_directory="$(swift build --configuration "$configuration" --show-bin-path)"
output_directory="$repository_root/.build/app/$configuration"
application_path="$output_directory/Solnari.app"
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/solnari-app.XXXXXX")"
icon_directory="$(mktemp -d "${TMPDIR:-/tmp}/solnari-icon.XXXXXX")"
trap 'rm -rf "$staging_directory" "$icon_directory"' EXIT

staged_application="$staging_directory/Solnari.app"
mkdir -p "$staged_application/Contents/MacOS" "$staged_application/Contents/Resources"
/usr/bin/ditto "$binary_directory/Solnari" "$staged_application/Contents/MacOS/Solnari"
/usr/bin/ditto "$repository_root/App/Info.plist" "$staged_application/Contents/Info.plist"

resource_bundle="$binary_directory/Solnari_Solnari.bundle"
if [[ -d "$resource_bundle" ]]; then
  /usr/bin/ditto "$resource_bundle" \
    "$staged_application/Contents/Resources/Solnari_Solnari.bundle"
fi

icon_source="$icon_directory/Solnari-1024.png"
iconset="$icon_directory/Solnari.iconset"
mkdir -p "$iconset"
xcrun swift "$repository_root/Scripts/generate-app-icon.swift" "$icon_source"
for specification in \
  '16 icon_16x16.png' \
  '32 icon_16x16@2x.png' \
  '32 icon_32x32.png' \
  '64 icon_32x32@2x.png' \
  '128 icon_128x128.png' \
  '256 icon_128x128@2x.png' \
  '256 icon_256x256.png' \
  '512 icon_256x256@2x.png' \
  '512 icon_512x512.png' \
  '1024 icon_512x512@2x.png'
do
  pixels="${specification%% *}"
  filename="${specification#* }"
  /usr/bin/sips --resampleHeightWidth "$pixels" "$pixels" "$icon_source" \
    --out "$iconset/$filename" >/dev/null
done
/usr/bin/iconutil --convert icns "$iconset" \
  --output "$staged_application/Contents/Resources/Solnari.icns"

/usr/bin/codesign --force --deep --sign - --timestamp=none "$staged_application"
mkdir -p "$output_directory"
if [[ -e "$application_path" ]]; then
  rm -rf "$application_path"
fi
mv "$staged_application" "$application_path"

print "$application_path"
