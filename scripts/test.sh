#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
# Runs with Command Line Tools; XCTest/full Xcode is not required.
swift run BridgeTests
