#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${1:-debug}
app_dir="$repository_dir/.build/Aegiz.app"
contents_dir="$app_dir/Contents"
team_id=${AEGIZ_TEAM_ID:-3S37YU6S3X}
signing_account=${AEGIZ_SIGNING_ACCOUNT:-M9R3HPSDS2}
codesign_identity=${AEGIZ_CODESIGN_IDENTITY:-}

cd "$repository_dir"
case "$configuration" in
    debug)
        core_binary="$repository_dir/target/debug/aegiz-core"
        askpass_binary="$repository_dir/target/debug/aegiz-askpass"
        watchdog_binary="$repository_dir/target/debug/aegiz-tunnel-watchdog"
        ;;
    release)
        core_binary="$repository_dir/target/release/aegiz-core"
        askpass_binary="$repository_dir/target/release/aegiz-askpass"
        watchdog_binary="$repository_dir/target/release/aegiz-tunnel-watchdog"
        ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 1
        ;;
esac
if [ "${AEGIZ_SKIP_BUILD:-0}" != "1" ]; then
    if [ "$configuration" = "release" ]; then
        cargo build --release -p aegiz-core
    else
        cargo build -p aegiz-core
    fi
    swift build -c "$configuration" --product Aegiz
fi

if [ ! -x "$core_binary" ]; then
    echo "Missing $core_binary. Build the core or remove AEGIZ_SKIP_BUILD=1." >&2
    exit 1
fi
if [ ! -x "$askpass_binary" ]; then
    echo "Missing $askpass_binary. Build the core or remove AEGIZ_SKIP_BUILD=1." >&2
    exit 1
fi
if [ ! -x "$watchdog_binary" ]; then
    echo "Missing $watchdog_binary. Build the core or remove AEGIZ_SKIP_BUILD=1." >&2
    exit 1
fi

swift_binary=$(find "$repository_dir/.build" -type f -path "*/$configuration/Aegiz" -perm -0100 | head -n 1)

if [ -z "$swift_binary" ]; then
    echo "Could not locate the compiled Aegiz executable" >&2
    exit 1
fi

"$repository_dir/scripts/build-app-icon.sh"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
ditto "$swift_binary" "$contents_dir/MacOS/Aegiz"
ditto "$core_binary" "$contents_dir/Resources/aegiz-core"
ditto "$askpass_binary" "$contents_dir/Resources/aegiz-askpass"
ditto "$watchdog_binary" "$contents_dir/Resources/aegiz-tunnel-watchdog"
ditto "$repository_dir/apps/macos/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
ditto "$repository_dir/docs/RECOVERY.md" "$contents_dir/Resources/RECOVERY.md"
ditto "$repository_dir/docs/SECURITY_MODEL.md" "$contents_dir/Resources/SECURITY_MODEL.md"
ditto "$repository_dir/apps/macos/Resources/Info.plist" "$contents_dir/Info.plist"
chmod 0755 \
    "$contents_dir/MacOS/Aegiz" \
    "$contents_dir/Resources/aegiz-core" \
    "$contents_dir/Resources/aegiz-askpass" \
    "$contents_dir/Resources/aegiz-tunnel-watchdog"
if [ -z "$codesign_identity" ]; then
    codesign_identity=$(
        security find-identity -v -p codesigning 2>/dev/null |
            awk -v account="($signing_account)" 'index($0, "Apple Development:") && index($0, account) { gsub(/"/, "", $2); print $2; exit }'
    )
fi
if [ -z "$codesign_identity" ]; then
    echo "No Apple Development signing identity for account $signing_account." >&2
    echo "Set AEGIZ_TEAM_ID, AEGIZ_SIGNING_ACCOUNT, and AEGIZ_CODESIGN_IDENTITY for your developer account." >&2
    exit 1
fi
identity_record=$(
    security find-identity -v -p codesigning 2>/dev/null |
        awk -v identity="$codesign_identity" 'index($0, identity) { print; exit }'
)
case "$identity_record $codesign_identity" in
    *"Developer ID Application:"*) timestamp_option=--timestamp ;;
    *) timestamp_option=--timestamp=none ;;
esac
codesign \
    --force \
    --options runtime \
    "$timestamp_option" \
    --sign "$codesign_identity" \
    "$contents_dir/Resources/aegiz-core"
codesign \
    --force \
    --options runtime \
    "$timestamp_option" \
    --sign "$codesign_identity" \
    "$contents_dir/Resources/aegiz-askpass"
codesign \
    --force \
    --options runtime \
    "$timestamp_option" \
    --sign "$codesign_identity" \
    "$contents_dir/Resources/aegiz-tunnel-watchdog"
codesign \
    --force \
    --options runtime \
    --entitlements "$repository_dir/apps/macos/Resources/Aegiz.entitlements" \
    "$timestamp_option" \
    --sign "$codesign_identity" \
    "$app_dir"
codesign --verify --deep --strict "$app_dir"
actual_team_id=$(codesign -dvv "$app_dir" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')
if [ -n "$team_id" ] && [ "$actual_team_id" != "$team_id" ]; then
    echo "Signed TeamIdentifier $actual_team_id does not match AEGIZ_TEAM_ID $team_id." >&2
    exit 1
fi
"$repository_dir/scripts/generate-release-metadata.sh" "$app_dir"

echo "$app_dir"
