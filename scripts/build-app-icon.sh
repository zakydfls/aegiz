#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_path=${1:-"$repository_dir/apps/macos/Resources/AppIcon.icns"}
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/aegiz-icon.XXXXXX")
iconset_dir="$temporary_dir/AppIcon.iconset"
source_png="$temporary_dir/AppIcon-1024.png"

cleanup() {
    case "$temporary_dir" in
        "${TMPDIR:-/tmp}"/aegiz-icon.*) rm -rf -- "$temporary_dir" ;;
    esac
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$iconset_dir" "$(dirname -- "$output_path")"
xcrun swift "$repository_dir/scripts/generate-app-icon.swift" "$source_png"

resize() {
    size=$1
    filename=$2
    sips -z "$size" "$size" "$source_png" --out "$iconset_dir/$filename" >/dev/null
}

resize 16 icon_16x16.png
resize 32 icon_16x16@2x.png
resize 32 icon_32x32.png
resize 64 icon_32x32@2x.png
resize 128 icon_128x128.png
resize 256 icon_128x128@2x.png
resize 256 icon_256x256.png
resize 512 icon_256x256@2x.png
resize 512 icon_512x512.png
ditto "$source_png" "$iconset_dir/icon_512x512@2x.png"

iconutil --convert icns --output "$output_path" "$iconset_dir"
echo "$output_path"
