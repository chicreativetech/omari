import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Omari: niri-like scrollable tiling for Omarchy. Bar icon + popup that
// explains what the mode does and carries two independent on/off switches:
// the scrolling-layout mode, and the niri-style overview. The scrolling mode
// lives in ~/.config/hypr/omari-mode.lua (Hyprland's scrolling layout +
// 3-finger swipe + column-aware SUPER+arrows); the overview's gesture lives
// in ~/.config/hypr/omari-overview.lua (4-finger swipe up) and its screen
// lives in Overview.qml, this plugin's "overlay" entry point. This panel
// only flips their toggle flags via
// ~/.config/omarchy/bar/scripts/omari-mode-toggle and
// ~/.config/omarchy/bar/scripts/omari-overview-toggle, which copy/remove
// ~/.local/state/omarchy/toggles/hypr/omari-{mode,overview}.lua and reload.
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
  readonly property string statusText: !modeFlag.loaded ? "Checking status…" : (modeFlag.enabled ? "Omari mode is on" : "Omari mode is off")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    modeFlag.refresh()
    overviewFlag.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  ToggleFlag {
    id: modeFlag
    flagPath: "$HOME/.local/state/omarchy/toggles/hypr/omari-mode.lua"
    toggleScript: "$HOME/.config/omarchy/bar/scripts/omari-mode-toggle"
  }

  ToggleFlag {
    id: overviewFlag
    flagPath: "$HOME/.local/state/omarchy/toggles/hypr/omari-overview.lua"
    toggleScript: "$HOME/.config/omarchy/bar/scripts/omari-overview-toggle"
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return modeFlag.enabled ? "on" : "off" }
    function enable(): string { if (!modeFlag.enabled) modeFlag.toggle(); return "on" }
    function disable(): string { if (modeFlag.enabled) modeFlag.toggle(); return "off" }
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
      }
    }
  }
}
