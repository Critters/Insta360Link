import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string ptzBin: Model.qmlPath(Qt.resolvedUrl("ptz.py"))
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/ptz.json"

  property var config: Model.defaultConfig()
  property var ranges: null
  property var pose: Model.emptyPose()
  property bool present: false
  property bool previewActive: false
  property bool otherInUse: false
  property string occupancyState: "missing"
  property string occupancyApp: ""
  property string occupancyVia: ""
  property bool configReady: false
  property bool booted: false
  property var pendingSet: null
  property var lastOccupancy: ({ state: "missing", via: "", app: "", device: "" })
  property var pendingOccupancy: null

  readonly property string statusText: Model.statusLine(present, otherInUse, previewActive, occupancyApp)
  readonly property bool live: otherInUse || previewActive

  function setPreviewActive(value) {
    previewActive = !!value
    commitOccupancy(lastOccupancy, false)
  }

  function selectPreset(id) {
    var preset = Model.presetById(config, id)
    setPose(Model.clonePose(preset), false)
  }

  function applyDefault() {
    selectPreset(config.defaultPreset)
  }

  function park() {
    setPose(Model.parkPose(config, ranges), false)
  }

  function setDefaultPreset(id) {
    var next = Model.normalizeConfig(config)
    next.defaultPreset = String(id)
    config = next
    persist()
  }

  function renamePreset(id, name) {
    var next = Model.normalizeConfig(config)
    for (var i = 0; i < next.presets.length; i++) {
      if (next.presets[i].id === String(id)) {
        var trimmed = String(name || "").trim()
        next.presets[i].name = trimmed || next.presets[i].id
      }
    }
    config = next
    persist()
  }

  function savePoseToPreset(id) {
    var next = Model.normalizeConfig(config)
    for (var i = 0; i < next.presets.length; i++) {
      if (next.presets[i].id === String(id)) {
        next.presets[i].pan = pose.pan
        next.presets[i].tilt = pose.tilt
        next.presets[i].zoom = pose.zoom
      }
    }
    config = next
    persist()
  }

  function saveParkToCurrent() {
    var next = Model.normalizeConfig(config)
    next.park = Model.clonePose(pose)
    config = next
    persist()
  }

  function nudge(dPan, dTilt, dZoom) {
    setPose(Model.nudgePose(pose, ranges, dPan, dTilt, dZoom), true)
  }

  function setPose(nextPose, fromNudge) {
    if (!present && occupancyState === "missing") return
    if (!fromNudge && Model.posesClose(pose, nextPose)) {
      pose = nextPose
      return
    }
    pose = nextPose
    if (setProc.running) {
      pendingSet = nextPose
      return
    }
    runSet(nextPose)
  }

  function runSet(nextPose) {
    if (!ptzBin) return
    setProc.command = ["python3", ptzBin, "set", String(nextPose.pan), String(nextPose.tilt), String(nextPose.zoom)]
    setProc.running = true
  }

  function refreshPose() {
    if (!ptzBin || getProc.running) return
    getProc.command = ["python3", ptzBin, "get"]
    getProc.running = true
  }

  function persist() {
    configFile.setText(JSON.stringify(config, null, 2) + "\n")
  }

  function loadConfig(raw) {
    config = Model.normalizeConfig(Model.parseJson(raw, null))
    configReady = true
    if (present && booted && !otherInUse && occupancyState === "idle")
      park()
  }

  function applyOccupancy(parsed, fromPoll) {
    lastOccupancy = parsed
    pendingOccupancy = parsed
    if (fromPoll) {
      occDebounce.restart()
      return
    }
    commitOccupancy(parsed, fromPoll)
  }

  Timer {
    id: occDebounce
    interval: 300
    onTriggered: {
      if (root.pendingOccupancy)
        root.commitOccupancy(root.pendingOccupancy, true)
    }
  }

  function commitOccupancy(parsed, fromPoll) {
    if (!parsed) return
    var foreign = parsed.state === "live" && !(previewActive && (parsed.app === "" || parsed.via === "pw"))
    if (previewActive && parsed.via === "v4l2" && parsed.app !== "") foreign = true

    var wasLive = otherInUse
    occupancyState = parsed.state
    occupancyApp = parsed.app
    occupancyVia = parsed.via
    present = parsed.state !== "missing"
    otherInUse = foreign

    if (!configReady) return

    if (!booted) {
      if (fromPoll) booted = true
      if (present && !otherInUse) park()
      return
    }

    if (!present) return
    if (otherInUse && !wasLive) applyDefault()
    if (!otherInUse && wasLive && !previewActive) park()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadConfig(text())
    onLoadFailed: root.loadConfig("")
  }

  Process {
    id: getProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseGet(text)
        root.present = parsed.present
        if (parsed.present) {
          root.pose = parsed.pose
          if (parsed.ranges) root.ranges = parsed.ranges
        }
      }
    }
  }

  Process {
    id: setProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseSet(text)
        if (parsed) root.pose = parsed
      }
    }
    onExited: function() {
      if (root.pendingSet) {
        var next = root.pendingSet
        root.pendingSet = null
        root.runSet(next)
      }
    }
  }

  Process {
    id: occProc
    command: ["python3", root.ptzBin, "occupancy"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOccupancy(Model.parseOccupancy(text), true)
    }
  }

  Timer {
    interval: 500
    running: root.ptzBin !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!occProc.running) occProc.running = true
    }
  }

  Component.onCompleted: {
    refreshPose()
    configFile.reload()
  }
}
