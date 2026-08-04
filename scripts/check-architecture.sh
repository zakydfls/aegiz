#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift_root="$repository_dir/apps/macos/Sources/Aegiz"
rust_root="$repository_dir/crates/aegiz-core/src"

for directory in \
  "$swift_root/App" \
  "$swift_root/Core" \
  "$swift_root/Domain" \
  "$swift_root/Features" \
  "$swift_root/Shared" \
  "$rust_root/application" \
  "$rust_root/infrastructure" \
  "$rust_root/interfaces"; do
  if [ ! -d "$directory" ]; then
    echo "Missing architecture boundary: $directory" >&2
    exit 1
  fi
done

if find "$swift_root/Core" "$swift_root/Domain" -name '*.swift' -exec \
  grep -nH '^import SwiftUI$' {} + | grep . >/dev/null; then
  echo 'Core and Domain must not import SwiftUI.' >&2
  exit 1
fi

if find "$rust_root/application" -name '*.rs' -exec \
  grep -nH 'crate::interfaces' {} + | grep . >/dev/null; then
  echo 'Rust application code must not depend on RPC interfaces.' >&2
  exit 1
fi

echo 'Aegiz architecture boundaries are intact.'
