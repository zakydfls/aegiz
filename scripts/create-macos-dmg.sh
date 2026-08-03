#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=${AEGIZ_VERSION:-$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$repository_dir/apps/macos/Resources/Info.plist"
)}
architecture=$(uname -m)
app_dir="$repository_dir/.build/Aegiz.app"
dist_dir="$repository_dir/dist"
dmg_path="$dist_dir/Aegiz-$version-$architecture.dmg"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/aegiz-dmg.XXXXXX")

cleanup() {
    case "$temporary_dir" in
        "${TMPDIR:-/tmp}"/aegiz-dmg.*) rm -rf -- "$temporary_dir" ;;
    esac
}
trap cleanup EXIT HUP INT TERM

if [ "${AEGIZ_SKIP_PACKAGE:-0}" != "1" ]; then
    "$repository_dir/scripts/package-macos-app.sh" release
fi
if [ ! -d "$app_dir" ]; then
    echo "Missing $app_dir. Package the release or remove AEGIZ_SKIP_PACKAGE=1." >&2
    exit 1
fi

mkdir -p "$dist_dir"
ditto "$app_dir" "$temporary_dir/Aegiz.app"
ln -s /Applications "$temporary_dir/Applications"
hdiutil create \
    -volname "Aegiz" \
    -srcfolder "$temporary_dir" \
    -format UDZO \
    -ov \
    "$dmg_path"
hdiutil verify "$dmg_path"
"$repository_dir/scripts/generate-release-metadata.sh" "$app_dir" "$dmg_path"

shasum -a 256 "$dmg_path"
echo "$dmg_path"
