#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# Load function definitions without running the player's main entry point.
source <(sed '$d' "$SCRIPT_DIR/../music.sh")

assert_time() {
    local input="$1" expected="$2"
    START_AT_SECONDS=0
    START_AT_EXPLICIT=0
    parse_start_time "$input"
    if [[ "$START_AT_SECONDS" != "$expected" || "$START_AT_EXPLICIT" != 1 ]]; then
        printf 'FAIL: %s -> %s (expected %s)\n' "$input" "$START_AT_SECONDS" "$expected" >&2
        exit 1
    fi
}

assert_time "90" 90
assert_time "90s" 90
assert_time "2m" 120
assert_time "2m30s" 150
assert_time "1h" 3600
assert_time "1h2m3s" 3723
assert_time "1H2M3S" 3723
assert_time "0s" 0

if (
    parse_start_time "2x"
) 2>/dev/null; then
    echo "FAIL: invalid time was accepted" >&2
    exit 1
fi

echo "Start-time parser tests passed."
