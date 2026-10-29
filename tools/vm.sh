#!/bin/bash
# Run a PowerShell command in the Windows VM over SSH:  tools/vm.sh 'Get-Date'
# Override the address with WINPHONE_VM=user@host if the VM's IP changes.
# The address lives in the git-ignored tools/.vm (user@host) unless WINPHONE_VM gives it.
VM="${WINPHONE_VM:-$(cat "$(dirname "$0")/.vm" 2>/dev/null)}"
[ -n "$VM" ] || { echo "Put user@host of the VM in tools/.vm or WINPHONE_VM." >&2; exit 2; }
ENC=$(printf '%s' "\$ProgressPreference='SilentlyContinue'; $*" | iconv -t UTF-16LE | base64 | tr -d '\n')
exec ssh -i ~/.ssh/winphone_vm -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 "$VM" "powershell -NoProfile -NonInteractive -EncodedCommand $ENC"
