import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Omari: niri-like scrollable tiling for Omarchy. Bar icon + popup that
// explains what the mode does and carries two independent on/off switches:
// the scrolling-layout mode, and the niri-style overview. The scrolling mode
// is hypr/omari-mode.lua (Hyprland's scrolling layout + 3-finger swipe +
// column-aware SUPER+arrows); the overview's gesture is hypr/omari-overview.lua
// (4-finger swipe up) and its screen is OmariOverview.qml, this plugin's
// "overlay" entry point.
//
// Both lua files ship inside this plugin directory, and each switch runs
// bin/omari-toggle out of that same directory to copy one into
// ~/.local/state/omarchy/toggles/hypr/ and reload Hyprland. Installing the
// plugin is therefore the entire install -- see ToggleFlag.qml, which owns
// one switch's state and locates the script.
Panel {
  id: root
  moduleName: "bergdahlchi.omari"
  ipcTarget: "bergdahlchi.omari"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color iconColor: modeFlag.enabled ? foreground : dim
  readonly property color barIconColor: modeFlag.enabled ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property string modeToggleHint: modeFlag.enabled ? "Turn Omari mode off" : "Turn Omari mode on"
  readonly property string overviewToggleHint: overviewFlag.enabled ? "Turn the overview swipe off" : "Turn the overview swipe on"
  readonly property string statusText: modeFlag.error !== "" ? "Omari mode is unavailable"
    : !modeFlag.loaded ? "Checking status…"
    : (modeFlag.enabled ? "Omari mode is on" : "Omari mode is off")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    modeFlag.refresh()
    overviewFlag.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  ToggleFlag {
    id: modeFlag
    flagName: "mode"
  }

  ToggleFlag {
    id: overviewFlag
    flagName: "overview"
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // Name the state instead of asking modeFlag to flip: `enabled` is false
    // until the first status probe answers, and a caller landing in that
    // window used to make enable() turn the mode off. apply() is idempotent.
    function status(): string { return !modeFlag.loaded ? "unknown" : (modeFlag.enabled ? "on" : "off") }
    function enable(): string { modeFlag.apply(true); return "on" }
    function disable(): string { modeFlag.apply(false); return "off" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        OmariIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) modeFlag.toggle()
      else if (buttonCode === Qt.MiddleButton) { modeFlag.refresh(); overviewFlag.refresh() }
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(420))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: modeFlag.toggle()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "o" || t === "O") modeFlag.toggle()
        else if (t === "v" || t === "V") overviewFlag.toggle()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        PanelHero {
          id: hero
          width: parent.width
          title: "Omari"
          meta: root.statusText
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: modeFlag.enabled ? 1.0 : 0.5
          iconComponent: Component {
            OmariIcon {
              iconSize: Style.font.display
              color: root.iconColor
            }
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        Text {
          width: parent.width
          text: "Omari enables niri-like scrollable tiling in Omarchy: windows scroll along a horizontal tape instead of stacking behind each other. A column can go full width without hiding your other apps behind it — scroll back to them with a three-finger swipe or SUPER+arrows, just like niri."
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Toggle {
          id: modeToggle
          width: parent.width
          label: "Enable Omari mode"
          checked: modeFlag.enabled
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: modeFlag.toggle()
          onHovered: function(isHovered) { modeToggle.isHovering = isHovered }

          property bool isHovering: false

          PanelToolTip {
            visible: modeToggle.isHovering
            text: root.modeToggleHint
            fontFamily: root.fontFamily
          }
        }

        Text {
          width: parent.width
          visible: modeFlag.error !== ""
          text: modeFlag.error
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        PanelSeparator {
          foreground: root.foreground
        }

        Text {
          width: parent.width
          text: "The overview shows every workspace as a row of live window thumbnails, niri-style — scroll down for more workspaces, click a thumbnail to jump to it. Swipe up with 4 fingers to open it, again (or Escape) to close it."
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Toggle {
          id: overviewToggle
          width: parent.width
          label: "Enable overview (4-finger swipe up)"
          checked: overviewFlag.enabled
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: overviewFlag.toggle()
          onHovered: function(isHovered) { overviewToggle.isHovering = isHovered }

          property bool isHovering: false

          PanelToolTip {
            visible: overviewToggle.isHovering
            text: root.overviewToggleHint
            fontFamily: root.fontFamily
          }
        }

        Text {
          width: parent.width
          visible: overviewFlag.error !== ""
          text: overviewFlag.error
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }
}
