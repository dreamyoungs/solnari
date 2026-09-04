#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 "usage: Scripts/prepare-dmg-assets.sh <output-directory>"
  exit 64
fi

repository_root="$(cd "$(dirname "${0:A}")/.." && pwd)"
source_directory="$repository_root/Assets/DMG"
output_directory="${1:A}"
background_source="$source_directory/background@2x.png"
volume_icon_source="$source_directory/volume-icon.png"

if [[ ! -f "$background_source" || ! -f "$volume_icon_source" ]]; then
  print -u2 "DMG source artwork is missing from Assets/DMG."
  exit 66
fi

mkdir -p "$output_directory"
iconset_directory="$output_directory/VolumeIcon.iconset"
/bin/rm -rf "$iconset_directory"
mkdir -p "$iconset_directory"

/usr/bin/sips --resampleHeightWidth 800 1320 \
  "$background_source" \
  --out "$output_directory/background@2x.png" >/dev/null
/usr/bin/sips --resampleHeightWidth 400 660 \
  "$background_source" \
  --out "$output_directory/background.png" >/dev/null
/usr/bin/sips -s format tiff \
  "$output_directory/background.png" \
  --out "$output_directory/background-1x.tiff" >/dev/null
/usr/bin/sips -s format tiff \
  "$output_directory/background@2x.png" \
  --out "$output_directory/background-2x.tiff" >/dev/null
/usr/bin/tiffutil -cathidpicheck \
  "$output_directory/background-1x.tiff" \
  "$output_directory/background-2x.tiff" \
  -out "$output_directory/background.tiff"

icon_names=(
  icon_16x16.png
  icon_16x16@2x.png
  icon_32x32.png
  icon_32x32@2x.png
  icon_128x128.png
  icon_128x128@2x.png
  icon_256x256.png
  icon_256x256@2x.png
  icon_512x512.png
  icon_512x512@2x.png
)
icon_dimensions=(16 32 32 64 128 256 256 512 512 1024)
for (( index = 1; index <= ${#icon_names}; index++ )); do
  dimension="${icon_dimensions[$index]}"
  /usr/bin/sips --resampleHeightWidth "$dimension" "$dimension" \
    "$volume_icon_source" \
    --out "$iconset_directory/${icon_names[$index]}" >/dev/null
done
/usr/bin/iconutil -c icns \
  "$iconset_directory" \
  -o "$output_directory/VolumeIcon.icns"

print "$output_directory/background.tiff"
print "$output_directory/VolumeIcon.icns"
