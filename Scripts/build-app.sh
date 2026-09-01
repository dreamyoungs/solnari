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

developer_directory="$(/usr/bin/xcode-select --print-path 2>/dev/null || true)"
swift_executable="$(/usr/bin/xcrun --find swift 2>/dev/null || true)"
if [[ -z "$developer_directory" || ! -d "$developer_directory" || \
      -z "$swift_executable" || ! -x "$swift_executable" ]]; then
  print -u2 "Xcode or Xcode Command Line Tools with Swift 6.1 or newer is required to build Solnari."
  print -u2 "Install the standalone tools with: xcode-select --install"
  print -u2 "Or select an installed Xcode with: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  exit 69
fi
if ! "$swift_executable" package dump-package >/dev/null; then
  print -u2 "The selected Swift toolchain cannot load Package.swift."
  print -u2 "Update Xcode or Command Line Tools, then verify the selection with: xcode-select --print-path"
  exit 69
fi

node_executable="${SOLNARI_NODE:-$(command -v node || true)}"
if [[ -z "$node_executable" || ! -x "$node_executable" ]]; then
  print -u2 "Node.js $(<"$repository_root/.node-version") with npm is required to build Solnari."
  exit 69
fi
node_executable="${node_executable:A}"
required_node_version="$(<"$repository_root/.node-version")"
actual_node_version="$($node_executable -p 'process.versions.node')"
if [[ "$actual_node_version" != "$required_node_version" ]]; then
  print -u2 "Node.js $required_node_version is required to build Solnari (found $actual_node_version)."
  exit 69
fi
if ! command -v npm >/dev/null 2>&1; then
  print -u2 "npm is required to build the bundled Node backend."
  exit 69
fi
if [[ ! -x "$repository_root/backend/node_modules/.bin/esbuild" ]]; then
  print -u2 "Backend build dependencies are not installed."
  print -u2 "Run: npm --prefix backend ci --include=dev"
  exit 66
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

case "$required_node_version" in
  24.20.0)
    node_license_sha256="5888dbb9a1d2b18f2c3e6c5f6af1b39de658372b402a0577b002777f14c62ace"
    ;;
  *)
    print -u2 "No verified Node.js LICENSE checksum is configured for $required_node_version."
    exit 65
    ;;
esac
node_license_directory="$repository_root/.build/licenses/node-$required_node_version"
node_license="$node_license_directory/LICENSE"
node_license_url="https://raw.githubusercontent.com/nodejs/node/v$required_node_version/LICENSE"
node_license_checksum=""
if [[ -f "$node_license" ]]; then
  node_license_checksum="$(/usr/bin/shasum -a 256 "$node_license" | /usr/bin/awk '{print $1}')"
fi
if [[ "$node_license_checksum" != "$node_license_sha256" ]]; then
  mkdir -p "$node_license_directory"
  node_license_download="$node_license.download"
  /bin/rm -f "$node_license_download"
  if ! /usr/bin/curl --fail --location --silent --show-error --retry 3 \
    --output "$node_license_download" "$node_license_url"; then
    /bin/rm -f "$node_license_download"
    print -u2 "Could not download the verified Node.js $required_node_version LICENSE."
    print -u2 "Check the network connection and retry the build."
    exit 69
  fi
  node_license_checksum="$(/usr/bin/shasum -a 256 "$node_license_download" | /usr/bin/awk '{print $1}')"
  if [[ "$node_license_checksum" != "$node_license_sha256" ]]; then
    /bin/rm -f "$node_license_download"
    print -u2 "The downloaded Node.js LICENSE checksum did not match the pinned version."
    exit 65
  fi
  /bin/mv "$node_license_download" "$node_license"
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
