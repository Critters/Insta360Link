import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "dave.insta360-link"
  ipcTarget: "dave.insta360-link"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var ptz: null
  property bool openedFromHotkey: false
  property bool previewOn: false
  property string selectedId: "1"
  property string editingId: ""
  property bool poseDirty: false
  property bool showHelp: false
  property bool shiftHeld: false
  property string clickPresetId: ""

  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  function service() {
    if (bar && bar.shell && typeof bar.shell.serviceFor === "function")
      return bar.shell.serviceFor("dave.insta360-link")
    return ptz
  }

  readonly property var config: (service() ? service().config : null) || Model.defaultConfig()
  readonly property var presets: config.presets
  readonly property string defaultId: config.defaultPreset
  readonly property string statusText: service() ? service().statusText : "UNPLUGGED"
  readonly property bool present: service() ? service().present : false

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    if (ptz && selectedId === "") selectedId = ptz.config.defaultPreset
    root.controller.show()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    if (ptz && selectedId === "") selectedId = ptz.config.defaultPreset
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    cancelRename()
    showHelp = false
    setPreview(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function setPreview(value) {
    previewOn = !!value && present
    var s = root.service()
    if (s) s.setPreviewActive(previewOn)
    if (!previewOn) previewLoader.active = false
    else previewLoader.active = true
  }

  function selectPreset(id) {
    selectedId = String(id)
    poseDirty = false
    var s = root.service()
    if (s) s.selectPreset(selectedId)
  }

  function setDefault(id) {
    var s = root.service()
    if (s) s.setDefaultPreset(id)
  }

  function startRename(id) {
    selectedId = String(id)
    editingId = String(id)
  }

  function commitRename(name) {
    if (editingId === "" || !root.service()) {
      cancelRename()
      return
    }
    var s = root.service()
    if (s) s.renamePreset(editingId, name)
    editingId = ""
  }

  function cancelRename() {
    editingId = ""
  }

  function nudge(dPan, dTilt, dZoom, fine) {
    var s = root.service()
    if (!s || !root.present) return
    s.nudge(dPan, dTilt, dZoom, !!fine)
    poseDirty = true
    saveTimer.restart()
  }

  function handleMove(dx, dy) {
    if (editingId !== "") return
    if (dx !== 0) nudge(dx, 0, 0, root.shiftHeld)
    if (dy !== 0) nudge(0, -dy, 0, root.shiftHeld)
  }

  Timer {
    id: clickDelay
    interval: 280
    onTriggered: root.selectPreset(root.clickPresetId)
  }

  Timer {
    id: saveTimer
    interval: 250
    onTriggered: {
      if (root.poseDirty && root.service())
        root.service().savePoseToPreset(root.selectedId)
      root.poseDirty = false
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingId !== ""
      onMoveRequested: function(dx, dy) { root.handleMove(dx, dy) }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "1" || t === "2" || t === "3") root.selectPreset(t)
        else if (t === "p" || t === "P") root.setPreview(!root.previewOn)
        else if (t === "+" || t === "=") root.nudge(0, 0, 1, root.shiftHeld)
        else if (t === "-" || t === "_") root.nudge(0, 0, -1, root.shiftHeld)
        else if (t === "d" || t === "D") root.setDefault(root.selectedId)
        else if (t === "i" || t === "I") root.showHelp = !root.showHelp
      }
      Keys.forwardTo: [shiftSpy]

      Item {
        id: shiftSpy
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Shift) root.shiftHeld = true
          else root.shiftHeld = !!(event.modifiers & Qt.ShiftModifier)
        }
        Keys.onReleased: function(event) {
          if (event.key === Qt.Key_Shift) root.shiftHeld = false
          else root.shiftHeld = !!(event.modifiers & Qt.ShiftModifier)
        }
      }

      Column {
        id: body
        width: parent.width
        spacing: Style.space(14)

        PanelHero {
          width: parent.width
          title: "Camera"
          meta: root.statusText + "  ·  v0.1.4"
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Text {
            text: "󰖠"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
          trailingControl: Row {
            spacing: Style.space(8)

            ToggleSwitch {
              checked: root.previewOn
              foreground: root.foreground
              accent: root.accent
              onToggled: root.setPreview(!root.previewOn)
            }

            Button {
              text: "i"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              selected: root.showHelp
              tooltipText: "How this works"
              onClicked: root.showHelp = !root.showHelp
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Rectangle {
          id: previewBox
          width: parent.width
          height: Math.round(width * 9 / 16)
          color: "#101010"
          radius: Style.cornerRadius
          clip: true
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

          Loader {
            id: previewLoader
            anchors.fill: parent
            active: false
            source: Qt.resolvedUrl("Preview.qml")
            onLoaded: if (item) item.active = root.previewOn
          }

          Text {
            visible: !root.previewOn
            anchors.centerIn: parent
            text: root.present ? "Preview off" : "Camera unplugged"
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          MouseArea {
            anchors.fill: parent
            enabled: !root.previewOn && root.present
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setPreview(true)
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(12)
          visible: root.showHelp

          Text {
            width: parent.width
            text: "- First preset is the camera's default.\n- Save upto 3 presets, changes you make are auto-saved as they are made.\n- Shift+Click to reduce the jog speed.\n- Double click a preset to rename it."
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            lineHeight: 1.35
          }
          Text {
            width: parent.width
            text: "Thanks DHH!"
            color: Qt.darker(root.foreground, 1.25)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Reset"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              onClicked: {
                var s = root.service()
                if (s) s.resetPresets()
                root.selectedId = "1"
              }
            }
            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Repo"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              onClicked: Quickshell.execDetached(["xdg-open", Model.repoUrl()])
            }
          }
        }

        Row {
          id: presetRow
          visible: !root.showHelp
          width: parent.width
          spacing: Style.space(8)

          Repeater {
            model: root.presets

            BorderSurface {
              id: tab
              required property var modelData
              readonly property string presetId: String(modelData.id)
              readonly property bool isSelected: root.selectedId === presetId
              readonly property bool isDefault: root.defaultId === presetId
              readonly property bool isEditing: root.editingId === presetId

              width: Math.max(1, (presetRow.width - 2 * presetRow.spacing) / 3)
              height: Style.space(36)
              radius: Style.cornerRadius
              color: isSelected
                ? Style.selectedFillFor(root.foreground, root.accent)
                : (tabMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.accent) : "transparent")
              borderSpec: Border.controlSpec(isSelected ? "selected" : (tabMouse.containsMouse ? "hover-cursor" : "normal"), root.foreground, root.accent)

              Row {
                anchors.centerIn: parent
                spacing: Style.space(6)
                visible: !tab.isEditing

                Text {
                  visible: tab.isDefault
                  text: "★"
                  color: tab.isSelected ? Style.selectedStateColor(root.foreground, root.accent) : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: tab.modelData.name
                  color: tab.isSelected ? Style.selectedStateColor(root.foreground, root.accent) : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: tab.isSelected
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              TextField {
                visible: tab.isEditing
                anchors.fill: parent
                anchors.margins: Style.space(4)
                foreground: root.foreground
                accent: root.accent
                verticalPadding: Style.space(2)
                onVisibleChanged: {
                  if (!visible) return
                  text = tab.modelData.name
                  selectAll()
                  forceActiveFocus()
                }
                onAccepted: root.commitRename(text)
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.cancelRename()
                    event.accepted = true
                  }
                }
              }

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                visible: !tab.isEditing
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) {
                  if (mouse.button === Qt.RightButton) {
                    clickDelay.stop()
                    root.setDefault(tab.presetId)
                    return
                  }
                  if (clickDelay.running && root.clickPresetId === tab.presetId) {
                    clickDelay.stop()
                    root.startRename(tab.presetId)
                    return
                  }
                  root.clickPresetId = tab.presetId
                  clickDelay.restart()
                }
              }
            }
          }
        }

        Item {
          visible: !root.showHelp
          width: parent.width
          implicitHeight: padGrid.implicitHeight

          Grid {
            id: padGrid
            anchors.horizontalCenter: parent.horizontalCenter
            columns: 3
            spacing: Style.space(8)

            Item { width: Style.space(44); height: Style.space(44) }
            PadButton {
              fastText: ">>"
              fineText: ">"
              iconRotation: -90
              shiftHeld: root.shiftHeld
              foreground: root.foreground
              accent: root.accent
              onTick: function(fine) { root.nudge(0, 1, 0, fine) }
              onShiftSeen: function(held) { root.shiftHeld = held }
            }
            PadButton {
              fastText: "+"
              fineText: "+"
              shiftHeld: root.shiftHeld
              foreground: root.foreground
              accent: root.accent
              onTick: function(fine) { root.nudge(0, 0, 1, fine) }
              onShiftSeen: function(held) { root.shiftHeld = held }
            }
            PadButton {
              fastText: "<<"
              fineText: "<"
              shiftHeld: root.shiftHeld
              foreground: root.foreground
              accent: root.accent
              onTick: function(fine) { root.nudge(-1, 0, 0, fine) }
              onShiftSeen: function(held) { root.shiftHeld = held }
            }
            Item { width: Style.space(44); height: Style.space(44) }
            PadButton {
              fastText: ">>"
              fineText: ">"
              shiftHeld: root.shiftHeld
              foreground: root.foreground
              accent: root.accent
              onTick: function(fine) { root.nudge(1, 0, 0, fine) }
              onShiftSeen: function(held) { root.shiftHeld = held }
            }
            Item { width: Style.space(44); height: Style.space(44) }
            PadButton {
              fastText: ">>"
              fineText: ">"
              iconRotation: 90
              shiftHeld: root.shiftHeld
              foreground: root.foreground
              accent: root.accent
              onTick: function(fine) { root.nudge(0, -1, 0, fine) }
              onShiftSeen: function(held) { root.shiftHeld = held }
            }
            PadButton {
              fastText: "-"
              fineText: "-"
              shiftHeld: root.shiftHeld
              foreground: root.foreground
              accent: root.accent
              onTick: function(fine) { root.nudge(0, 0, -1, fine) }
              onShiftSeen: function(held) { root.shiftHeld = held }
            }
          }
        }
      }
    }
  }

  onPreviewOnChanged: {
    if (previewLoader.item) previewLoader.item.active = root.previewOn
  }

  onPtzChanged: {
    if (ptz && (selectedId === "1" || selectedId === "2" || selectedId === "3"))
      return
    if (ptz) selectedId = ptz.config.defaultPreset
  }
}
