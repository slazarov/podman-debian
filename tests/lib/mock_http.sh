#!/bin/bash
# The tests read MOCK_URL and MOCK_PID after sourcing this file.
# shellcheck disable=SC2034

# Start and stop tests/lib/mock_http_server.py from a test.
#
#   start_mock_http <root-dir> <log-file> [--rule REGEX=ACTION[:COUNT]]...
#       Serves <root-dir> on 127.0.0.1 and sets MOCK_URL and MOCK_PID.
#       Returns 1 if the server does not come up within five seconds.
#   stop_mock_http
#       Stops the server started last.
#   mock_hits <log-file> <regex>
#       How many requests matched <regex>.

MOCK_URL=""
MOCK_PID=""
_MOCK_HTTP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

start_mock_http() {
    local lroot="$1" llog="$2"
    shift 2
    local lport_file
    lport_file="$(mktemp -u)"
    : > "${llog}"
    python3 "${_MOCK_HTTP_DIR}/mock_http_server.py" \
        --root "${lroot}" --port-file "${lport_file}" --log "${llog}" "$@" \
        >/dev/null 2>&1 &
    MOCK_PID=$!
    for _ in $(seq 1 50); do
        if [[ -s "${lport_file}" ]]; then
            MOCK_URL="http://127.0.0.1:$(cat "${lport_file}")"
            rm -f "${lport_file}"
            return 0
        fi
        sleep 0.1
    done
    echo "mock HTTP server did not start" >&2
    return 1
}

stop_mock_http() {
    if [[ -n "${MOCK_PID}" ]]; then
        kill "${MOCK_PID}" >/dev/null 2>&1 || true
        wait "${MOCK_PID}" 2>/dev/null || true
    fi
    MOCK_PID=""
    MOCK_URL=""
}

mock_hits() {
    grep -cE "$2" "$1" || true
}

# require_integration_deps <what> -> call where a test would print SKIP for
# a missing tool. With REQUIRE_INTEGRATION_DEPS=1 (CI), the skip becomes a
# failure: exit 1.
require_integration_deps() {
    if [[ "${REQUIRE_INTEGRATION_DEPS:-0}" == "1" ]]; then
        echo "  FAIL: REQUIRE_INTEGRATION_DEPS=1 but $1 is missing." >&2
        echo "Results: 0 passed, 1 failed"
        exit 1
    fi
}
