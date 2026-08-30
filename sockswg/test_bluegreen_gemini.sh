#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$ROOT_DIR/sockswg/sockswg-bluegreen
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

sed '/^case "${1:-}" in/,$d' "$SCRIPT" > "$TEST_DIR/library.sh"
BASE_DIR=$TEST_DIR/base
STATE_DIR=$TEST_DIR/state
SETTINGS_FILE=$TEST_DIR/settings
source "$TEST_DIR/library.sh"

assert_result() {
  local expected_result=$1 expected_rc=$2 body=$3 http_code=$4 result rc=0
  if result=$(classify_gemini_response "$body" "$http_code"); then
    rc=0
  else
    rc=$?
  fi
  [ "$result" = "$expected_result" ] || {
    printf 'expected result %s, got %s\n' "$expected_result" "$result" >&2
    exit 1
  }
  [ "$rc" = "$expected_rc" ] || {
    printf 'expected rc %s, got %s\n' "$expected_rc" "$rc" >&2
    exit 1
  }
}

printf '%s\n' '[["wrb.fr",null,"[null,[\"c_test\",\"r_test\"],[[\"rc_671f429b17db605f\"]]]"]]' \
  > "$TEST_DIR/success"
printf '%s\n' '[["wrb.fr",null,null,null,null,[9,null,[["type.googleapis.com/BardErrorInfo",[1060]]]]]]' \
  > "$TEST_DIR/error-1060"
printf '%s\n' '<html><title>Sorry</title><a href="/sorry/">Too Many Requests 429</a></html>' \
  > "$TEST_DIR/blocked"
printf '%s\n' 'unexpected body' > "$TEST_DIR/unknown"

assert_result ok 0 "$TEST_DIR/success" 200
assert_result bard-error-1060 1 "$TEST_DIR/error-1060" 200
assert_result google-blocked 1 "$TEST_DIR/blocked" 200
assert_result http-503 1 "$TEST_DIR/unknown" 503
assert_result invalid-response 1 "$TEST_DIR/unknown" 200

mkdir -p "$BASE_DIR" "$STATE_DIR"
write_gemini_cache a 104.28.0.1 bard-error-1060
grep -qx 'result=bard-error-1060' "$STATE_DIR/gemini-a"
grep -qx 'tier=unusable' "$BASE_DIR/quality-a"
grep -qx 'gemini=bard-error-1060' "$BASE_DIR/quality-a"

printf 'PASS: sockswg blue-green Gemini response tests\n'
