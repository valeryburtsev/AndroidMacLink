#!/bin/bash
# Decompile first-party managed assemblies from a Phone Link package into corpus/windows/decompiled/.
#   tools/decompile-windows.sh corpus/windows/full/Microsoft.YourPhone_<version>
# Static only: nothing from the package is loaded or executed.
set -uo pipefail
export PATH="/opt/homebrew/opt/dotnet/bin:$HOME/.dotnet/tools:$PATH"
export DOTNET_ROOT="/opt/homebrew/opt/dotnet/libexec"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
pkg="$1"; out="corpus/windows/decompiled"; mkdir -p "$out"
ok=0; fail=0
while read -r kind size name; do
  case "$kind" in managed-*) ;; *) continue ;; esac
  case "$name" in
    YourPhone*|PhoneExperienceHost.dll|SharedUtilities*|ConnectedDevicesDevKit*|LibNanoAPI.Projection.dll) ;;
    *) continue ;;
  esac
  dest="$out/${name%.dll}"
  [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ] && { ok=$((ok+1)); continue; }
  mkdir -p "$dest"
  if ilspycmd -p --nested-directories -r "$pkg" -o "$dest" "$pkg/$name" > "$dest.log" 2>&1; then
    ok=$((ok+1)); rm -f "$dest.log"; echo "ok   $name ($(find "$dest" -name '*.cs' | wc -l | tr -d ' ') files)"
  else
    fail=$((fail+1)); echo "FAIL $name (see $dest.log)"
  fi
done < corpus/windows/triage.txt
echo "DONE ok=$ok fail=$fail"
