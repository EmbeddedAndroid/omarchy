#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# A two-core machine with one cluster, three thermal zones and a fan.
fake="$test_tmp/root"
mkdir -p "$fake/proc" "$fake/sys/devices/system/cpu/cpufreq/policy0" "$fake/sys/class/hwmon/hwmon0"
cat >"$fake/proc/stat" <<'EOF'
cpu  100 0 100 700 100 0 0 0 0 0
cpu0 50 0 50 350 50 0 0 0 0 0
cpu1 50 0 50 350 50 0 0 0 0 0
intr 1 2 3
EOF
cat >"$fake/proc/meminfo" <<'EOF'
MemTotal:       16000000 kB
MemFree:         1000000 kB
MemAvailable:   12000000 kB
EOF
echo "0 1" >"$fake/sys/devices/system/cpu/cpufreq/policy0/related_cpus"
echo 1800000 >"$fake/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq"
echo 3600000 >"$fake/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq"
zone() {
  local dir="$fake/sys/class/thermal/thermal_zone$1"
  mkdir -p "$dir"
  echo "$2" >"$dir/type"
  echo "$3" >"$dir/temp"
  shift 3
  local i=0
  while (( $# )); do
    echo "$1" >"$dir/trip_point_${i}_type"
    echo "$2" >"$dir/trip_point_${i}_temp"
    shift 2
    i=$((i + 1))
  done
}
zone 0 cpu-0-0-thermal 72000 passive 95000 critical 115000
zone 1 gpu-0-0-thermal 51000 passive 95000
zone 2 nsphvx-0-thermal 90000 critical 115000
zone 3 battery 30000 critical 60000
echo "fan" >"$fake/sys/class/hwmon/hwmon0/name"
echo 2400 >"$fake/sys/class/hwmon/hwmon0/fan1_input"
echo 0 >"$fake/sys/class/hwmon/hwmon0/fan2_input"
echo "CPU" >"$fake/sys/class/hwmon/hwmon0/fan2_label"

out=$(OMARCHY_SYSTEM_LOAD_ROOT="$fake" "$ROOT/bin/omarchy-system-load")
expect() { grep -qxF "$1" <<<"$out" || fail "$2" "output: $out"; }
expect $'cpu\t800\t1000' "aggregate CPU counters include iowait as idle"
expect $'cpu1\t400\t500' "per-core CPU counters"
expect $'freq\t0,1\t1800000\t3600000' "cluster frequency with its CPUs"
expect $'temp\tcpu\t72000' "CPU temperature group"
expect $'temp\tnpu\t90000' "NSP zones report as the NPU group"
expect $'hot\tnsphvx-0-thermal\t90000\t95000' "a zone without a passive trip throttles 20 C under critical"
expect $'fan\t\t2400' "fan speed without a driver label"
expect $'fan\tCPU\t0' "fan label from the driver"
expect $'memory\t4000000\t16000000' "memory used and total"
grep -q "battery" <<<"$out" && fail "zones outside the reported groups are ignored"
grep -q "^app" <<<"$out" && fail "per-program memory only with --processes"
grep -q "^vpu" <<<"$out" && fail "no V4L2 codec, no video engine record"
pass "omarchy-system-load reports CPU, clocks, thermals, fans and memory"

v4l2_device() {
  local dir="$fake/sys/class/video4linux/$1"
  mkdir -p "$dir/device/power"
  echo "$2" >"$dir/name"
  echo "$3" >"$dir/device/power/runtime_status"
}
v4l2_device video0 msm_vfe0_video0 active
out=$(OMARCHY_SYSTEM_LOAD_ROOT="$fake" "$ROOT/bin/omarchy-system-load")
grep -q "^vpu" <<<"$out" && fail "a camera is not a video engine" "output: $out"
v4l2_device video16 qcom-iris-decoder suspended
v4l2_device video17 qcom-iris-encoder suspended
out=$(OMARCHY_SYSTEM_LOAD_ROOT="$fake" "$ROOT/bin/omarchy-system-load")
expect $'vpu\tidle' "a suspended codec is idle"
echo active >"$fake/sys/class/video4linux/video17/device/power/runtime_status"
out=$(OMARCHY_SYSTEM_LOAD_ROOT="$fake" "$ROOT/bin/omarchy-system-load")
expect $'vpu\tactive' "a powered codec is active"
[[ $(grep -c "^vpu" <<<"$out") == 1 ]] || fail "one record for the engine" "output: $out"
pass "the video engine is reported from the codec's runtime power state"

proc_status() {
  mkdir -p "$fake/proc/$1"
  printf 'Name:\t%s\nVmRSS:\t%s kB\n' "$2" "$3" >"$fake/proc/$1/status"
}
proc_status 10 firefox 400000
proc_status 11 firefox 300000
proc_status 12 Hyprland 200000
proc_status 15 xdg-desktop-por 100000
printf '/usr/lib/xdg-desktop-portal-hyprland\0--verbose\0' >"$fake/proc/15/cmdline"
proc_status 13 kthreadd ""
mkdir -p "$fake/proc/14"
codec_user() {
  mkdir -p "$fake/proc/$1/fd"
  printf '%s\n' "$2" >"$fake/proc/$1/comm"
  ln -s "$3" "$fake/proc/$1/fd/$4"
}
codec_user 20 chromium /dev/video16 30
codec_user 21 chromium /dev/video16 31
codec_user 22 snapshot /dev/video17 4
codec_user 23 snapshot /dev/video0 5
out=$(OMARCHY_SYSTEM_LOAD_ROOT="$fake" "$ROOT/bin/omarchy-system-load" --processes)
expect $'app\t700000\tfirefox' "a program's processes are summed"
expect $'app\t200000\tHyprland' "each program reported"
expect $'app\t100000\txdg-desktop-portal-hyprland' "a name the kernel clipped is completed from argv[0]"
[[ $(grep -m1 "^app" <<<"$out") == $'app\t700000\tfirefox' ]] || fail "largest program first"
pass "per-program memory, largest first, skipping unreadable processes"

expect $'vpuapp\tdecode\tchromium' "a program holding the decoder"
expect $'vpuapp\tencode\tsnapshot' "a program holding the encoder"
[[ $(grep -c "^vpuapp" <<<"$out") == 2 ]] || fail "each program once per use; cameras are not codec users" "output: $out"
pass "programs using the video engine, from their open file descriptors"

run_node_test <<'JS'
const m = requireFromRoot('shell/plugins/panels/system-load/Model.js')

const a = m.parseSample('cpu\t800\t1000\ncpu0\t400\t500\ncpu1\t400\t500\nfreq\t0,1\t1800000\t3600000\ntemp\tcpu\t72000\nhot\tcpu-0\t72000\t95000\nfan\tfan fan1\t2400\nmemory\t4000000\t16000000\n')
const b = m.parseSample('cpu\t850\t1100\ncpu0\t410\t550\ncpu1\t440\t550\nfreq\t0,1\t3600000\t3600000\n')
const loads = m.cpuLoads(a, b)
assertEqual(loads.total, 50, 'CPU load is the busy share of the jiffies between samples')
assertDeepEqual(loads.cores.map(c => c.load), [80, 20], 'per-core loads in core order')
assertEqual(m.cpuLoads(null, b).total, null, 'no load before a second sample')
assertDeepEqual(m.clusters(b.freqs, loads.cores)[0].loads, [80, 20], 'cores grouped by their cluster')

const nvtop = '[\n  {\n   "device_name": "Qualcomm Hexagon v81 NPU",\n   "gpu_clock": "403MHz",\n   "gpu_util": "12%",\n   "hvx_util": "40%",\n   "hmx_util": "70%"\n  },\n  {\n   "device_name": "Adreno (TM) X2-85",\n   "gpu_clock": "1850MHz",\n   "gpu_util": "8%",\n   "processes" : [\n     { "cmdline": "/usr/bin/Hyprland --x", "gpu_usage": "6%" },\n     { "cmdline": "firefox", "gpu_usage": "2%" },\n     { "cmdline": "idle", "gpu_usage": "0%" }\n   ]\n  }\n]\n'
const taken = m.takeNvtopSnapshot('partial\n' + nvtop)
const accel = m.accelerators(taken.devices)
assertEqual(accel.gpu.util, 8, 'GPU utilization from nvtop')
assertEqual(accel.gpu.clock, 1850, 'GPU clock in MHz')
assertEqual(accel.npu.util, 12, 'NPU scalar utilization')
assertEqual(accel.npu.hmx, 70, 'NPU matrix utilization')
assertDeepEqual(m.topProcesses(accel.gpu.processes, 3).map(p => p.name), ['Hyprland', 'firefox'], 'busy GPU processes, busiest first')
assertEqual(m.takeNvtopSnapshot('[\n  {\n').devices, null, 'an incomplete snapshot is not parsed')
assertEqual(m.accelerators([]).gpu, null, 'no GPU without nvtop devices')

assertEqual(m.engineState(3), 'idle', 'low load dims')
assertEqual(m.engineState(60), 'busy', 'high load is busy')
assertEqual(m.engineState(null), 'none', 'no reading')
assertEqual(m.isHot({ temp: 91000, limit: 95000 }), true, 'within 5 C of the throttle point is hot')
assertEqual(m.isHot({ temp: 80000, limit: 95000 }), false, 'far from the throttle point is not hot')
assertEqual(m.label('G', null), 'G', 'a missing value never renders a placeholder')
assertEqual(m.joinPresent([null, '51°C', '']), '51°C', 'missing parts leave no separator')
assertEqual(m.celsius(null), null, 'no temperature, no text')
assertEqual(m.frequency(3609600), '3.6 GHz', 'GHz formatting')
assertEqual(m.cpuRange([7, 6, 8, 9, 10, 11]), '6-11', 'a cluster labels its core range')
assertEqual(m.cpuRange([0, 2]), '0,2', 'non-contiguous cores are listed')
const seg = m.memorySegments({ used: 1000, total: 4000 }, [{ name: 'b', kb: 300 }, { name: 'a', kb: 500 }])
assertDeepEqual(seg.map(s => [s.name, s.kb]), [['a', 500], ['b', 300], ['Other', 200]], 'top programs then the rest of used memory')
assertEqual(seg[0].fraction, 0.125, 'segments are shares of total memory')
const capped = m.memorySegments({ used: 600, total: 4000 }, [{ name: 'a', kb: 500 }, { name: 'b', kb: 400 }])
assertDeepEqual(capped.map(s => [s.name, s.kb]), [['a', 500], ['b', 100]], 'shared pages cannot push the bar past used memory')
assertDeepEqual(m.memorySegments(null, []), [], 'no memory reading, no bar')
assertEqual(m.size(700000), '684 MB', 'MB below a gigabyte')
assertEqual(m.size(0), null, 'no size, no text')
assertDeepEqual(m.fanCells([{ label: '', rpm: 2400 }, { label: 'GPU', rpm: 0 }]), [{ label: 'Fan 1', value: '2400 rpm' }, { label: 'GPU', value: 'Off' }], 'fans by label or position; a stopped fan reads Off')
assertDeepEqual(m.fanCells([{ label: '', rpm: NaN }]), [], 'an unreadable fan is left out')

assertEqual(m.videoEngine(m.parseSample('memory\t1\t2\n')), null, 'no codec, no video engine')
const busy = m.videoEngine(m.parseSample('vpu\tactive\nvpuapp\tdecode\tchromium\nvpuapp\tencode\tsnapshot\n'))
assertEqual(busy.state, 'Decoding · Encoding', 'a powered engine names its work')
assertEqual(m.videoUsers(busy), 'chromium decode · snapshot encode', 'programs with what they use it for')
const paused = m.videoEngine(m.parseSample('vpu\tidle\nvpuapp\tdecode\tchromium\n'))
assertEqual(paused.state, 'Idle', 'an open but unpowered decoder is not decoding')
assertEqual(paused.active, false, 'only a powered engine lights the bar')
assertEqual(m.videoEngine(m.parseSample('vpu\tactive\n')).state, 'Active', 'powered with no visible program')
assertEqual(m.videoUsers(null), '', 'no engine, no text')
JS
