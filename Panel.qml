import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Omari: niri-like scrollable tiling for Omarchy. Bar icon + popup that
// explains what the mode does and carries a single on/off switch. The
// actual mode lives in ~/.config/hypr/omari-mode.lua (Hyprland's scrolling
// layout + 3-finger swipe + column-aware SUPER+arrows); this panel only
// toggles it via ~/.config/omarchy/bar/scripts/omari-mode-toggle, which
// flips ~/.local/state/omarchy/toggles/hypr/omari-mode.lua and reloads.
Panel {
  id: root
  moduleName: "bergdahlchi.omari"
  ipcTarget: "bergdahlchi.omari"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color iconColor: omari.enabled ? foreground : dim
  readonly property color barIconColor: omari.enabled ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property string toggleHint: omari.enabled ? "Turn Omari mode off" : "Turn Omari mode on"
  readonly property string statusText: !omari.loaded ? "Checking status…" : (omari.enabled ? "Omari mode is on" : "Omari mode is off")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    omari.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Owns the on/off state: polls the toggle flag file's presence and shells
  // out to the toggle script, same "flip a file, reload" contract the
  // script and omari-mode.lua already use.
  Item {
    id: omari

    property bool enabled: false
    property bool loaded: false
    property bool busy: false

    function refresh() {
      if (!statusProbe.running) statusProbe.running = true
    }

    function toggleOmari() {
      if (busy) return
      busy = true
      enabled = !enabled
      toggleProcess.running = true
    }

    Process {
      id: statusProbe
      command: ["bash", "-lc", "test -f \"$HOME/.local/state/omarchy/toggles/hypr/omari-mode.lua\" && echo on || echo off"]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          omari.enabled = text.trim() === "on"
          omari.loaded = true
        }
      }
    }

    Process {
      id: toggleProcess
      command: ["bash", "-lc", "\"$HOME/.config/omarchy/bar/scripts/omari-mode-toggle\""]
      onExited: {
        omari.busy = false
        omari.refresh()
      }
    }

    Timer {
      interval: 5000
      running: true
      repeat: true
      onTriggered: omari.refresh()
    }

    Component.onCompleted: refresh()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return omari.enabled ? "on" : "off" }
    function enable(): string { if (!omari.enabled) omari.toggleOmari(); return "on" }
    function disable(): string { if (omari.enabled) omari.toggleOmari(); return "off" }
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
      if (buttonCode === Qt.RightButton) omari.toggleOmari()
      else if (buttonCode === Qt.MiddleButton) omari.refresh()
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
      onActivateRequested: omari.toggleOmari()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "o" || t === "O") omari.toggleOmari()
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
          iconOpacity: omari.enabled ? 1.0 : 0.5
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
          checked: omari.enabled
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: omari.toggleOmari()
          onHovered: function(isHovered) { modeToggle.isHovering = isHovered }

          property bool isHovering: false

          PanelToolTip {
            visible: modeToggle.isHovering
            text: root.toggleHint
            fontFamily: root.fontFamily
          }
        }
      }
    }
  }
}
