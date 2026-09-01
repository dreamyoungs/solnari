#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  print -u2 "usage: Scripts/create-dmg.sh <Solnari.app> <output.dmg> [volume-name]"
  exit 64
fi

application_path="${1:A}"
output_path="${2:A}"
volume_name="${3:-Solnari}"
if [[ ! -d "$application_path" || "${application_path:e}" != "app" ]]; then
  print -u2 "A built Solnari.app bundle is required."
  exit 66
fi
if [[ "${output_path:e}" != "dmg" ]]; then
  print -u2 "The output path must end in .dmg."
  exit 64
fi

staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/solnari-dmg.XXXXXX")"
cleanup() {
  /bin/rm -rf "$staging_directory"
}
trap cleanup EXIT

/usr/bin/ditto "$application_path" "$staging_directory/Solnari.app"
/bin/ln -s /Applications "$staging_directory/Applications"
mkdir -p "${output_path:h}"
/bin/rm -f "$output_path"
/usr/bin/hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$staging_directory" \
  -format UDZO \
  -ov \
  "$output_path"

print "$output_path"
