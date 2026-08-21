import QtQuick
import qs.Ui
import qs.Commons

BorderSurface {
  id: root

  property string iconText: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property bool holding: false

  signal tick()

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
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onPressed: root.holding = true
    onReleased: root.holding = false
    onCanceled: root.holding = false
  }

  Timer {
    interval: 150
    repeat: true
    running: root.holding
    triggeredOnStart: true
    onTriggered: root.tick()
  }
}
