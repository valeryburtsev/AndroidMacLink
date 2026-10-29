#!/bin/bash
# Compare what Phone Link sends for the features built from code alone with what our client
# builds: device controls, picture messages, call history, photo delete.
#
#   tools/capture/controls-check.sh mark <session>         print where the capture ends now
#   tools/capture/controls-check.sh show <session> [seq]   structure of the relevant messages
#                                                          recorded after <seq> (default: all)
#
# Do "mark", perform the actions in Phone Link on the VM, then "show" with the number printed.
# Only key names, types and sizes are printed, never values: the capture holds real content.
# The capture proxy must be running with raw WebSocket recording (WINPHONE_RAW_WS=true).
set -euo pipefail
cd "$(dirname "$0")/../.."
probe=app/.build/debug/winphone-probe
session="${2:-}"
flows="captures/$session/flows.jsonl"

case "${1:-}" in
  mark)
    [ -f "$flows" ] || { echo "no capture at $flows"; exit 1; }
    tail -1 "$flows" | python3 -c 'import sys, json; print(json.loads(sys.stdin.read()).get("seq", 0))'
    ;;
  show)
    [ -f "$flows" ] || { echo "no capture at $flows"; exit 1; }
    from="${3:-0}"
    section() {
      echo
      echo "=== $1"
      shift
      "$probe" app-messages "$flows" --shape --from "$from" "$@" 2>/dev/null | grep -v '^$' || true
    }
    section "ring my phone, ringer and Do Not Disturb as resource requests (expect /ringmyphone or /devicestatus with request type update)" --route /DeviceResourceManager
    section "ringer and Do Not Disturb as commands (expect deviceStatusCommandType, deviceStatusCommandValue)" --route /command/devicestatus
    section "media keys (expect audioCommandValue, key, no contentType)" --route /command/audio
    section "messages: attachment fetch is requestType 1 with messagingMmsPartIds; a picture send has partCount, partBytes" --route /chat/v1
    section "photos: delete has requestType 0, mediaIds, checksums" --route /media/v1
    section "call history: forced sync" --route /calling
    section "dial on phone" --route /calling/dial
    section "call history pushes from the phone" --route /legacy/phonecontent --content-type callLogs
    section "start-of-session exchange (look at configuration.CallLogs and sequenceNumbers.call_logs)" --route /connect/v1
    echo
    echo "=== peer-to-peer signalling (kinds and key names only; the descriptions hold key material)"
    "$probe" app-messages "$flows" --shape --from "$from" 2>/dev/null | grep -A1 "PLATFORM /Context/Message" | grep -v '^--' || true
    ;;
  *)
    sed -n 2,12p "$0"
    exit 2
    ;;
esac
