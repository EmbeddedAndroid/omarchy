#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
runtime_dir="$test_tmp/runtime"
test_home="$test_tmp/home"
level_file="$test_tmp/level"
mkdir -p "$mock_bin" "$runtime_dir" "$test_home"

cat >"$mock_bin/brightnessctl" <<'SH'
#!/bin/bash
if [[ $* == *"--list"* ]]; then
  printf 'input3::capslock,leds,0,0%%,1\n'
  printf 'mock::kbd_backlight,leds,%s,0%%,3\n' "$(<"$LEVEL_FILE")"
elif [[ $* == *" get" ]]; then
  cat "$LEVEL_FILE"
elif [[ $* == *" max" ]]; then
  printf '3\n'
elif [[ $* == *" set "* ]]; then
  [[ $2 == "mock::kbd_backlight" ]] || exit 1
  printf '%s\n' "${@: -1}" >"$LEVEL_FILE"
fi
SH

cat >"$mock_bin/omarchy-osd" <<'SH'
#!/bin/bash
SH

chmod +x "$mock_bin"/*

keyboard() {
  HOME="$test_home" LEVEL_FILE="$level_file" XDG_RUNTIME_DIR="$runtime_dir" PATH="$mock_bin:$PATH" \
    "$ROOT/bin/omarchy-brightness-keyboard" "$@"
}

level() {
  cat "$level_file"
}

echo 2 >"$level_file"
keyboard off
[[ $(level) == "0" ]] || fail "off turns a lit backlight off"
keyboard off
keyboard restore
[[ $(level) == "2" ]] || fail "a second off keeps the level to restore" "actual: $(level)"
pass "off and restore bring back the lit level"

keyboard restore
[[ $(level) == "2" ]] || fail "restore leaves a lit backlight alone"
pass "restore leaves a lit backlight alone"

echo 0 >"$level_file"
keyboard restore
[[ $(level) == "3" ]] || fail "a backlight nobody switched off lights at the brightest level" "actual: $(level)"
pass "a backlight nobody switched off comes back on"

echo 0 >"$level_file"
keyboard --no-osd cycle
echo 0 >"$level_file"
keyboard restore
[[ $(level) == "1" ]] || fail "restore uses the level last set from the keys" "actual: $(level)"
pass "restore uses the level last set from the keys"

echo 3 >"$level_file"
keyboard --no-osd cycle
keyboard off
keyboard restore
[[ $(level) == "0" ]] || fail "a backlight switched off with the keys stays off" "actual: $(level)"
pass "a backlight switched off with the keys stays off"

echo 3 >"$level_file"
keyboard off
keyboard --no-osd cycle
keyboard restore
[[ $(level) == "1" ]] || fail "a manual change replaces the pending restore" "actual: $(level)"
pass "a manual change replaces the pending restore"
