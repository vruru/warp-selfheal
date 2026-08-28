#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WATCHDOG="$ROOT_DIR/wireproxy/warp-wireproxy-watchdog"
MENU="$ROOT_DIR/menu.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [ "$expected" = "$actual" ] || fail "$message (expected=$expected actual=$actual)"
}

assert_contains() {
  local needle="$1"
  local file="$2"
  local message="$3"
  grep -Fq -- "$needle" "$file" || fail "$message"
}

extract_embedded_watchdog() {
  awk '
    /<<'\''WIREPROXY_WATCHDOG_EOF'\''/ { capture=1; next }
    capture && /^WIREPROXY_WATCHDOG_EOF$/ { exit }
    capture { print }
  ' "$MENU"
}

embedded_watchdog="$TEST_ROOT/embedded-watchdog"
extract_embedded_watchdog > "$embedded_watchdog"
cmp -s "$WATCHDOG" "$embedded_watchdog" || fail 'menu.sh embedded watchdog differs from canonical watchdog'

MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
url="${*: -1}"
if [[ "$url" == *'['* ]]; then
  family=6
else
  family=4
fi
printf 'IPv%s\n' "$family" >> "$MOCK_ROOT/calls"
mode=$(cat "$MOCK_ROOT/mode-v$family")
if [ -e "$MOCK_ROOT/restarted" ] && [ "${MOCK_RECOVER_AFTER_RESTART:-0}" = 1 ]; then
  mode=on
fi
case "$mode" in
  on|plus) printf 'warp=%s\n' "$mode" ;;
  *) exit 28 ;;
esac
MOCK_CURL

cat > "$MOCK_BIN/systemctl" <<'MOCK_SYSTEMCTL'
#!/usr/bin/env bash
case "$1" in
  is-active)
    [ "$(cat "$MOCK_ROOT/service-state")" = active ]
    ;;
  restart)
    count=$(cat "$MOCK_ROOT/restarts")
    printf '%s\n' "$((count + 1))" > "$MOCK_ROOT/restarts"
    printf 'active\n' > "$MOCK_ROOT/service-state"
    : > "$MOCK_ROOT/restarted"
    ;;
  *) exit 1 ;;
esac
MOCK_SYSTEMCTL

cat > "$MOCK_BIN/logger" <<'MOCK_LOGGER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_ROOT/log"
MOCK_LOGGER

cat > "$MOCK_BIN/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
exit 0
MOCK_SLEEP

chmod +x "$MOCK_BIN"/*

setup_case() {
  local name="$1"
  local addresses="$2"
  MOCK_ROOT="$TEST_ROOT/$name"
  export MOCK_ROOT
  mkdir -p "$MOCK_ROOT/state"
  printf 'active\n' > "$MOCK_ROOT/service-state"
  printf '0\n' > "$MOCK_ROOT/restarts"
  printf 'on\n' > "$MOCK_ROOT/mode-v4"
  printf 'on\n' > "$MOCK_ROOT/mode-v6"
  : > "$MOCK_ROOT/calls"
  : > "$MOCK_ROOT/log"
  cat > "$MOCK_ROOT/proxy.conf" <<EOF
[Interface]
Address = $addresses

[Peer]
Endpoint = engage.cloudflareclient.com:2408

[Socks5]
BindAddress = 127.0.0.1:40000
EOF
  : > "$MOCK_ROOT/settings"
  rm -f "$MOCK_ROOT/restarted"
}

run_watchdog() {
  STATE_DIR="$MOCK_ROOT/state" \
  CONFIG_FILE="$MOCK_ROOT/proxy.conf" \
  SETTINGS_FILE="$MOCK_ROOT/settings" \
  WATCHDOG_PATH="$MOCK_BIN:/usr/bin:/bin" \
  RESTART_DELAY=0 \
  HEALTH_FAIL_THRESHOLD=2 \
  MOCK_RECOVER_AFTER_RESTART="${MOCK_RECOVER_AFTER_RESTART:-0}" \
  "$WATCHDOG"
}

setup_case dual-healthy '172.16.0.2/32, 2606:4700:110::2/128'
printf 'plus\n' > "$MOCK_ROOT/mode-v4"
run_watchdog
assert_eq 0 "$(cat "$MOCK_ROOT/restarts")" 'healthy dual-stack check restarted WireProxy'
assert_contains IPv4 "$MOCK_ROOT/calls" 'IPv4 was not checked'
assert_contains IPv6 "$MOCK_ROOT/calls" 'IPv6 was not checked'

setup_case ipv4-regression '172.16.0.2/32, 2606:4700:110::2/128'
printf 'fail\n' > "$MOCK_ROOT/mode-v4"
export MOCK_RECOVER_AFTER_RESTART=1
run_watchdog
assert_eq 0 "$(cat "$MOCK_ROOT/restarts")" 'first IPv4 failure restarted WireProxy'
assert_eq 1 "$(cat "$MOCK_ROOT/state/failures-v4")" 'first IPv4 failure was not recorded'
run_watchdog
assert_eq 1 "$(cat "$MOCK_ROOT/restarts")" 'second consecutive IPv4 failure did not restart WireProxy'
assert_eq 0 "$(cat "$MOCK_ROOT/state/failures-v4")" 'IPv4 failure counter was not reset after recovery'
unset MOCK_RECOVER_AFTER_RESTART

setup_case alternating-failures '172.16.0.2/32, 2606:4700:110::2/128'
printf 'fail\n' > "$MOCK_ROOT/mode-v4"
run_watchdog
printf 'on\n' > "$MOCK_ROOT/mode-v4"
printf 'fail\n' > "$MOCK_ROOT/mode-v6"
run_watchdog
assert_eq 0 "$(cat "$MOCK_ROOT/restarts")" 'different one-off stack failures incorrectly accumulated'
assert_eq 0 "$(cat "$MOCK_ROOT/state/failures-v4")" 'recovered IPv4 counter was not reset'
assert_eq 1 "$(cat "$MOCK_ROOT/state/failures-v6")" 'IPv6 failure counter was not recorded independently'

setup_case ipv6-only '2606:4700:110::2/128'
printf 'fail\n' > "$MOCK_ROOT/mode-v4"
printf 'plus\n' > "$MOCK_ROOT/mode-v6"
run_watchdog
if grep -Fq IPv4 "$MOCK_ROOT/calls"; then
  fail 'IPv4 was checked even though the configuration is IPv6-only'
fi
assert_contains IPv6 "$MOCK_ROOT/calls" 'IPv6-only configuration was not checked'

printf 'PASS: watchdog dual-stack regression tests\n'
