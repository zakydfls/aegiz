#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
podman_bin=${AEGIZ_PODMAN_BIN:-$(command -v podman || true)}
fixture_suffix=$$
fixture_name="aegiz-ssh-fixture-$fixture_suffix"
fixture_image="localhost/aegiz-ssh-fixture:dev"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/aegiz-ssh-fixture.XXXXXX")

if [ -z "$podman_bin" ]; then
    echo "Podman is required for the disposable OpenSSH fixture." >&2
    exit 1
fi

cleanup() {
    if "$podman_bin" container exists "$fixture_name"; then
        "$podman_bin" stop --time 2 "$fixture_name" >/dev/null 2>&1 || true
    fi
    case "$fixture_dir" in
        "${TMPDIR:-/tmp}"/aegiz-ssh-fixture.*) rm -rf -- "$fixture_dir" ;;
    esac
}
trap cleanup EXIT HUP INT TERM

port_for() {
    endpoint=$("$podman_bin" port "$fixture_name" 22/tcp | head -n 1)
    port=${endpoint##*:}
    case "$port" in
        ''|*[!0-9]*)
            echo "Could not resolve the disposable SSH port." >&2
            exit 1
            ;;
    esac
    echo "$port"
}

wait_for_ssh() {
    port=$1
    attempts=0
    while [ "$attempts" -lt 30 ]; do
        if ssh-keyscan -p "$port" 127.0.0.1 >"$fixture_dir/known_hosts" 2>/dev/null; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    echo "Disposable OpenSSH fixture did not become ready." >&2
    "$podman_bin" logs "$fixture_name" >&2
    return 1
}

ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/client"
chmod 0600 "$fixture_dir/client"

"$podman_bin" build \
    -t "$fixture_image" \
    -f "$repository_dir/fixtures/ssh/Containerfile" \
    "$repository_dir/fixtures/ssh"
"$podman_bin" run --rm -d \
    --name "$fixture_name" \
    -p 127.0.0.1::22 \
    -v "$fixture_dir/client.pub:/fixture/authorized_keys:ro" \
    "$fixture_image" >/dev/null

fixture_port=$(port_for)
wait_for_ssh "$fixture_port"

cd "$repository_dir"
env \
    AEGIZ_SSH_FIXTURE_PORT="$fixture_port" \
    AEGIZ_SSH_FIXTURE_IDENTITY="$fixture_dir/client" \
    AEGIZ_SSH_FIXTURE_KNOWN_HOSTS="$fixture_dir/known_hosts" \
    AEGIZ_SSH_FIXTURE_LOCAL_DIR="$fixture_dir" \
    cargo test -p aegiz-core native_openssh_host_ops_and_sftp_round_trip -- --ignored

echo "Disposable OpenSSH host-ops and SFTP fixture passed."
