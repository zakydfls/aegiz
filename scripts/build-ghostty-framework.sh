#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_dir="$repository_dir/.build/vendor/ghostty"
output_dir="$repository_dir/apps/macos/Frameworks"
ghostty_commit="4d605bf0d819df901a0332bbb320dc849fdd82e4"

if ! command -v zig >/dev/null 2>&1; then
    echo "zig is required to build GhosttyKit.xcframework" >&2
    exit 1
fi

if [ ! -d "$source_dir/.git" ]; then
    mkdir -p "$(dirname "$source_dir")"
    git clone https://github.com/ghostty-org/ghostty.git "$source_dir"
fi

cd "$source_dir"
git fetch --depth 1 origin "$ghostty_commit"
git checkout --detach "$ghostty_commit"
zig build \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native \
    -Doptimize=ReleaseFast

mkdir -p "$output_dir"
framework_source="$source_dir/macos/GhosttyKit.xcframework"
if [ ! -d "$framework_source" ]; then
    echo "GhosttyKit build did not produce $framework_source" >&2
    exit 1
fi
rm -rf "$output_dir/GhosttyKit.xcframework"
ditto "$framework_source" "$output_dir/GhosttyKit.xcframework"
echo "GhosttyKit installed at $output_dir/GhosttyKit.xcframework"
