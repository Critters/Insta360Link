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
  property bool pendingUnlock: false
  property var pendingNudge: null
  property bool poseTouched: false
  property var lastOccupancy: ({ state: "missing", via: "", app: "", device: "" })
  property var pendingOccupancy: null
  property bool persisting: false
  property bool haveDiskConfig: false

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

  function setDefaultPreset(id) {
    var next = Model.normalizeConfig(config)
    next.defaultPreset = String(id)
    config = next
    persist()
  }

  function resetPresets() {
    config = Model.defaultConfig()
    haveDiskConfig = true
    persist()
    selectPreset("1")
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

  function nudge(dPan, dTilt, dZoom, fine) {
    poseTouched = true
    if (setProc.running) {
      if (!pendingNudge)
        pendingNudge = { dPan: 0, dTilt: 0, dZoom: 0, fine: !!fine }
      pendingNudge.dPan += dPan
      pendingNudge.dTilt += dTilt
      pendingNudge.dZoom += dZoom
      pendingNudge.fine = !!fine
      return
    }
    runNudge(dPan, dTilt, dZoom, !!fine)
  }

  function runNudge(dPan, dTilt, dZoom, fine) {
    if (!ptzBin) return
    var cmd = ["python3", ptzBin, "nudge"]
    if (fine) cmd.push("--fine")
    cmd.push(String(dPan), String(dTilt), String(dZoom))
    setProc.command = cmd
    setProc.running = true
  }

  function setPose(nextPose, fromNudge) {
    if (!present && occupancyState === "missing") return
    if (!fromNudge && Model.posesClose(pose, nextPose)) {
      pose = nextPose
      return
    }
    poseTouched = true
    pose = nextPose
    pendingNudge = null
    if (setProc.running) {
      pendingSet = nextPose
      pendingUnlock = !fromNudge
      return
    }
    runSet(nextPose, !fromNudge)
  }

  function runSet(nextPose, unlock) {
    if (!ptzBin) return
    var cmd = ["python3", ptzBin, "set"]
    if (unlock) cmd.push("--unlock")
    cmd.push(String(nextPose.pan), String(nextPose.tilt), String(nextPose.zoom))
    setProc.command = cmd
    setProc.running = true
  }

  function refreshPose() {
    if (!ptzBin || getProc.running) return
    getProc.command = ["python3", ptzBin, "get"]
    getProc.running = true
  }

  function persist() {
    if (!configReady) return
    haveDiskConfig = true
    persisting = true
    configFile.setText(JSON.stringify(config, null, 2) + "\n")
    persistUnlock.restart()
  }

  function loadConfig(raw) {
    var parsed = Model.parseJson(raw, null)
    if (parsed && parsed.presets) {
      config = Model.normalizeConfig(parsed)
      haveDiskConfig = true
    } else if (!haveDiskConfig) {
      config = Model.defaultConfig()
    }
    configReady = true
    persisting = false
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
    id: persistUnlock
    interval: 500
    onTriggered: root.persisting = false
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
      return
    }

    if (!present) return
    if (otherInUse && !wasLive) applyDefault()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: if (!root.persisting) reload()
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
          if (!root.poseTouched) root.pose = parsed.pose
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
        if (parsed && !root.pendingSet) root.pose = parsed
      }
    }
    onExited: function() {
      if (root.pendingSet) {
        var next = root.pendingSet
        var unlock = root.pendingUnlock
        root.pendingSet = null
        root.pendingUnlock = false
        root.pendingNudge = null
        root.runSet(next, unlock)
        return
      }
      if (root.pendingNudge) {
        var n = root.pendingNudge
        root.pendingNudge = null
        root.runNudge(n.dPan, n.dTilt, n.dZoom, n.fine)
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

  Process {
    id: prepareProc
  }

  Component.onCompleted: {
    console.log("insta360-link service 0.1.7")
    if (ptzBin) {
      prepareProc.command = ["python3", ptzBin, "prepare"]
      prepareProc.running = true
    }
    refreshPose()
    configFile.reload()
  }
}
