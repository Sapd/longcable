#!/bin/bash
# Copyright 2026 Denis Arnst (Sapd) - https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
#
# End-to-end test of the Windows setup command against a real Windows PC.
# Usage: scripts/test-setup-e2e.sh SSH_HOST MAC_IP MAC_NAME
# Needs: an SSH alias to the PC (administrator, usbip-win2 installed), a release
# build (swift build -c release). Uses port 3241 and HTTP port 8765 on MAC_IP only;
# the PC's other USB/IP devices are checked to stay unchanged.
set -euo pipefail
host=$1 ip=$2 name=$3
cd "$(dirname "$0")/.."
bin=.build/release/longcable-server
server_pid=""
http_pid=""
stop_server() { [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null && wait "$server_pid" 2>/dev/null || true; server_pid=""; }
cleanup() { stop_server; [ -n "$http_pid" ] && kill "$http_pid" 2>/dev/null || true; [ -n "${web:-}" ] && rm -rf "$web"; }
trap cleanup EXIT
serve() {
  stop_server
  "$bin" --virtual-mic-dev 0.0.0.0 100.64.0.0/10 --port 3241 --tone 440 "$@" >/dev/null 2>&1 & server_pid=$!
  for _ in $(seq 1 50); do nc -z "$ip" 3241 2>/dev/null && return; sleep 0.1; done
  echo "test server did not start"; exit 1
}
# Serve only the setup script, from a temporary folder.
web=$(mktemp -d); cp scripts/setup-windows.ps1 "$web/"
(cd "$web" && exec python3 -m http.server 8765 --bind "$ip" >/dev/null 2>&1) & http_pid=$!
scp -q scripts/test-setup-windows.ps1 "$host":C:/Temp/test-setup-windows.ps1
failed=0
step() {
  local out rc=0
  out=$(ssh -o BatchMode=yes "$host" "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Temp\\test-setup-windows.ps1 -Step $1 -Ip $ip -Name $name -ScriptUrl http://$ip:8765/setup-windows.ps1" 2>&1) || rc=$?
  echo "$out" | grep -E '^===|PASS|FAIL|\| +(Connected|Already|Waiting|Not connected|Removed|Can.t|The Longcable service)' || true
  [ $rc -eq 0 ] || { failed=1; echo "(step $1 exited $rc)"; }
}
sleep 1
step start
serve;                        step first
                              step again
serve --also-shared 1-9;      step unplugged
serve --no-shared-list;       step oldservice
serve --broken-shared-list;   step truncated
serve;                        step byname
                              step unreachable
                              step autosync
serve --also-shared 1-7;      step autosyncrun
                              step autosyncremove
serve;                        step removeall
if [ $failed -eq 0 ]; then echo "E2E RESULT: ALL PASSED"; else echo "E2E RESULT: FAILED"; exit 1; fi
