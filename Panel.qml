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
// The popup is two tabs. Info is the whole of what Omari is and what it does:
// the paragraph, the link, and all three switches -- the mode, the overview,
// and Alt-Tab -- each under the sentence that says what it turns on. Keys
// carries the tuning, one section per feature that is switched on: the
// shortcut it answers to, and under the overview's, which way a two-finger
// swipe moves it. The split is between reading what a thing is and adjusting
// how you reach it; whether you want it at all belongs to the first, which is
// the visit that matters most.
//
// The overview and Alt-Tab switches are shown only while Omari mode is on, and
// they follow it: the mode going on turns both on, the mode going off takes
// both down -- see bin/omari-toggle, which owns that cascade so the CLI and
// the IPC methods get it too. Either can still be switched off on its own
// while the mode is up; the next flip of the mode sets them again.
// They are three independent toggles, but they are not three independent
// features: the overview draws the scrolling layout's workspaces and Alt-Tab
// is the keyboard half of moving along the same tape, so offering either one
// on a stock Hyprland layout is offering half a thing.
//
// Both lua files ship inside this plugin directory, and each switch runs
// bin/omari-toggle out of that same directory to copy one into
// ~/.local/state/omarchy/toggles/hypr/ and reload Hyprland. Installing the
// plugin is therefore the entire install -- see ToggleFlag.qml, which owns
// one switch's state and locates the script.
//
// The shortcuts are the other half of that arrangement and deliberately not
// part of it: bin/omari-keybind writes them to ~/.config/omari/keybinds.conf,
// the lua configs read that file on every load, and so a shortcut is a
// `hyprctl reload` rather than a reinstall of the config -- and survives the
// config being switched off and back on. See Keybind.qml and KeybindField.qml.
//
// The overview's scroll direction is neither: it changes nothing outside this
// shell, so it installs nothing and reloads nothing. It is a line in
// ~/.config/omari/settings.conf that OmariOverview.qml watches -- see
// Setting.qml, which is also how this popup and that overview, two objects
// with no singleton between them, say anything to each other at all.
Panel {
  id: root
  moduleName: "bergdahlchi.omari"
  ipcTarget: "bergdahlchi.omari"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Util.alpha(foreground, 0.65)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color iconColor: modeFlag.enabled ? foreground : dim
  readonly property color barIconColor: modeFlag.enabled ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property string modeToggleHint: modeFlag.enabled ? "Turn Omari off" : "Turn Omari on"
  readonly property string overviewToggleHint: overviewFlag.enabled ? "Turn the overview swipe off" : "Turn the overview swipe on"
  readonly property string alttabToggleHint: alttabFlag.enabled ? "Turn the Alt-Tab switcher off" : "Turn the Alt-Tab switcher on"
  // Which way round a swipe reads also depends on the touchpad's own
  // natural-scrolling setting, which is the whole reason this switch exists --
  // so the hint says what the switch does rather than naming a direction it
  // cannot know it will produce.
  readonly property string reverseScrollHint: reverseScrollSetting.value
    ? "Stop reversing two-finger swipes in the overview"
    : "Reverse two-finger swipes in the overview"
  // The link's ink, as something Qt's rich text will actually read. Text's own
  // linkColor property is ignored by this Qt build -- an <a> renders in the
  // stock blue whatever it is set to -- so the colour has to travel inside the
  // markup instead. Alpha forced to 1 because a colour with any other alpha
  // stringifies as #aarrggbb, which the HTML parser does not understand.
  readonly property string linkInk: {
    var c = root.foreground
    return Qt.rgba(c.r, c.g, c.b, 1).toString()
  }

  readonly property string statusText: modeFlag.error !== "" ? "Omari is unavailable"
    : !modeFlag.loaded ? "Checking status…"
    : (modeFlag.enabled ? "Omari is on" : "Omari is off")

  // "info" or "keys". Reset on every open rather than remembered: the popup's
  // first job is still to say what Omari is, and Keys is one click away.
  property string tab: "info"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    root.tab = "info"
    modeFlag.refresh()
    overviewFlag.refresh()
    alttabFlag.refresh()
    overviewKeybind.refresh()
    alttabKeybind.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  ToggleFlag {
    id: modeFlag
    flagName: "mode"
    // bin/omari-toggle turns the overview and Alt-Tab on with the mode and off
    // with it. Neither of those flags ran the script, so neither knows:
    // re-probe both once the mode's own run has landed. Cheap, and only on an
    // actual toggle -- not the 20-second poll this deliberately does not do.
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

  Keybind {
    id: overviewKeybind
    bindName: "overview"
  }

  Keybind {
    id: alttabKeybind
    bindName: "alttab"
  }

  // Not a ToggleFlag and not a Keybind: nothing outside this shell has an
  // opinion about which way a swipe reads, so this installs no config and
  // reloads nothing -- it writes ~/.config/omari/settings.conf, and the
  // overview is watching that file. See Setting.qml.
  Setting {
    id: reverseScrollSetting
    settingName: "overview-reverse-scroll"
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
    contentWidth: panel.fittedContentWidth(Style.space(380) + 200)
    // No height cap. The cap used to be space(420), which fit the popup back
    // when it explained one switch; the overview's paragraph and switch pushed
    // the column past it and the bottom of the content was simply clipped.
    // fittedContentHeight already limits the card to what fits on screen, so
    // asking for the column's own height is both enough and self-adjusting --
    // there is nothing here whose height a fixed number could track. The tabs
    // change that height as they switch, and this follows them for free: a
    // Positioner skips invisible children, so the hidden tab occupies nothing.
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // A shortcut is typed, and this handler takes keys before any descendant
      // does -- so while a field is being edited it has to stand down entirely
      // or "j" would move the cursor instead of landing in the text.
      blocked: overviewKeybindField.editing || alttabKeybindField.editing
      onActivateRequested: modeFlag.toggle()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // Left/right walks the tabs. Tab itself is already the bar's own
      // "next widget's popup", which is a bigger move than this one.
      onMoveRequested: function(dx, dy) {
        if (dx > 0) root.tab = "keys"
        else if (dx < 0) root.tab = "info"
      }
      onTextKey: function(t) {
        // Each letter only while the switch it names is on screen: a mnemonic
        // for a switch nobody can see is a key that changes something
        // invisible. All three live in Info now, so V and T ask for that tab
        // as well as for the mode; O needs no guard because Info is where the
        // popup opens and the mode's own switch is never hidden.
        if (t === "i" || t === "I") root.tab = "info"
        else if (t === "y" || t === "Y") root.tab = "keys"
        else if (t === "o" || t === "O") modeFlag.toggle()
        else if ((t === "v" || t === "V") && modeFlag.enabled && root.tab === "info") overviewFlag.toggle()
        else if ((t === "t" || t === "T") && modeFlag.enabled && root.tab === "info") alttabFlag.toggle()
        // R only where its switch is, which is the one place the overview's
        // scroll direction can be seen: Keys, with the overview switched on.
        else if ((t === "r" || t === "R") && overviewKeysSection.visible && root.tab === "keys") reverseScrollSetting.toggle()
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

        // The tab row sits above the separator so the rule reads as the top of
        // whichever tab is showing rather than as a line under the header.
        ButtonGroup {
          id: tabs
          options: [
            { value: "info", label: "Info", tooltip: "What Omari is, and its switches" },
            { value: "keys", label: "Keys", tooltip: "Shortcuts" }
          ]
          value: root.tab
          foreground: root.foreground
          fontFamily: root.fontFamily
          // The popup drives its own cursor and never hands Tab focus to a
          // control, so the group is not a stop in a chain that does not exist.
          focusable: false
          onChanged: function(value) { root.tab = value }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        // ------------------------------------------------------------- Info
        Column {
          id: infoTab
          width: parent.width
          spacing: Style.space(14)
          visible: root.tab === "info"

          Text {
            width: parent.width
            text: "Omari brings a Niri-style scrolling workflow to Omarchy.\n\nOmari builds on Omarchy’s existing scrolling layout and enhances it to feel smoother, more natural, and much closer to the Niri experience."
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            // Full-strength foreground rather than the accent: the underline
            // Qt gives an <a> is already enough to say it is a link, and the
            // accent made one line of ordinary prose louder than the switch
            // underneath it, which is the thing to look at. Brighter than the
            // paragraph above it, which is the dim body ink, so the one line
            // worth clicking still reads as the one line worth clicking.
            //
            // Spelled into the markup rather than set with linkColor, which
            // this Qt build ignores -- see root.linkInk.
            text: '<a href="https://github.com/chicreativetech/omari#keyboard-shortcuts" style="color:'
              + root.linkInk + '">Omari controls</a>'
            textFormat: Text.RichText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onLinkActivated: function(link) { Qt.openUrlExternally(link) }

            HoverHandler {
              cursorShape: Qt.PointingHandCursor
            }
          }

          Toggle {
            id: modeToggle
            width: parent.width
            label: "Enable Omari"
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

          // Everything below hangs off Omari mode being on. A Column rather
          // than an Item so the outer Column's spacing still applies inside
          // it, and `visible` rather than a height animation because a
          // Positioner skips invisible children entirely -- the group takes no
          // space and no spacing, and contentHeight (bound to
          // column.implicitHeight) follows it down without anything here
          // having to say a number.
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
              text: "Overview"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              width: parent.width
              text: "Niri’s Overview mode is available in Omari with " + overviewKeybind.label
                + " or a 4-finger swipe up on the trackpad. It gives you a zoomed-out view of all open applications across your workspaces."
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Toggle {
              id: overviewToggle
              width: parent.width
              label: "Enable Overview mode"
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
              text: "ALT+TAB"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              width: parent.width
              text: "Omari also includes a Niri-inspired switcher on " + alttabKeybind.label
                + " for quickly switching between applications. You can show all applications or limit the view to the current workspace or output."
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Toggle {
              id: alttabToggle
              width: parent.width
              label: "Enable Niri-style ALT+TAB"
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

        // ------------------------------------------------------------- Keys
        Column {
          id: keysTab
          width: parent.width
          spacing: Style.space(14)
          visible: root.tab === "keys"

          // A shortcut only exists for a config that is installed, so this tab
          // shows a field per feature that is actually on -- and when none is,
          // it says where the switches are rather than standing empty, which
          // reads as a tab that is broken.
          Text {
            width: parent.width
            visible: !modeFlag.enabled
            text: "Turn Omari on in the Info tab to choose the shortcuts for the overview and the Alt-Tab switcher."
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            visible: modeFlag.enabled && !overviewFlag.enabled && !alttabFlag.enabled
            text: "Switch the overview or the Alt-Tab switcher on in the Info tab to give it a shortcut."
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // The binding is stored either way -- turning the overview back on
          // brings its shortcut back with it -- but a field for a config that
          // is not installed is a control with nothing on the other end of it.
          Column {
            id: overviewKeysSection
            width: parent.width
            spacing: Style.space(14)
            visible: modeFlag.enabled && overviewFlag.enabled

            Text {
              width: parent.width
              text: "Overview"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            KeybindField {
              id: overviewKeybindField
              width: parent.width
              binding: overviewKeybind
              foreground: root.foreground
              dim: root.dim
              fontFamily: root.fontFamily
              onExitRequested: keyCatcher.forceActiveFocus()
            }

            // The one setting in this tab that is not a key, and it is here
            // rather than in Info for the reason the tabs are split at all:
            // Info says what the overview is and whether you want it, Keys is
            // where you tune how you reach it, and which way two fingers move
            // it is the same kind of choice as which keys open it.
            Toggle {
              id: reverseScrollToggle
              width: parent.width
              label: "Reverse scroll direction in overview"
              checked: reverseScrollSetting.value
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: reverseScrollSetting.toggle()
              onHovered: function(isHovered) { reverseScrollToggle.isHovering = isHovered }

              property bool isHovering: false

              PanelToolTip {
                visible: reverseScrollToggle.isHovering
                text: root.reverseScrollHint
                fontFamily: root.fontFamily
              }
            }

            Text {
              width: parent.width
              visible: reverseScrollSetting.error !== ""
              text: reverseScrollSetting.error
              wrapMode: Text.WordWrap
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Column {
            id: alttabKeysSection
            width: parent.width
            spacing: Style.space(14)
            visible: modeFlag.enabled && alttabFlag.enabled

            // Only a rule between two sections, never above the first one:
            // with the overview off, Alt-Tab's heading is the top of the tab.
            PanelSeparator {
              visible: overviewKeysSection.visible
              foreground: root.foreground
            }

            Text {
              width: parent.width
              text: "ALT+TAB"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            KeybindField {
              id: alttabKeybindField
              width: parent.width
              binding: alttabKeybind
              foreground: root.foreground
              dim: root.dim
              fontFamily: root.fontFamily
              onExitRequested: keyCatcher.forceActiveFocus()
            }
          }
        }
      }
    }
  }
}
