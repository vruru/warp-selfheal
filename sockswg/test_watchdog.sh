#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WATCHDOG="$ROOT_DIR/sockswg/sockswg-watchdog"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected=$1 actual=$2)"; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "$3"; }

MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
[[ "$url" == *'['* ]] && family=6 || family=4
printf 'IPv%s\n' "$family" >> "$MOCK_ROOT/calls"
mode=$(cat "$MOCK_ROOT/mode-v$family")
[ -e "$MOCK_ROOT/restarted" ] && [ "${MOCK_RECOVER_AFTER_RESTART:-0}" = 1 ] && mode=on
case "$mode" in on|plus) printf 'warp=%s\n' "$mode" ;; *) exit 28 ;; esac
EOF

cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-active) [ "$(cat "$MOCK_ROOT/service-state")" = active ] ;;
  restart)
    count=$(cat "$MOCK_ROOT/restarts")
    printf '%s\n' "$((count + 1))" > "$MOCK_ROOT/restarts"
    printf 'active\n' > "$MOCK_ROOT/service-state"
    : > "$MOCK_ROOT/restarted"
    ;;
  *) exit 1 ;;
esac
EOF

cat > "$MOCK_BIN/ip" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = link ] && [ "$(cat "$MOCK_ROOT/service-state")" = active ]
EOF

cat > "$MOCK_BIN/logger" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_ROOT/log"
EOF

cat > "$MOCK_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_BIN"/*

setup_case() {
  MOCK_ROOT="$TEST_ROOT/$1"
  export MOCK_ROOT
  mkdir -p "$MOCK_ROOT/state"
  printf 'active\n' > "$MOCK_ROOT/service-state"
  printf '0\n' > "$MOCK_ROOT/restarts"
  printf 'on\n' > "$MOCK_ROOT/mode-v4"
  printf 'on\n' > "$MOCK_ROOT/mode-v6"
  : > "$MOCK_ROOT/calls"
  : > "$MOCK_ROOT/log"
  : > "$MOCK_ROOT/settings"
  rm -f "$MOCK_ROOT/restarted"
  cat > "$MOCK_ROOT/sockswg.conf" <<'EOF'
[Interface]
Address = 172.16.0.2/32
Address = 2606:4700:110::2/128
[Peer]
Endpoint = engage.cloudflareclient.com:2408
EOF
  cat > "$MOCK_ROOT/sockd.conf" <<'EOF'
internal: 127.0.0.1 port = 40000
EOF
}

run_watchdog() {
  STATE_DIR="$MOCK_ROOT/state" CONFIG_FILE="$MOCK_ROOT/sockswg.conf" \
  SOCKS_CONFIG="$MOCK_ROOT/sockd.conf" SETTINGS_FILE="$MOCK_ROOT/settings" \
  WATCHDOG_PATH="$MOCK_BIN:/usr/bin:/bin" RESTART_DELAY=0 HEALTH_FAIL_THRESHOLD=2 \
  MOCK_RECOVER_AFTER_RESTART="${MOCK_RECOVER_AFTER_RESTART:-0}" "$WATCHDOG"
}

setup_case healthy
printf 'plus\n' > "$MOCK_ROOT/mode-v6"
run_watchdog
assert_eq 0 "$(cat "$MOCK_ROOT/restarts")" 'healthy check restarted sockswg'
assert_contains IPv4 "$MOCK_ROOT/calls" 'IPv4 was not checked'
assert_contains IPv6 "$MOCK_ROOT/calls" 'IPv6 was not checked'

setup_case service-down
printf 'inactive\n' > "$MOCK_ROOT/service-state"
export MOCK_RECOVER_AFTER_RESTART=1
run_watchdog
assert_eq 2 "$(cat "$MOCK_ROOT/restarts")" 'inactive stack did not restart both services'
unset MOCK_RECOVER_AFTER_RESTART

setup_case endpoint-rotation
printf 'fail\n' > "$MOCK_ROOT/mode-v4"
export MOCK_RECOVER_AFTER_RESTART=1
run_watchdog
run_watchdog
assert_eq 2 "$(cat "$MOCK_ROOT/restarts")" 'failure threshold did not restart both services'
assert_contains 'Endpoint = engage.cloudflareclient.com:4500' "$MOCK_ROOT/sockswg.conf" 'Endpoint did not rotate'
assert_eq 0 "$(cat "$MOCK_ROOT/state/failures-v4")" 'failure counter did not reset'
unset MOCK_RECOVER_AFTER_RESTART

setup_case alternating
printf 'fail\n' > "$MOCK_ROOT/mode-v4"
run_watchdog
printf 'on\n' > "$MOCK_ROOT/mode-v4"
printf 'fail\n' > "$MOCK_ROOT/mode-v6"
run_watchdog
assert_eq 0 "$(cat "$MOCK_ROOT/restarts")" 'alternating failures incorrectly accumulated'
assert_eq 0 "$(cat "$MOCK_ROOT/state/failures-v4")" 'IPv4 counter did not reset'
assert_eq 1 "$(cat "$MOCK_ROOT/state/failures-v6")" 'IPv6 counter was not independent'

printf 'PASS: sockswg watchdog regression tests\n'
