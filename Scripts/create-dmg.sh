#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  print -u2 "usage: Scripts/create-dmg.sh <Solnari.app> <output.dmg> [volume-name]"
  exit 64
fi

application_path="${1:A}"
output_path="${2:A}"
volume_name="${3:-Solnari}"
repository_root="$(cd "$(dirname "${0:A}")/.." && pwd)"
if [[ ! -d "$application_path" || "${application_path:e}" != "app" ]]; then
  print -u2 "A built Solnari.app bundle is required."
  exit 66
fi
if [[ "${output_path:e}" != "dmg" ]]; then
  print -u2 "The output path must end in .dmg."
  exit 64
fi

working_directory="$(mktemp -d "${TMPDIR:-/tmp}/solnari-dmg.XXXXXX")"
asset_directory="$working_directory/assets"
attach_plist="$working_directory/attach.plist"
mount_directory=""
writable_image="$working_directory/Solnari-writable.dmg"
device_identifier=""
cleanup() {
  if [[ -n "$device_identifier" ]]; then
    /usr/bin/hdiutil detach "$device_identifier" -quiet || true
  fi
  /bin/rm -rf "$working_directory"
}
trap cleanup EXIT

mkdir -p "$asset_directory" "${output_path:h}"
"$repository_root/Scripts/prepare-dmg-assets.sh" "$asset_directory" >/dev/null

application_size_kb="$(/usr/bin/du -sk "$application_path" | /usr/bin/awk '{ print $1 }')"
image_size_mb="$(( application_size_kb / 1024 + 64 ))"
/usr/bin/hdiutil create \
  -size "${image_size_mb}m" \
  -fs HFS+ \
  -volname "$volume_name" \
  -ov \
  -quiet \
  "$writable_image"

/usr/bin/hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  -plist \
  "$writable_image" > "$attach_plist"
device_identifier="$(/usr/libexec/PlistBuddy \
  -c 'Print :system-entities:0:dev-entry' \
  "$attach_plist")"
mount_directory="$(/usr/libexec/PlistBuddy \
  -c 'Print :system-entities:0:mount-point' \
  "$attach_plist")"
mounted_volume_name="${mount_directory:t}"

/usr/bin/ditto "$application_path" "$mount_directory/Solnari.app"
/bin/ln -s /Applications "$mount_directory/Applications"
mkdir -p "$mount_directory/.background"
/bin/cp "$asset_directory/background.tiff" "$mount_directory/.background/background.tiff"
/usr/bin/touch "$mount_directory/.metadata_never_index"
/usr/bin/SetFile -a V \
  "$mount_directory/.background" \
  "$mount_directory/.metadata_never_index"

/usr/bin/osascript - "$mounted_volume_name" <<'APPLESCRIPT'
on run arguments
  set volumeName to item 1 of arguments
  tell application "Finder"
    tell disk volumeName
      open
      set finderWindow to container window
      set current view of finderWindow to icon view
      set toolbar visible of finderWindow to false
      set statusbar visible of finderWindow to false
      set pathbar visible of finderWindow to false
      set bounds of finderWindow to {100, 100, 760, 500}

      set viewOptions to icon view options of finderWindow
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 128
      set text size of viewOptions to 13
      set label position of viewOptions to bottom
      set shows item info of viewOptions to false
      set shows icon preview of viewOptions to true
      set background picture of viewOptions to file ".background:background.tiff"

      set position of item "Solnari.app" of finderWindow to {175, 195}
      set position of item "Applications" of finderWindow to {485, 195}
      update without registering applications
      delay 2
      close
    end tell
  end tell
end run
APPLESCRIPT

/bin/cp "$asset_directory/VolumeIcon.icns" "$mount_directory/.VolumeIcon.icns"
/usr/bin/SetFile -a V "$mount_directory/.VolumeIcon.icns"
/usr/bin/SetFile -a C "$mount_directory"
/bin/sync
/usr/bin/hdiutil detach "$device_identifier" -quiet
device_identifier=""

mkdir -p "${output_path:h}"
/bin/rm -f "$output_path"
/usr/bin/hdiutil convert \
  "$writable_image" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -quiet \
  -ov \
  -o "$output_path"

print "$output_path"
