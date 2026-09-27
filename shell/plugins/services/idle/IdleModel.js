function secondsFromConfig(value, fallback) {
  var n = Number(value)
  if (!isFinite(n) || n < 0) return fallback
  return Math.floor(n)
}

function eventParts(event, count) {
  try {
    if (event && event.parse) return event.parse(count)
  } catch (error) {
  }
  return String(event && event.data ? event.data : "").split(",")
}

function screensaverWindowsAfter(windows, address, visible) {
  var key = String(address || "")
  if (!key) {
    var current = windows || {}
    var existingCount = 0
    for (var currentKey in current) {
      if (current[currentKey]) existingCount++
    }
    return { windows: current, count: existingCount }
  }

  var next = {}
  var count = 0
  for (var existing in windows || {}) {
    if (existing !== key && windows[existing]) {
      next[existing] = true
      count++
    }
  }

  if (visible) {
    next[key] = true
    count++
  }

  return {
    windows: next,
    count: count
  }
}

// Starting the screensaver can make the compositor report activity; that is
// not the user while the screensaver is up or still launching.
function screensaverHoldsIdle(started, windowCount, launching) {
  return !!started && (windowCount > 0 || !!launching)
}

// Idle suspend runs on battery, or on AC when configured; 0 seconds disables it.
function suspendArmed(seconds, onBattery, suspendOnAc) {
  return seconds > 0 && (!!onBattery || !!suspendOnAc)
}

if (typeof module !== "undefined") {
  module.exports = {
    secondsFromConfig: secondsFromConfig,
    eventParts: eventParts,
    screensaverWindowsAfter: screensaverWindowsAfter,
    screensaverHoldsIdle: screensaverHoldsIdle,
    suspendArmed: suspendArmed
  }
}
