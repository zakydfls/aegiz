#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cd "$repository_dir"
cargo build -p aegiz-core
export AEGIZ_CORE_BIN="$repository_dir/target/debug/aegiz-core"
exec swift run Aegiz

