// Tide math over Open-Meteo Marine hourly sea_level_height_msl data.

// weather.json holds {"name": ..., "latitude": ..., "longitude": ...} —
// same file and format the omarchy weather widget reads.
function parseLocationFile(raw) {
  var unset = { name: "", latitude: null, longitude: null }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset

    var latitude = parseFloat(data.latitude)
    var longitude = parseFloat(data.longitude)
    var hasCoordinates = !isNaN(latitude) && !isNaN(longitude)
    return {
      name: typeof data.name === "string" ? data.name.replace(/^\s+|\s+$/g, "") : "",
      latitude: hasCoordinates ? latitude : null,
      longitude: hasCoordinates ? longitude : null
    }
  } catch (e) {
    return unset
  }
}

// Local extrema of the hourly sea-level series. The true peak sits between
// hourly samples, so refine each extremum with a parabola through its
// neighbors — good to a few minutes.
function tideEvents(report) {
  if (!report || !report.hourly || !report.hourly.time) return []
  var times = report.hourly.time
  var heights = report.hourly.sea_level_height_msl
  if (!heights) return []

  var out = []
  for (var i = 1; i < heights.length - 1; i++) {
    var a = heights[i - 1], b = heights[i], c = heights[i + 1]
    if (a === null || b === null || c === null || a === undefined || b === undefined || c === undefined) continue
    var isMax = b > a && b >= c
    var isMin = b < a && b <= c
    if (!isMax && !isMin) continue

    var denom = a - 2 * b + c
    var shift = denom === 0 ? 0 : (a - c) / (2 * denom)
    if (shift > 1) shift = 1
    if (shift < -1) shift = -1

    var t = new Date(times[i])
    if (isNaN(t.getTime())) continue
    out.push({
      time: new Date(t.getTime() + shift * 3600 * 1000),
      high: isMax,
      height: b - (a - c) * shift / 4
    })
  }
  return out
}

function upcomingEvents(events, now, count) {
  var out = []
  for (var i = 0; i < events.length && out.length < count; i++) {
    if (events[i].time.getTime() > now.getTime()) out.push(events[i])
  }
  return out
}

// Sea level right now, linearly interpolated between the hourly samples.
function heightAt(report, now) {
  if (!report || !report.hourly || !report.hourly.time) return null
  var times = report.hourly.time
  var heights = report.hourly.sea_level_height_msl
  if (!heights || times.length < 2) return null

  var start = new Date(times[0])
  if (isNaN(start.getTime())) return null
  var pos = (now.getTime() - start.getTime()) / 3600000
  var i = Math.floor(pos)
  if (i < 0 || i >= heights.length - 1) return null
  var a = heights[i], b = heights[i + 1]
  if (a === null || b === null || a === undefined || b === undefined) return null
  return a + (b - a) * (pos - i)
}

function formatHeight(h) {
  if (h === null || h === undefined || isNaN(h)) return ""
  return (h >= 0 ? "+" : "") + h.toFixed(1) + "m"
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

function formatTime(date) {
  return pad2(date.getHours()) + ":" + pad2(date.getMinutes())
}

function dayLabel(date, now) {
  if (date.toDateString() === now.toDateString()) return "TODAY"
  return ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"][date.getDay()]
}

// Sea level at an arbitrary instant via Catmull-Rom through the hourly
// samples — smooth enough to draw the curve without visible hour kinks.
function smoothHeightAt(report, timeMs) {
  if (!report || !report.hourly || !report.hourly.time) return null
  var heights = report.hourly.sea_level_height_msl
  if (!heights) return null
  var start = new Date(report.hourly.time[0])
  if (isNaN(start.getTime())) return null

  var n = heights.length
  var pos = (timeMs - start.getTime()) / 3600000
  if (pos < 0 || pos > n - 1) return null
  var i = Math.floor(pos)
  if (i >= n - 1) i = n - 2
  var f = pos - i

  var p1 = heights[i], p2 = heights[i + 1]
  var p0 = i > 0 ? heights[i - 1] : p1
  var p3 = i + 2 < n ? heights[i + 2] : p2
  if (p0 === null || p1 === null || p2 === null || p3 === null
    || p0 === undefined || p1 === undefined || p2 === undefined || p3 === undefined) return null

  return 0.5 * ((2 * p1) + (-p0 + p2) * f
    + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f * f
    + (-p0 + 3 * p1 - 3 * p2 + p3) * f * f * f)
}

// Today's tidal swing: highest high minus lowest low of today's events.
function todayRange(events, now) {
  var highs = [], lows = []
  for (var i = 0; i < events.length; i++) {
    if (events[i].time.toDateString() !== now.toDateString()) continue
    if (events[i].high) highs.push(events[i].height)
    else lows.push(events[i].height)
  }
  if (highs.length === 0 || lows.length === 0) return ""
  return (Math.max.apply(null, highs) - Math.min.apply(null, lows)).toFixed(1) + "m"
}

function untilText(from, to) {
  var mins = Math.max(0, Math.round((to.getTime() - from.getTime()) / 60000))
  var h = Math.floor(mins / 60)
  var m = mins % 60
  if (h === 0) return m + " min"
  return h + "h " + pad2(m) + "m"
}

// Open-Meteo geocoding response → suggestion rows for the location picker
// (same shape the weather panel uses).
function parseGeocodingResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data.results
    if (!results || !results.length) return []

    var out = []
    for (var i = 0; i < results.length; i++) {
      var r = results[i]
      if (!r || !r.name || r.latitude === undefined || r.longitude === undefined) continue
      var region = [r.admin1, r.country].filter(function(part) { return !!part }).join(", ")
      out.push({
        name: String(r.name),
        description: region,
        latitude: r.latitude,
        longitude: r.longitude
      })
    }
    return out
  } catch (e) {
    return []
  }
}

// Serialized location file, matching weather.json's shape.
function locationFileContents(name, latitude, longitude) {
  return JSON.stringify({ name: name, latitude: latitude, longitude: longitude }, null, 2) + "\n"
}

// Tides for the day the panel is showing, chronological. That is today's
// events; once today's last event has passed, tomorrow's — the row stays
// forward-looking in the evening.
function dayTides(events, now) {
  var today = [], tomorrow = []
  var tomorrowDate = new Date(now.getTime() + 24 * 3600 * 1000)
  for (var i = 0; i < events.length; i++) {
    var d = events[i].time.toDateString()
    if (d === now.toDateString()) today.push(events[i])
    else if (d === tomorrowDate.toDateString()) tomorrow.push(events[i])
  }
  var todayRemaining = today.filter(function(e) { return e.time.getTime() > now.getTime() })
  if (todayRemaining.length === 0 && tomorrow.length > 0) return { label: "TOMORROW", events: tomorrow }
  return { label: "TODAY", events: today }
}
