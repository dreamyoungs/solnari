#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "${0:A}")/.." && pwd)"
configuration="${1:-debug}"
application_path="$($repository_root/Scripts/build-app.sh "$configuration" | tail -n 1)"
current_user="$(/usr/bin/id -un)"
user_home="$(/usr/bin/dscl . -read "/Users/$current_user" NFSHomeDirectory | /usr/bin/awk '{print $2}')"
if [[ -z "$user_home" || "$user_home" != /Users/* ]]; then
  print -u2 "Could not resolve a safe user application directory."
  exit 71
fi
installed_directory="$user_home/Applications"
installed_application="$installed_directory/Solnari Development.app"

if /usr/bin/pgrep -x Solnari >/dev/null 2>&1; then
  /usr/bin/osascript -e 'tell application id "com.dreamyoungs.solnari" to quit' \
    >/dev/null 2>&1 || true
  for attempt in {1..20}; do
    /usr/bin/pgrep -x Solnari >/dev/null 2>&1 || break
    /bin/sleep 0.25
  done
  if /usr/bin/pgrep -x Solnari >/dev/null 2>&1; then
    /usr/bin/pkill -TERM -x Solnari
    for attempt in {1..20}; do
      /usr/bin/pgrep -x Solnari >/dev/null 2>&1 || break
      /bin/sleep 0.25
    done
  fi
  if /usr/bin/pgrep -x Solnari >/dev/null 2>&1; then
    print -u2 "Could not stop the existing Solnari process."
    exit 70
  fi
fi

mkdir -p "$installed_directory"
if [[ -e "$installed_application" ]]; then
  rm -rf "$installed_application"
fi
/usr/bin/ditto "$application_path" "$installed_application"
/usr/bin/open "$installed_application"

print "$installed_application"
