import QtQuick
import qs.Commons

// Three vertical "columns" on a tape, the focused (middle) one wider and at
// full opacity, the neighbors dimmed slivers -- the scrollable-tiling shape
// Omari mode puts Hyprland into. Drawn natively (like TailscaleIcon) rather
// than relying on a Nerd Font glyph, so the bar slot never renders a tofu box.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real colH: root.iconSize * 0.86
  readonly property real gap: Math.max(1, root.iconSize * 0.09)
  readonly property real sideW: root.iconSize * 0.2
  readonly property real midW: Math.max(1, root.iconSize - sideW * 2 - gap * 2)
  readonly property real rad: Math.max(1, root.iconSize * 0.12)

  Column1 {
    x: 0
    width: root.sideW
    opacity: 0.35
  }

  Column1 {
    x: root.sideW + root.gap
    width: root.midW
  }

  Column1 {
    x: root.iconSize - root.sideW
    width: root.sideW
    opacity: 0.35
  }

  component Column1: Rectangle {
    anchors.verticalCenter: parent.verticalCenter
    height: root.colH
    radius: root.rad
    color: root.color
  }
}
