#!/bin/bash
# Copy a folder out of the Windows VM as a tar stream, without touching its permissions.
#   tools/vm-pull.sh 'C:\Program Files\WindowsApps' Some.Package_1.2.3 corpus/windows/full
set -euo pipefail
# The address lives in the git-ignored tools/.vm (user@host) unless WINPHONE_VM gives it.
VM="${WINPHONE_VM:-$(cat "$(dirname "$0")/.vm" 2>/dev/null)}"
[ -n "$VM" ] || { echo "Put user@host of the VM in tools/.vm or WINPHONE_VM." >&2; exit 2; }
parent="$1"; name="$2"; dest="$3"
mkdir -p "$dest"
tmp="$(mktemp -t vmpull).tar"
ssh -i ~/.ssh/winphone_vm -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 "$VM" \
  "tar -cf - -C \"$parent\" \"$name\"" > "$tmp"
if tar -tf "$tmp" | grep -qE '^/|(^|/)\.\./'; then echo "unsafe paths in archive" >&2; exit 1; fi
tar -xf "$tmp" -C "$dest"
rm -f "$tmp"
echo "$name: $(find "$dest/$name" -type f | wc -l | tr -d ' ') files"
