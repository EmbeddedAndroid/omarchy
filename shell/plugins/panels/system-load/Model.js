// Readings below this percentage render dimmed in the bar.
var IDLE_PERCENT = 10
// Readings at or above this percentage mark the engine as busy.
var BUSY_PERCENT = 50
// A sensor this close to its throttle point (m°C) marks the system hot.
var HOT_MARGIN = 5000

function parseSample(raw) {
  var sample = { cpus: {}, freqs: [], temps: {}, hot: null, fans: [], memory: null, apps: [], vpu: null, vpuApps: [] }
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split("\t")
    var key = f[0]
    if (/^cpu\d*$/.test(key) && f.length >= 3) {
      sample.cpus[key] = { idle: Number(f[1]), total: Number(f[2]) }
    } else if (key === "freq" && f.length >= 4) {
      sample.freqs.push({ cpus: f[1].split(",").map(Number), cur: Number(f[2]), max: Number(f[3]) })
    } else if (key === "temp" && f.length >= 3) {
      sample.temps[f[1]] = Number(f[2])
    } else if (key === "hot" && f.length >= 4) {
      sample.hot = { zone: f[1], temp: Number(f[2]), limit: Number(f[3]) }
    } else if (key === "fan" && f.length >= 3) {
      sample.fans.push({ label: f[1], rpm: Number(f[2]) })
    } else if (key === "memory" && f.length >= 3) {
      sample.memory = { used: Number(f[1]), total: Number(f[2]) }
    } else if (key === "app" && f.length >= 3) {
      sample.apps.push({ kb: Number(f[1]), name: f[2] })
    } else if (key === "vpu" && f.length >= 2) {
      sample.vpu = f[1]
    } else if (key === "vpuapp" && f.length >= 3) {
      sample.vpuApps.push({ use: f[1], name: f[2] })
    }
  }
  return sample
}

// Busy percentage for one /proc/stat counter between two samples.
function busyPercent(prev, next) {
  if (!prev || !next) return null
  var total = next.total - prev.total
  if (total <= 0) return null
  var idle = next.idle - prev.idle
  return Math.max(0, Math.min(100, Math.round(100 * (total - idle) / total)))
}

// Overall and per-core CPU load, cores in numeric order.
function cpuLoads(prev, next) {
  var loads = { total: busyPercent(prev && prev.cpus.cpu, next && next.cpus.cpu), cores: [] }
  if (!next) return loads
  var names = Object.keys(next.cpus).filter(function(k) { return k !== "cpu" })
  names.sort(function(a, b) { return Number(a.slice(3)) - Number(b.slice(3)) })
  for (var i = 0; i < names.length; i++) {
    loads.cores.push({ cpu: Number(names[i].slice(3)), load: busyPercent(prev && prev.cpus[names[i]], next.cpus[names[i]]) })
  }
  return loads
}

// Cores grouped by cpufreq policy (the CPU clusters), fastest-capable first.
function clusters(freqs, cores) {
  var byCpu = {}
  for (var i = 0; i < (cores || []).length; i++) byCpu[cores[i].cpu] = cores[i].load
  var list = (freqs || []).slice().sort(function(a, b) { return b.max - a.max || a.cpus[0] - b.cpus[0] })
  return list.map(function(f) {
    return {
      cpus: f.cpus,
      cur: f.cur,
      max: f.max,
      loads: f.cpus.map(function(c) { return byCpu[c] === undefined ? null : byCpu[c] })
    }
  })
}

// nvtop -l prints a JSON array per refresh; returns the devices of the last
// complete array in the buffer and the unconsumed remainder.
// "0-5" for a contiguous run of CPU numbers, else a comma list.
function cpuRange(cpus) {
  var list = (cpus || []).slice().sort(function(a, b) { return a - b })
  if (list.length === 0) return ""
  var contiguous = list[list.length - 1] - list[0] === list.length - 1
  return contiguous && list.length > 1 ? list[0] + "-" + list[list.length - 1] : list.join(",")
}

function takeNvtopSnapshot(buffer) {
  var text = String(buffer || "")
  var end = text.lastIndexOf("\n]")
  if (end < 0) return { devices: null, rest: text }
  // The array opens on a line of its own; nested lists open after a key.
  var start = text.lastIndexOf("\n[\n", end)
  start = start >= 0 ? start + 1 : (text.indexOf("[\n") === 0 ? 0 : -1)
  if (start < 0) return { devices: null, rest: text.slice(end + 2) }
  var devices = null
  try { devices = JSON.parse(text.slice(start, end + 2)) } catch (e) { devices = null }
  return { devices: devices, rest: text.slice(end + 2) }
}

function percent(value) {
  if (value === null || value === undefined) return null
  var n = parseInt(String(value), 10)
  return isFinite(n) ? n : null
}

function megahertz(value) {
  if (value === null || value === undefined) return null
  var n = parseInt(String(value), 10)
  return isFinite(n) ? n : null
}

// Splits nvtop devices into the first GPU and the first NPU.
function accelerators(devices) {
  var out = { gpu: null, npu: null }
  var list = Array.isArray(devices) ? devices : []
  for (var i = 0; i < list.length; i++) {
    var d = list[i] || {}
    var name = String(d.device_name || "")
    var entry = {
      name: name,
      util: percent(d.gpu_util),
      clock: megahertz(d.gpu_clock),
      hvx: percent(d.hvx_util),
      hmx: percent(d.hmx_util),
      processes: Array.isArray(d.processes) ? d.processes : []
    }
    if (/\bNPU\b/.test(name)) { if (!out.npu) out.npu = entry }
    else if (!out.gpu) out.gpu = entry
  }
  return out
}

