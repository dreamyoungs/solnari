#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 "usage: Scripts/verify-dmg.sh <image.dmg>"
  exit 64
fi

dmg_path="${1:A}"
if [[ ! -f "$dmg_path" || "${dmg_path:e}" != "dmg" ]]; then
  print -u2 "A built DMG is required."
  exit 66
fi

mount_directory="$(mktemp -d "${TMPDIR:-/tmp}/solnari-dmg-verify.XXXXXX")"
device_identifier=""
cleanup() {
  if [[ -n "$device_identifier" ]]; then
    /usr/bin/hdiutil detach "$device_identifier" -quiet || true
  fi
  /bin/rm -rf "$mount_directory"
}
trap cleanup EXIT

/usr/bin/hdiutil verify "$dmg_path" >/dev/null
attach_output="$(/usr/bin/hdiutil attach \
  -readonly \
  -noverify \
  -noautoopen \
  -nobrowse \
  -mountpoint "$mount_directory" \
  "$dmg_path")"
device_identifier="$(print -r -- "$attach_output" | /usr/bin/awk 'NR == 1 { print $1 }')"

if [[ ! -d "$mount_directory/Solnari.app" ]]; then
  print -u2 "The DMG does not contain Solnari.app."
  exit 65
fi
if [[ ! -L "$mount_directory/Applications" \
  || "$(/usr/bin/readlink "$mount_directory/Applications")" != "/Applications" ]]; then
  print -u2 "The DMG does not contain the expected Applications shortcut."
  exit 65
fi
for packaged_file in \
  "$mount_directory/.background/background.tiff" \
  "$mount_directory/.VolumeIcon.icns" \
  "$mount_directory/.DS_Store"; do
  if [[ ! -f "$packaged_file" ]]; then
    print -u2 "The DMG layout is missing ${packaged_file:t}."
    exit 65
  fi
done

/usr/bin/hdiutil detach "$device_identifier" -quiet
device_identifier=""
print "$dmg_path"
