#!/bin/bash
# Pull every APK split of a package from the connected phone into corpus/android/<package>-<version>/.
#   tools/adb-pull-apk.sh com.microsoft.appmanager
set -euo pipefail
pkg="$1"
ver=$(adb shell dumpsys package "$pkg" | grep -m1 versionName | sed 's/.*versionName=//' | tr -d '\r')
[ -n "$ver" ] || { echo "package $pkg not found on device" >&2; exit 1; }
dest="corpus/android/$pkg-$ver"
mkdir -p "$dest"
adb shell pm path "$pkg" | sed 's/^package://' | tr -d '\r' | while read -r remote; do
  local_file="$dest/$(basename "$remote")"
  [ -f "$local_file" ] || adb pull "$remote" "$local_file" | tail -1
done
chmod a-w "$dest"/*.apk
for f in "$dest"/*.apk; do printf '   %s %.1f MB\n' "$(basename "$f")" "$(echo "$(stat -f %z "$f") / 1048576" | bc -l)"; done
tools/.venv/bin/python tools/evidence/ledger.py register "$dest" --kind apk --version "$ver" --source "adb pull from phone, package $pkg"
