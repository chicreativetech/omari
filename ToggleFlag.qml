import QtQuick
import Quickshell.Io

// Owns one on/off state backed by a toggle-flag file's presence: polls for
// the file and shells out to a toggle script that flips it (copy the source
// lua in, or remove it) and reloads Hyprland. Both omari-mode and
// omari-overview use this exact "flag a file, reload" contract, just with
// different flag/script paths, so Panel.qml instantiates this once per mode
// instead of duplicating the state machine.
Item {
  id: root

  required property string flagPath
  required property string toggleScript

  property bool enabled: false
  property bool loaded: false
  property bool busy: false

  function refresh() {
    if (!statusProbe.running) statusProbe.running = true
  }

  function toggle() {
    if (busy) return
    busy = true
    enabled = !enabled
    toggleProcess.running = true
  }

  // `test` already answers "does this file exist" in its exit code, so there
  // is nothing here for a shell to do. The old form ran `bash -lc`, which
  // sourced the user's whole login profile — twice every poll, for the two
  // toggles Panel.qml instantiates, forever.
  Process {
    id: statusProbe
    command: ["test", "-f", root.flagPath]
    onExited: function(exitCode) {
      root.enabled = exitCode === 0
      root.loaded = true
    }
  }

  // The toggle script has its own shebang and is executable; exec it.
  Process {
    id: toggleProcess
    command: [root.toggleScript]
    onExited: {
      root.busy = false
      root.refresh()
    }
  }

  // The flag only ever changes because something on this machine ran a
  // toggle script, so a slow poll is purely a safety net for a toggle made
  // outside the bar (the keybinding, the gesture, an edit by hand) — the
  // popup's own toggles update their state directly.
  Timer {
    interval: 20000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()
}
