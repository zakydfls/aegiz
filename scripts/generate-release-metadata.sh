#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir=${1:-"$repository_dir/.build/Aegiz.app"}
dmg_path=${2:-}
dist_dir="$repository_dir/dist"
ghostty_commit="4d605bf0d819df901a0332bbb320dc849fdd82e4"
bom_serial=$(uuidgen | tr '[:upper:]' '[:lower:]')
source_info_plist="$repository_dir/apps/macos/Resources/Info.plist"
if [ -f "$app_dir/Contents/Info.plist" ]; then
    release_info_plist="$app_dir/Contents/Info.plist"
else
    release_info_plist="$source_info_plist"
fi
product_version=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$release_info_plist"
)

mkdir -p "$dist_dir"

cargo_components=$(
    cargo metadata --format-version 1 --locked --manifest-path "$repository_dir/Cargo.toml" |
        jq '[.packages[] | {
            type: "library",
            name: .name,
            version: .version,
            purl: ("pkg:cargo/" + .name + "@" + .version),
            licenses: (if .license == null then [] else [{expression: .license}] end)
        }]'
)
swift_components=$(
    jq '[.pins[] | {
        type: "library",
        name: .identity,
        version: (.state.version // .state.revision),
        purl: ("pkg:swift/" + .identity + "@" + (.state.version // .state.revision)),
        externalReferences: [{type: "vcs", url: .location}]
    }]' "$repository_dir/Package.resolved"
)

jq -n \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg ghostty "$ghostty_commit" \
    --arg product_version "$product_version" \
    --arg serial "$bom_serial" \
    --argjson cargo "$cargo_components" \
    --argjson swift "$swift_components" \
    '{
        bomFormat: "CycloneDX",
        specVersion: "1.5",
        serialNumber: ("urn:uuid:" + $serial),
        version: 1,
        metadata: {
            timestamp: $timestamp,
            component: {type: "application", name: "Aegiz", version: $product_version}
        },
        components: ($cargo + $swift + [{
            type: "library",
            name: "GhosttyKit",
            version: $ghostty,
            externalReferences: [{type: "vcs", url: "https://github.com/ghostty-org/ghostty"}]
        }])
    }' >"$dist_dir/sbom.cdx.json"

if [ -d "$app_dir" ]; then
    app_binary="$app_dir/Contents/MacOS/Aegiz"
    core_binary="$app_dir/Contents/Resources/aegiz-core"
    askpass_binary="$app_dir/Contents/Resources/aegiz-askpass"
    watchdog_binary="$app_dir/Contents/Resources/aegiz-tunnel-watchdog"
    app_hash=$(shasum -a 256 "$app_binary" | awk '{print $1}')
    core_hash=$(shasum -a 256 "$core_binary" | awk '{print $1}')
    askpass_hash=$(shasum -a 256 "$askpass_binary" | awk '{print $1}')
    watchdog_hash=$(shasum -a 256 "$watchdog_binary" | awk '{print $1}')
    bundle_hash=$(
        cd "$app_dir"
        find Contents -type f | LC_ALL=C sort |
            while IFS= read -r file; do shasum -a 256 "$file"; done |
            shasum -a 256 |
            awk '{print $1}'
    )
    signature=$(codesign -dvv "$app_dir" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')
else
    app_hash=""
    core_hash=""
    askpass_hash=""
    watchdog_hash=""
    bundle_hash=""
    signature="unpackaged"
fi

if [ -n "$dmg_path" ] && [ -f "$dmg_path" ]; then
    dmg_hash=$(shasum -a 256 "$dmg_path" | awk '{print $1}')
    dmg_filename=$(basename -- "$dmg_path")
    dmg_size=$(stat -f %z "$dmg_path")
else
    dmg_hash=""
    dmg_filename=""
    dmg_size=0
fi

jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg version "$product_version" \
    --arg platform "$(uname -m)-apple-macos" \
    --arg app_sha256 "$app_hash" \
    --arg core_sha256 "$core_hash" \
    --arg askpass_sha256 "$askpass_hash" \
    --arg watchdog_sha256 "$watchdog_hash" \
    --arg bundle_sha256 "$bundle_hash" \
    --arg dmg_sha256 "$dmg_hash" \
    --arg dmg_filename "$dmg_filename" \
    --argjson dmg_size_bytes "$dmg_size" \
    --arg ghostty_commit "$ghostty_commit" \
    --arg signing_authority "$signature" \
    '{
        schema_version: 1,
        generated_at: $generated_at,
        product: "Aegiz",
        version: $version,
        platform: $platform,
        artifacts: ({
            app_binary_sha256: $app_sha256,
            core_binary_sha256: $core_sha256,
            askpass_binary_sha256: $askpass_sha256,
            tunnel_watchdog_binary_sha256: $watchdog_sha256,
            app_bundle_tree_sha256: $bundle_sha256
        } + if $dmg_sha256 == "" then {} else {
            dmg: {
                filename: $dmg_filename,
                sha256: $dmg_sha256,
                size_bytes: $dmg_size_bytes
            }
        } end),
        dependencies: {ghostty_commit: $ghostty_commit},
        signing_authority: $signing_authority,
        sbom: "sbom.cdx.json"
    }' >"$dist_dir/release-manifest.json"

jq empty "$dist_dir/sbom.cdx.json" "$dist_dir/release-manifest.json"
echo "$dist_dir/release-manifest.json"
