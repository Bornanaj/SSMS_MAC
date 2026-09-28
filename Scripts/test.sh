#!/bin/bash
# Runs the offline suite, then the live suites when a server is reachable.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> building"
swift build || exit 1

echo "==> offline regression suite"
./.build/debug/ssms-tests || exit 1

echo "==> editor rendering check"
./.build/debug/ssms-mac --editor-check || exit 1

HOST="${SQL_HOST:-127.0.0.1}"
PORT="${SQL_PORT:-11433}"
if ! nc -z -G 2 "$HOST" "$PORT" 2>/dev/null; then
    echo "==> no server on $HOST:$PORT, skipping the live suites"
    exit 0
fi

echo "==> live service smoke tests"
./.build/debug/tdscli all >/dev/null || exit 1
echo "    ok"

# A hang is a real failure mode here: a blocking keychain read on the main thread
# once wedged launch entirely. Bound the run so it reports instead of stalling CI.
run_with_timeout() {
    local seconds="$1"; shift
    "$@" &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$seconds" ]; then
            kill -9 "$pid" 2>/dev/null
            echo "TIMED OUT after ${seconds}s"
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

# A database compared with itself must come out identical (exit 63) in both tools; any
# difference means the reader, normalizer or comparer disagrees with itself.
echo "==> schema and data compare against the same database"
DB="${SQL_DB:-master}"
for kind in schema data; do
    ./.build/debug/ssms-compare "$kind" --quiet \
        --source-server "$HOST,$PORT" --source-database "$DB" \
        --target-server "$HOST,$PORT" --target-database "$DB"
    status=$?
    if [ "$status" -ne 63 ]; then
        echo "    $kind compare of $DB with itself exited $status, expected 63 (identical)"
        exit 1
    fi
done
echo "    ok"

echo "==> application self test"
run_with_timeout 180 ./.build/debug/ssms-mac --selftest || exit 1
