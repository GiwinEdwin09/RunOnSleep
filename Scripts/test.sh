#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
TEST_FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
swift test --enable-swift-testing --disable-xctest --cache-path .build/cache --config-path .build/config --security-path .build/security \
    -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" \
    -Xlinker -F -Xlinker "$TEST_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib"
