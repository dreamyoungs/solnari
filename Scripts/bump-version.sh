#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "${0:A}")/.." && pwd)"
requested="${1:-}"
mode="${2:-}"
if [[ -z "$requested" || ( -n "$mode" && "$mode" != "--dry-run" ) ]]; then
  print -u2 "usage: Scripts/bump-version.sh <major|minor|patch|build|x.y.z> [--dry-run]"
  exit 64
fi

current_version="$(<"$repository_root/VERSION")"
current_build="$(<"$repository_root/BUILD_NUMBER")"
if [[ "$current_version" != <->.<->.<-> || "$current_build" != <-> ]]; then
  print -u2 "VERSION or BUILD_NUMBER is invalid."
  exit 65
fi

parts=("${(@s:.:)current_version}")
major="$parts[1]"
minor="$parts[2]"
patch="$parts[3]"
case "$requested" in
  major) next_version="$((major + 1)).0.0" ;;
  minor) next_version="$major.$((minor + 1)).0" ;;
  patch) next_version="$major.$minor.$((patch + 1))" ;;
  build) next_version="$current_version" ;;
  <->.<->.<->) next_version="$requested" ;;
  *)
    print -u2 "Version must be major, minor, patch, build, or three integers such as 0.2.1."
    exit 64
    ;;
esac
if [[ "$requested" != "build" && "$next_version" == "$current_version" ]]; then
  print -u2 "The requested version is already current."
  exit 64
fi
next_build="$((current_build + 1))"

print "Solnari $current_version ($current_build) -> $next_version ($next_build)"
if [[ "$mode" == "--dry-run" ]]; then
  exit 0
fi

print "$next_version" > "$repository_root/VERSION"
print "$next_build" > "$repository_root/BUILD_NUMBER"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next_version" \
  "$repository_root/App/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next_build" \
  "$repository_root/App/Info.plist"

if [[ "$requested" != "build" ]]; then
  npm --prefix "$repository_root/backend" version "$next_version" \
    --no-git-tag-version --allow-same-version >/dev/null
fi

print "Update CHANGELOG.md before publishing the release."
