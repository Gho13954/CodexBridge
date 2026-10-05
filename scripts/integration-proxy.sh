#!/bin/bash
set -euo pipefail
task_repo="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
task_cli="$task_repo/.build/release/codexbridge"
task_core="$task_repo/.build/core/mihomo"
test -x "$task_cli" && test -x "$task_core" || { echo 'Build and fetch the core first.' >&2; exit 1; }
task_tmp="$(/usr/bin/mktemp -d "$task_repo/.build/integration.XXXXXX")"
task_pid=''
cleanup() {
    if [ -n "$task_pid" ]; then kill "$task_pid" >/dev/null 2>&1 || true; wait "$task_pid" 2>/dev/null || true; fi
    rm -rf "$task_tmp"
}
trap cleanup EXIT
task_metadata="$("$task_cli" test-config "$task_tmp/config.json")"
task_port="$(printf '%s\n' "$task_metadata" | /usr/bin/awk '/Test mixed port:/ {print $4}')"
task_ip="$(printf '%s\n' "$task_metadata" | /usr/bin/awk '/Test IPv4 address:/ {print $4}')"
[ -n "$task_ip" ] || { echo 'This local integration probe needs an IPv4 target address.' >&2; exit 1; }
"$task_core" -t -d "$task_tmp" -f "$task_tmp/config.json"
"$task_core" -d "$task_tmp" -f "$task_tmp/config.json" > "$task_tmp/core.log" 2>&1 &
task_pid=$!
for task_try in {1..30}; do
    if /usr/bin/nc -z 127.0.0.1 "$task_port" >/dev/null 2>&1; then break; fi
    /bin/sleep 0.1
done
task_target='codex-cloud-backend.chatgpt.com'
task_result="$(/usr/bin/curl --proxy "http://127.0.0.1:$task_port" --noproxy '' \
    --connect-to "$task_target:443:$task_ip:443" --connect-timeout 10 --max-time 20 \
    --silent --show-error --output /dev/null \
    --write-out 'http=%{http_code} connect=%{http_connect} tls=%{ssl_verify_result}' "https://$task_target/")"
echo "$task_result"
[[ "$task_result" == *'connect=200 tls=0'* ]] || { echo 'TLS/proxy probe failed.' >&2; exit 1; }
/usr/bin/grep -F 'using Existing-Clash' "$task_tmp/core.log"
echo 'PASS: TLS SNI forwarding through the existing Clash proxy. This is not an authenticated account test.'
