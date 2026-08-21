import QtQuick
import QtMultimedia

Item {
  id: root

  property bool active: false
  readonly property bool hasDevice: device !== undefined && device !== null

  MediaDevices {
    id: devices
  }

  readonly property var device: {
    var inputs = devices.videoInputs
    for (var i = 0; i < inputs.length; i++) {
      var label = String(inputs[i].description || "")
      if (label.indexOf("Insta360") !== -1) return inputs[i]
    }
    return inputs.length ? inputs[0] : null
  }

  Rectangle {
    anchors.fill: parent
    color: "#000000"
  }

  CaptureSession {
    camera: Camera {
      id: camera
      cameraDevice: root.device
      active: root.active && root.hasDevice
    }
    videoOutput: view
  }

  VideoOutput {
    id: view
    anchors.fill: parent
    fillMode: VideoOutput.PreserveAspectFit
  }
}
