#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
podman_bin=${AEGIZ_PODMAN_BIN:-$(command -v podman || true)}
fixture_suffix=$$
redis_name="aegiz-redis-fixture-$fixture_suffix"
postgres_name="aegiz-postgres-fixture-$fixture_suffix"
mysql_name="aegiz-mysql-fixture-$fixture_suffix"
fixture_password="aegiz-fixture"

if [ -z "$podman_bin" ]; then
    echo "Podman is required for disposable database fixtures." >&2
    exit 1
fi

cleanup() {
    for fixture_name in "$redis_name" "$postgres_name" "$mysql_name"; do
        if "$podman_bin" container exists "$fixture_name"; then
            "$podman_bin" stop --time 2 "$fixture_name" >/dev/null 2>&1 || true
        fi
    done
}
trap cleanup EXIT INT TERM

wait_for() {
    fixture_name=$1
    shift
    attempts=0
    while [ "$attempts" -lt 45 ]; do
        if "$podman_bin" exec "$fixture_name" "$@" >/dev/null 2>&1; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    echo "$fixture_name did not become ready." >&2
    "$podman_bin" logs "$fixture_name" >&2
    return 1
}

port_for() {
    fixture_name=$1
    container_port=$2
    endpoint=$("$podman_bin" port "$fixture_name" "$container_port/tcp" | head -n 1)
    port=${endpoint##*:}
    case "$port" in
        ''|*[!0-9]*)
            echo "Could not resolve the local port for $fixture_name." >&2
            exit 1
            ;;
    esac
    echo "$port"
}

wait_for_tcp() {
    port=$1
    attempts=0
    while [ "$attempts" -lt 20 ]; do
        if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    echo "Local fixture port $port did not become reachable." >&2
    return 1
}

run_fixture_test() {
    variable_name=$1
    port=$2
    test_name=$3
    attempt=1
    while [ "$attempt" -le 5 ]; do
        if env "$variable_name=$port" \
            cargo test -p aegiz-core "$test_name" -- --ignored; then
            return 0
        fi
        if [ "$attempt" -lt 5 ]; then
            echo "$test_name handshake was not ready; retrying ($attempt/5)." >&2
            sleep 1
        fi
        attempt=$((attempt + 1))
    done
    echo "$test_name did not pass after 5 attempts." >&2
    return 1
}

"$podman_bin" run --rm -d --name "$redis_name" \
    -p 127.0.0.1::6379 docker.io/library/redis:7-alpine >/dev/null
"$podman_bin" run --rm -d --name "$postgres_name" \
    -e POSTGRES_PASSWORD="$fixture_password" \
    -p 127.0.0.1::5432 docker.io/library/postgres:17-alpine >/dev/null
"$podman_bin" run --rm -d --name "$mysql_name" \
    -e MYSQL_ROOT_PASSWORD="$fixture_password" \
    -p 127.0.0.1::3306 docker.io/library/mysql:8.4 >/dev/null

wait_for "$redis_name" redis-cli ping
wait_for "$postgres_name" pg_isready -U postgres
wait_for "$mysql_name" mysqladmin ping -uroot "-p$fixture_password" --silent

redis_port=$(port_for "$redis_name" 6379)
postgres_port=$(port_for "$postgres_name" 5432)
mysql_port=$(port_for "$mysql_name" 3306)
wait_for_tcp "$redis_port"
wait_for_tcp "$postgres_port"
wait_for_tcp "$mysql_port"

cd "$repository_dir"
run_fixture_test AEGIZ_REDIS_FIXTURE_PORT "$redis_port" native_redis_fixture_round_trip
run_fixture_test AEGIZ_POSTGRES_FIXTURE_PORT "$postgres_port" native_postgres_fixture_query
run_fixture_test AEGIZ_MYSQL_FIXTURE_PORT "$mysql_port" native_mysql_fixture_query

echo "Disposable Redis, PostgreSQL, and MySQL fixtures passed."
