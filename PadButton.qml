import QtQuick
import qs.Ui
import qs.Commons

BorderSurface {
  id: root

  property string fastText: ">>"
  property string fineText: ">"
  property bool shiftHeld: false
  property real iconRotation: 0
  property color foreground: Color.foreground
  property color accent: Color.accent
  property bool holding: false
  property bool fine: false

  readonly property string iconText: shiftHeld ? fineText : fastText

  signal tick(bool fine)
  signal shiftSeen(bool held)

  implicitWidth: Style.space(44)
  implicitHeight: Style.space(44)
  radius: Style.cornerRadius
  color: mouse.pressed || holding
    ? Style.pressedFillFor(foreground, accent)
    : (mouse.containsMouse ? Style.hoverFillFor(foreground, accent) : "transparent")
  borderSpec: Border.controlSpec(mouse.containsMouse || holding ? "hover-cursor" : "normal", foreground, accent)

  Text {
    anchors.centerIn: parent
    text: root.iconText
    color: root.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.title
    font.bold: true
    rotation: root.iconRotation
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onPressed: function(mouse) {
      root.fine = !!(mouse.modifiers & Qt.ShiftModifier)
      root.shiftSeen(root.fine)
      root.holding = true
    }
    onPositionChanged: function(mouse) {
      var held = !!(mouse.modifiers & Qt.ShiftModifier)
      root.shiftSeen(held)
      if (root.holding) root.fine = held
    }
    onReleased: function(ev) {
      root.holding = false
      root.shiftSeen(!!(ev.modifiers & Qt.ShiftModifier))
    }
    onCanceled: root.holding = false
  }

  Timer {
    interval: 90
    repeat: true
    running: root.holding
    triggeredOnStart: true
    onTriggered: root.tick(root.fine)
  }
}
