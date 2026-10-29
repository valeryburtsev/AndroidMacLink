#!/bin/bash
# Start the capture proxy for the Windows VM. Listens only on the VMware NAT interface.
#   tools/capture/start.sh <session-name> [intercept-hosts-regex]
# Only hosts matching the regex are decrypted; every other connection is tunnelled untouched,
# so Windows Update, the Store and anything certificate-pinned keep working.
set -euo pipefail
cd "$(dirname "$0")/../.."
session="${1:?session name}"
hosts="${2:-(^|\.)dcg(-df|-beta)?\.microsoft\.com(:443)?$}"
listen="${WINPHONE_PROXY_HOST:-192.168.140.1}"
# Another port when 8080 is taken (WINPHONE_PROXY_PORT); the VM's proxy setting must name it too.
port="${WINPHONE_PROXY_PORT:-8080}"
mkdir -p captures/.mitmproxy "captures/$session"
exec mitmdump --listen-host "$listen" --listen-port "$port" \
  --set confdir=captures/.mitmproxy \
  --allow-hosts "$hosts" \
  -s tools/capture/mitm_addon.py \
  --set phonelink_out="captures/$session" \
  --set phonelink_hosts='(^|\.)dcg(-df|-beta)?\.microsoft\.com$|\.signalr\.net$|^login\.(microsoftonline|live|microsoft)\.com$' \
  --set phonelink_raw_ws="${WINPHONE_RAW_WS:-false}" \
  --set termlog_verbosity=warn
