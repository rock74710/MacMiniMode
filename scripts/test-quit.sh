#!/bin/bash
# 驗證退出等待、失敗重試和斷言檢查，不修改系統電源設定。
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/macminimode-quit-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc Sources/menubar/QuitController.swift Tests/QuitControllerTests.swift -o "$TEST_BUILD/test-quit"
"$TEST_BUILD/test-quit"
