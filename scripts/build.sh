#!/bin/bash
set -euo pipefail
task_repo="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$task_repo"
/usr/bin/swift build -c release
