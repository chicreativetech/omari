import QtQuick
import qs.Commons
import qs.Ui

// One row of the popup's Keys tab: a text field holding a shortcut, an OK that
// saves the draft in it, and a Reset that puts the shipped default back. Used
// twice, once per configurable binding -- the state lives in the Keybind it is
// handed. Both buttons are icon-only and sized down from the kit's default
// padding: they sit on the field's own line, and two word-width buttons there
// leave the field too narrow to read a long shortcut in.
//
// Typed rather than captured. A capture field ("press the keys now") cannot
// see the combinations worth binding: the popup holds a keyboard grab, so
// SUPER+ALT+O arrives as whatever the compositor left of it after its own
// binds took their share, and the ones already taken -- exactly the ones a
// user is here to move away from -- are the ones that never arrive at all.
// Typing the combination has no such hole, and bin/omari-keybind is the thing
// that says whether what was typed is a shortcut.
Column {
  id: root

  required property var binding
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  // Panel.qml blocks its PanelKeyCatcher on this. The catcher takes keys
  // before any descendant does, so without it a shortcut could not be typed --
  // "j" would move the cursor rather than land in the field.
  readonly property bool editing: field.activeFocus

  // Escape while typing means "leave the field", not "close the popup", so the
  // panel takes focus back rather than the catcher ever seeing the key.
  signal exitRequested()

  spacing: Style.space(6)

  // The field is a draft until Enter: anything typed sits here, and `binding`
  // is only asked to save on accept. Re-seeded from the binding whenever that
  // changes underneath -- a save landing, a Reset, a rejected save reverting.
  function revert() {
    field.text = root.binding.value
  }

  // Unconditionally, focus or no focus. `value` only ever moves because of
  // something this field asked for, and a save answers in the spelling the
  // script stores rather than the one that was typed -- "super+alt+p" comes
  // back as "SUPER + ALT + P", and the field showing the draft it sent is the
  // field disagreeing with what is actually bound.
  Connections {
    target: root.binding
    function onValueChanged() { root.revert() }
  }

  Component.onCompleted: revert()

  Row {
    width: parent.width
    spacing: Style.space(8)

    TextField {
      id: field
      width: parent.width - okButton.width - resetButton.width - parent.spacing * 2
      foreground: root.foreground
      placeholderText: root.binding.defaultValue

      // Deliberately not disabled while the save is in flight. Disabling takes
      // the field's focus away, which unblocks the panel's key catcher -- and
      // the next keystroke after an Enter would then be a panel mnemonic
      // rather than a character. apply() already ignores a second call while
      // it is busy, which is the whole of what disabling would have bought.
      onAccepted: root.binding.apply(text)
      // Leaving the field without pressing Enter discards the draft. The
      // alternative -- saving on focus loss -- reloads Hyprland for a
      // half-typed shortcut every time the mouse moves away.
      onActiveFocusChanged: if (!activeFocus) root.revert()

      Keys.onEscapePressed: function(event) {
        root.revert()
        root.exitRequested()
        event.accepted = true
      }
    }

    // The mouse half of Enter, and nothing more: same draft, same apply(). It
    // deliberately does not take focus -- Button only grabs it when
    // `focusable`, and a click that pulled focus off the field would trip
    // onActiveFocusChanged and revert the very draft this is here to save.
    Button {
      id: okButton
      iconText: "󰄬"
      tooltipText: "Apply this shortcut"
      bordered: true
      foreground: root.foreground
      // Nothing to apply unless the field disagrees with what is bound. A
      // rejected save reverts the field, so this goes quiet again with it.
      enabled: !root.binding.busy && field.text.trim() !== "" && field.text !== root.binding.value
      opacity: enabled ? 1.0 : 0.45
      fontFamily: root.fontFamily
      iconSize: Style.font.iconSmall
      horizontalPadding: Style.spacing.controlGap
      verticalPadding: Style.spacing.labelGap
      anchors.verticalCenter: parent.verticalCenter
      onClicked: root.binding.apply(field.text)
    }

    Button {
      id: resetButton
      iconText: "󰦛"
      tooltipText: "Put the default shortcut back"
      bordered: true
      foreground: root.foreground
      enabled: !root.binding.busy && !root.binding.isDefault
      opacity: enabled ? 1.0 : 0.45
      fontFamily: root.fontFamily
      iconSize: Style.font.iconSmall
      horizontalPadding: Style.spacing.controlGap
      verticalPadding: Style.spacing.labelGap
      anchors.verticalCenter: parent.verticalCenter
      onClicked: root.binding.reset()
    }
  }

  Text {
    width: parent.width
    // The error replaces the hint rather than stacking under it: a rejected
    // binding has already been reverted in the field, so "press Enter to
    // apply" is not the thing to read next.
    text: root.binding.error !== "" ? root.binding.error
      : "Modifiers and a key, e.g. " + root.binding.defaultValue + ". Press Enter or 󰄬 to apply."
    wrapMode: Text.WordWrap
    color: root.binding.error !== "" ? Color.urgent : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
