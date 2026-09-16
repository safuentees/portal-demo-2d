#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
# Desktop/Documents may be synced by File Provider, which can attach Finder
# metadata that invalidates app signatures. Keep generated products local.
build_dir="${BUILD_DIR:-${TMPDIR:-/tmp}/MetslStarter-build}"
mkdir -p "$build_dir"

xcodebuild -quiet \
    -project "$project_root/MetslStarter.xcodeproj" \
    -scheme MetslStarter -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$build_dir" build

xcrun swiftc -swift-version 5 \
    "$project_root"/Sources/Scene/*.swift \
    "$project_root"/Sources/Rendering/*.swift \
    "$project_root"/Sources/Rendering/Meshes/*.swift \
    "$project_root"/Sources/Input/*.swift \
    "$project_root/Tests/SmokeTests.swift" \
    -o "$build_dir/SmokeTests"

MTL_DEBUG_LAYER=1 "$build_dir/SmokeTests" \
    "$build_dir/Build/Products/Debug/MetslStarter.app/Contents/Resources/default.metallib"
