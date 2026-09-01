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
node_executable="${SOLNARI_NODE:-$(command -v node || true)}"
if [[ -z "$node_executable" || ! -x "$node_executable" ]]; then
  print -u2 "Node.js 24 or newer is required to build Solnari."
  exit 69
fi
node_executable="${node_executable:A}"
required_node_version="$(<"$repository_root/.node-version")"
actual_node_version="$($node_executable -p 'process.versions.node')"
if [[ "$actual_node_version" != "$required_node_version" ]]; then
  print -u2 "Node.js $required_node_version is required to build Solnari (found $actual_node_version)."
  exit 69
fi
npm --prefix "$repository_root/backend" run build
swift build --configuration "$configuration" --product Solnari
binary_directory="$(swift build --configuration "$configuration" --show-bin-path)"
output_directory="$repository_root/.build/app/$configuration"
application_path="$output_directory/Solnari.app"
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/solnari-app.XXXXXX")"
icon_directory="$(mktemp -d "${TMPDIR:-/tmp}/solnari-icon.XXXXXX")"
cleanup() {
  rm -rf "$staging_directory" "$icon_directory"
}
trap cleanup EXIT

staged_application="$staging_directory/Solnari.app"
mkdir -p \
  "$staged_application/Contents/MacOS" \
  "$staged_application/Contents/Resources/Node/bin" \
  "$staged_application/Contents/Resources/NodeBackend" \
  "$staged_application/Contents/Resources/Licenses"
/usr/bin/ditto "$binary_directory/Solnari" "$staged_application/Contents/MacOS/Solnari"
/usr/bin/ditto "$repository_root/App/Info.plist" "$staged_application/Contents/Info.plist"
/usr/bin/ditto "$node_executable" "$staged_application/Contents/Resources/Node/bin/node"
/bin/chmod 755 "$staged_application/Contents/Resources/Node/bin/node"
/usr/bin/ditto \
  "$repository_root/backend/dist/server.cjs" \
  "$staged_application/Contents/Resources/NodeBackend/server.cjs"
/usr/bin/ditto \
  "$repository_root/backend/dist/mcp-server.cjs" \
  "$staged_application/Contents/Resources/NodeBackend/mcp-server.cjs"
/usr/bin/ditto \
  "$repository_root/backend/src/subprocess-guard.cjs" \
  "$staged_application/Contents/Resources/NodeBackend/subprocess-guard.cjs"
/usr/bin/ditto \
  "$repository_root/LICENSE" \
  "$staged_application/Contents/Resources/Licenses/Solnari-LICENSE.txt"

node_license="${node_executable:h:h}/LICENSE"
if [[ ! -f "$node_license" ]]; then
  print -u2 "The selected Node.js installation does not include its LICENSE file."
  exit 66
fi
"$node_executable" "$repository_root/Scripts/collect-licenses.mjs" \
  "$node_license" \
  "$repository_root/backend/package-lock.json" \
  "$repository_root/backend/node_modules" \
  "$repository_root/.build/checkouts" \
  "$staged_application/Contents/Resources/Licenses/THIRD-PARTY-NOTICES.txt"

resource_bundle="$binary_directory/Solnari_Solnari.bundle"
if [[ -d "$resource_bundle" ]]; then
  /usr/bin/ditto "$resource_bundle" \
    "$staged_application/Contents/Resources/Solnari_Solnari.bundle"
fi

icon_source="$repository_root/Sources/Solnari/Resources/SolnariIcon.png"
iconset="$icon_directory/Solnari.iconset"
mkdir -p "$iconset"
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

signing_identity="${SOLNARI_CODESIGN_IDENTITY:--}"
node_codesign_arguments=(--force --sign "$signing_identity")
app_codesign_arguments=(--force --sign "$signing_identity")
if [[ "$signing_identity" == "-" ]]; then
  node_codesign_arguments+=(--timestamp=none)
  app_codesign_arguments+=(
    --timestamp=none
    --requirements
    '=designated => identifier "com.dreamyoungs.solnari"'
  )
else
  node_codesign_arguments+=(
    --timestamp
    --options runtime
    --entitlements "$repository_root/App/Node.entitlements"
  )
  app_codesign_arguments+=(--timestamp --options runtime)
fi
/usr/bin/codesign "${node_codesign_arguments[@]}" \
  "$staged_application/Contents/Resources/Node/bin/node"
/usr/bin/codesign "${app_codesign_arguments[@]}" "$staged_application"
mkdir -p "$output_directory"
if [[ -e "$application_path" ]]; then
  rm -rf "$application_path"
fi
mv "$staged_application" "$application_path"

print "$application_path"
