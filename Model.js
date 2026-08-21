function repoUrl() {
  return "https://github.com/OWNER/Insta360Link"
}

function num(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

function emptyPose() {
  return { pan: 0, tilt: 0, zoom: 100 }
}

function clonePose(pose) {
  if (!pose) return emptyPose()
  return {
    pan: num(pose.pan, 0),
    tilt: num(pose.tilt, 0),
    zoom: num(pose.zoom, 100)
  }
}

function posesClose(a, b) {
  if (!a || !b) return false
  return Math.abs(a.pan - b.pan) < 3600 && Math.abs(a.tilt - b.tilt) < 3600 && a.zoom === b.zoom
}

function defaultPreset(id, name) {
  return { id: String(id), name: String(name || id), pan: 0, tilt: 0, zoom: 100 }
}

function normalizePreset(raw, fallbackId) {
  var id = String((raw && raw.id) || fallbackId || "1")
  var name = String((raw && raw.name) || id)
  if (!name) name = id
  return {
    id: id,
    name: name,
    pan: num(raw && raw.pan, 0),
    tilt: num(raw && raw.tilt, 0),
    zoom: num(raw && raw.zoom, 100)
  }
}

function defaultConfig() {
  return {
    version: 1,
    defaultPreset: "1",
    presets: [
      defaultPreset("1", "1"),
      defaultPreset("2", "2"),
      defaultPreset("3", "3")
    ]
  }
}

function normalizeConfig(raw) {
  var cfg = defaultConfig()
  if (!raw || typeof raw !== "object") return cfg
  var presets = []
  var incoming = Array.isArray(raw.presets) ? raw.presets : []
  for (var i = 0; i < 3; i++) {
    var id = String(i + 1)
    presets.push(normalizePreset(incoming[i] || cfg.presets[i], id))
    presets[i].id = id
  }
  cfg.presets = presets
  var def = String(raw.defaultPreset || "1")
  if (def !== "1" && def !== "2" && def !== "3") def = "1"
  cfg.defaultPreset = def
  return cfg
}

function parseJson(text, fallback) {
  var raw = String(text || "").trim()
  if (!raw) return fallback
  try {
    return JSON.parse(raw)
  } catch (e) {
    return fallback
  }
}

function parseOccupancy(text) {
  var parsed = parseJson(text, null)
  if (!parsed || typeof parsed !== "object")
    return { state: "missing", via: "", app: "", device: "" }
  var state = String(parsed.state || "missing")
  if (state !== "live" && state !== "idle" && state !== "missing") state = "missing"
  return {
    state: state,
    via: String(parsed.via || ""),
    app: String(parsed.app || ""),
    device: String(parsed.device || "")
  }
}

function parseGet(text) {
  var parsed = parseJson(text, null)
  if (!parsed || parsed.present !== true)
    return { present: false, pose: emptyPose(), ranges: null, device: "" }
  return {
    present: true,
    pose: clonePose(parsed.pose),
    ranges: parsed.ranges || null,
    device: String(parsed.device || "")
  }
}

function parseSet(text) {
  var parsed = parseJson(text, null)
  if (!parsed || !parsed.pose) return null
  return clonePose(parsed.pose)
}

function presetById(config, id) {
  var presets = config && config.presets ? config.presets : []
  for (var i = 0; i < presets.length; i++) {
    if (String(presets[i].id) === String(id)) return presets[i]
  }
  return presets[0] || defaultPreset("1", "1")
}

function statusLine(present, otherInUse, previewOn, app) {
  if (!present) return "UNPLUGGED"
  if (otherInUse) return app ? ("LIVE · " + String(app).toUpperCase()) : "LIVE"
  if (previewOn) return "PREVIEW"
  return "IDLE"
}

function qmlPath(url) {
  var s = String(url || "")
  if (s.indexOf("file://") === 0) return s.substring(7)
  return s
}

function nudgePose(pose, ranges, dPan, dTilt, dZoom) {
  var next = clonePose(pose)
  var panStep = ranges && ranges.pan ? ranges.pan.step : 3600
  var tiltStep = ranges && ranges.tilt ? ranges.tilt.step : 3600
  var zoomStep = ranges && ranges.zoom ? ranges.zoom.step : 1
  if (dPan) panStep = Math.max(panStep, 7200)
  if (dTilt) tiltStep = Math.max(tiltStep, 18000)
  if (dZoom) zoomStep = Math.max(zoomStep, 10)
  next.pan += dPan * panStep
  next.tilt += dTilt * tiltStep
  next.zoom += dZoom * zoomStep
  if (ranges && ranges.pan) next.pan = snapValue(next.pan, ranges.pan)
  if (ranges && ranges.tilt) next.tilt = snapValue(next.tilt, ranges.tilt)
  if (ranges && ranges.zoom) next.zoom = snapValue(next.zoom, ranges.zoom)
  return next
}

function snapValue(value, spec) {
  var lo = spec.min
  var hi = spec.max
  var step = spec.step || 1
  var n = Number(value)
  if (!isFinite(n)) n = lo
  n = Math.max(lo, Math.min(hi, n))
  return lo + Math.round((n - lo) / step) * step
}
