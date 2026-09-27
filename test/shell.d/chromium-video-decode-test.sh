#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

export PATH="$ROOT/bin:$PATH"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

sysfs="$test_tmp/sysfs"
video_device() {
  mkdir -p "$sysfs/sys/class/video4linux/$1"
  echo "$2" >"$sysfs/sys/class/video4linux/$1/name"
}
video_device video0 msm_vfe0_video0
video_device video1 uvcvideo

OMARCHY_HW_SYSFS="$sysfs" omarchy-hw-video-decoder && fail "cameras are not video decoders"
OMARCHY_HW_SYSFS="$test_tmp/empty" omarchy-hw-video-decoder && fail "no V4L2 devices, no decoder"
pass "omarchy-hw-video-decoder ignores capture devices"

video_device video16 qcom-iris-decoder
OMARCHY_HW_SYSFS="$sysfs" omarchy-hw-video-decoder || fail "an Iris decoder is detected"
pass "omarchy-hw-video-decoder detects a V4L2 decoder"

test_home="$test_tmp/home"
conf="$test_home/.config/chromium-flags.conf"
install_decode() {
  HOME="$test_home" OMARCHY_HW_SYSFS="${1:-$sysfs}" OMARCHY_PATH="$ROOT" omarchy-install-chromium-video-decode
}

mkdir -p "$test_home/.config"
cp "$ROOT/config/chromium-flags.conf" "$conf"
install_decode
[[ $(grep -c -- "^--enable-features=" "$conf") == 1 ]] || fail "the feature joins the existing --enable-features line" "$(cat "$conf")"
grep -qx -- "--enable-features=TouchpadOverscrollHistoryNavigation,AcceleratedVideoDecoder" "$conf" ||
  fail "existing features are kept" "$(cat "$conf")"
pass "AcceleratedVideoDecoder is merged into the Omarchy defaults"

before=$(cat "$conf")
install_decode
[[ $(cat "$conf") == "$before" ]] || fail "a second run changes nothing" "$(cat "$conf")"
pass "installing twice is a no-op"

printf -- "--ozone-platform=wayland\n" >"$conf"
install_decode
grep -qx -- "--enable-features=AcceleratedVideoDecoder" "$conf" || fail "a feature line is added when none exists" "$(cat "$conf")"
pass "a config without --enable-features gets one"

printf -- "--enable-features=Foo\n" >"$conf"
install_decode "$test_tmp/empty"
grep -qx -- "--enable-features=Foo" "$conf" || fail "no decoder, no change" "$(cat "$conf")"
pass "machines without a decoder keep software decoding"

rm -f "$conf"
install_decode
[[ ! -e $conf ]] || fail "no Chromium config is created"
pass "no Chromium config, nothing written"
