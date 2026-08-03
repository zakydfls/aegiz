#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_dir"

AEGIZ_RUN_KEYCHAIN_FIXTURE=1 \
    swift test --filter disposableLoginKeychainRoundTrip

echo "Disposable macOS login Keychain fixture passed and removed its item."
