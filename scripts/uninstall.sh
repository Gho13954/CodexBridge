#!/bin/bash
set -euo pipefail
task_repo="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
/usr/bin/sudo /bin/bash "$task_repo/scripts/service-admin.sh" uninstall
