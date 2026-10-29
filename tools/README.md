# Lab tooling

| Purpose | Tool | Where |
|---|---|---|
| Android decompilation | jadx, apktool | Homebrew |
| Windows .NET decompilation | ilspycmd | `dotnet tool install -g ilspycmd` (needs .NET SDK from Homebrew) |
| Dynamic instrumentation | frida-tools | `tools/.venv` |
| HTTPS / WebSocket capture | mitmproxy | Homebrew |
| LAN capture | Wireshark | Homebrew cask |
| Device access | adb (android-platform-tools) | Homebrew cask |
| Protocol decoding | msgpack, protobuf (Python) | `tools/.venv` |
| Core implementation | Go 1.23+ | Homebrew |

Activate the Python environment with `source tools/.venv/bin/activate`.

## Windows VM access

The VM (VMware Fusion, Windows 11 ARM, NAT address and user in the git-ignored `tools/.vm`) is reached over
SSH with the project-only key `~/.ssh/winphone_vm`. No password is stored anywhere.

- `tools/vm.sh '<PowerShell>'` runs a PowerShell command in the VM.
- `tools/vm-pull.sh '<parent dir>' <folder> <dest>` copies a folder out as a tar stream. It reads
  package folders in place, so nothing under `WindowsApps` has its ownership or ACLs changed.

Decompiled sources go in `corpus/` and raw captures in `captures/`; both are git-ignored and must
stay out of any public repository.

## Status (2026-10-08)

Installed and verified: Go 1.27, jadx 1.5.6, apktool 3.0.3, protoc 36.2, mitmproxy 12.2, adb,
Python 3.12, .NET SDK 10 (Homebrew formula), ilspycmd 11.1, frida-tools 14.11 / frida 17.23 (venv),
tshark 4.6.9. LinkMyPhone is cloned at `third_party/linkmyphone` (MIT) and builds on macOS except
for `clipboard/native_watch.go` (Linux-only `Pdeathsig`); its control-plane tests fail only because
macOS limits Unix socket paths to 104 bytes.

Add to your shell profile so `dotnet` and `ilspycmd` resolve:

    export PATH="/opt/homebrew/opt/dotnet/bin:$HOME/.dotnet/tools:$PATH"
    export DOTNET_ROOT="/opt/homebrew/opt/dotnet/libexec"

Needs your password (run yourself): the Wireshark GUI and the packet-capture permission helper.

    brew install --cask wireshark-app

## Our own capture and evidence tools

Written from scratch for this project (ideas borrowed from the `morluto/rea` design, no code copied):

- `capture/mitm_addon.py`: mitmproxy addon that records Phone Link cloud traffic to
  `captures/<session>/flows.jsonl`. It only records hosts matching `phonelink_hosts`
  (default: `dcg.microsoft.com` and the Microsoft login hosts), redacts tokens, cookies
  and JWTs before writing, and decodes SignalR WebSocket messages into hub frames.

      mitmdump -s tools/capture/mitm_addon.py --set phonelink_out=captures/session1

- `capture/wire.py`: the redaction, SignalR framing and MessagePack decoding it relies on.
  The decoder is self-contained because Homebrew's mitmproxy bundles no `msgpack` module.
  Tests: `cd tools/capture && ../.venv/bin/python -m unittest test_wire`.
- `evidence/ledger.py`: registers binaries and captures by SHA-256 and records each
  protocol claim as `observed`, `inferred` or `unknown` against the exact artifact.
  Output goes to `evidence/`, which holds no secrets and can be committed.

Rules adopted for the lab: never execute a target binary on the Mac, keep decompiled
corpora read-only, redact at capture time rather than afterwards, and write down what
is still unknown instead of guessing.

## Windows-side static analysis pipeline

1. `tools/vm-pull.sh` copies the installed package into `corpus/windows/full/` (read-only, git-ignored).
2. `tools/pe_triage.py <package dir>` classifies each DLL as managed, ReadyToRun or native.
3. `tools/decompile-windows.sh <package dir>` decompiles first-party managed assemblies with ilspycmd.
4. `tools/catalog/recover_protos.py` rebuilds exact `.proto` files from embedded descriptors into
   `protocol/recovered/windows/`.
5. `tools/catalog/build_catalog.py` writes `protocol/windows-catalog.md` (endpoints, hub methods,
   routes by feature, schema index). `tools/catalog/scan_windows.py` is the raw scanner behind it.

## Android-side static analysis

- `tools/adb-pull-apk.sh <package>` pulls every APK split from the connected phone into
  `corpus/android/<package>-<version>/` and registers the hashes.
- jadx output goes to `corpus/android/jadx/<package>-<version>/`.
- The Link to Windows APK contains Microsoft's original `.proto` sources as resources. They are
  extracted to `protocol/recovered/android/`, which is git-ignored because the files are
  Microsoft's copyrighted source and must not be published.

## Live capture from the VM

1. On the Mac: `tools/capture/start.sh <session>` starts mitmdump on `192.168.140.1:8080`, the
   VMware NAT interface, so only the VM can reach it. It decrypts only the DCG hosts and tunnels
   everything else untouched. Output goes to `captures/<session>/` (`flows.jsonl`, `hosts.log`).
   The proxy's CA and private key live in `captures/.mitmproxy/`, which is git-ignored.
2. In the VM, as administrator: `C:\winphone\proxy-on.cmd` trusts that CA and sets the user proxy.
   `C:\winphone\proxy-off.cmd` undoes both. Copies of the scripts are in `tools/windows/`.
   These change security settings, so the user runs them, not Claude.
3. Restart Phone Link after switching the proxy on or off.
4. `WINPHONE_RAW_WS=true tools/capture/start.sh <session> '<hosts regex incl. signalr>'` also records
   every relay WebSocket message as base64. `app/.build/debug/winphone-probe app-messages
   captures/<session>/flows.jsonl [--route R] [--content-type T] [--full]` decodes them with the
   Swift codecs and prints APP payloads as value sets.

### Notification traffic

No notification message has been captured yet: the phone had never granted Link to Windows
notification access. `tools/capture/notification-test.sh` has the four steps: `check` (read-only,
over adb), `settings` (opens the phone's notification-access page; the user allows Link to Windows
there), `post [n]` (posts test notifications from the adb shell, so no real notification is
involved), and `decode <session>` (prints what the phone pushed on `/legacy/phonecontent` and what
the PC sent on `/notifications`).

### Device controls, picture messages, call history, photo delete

These were built from the decompiled code alone. `tools/capture/controls-check.sh` compares a
recording with them: `mark <session>` prints where the capture ends, and after the actions were
done in Phone Link, `show <session> <seq>` prints the structure of the relevant requests recorded
since (key names, types and sizes only).

## Fixtures for the Swift tests

- `capture/make_fixtures.py <flows.jsonl> <out.json>` turns a capture taken with
  `WINPHONE_RAW_WS=true` into byte-exact hub frames with payloads zeroed and UUIDs replaced.
- `capture/make_http_fixtures.py <fixtures dir> <flows.jsonl>...` extracts request shapes and one
  pairing's responses with identifiers and PINs replaced.
- `catalog/render_protos.py <descriptor set> app/Protos` renders our `.proto` files; then
  `protoc --swift_out` generates `app/Sources/WinPhoneCore/Generated`.

Captures taken before 2026-10-09 10:00 still contain the account name and e-mail inside the
enrollment response, because the redaction did not cover those fields then. They are git-ignored;
do not share them.
