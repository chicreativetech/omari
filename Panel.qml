import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Omari: niri-like scrollable tiling for Omarchy. Bar icon + popup that
// explains what the mode does and carries three independent on/off switches:
// scrolling-layout mode, the niri-style overview, and Alt-Tab. Scrolling mode
// is hypr/omari-mode.lua (Hyprland's scrolling layout + 3-finger swipe +
// column-aware SUPER+arrows + SUPER+PageDown/PageUp workspace switching);
// the overview's gesture is hypr/omari-overview.lua (4-finger swipe up) and
// its screen is OmariOverview.qml, this plugin's "overlay" entry point.
//
// The overview and Alt-Tab switches are shown only while Omari mode is on, and
// their features go down with it -- see bin/omari-toggle, which owns that
// cascade so the CLI and the IPC methods get it too.
// They are three independent toggles, but they are not three independent
// features: the overview draws the scrolling layout's workspaces and Alt-Tab
// is the keyboard half of moving along the same tape, so offering either one
// on a stock Hyprland layout is offering half a thing. With the mode off the
// popup is one paragraph and one switch -- which is also the popup a first
// install opens, and the shortest possible read of what to press first.
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
  readonly property string alttabToggleHint: alttabFlag.enabled ? "Turn the Alt-Tab switcher off" : "Turn the Alt-Tab switcher on"
  readonly property string statusText: modeFlag.error !== "" ? "Omari mode is unavailable"
    : !modeFlag.loaded ? "Checking status…"
    : (modeFlag.enabled ? "Omari mode is on" : "Omari mode is off")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    modeFlag.refresh()
    overviewFlag.refresh()
    alttabFlag.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  ToggleFlag {
    id: modeFlag
    flagName: "mode"
    // bin/omari-toggle takes the overview and Alt-Tab down with the mode, and
    // puts back the ones that were up when it goes back on. Neither of those
    // flags ran the script, so neither knows: re-probe both once the mode's
    // own run has landed. Cheap, and only on an actual toggle -- not the
    // 20-second poll this deliberately does not do.
    onSettled: {
      overviewFlag.refresh()
      alttabFlag.refresh()
    }
  }

  ToggleFlag {
    id: overviewFlag
    flagName: "overview"
  }

  ToggleFlag {
    id: alttabFlag
    flagName: "alttab"
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
      else if (buttonCode === Qt.MiddleButton) { modeFlag.refresh(); overviewFlag.refresh(); alttabFlag.refresh() }
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
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // No height cap. The cap used to be space(420), which fit the popup back
    // when it explained one switch; the overview's paragraph and switch pushed
    // the column past it and the bottom of the content was simply clipped.
    // fittedContentHeight already limits the card to what fits on screen, so
    // asking for the column's own height is both enough and self-adjusting --
    // there is nothing here whose height a fixed number could track.
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: modeFlag.toggle()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        // V and T only while their switches are on screen: a mnemonic for a
        // control nobody can see is a key that changes something invisible.
        if (t === "o" || t === "O") modeFlag.toggle()
        else if ((t === "v" || t === "V") && modeFlag.enabled) overviewFlag.toggle()
        else if ((t === "t" || t === "T") && modeFlag.enabled) alttabFlag.toggle()
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
          text: "Omari enables niri-like scrollable tiling in Omarchy: windows scroll along a horizontal tape instead of stacking behind each other. A column can go full width without hiding your other apps behind it — scroll back to them with a three-finger swipe or SUPER+arrows, just like niri. SUPER+PageDown/PageUp move between workspaces."
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

        // Everything below hangs off Omari mode being on. A Column rather than
        // an Item so the outer Column's spacing still applies inside it, and
        // `visible` rather than a height animation because a Positioner skips
        // invisible children entirely -- the group takes no space and no
        // spacing, and contentHeight (bound to column.implicitHeight) follows
        // it down without anything here having to say a number.
        Column {
          id: overviewSection
          width: parent.width
          spacing: Style.space(14)
          visible: modeFlag.enabled

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
            label: "Enable overview"
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

        Column {
          id: alttabSection
          width: parent.width
          spacing: Style.space(14)
          visible: modeFlag.enabled

          PanelSeparator {
            foreground: root.foreground
          }

          Text {
            width: parent.width
            text: "Alt-Tab becomes niri's window switcher: hold ALT and press Tab to walk a row of live window thumbnails, release to land on one. While it is up, A, W and O narrow the row to all windows, this workspace's, or this monitor's. Replaces Omarchy's ALT+Tab; SUPER+Tab still changes workspace."
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Toggle {
            id: alttabToggle
            width: parent.width
            label: "Enable Alt-Tab switcher"
            checked: alttabFlag.enabled
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: alttabFlag.toggle()
            onHovered: function(isHovered) { alttabToggle.isHovering = isHovered }

            property bool isHovering: false

            PanelToolTip {
              visible: alttabToggle.isHovering
              text: root.alttabToggleHint
              fontFamily: root.fontFamily
            }
          }

          Text {
            width: parent.width
            visible: alttabFlag.error !== ""
            text: alttabFlag.error
            wrapMode: Text.WordWrap
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
