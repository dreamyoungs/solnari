#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "${0:A}")/.." && pwd)"
configuration="${1:-debug}"
application_path="$($repository_root/Scripts/build-app.sh "$configuration" | tail -n 1)"
/usr/bin/open "$application_path"
