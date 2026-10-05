#!/bin/bash
set -euo pipefail
task_cli='/Library/Application Support/CodexBridge/codexbridge'
test -x "$task_cli" || { echo 'CodexBridge is not installed.' >&2; exit 1; }
"$task_cli" status
/bin/launchctl print system/io.github.codexbridge | /usr/bin/awk '/state =|pid =|last exit code =/ {print}'