// Processes using the GPU now, busiest first.
function topProcesses(processes, count) {
  var list = []
  for (var i = 0; i < (processes || []).length; i++) {
    var p = processes[i] || {}
    var usage = percent(p.gpu_usage)
    if (usage === null || usage <= 0) continue
    var cmd = String(p.cmdline || "").split(" ")[0].split("/").pop()
    list.push({ name: cmd, usage: usage })
  }
  list.sort(function(a, b) { return b.usage - a.usage })
  return list.slice(0, count || 3)
}

function engineState(value) {
  if (value === null || value === undefined) return "none"
  if (value >= BUSY_PERCENT) return "busy"
  if (value < IDLE_PERCENT) return "idle"
  return "normal"
}

function isHot(hot) {
  return !!(hot && hot.limit > 0 && hot.limit - hot.temp <= HOT_MARGIN)
}

function label(letter, value) {
  return value === null || value === undefined ? letter : letter + " " + value + "%"
}

// Joins the parts that have a value, so missing readings leave no gap.
function joinPresent(parts, separator) {
  return (parts || []).filter(function(p) { return p !== null && p !== undefined && p !== "" }).join(separator || " · ")
}

function size(kb) {
  if (!isFinite(kb) || kb <= 0) return null
  return kb >= 1048576 ? (kb / 1048576).toFixed(1) + " GB" : Math.round(kb / 1024) + " MB"
}

// Stacked-bar segments of total memory: the top programs, then the rest of
// the used memory. Program totals can overlap through shared pages, so they
// are capped to what is actually in use and "other" never goes negative.
function memorySegments(mem, apps) {
  if (!mem || !mem.total) return []
  var segments = []
  var left = mem.used
  var list = (apps || []).slice().sort(function(a, b) { return b.kb - a.kb })
  for (var i = 0; i < list.length && left > 0; i++) {
    var kb = Math.min(list[i].kb, left)
    if (kb <= 0) continue
    segments.push({ name: list[i].name, kb: kb, fraction: kb / mem.total, alpha: Math.max(0.3, 1 - i * 0.14), other: false })
    left -= kb
  }
  if (left > 0) segments.push({ name: "Other", kb: left, fraction: left / mem.total, alpha: 0.18, other: true })
  return segments
}

// One tile per fan: its driver label, else its position.
function fanCells(fans) {
  var cells = []
  var list = fans || []
  for (var i = 0; i < list.length; i++) {
    if (!isFinite(list[i].rpm)) continue
    cells.push({ label: list[i].label || "Fan " + (i + 1), value: list[i].rpm > 0 ? list[i].rpm + " rpm" : "Off" })
  }
  return cells
}

// The video engine: powered or not, and while the popup is open, the programs
// decoding or encoding on it. Null when the machine has no V4L2 codec.
function videoEngine(sample) {
  if (!sample || !sample.vpu) return null
  var decode = [], encode = []
  var apps = sample.vpuApps || []
  for (var i = 0; i < apps.length; i++) {
    var list = apps[i].use === "encode" ? encode : decode
    if (list.indexOf(apps[i].name) < 0) list.push(apps[i].name)
  }
  // An open device is not work: a paused video keeps the decoder open while
  // the engine powers down, so only a powered engine counts as busy.
  var active = sample.vpu === "active"
  var uses = []
  if (active && decode.length) uses.push("Decoding")
  if (active && encode.length) uses.push("Encoding")
  return {
    active: active,
    decode: decode,
    encode: encode,
    state: uses.length ? uses.join(" · ") : (active ? "Active" : "Idle")
  }
}

// "chromium decode · snapshot encode" for the programs holding the codec.
function videoUsers(vpu) {
  if (!vpu) return ""
  var parts = vpu.decode.map(function(n) { return n + " decode" })
  return parts.concat(vpu.encode.map(function(n) { return n + " encode" })).join(" · ")
}

function celsius(milli) {
  return milli === null || milli === undefined ? null : Math.round(milli / 1000) + "°C"
}

function frequency(khz) {
  if (!khz) return null
  return khz >= 1000000 ? (khz / 1000000).toFixed(1) + " GHz" : Math.round(khz / 1000) + " MHz"
}

function memory(mem) {
  if (!mem || !mem.total) return null
  return (mem.used / 1048576).toFixed(1) + " / " + Math.round(mem.total / 1048576) + " GB"
}

if (typeof module !== "undefined") {
  module.exports = {
    IDLE_PERCENT: IDLE_PERCENT,
    BUSY_PERCENT: BUSY_PERCENT,
    HOT_MARGIN: HOT_MARGIN,
    parseSample: parseSample,
    busyPercent: busyPercent,
    cpuLoads: cpuLoads,
    clusters: clusters,
    cpuRange: cpuRange,
    takeNvtopSnapshot: takeNvtopSnapshot,
    percent: percent,
    accelerators: accelerators,
    topProcesses: topProcesses,
    engineState: engineState,
    isHot: isHot,
    label: label,
    joinPresent: joinPresent,
    celsius: celsius,
    frequency: frequency,
    memory: memory,
    size: size,
    memorySegments: memorySegments,
    fanCells: fanCells,
    videoEngine: videoEngine,
    videoUsers: videoUsers
  }
}
