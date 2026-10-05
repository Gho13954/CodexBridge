#!/bin/bash
set -euo pipefail
task_repo="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    echo 'Run this script as your normal user; it requests sudo only after preparing the build.' >&2
    exit 1
fi
"$task_repo/scripts/build.sh"
"$task_repo/scripts/fetch-core.sh"
"$task_repo/.build/release/codexbridge" doctor
echo 'Preparing complete. macOS administrator authorization is required to install the boot service.'
echo 'If the earlier temporary bridge is still running, stop it with Ctrl+C before installing.'
/usr/bin/sudo /bin/bash "$task_repo/scripts/service-admin.sh" install "$task_repo" "$HOME"
