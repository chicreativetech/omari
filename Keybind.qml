import QtQuick
import Quickshell.Io

// Owns one configurable Omari shortcut. The sibling of ToggleFlag: same shape,
// same plugin-relative script lookup, same reason for every part of it -- read
// that file first, and only the differences are commented here.
//
// The script is bin/omari-keybind, which stores the binding in
// ~/.config/omari/keybinds.conf and reloads Hyprland. The lua configs read that
// file themselves on load, so saving a shortcut never touches the copy in the
// toggles directory and never needs omari-toggle to run again.
Item {
  id: root

  // "overview" or "alttab": the key in keybinds.conf, and the script's own
  // first argument.
  required property string bindName

  // What is bound now, and what this release ships as the default. Both come
  // from the script -- the default is not spelled here as well, so there is
  // one place it can be changed.
  property string value: ""
  property string defaultValue: ""
  property bool loaded: false
  property bool busy: false

  // Only one slot, unlike ToggleFlag's two. Reading a binding cannot really
  // fail -- a missing config file is the default, not an error -- so the only
  // message worth keeping is the one from a save that was rejected, and that
  // is the one a later probe must not erase.
  property string error: ""

  readonly property bool isDefault: value !== "" && value === defaultValue

  // What prose says while the first probe is still out -- a frame or two at
  // shell start, and the Info tab names both shortcuts in the middle of a
  // sentence. Not a spelled-out default: the point of asking the script for it
  // is that it is written down once.
  readonly property string label: value !== "" ? value : "its shortcut"

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    try { url = decodeURIComponent(url) } catch (e) {}
    return url.replace(/\/+$/, "")
  }

  // bash rather than exec, for the reason ToggleFlag gives: a plugin directory
  // that arrived without its executable bits fails to *start* the script, and
  // a process that never starts never reports anything back.
  readonly property var keybindCommand: ["bash", root.pluginDir + "/bin/omari-keybind", root.bindName]

  function refresh() {
    if (!probe.running) probe.start(["show"])
  }

  // Both saves go through one process and one parser, because the script
  // answers `set` and `reset` in exactly the shape `show` uses.
  function apply(binding) {
    if (busy) return
    busy = true
    error = ""
    saver.start(["set", binding])
  }

  function reset() {
    if (busy) return
    busy = true
    error = ""
    saver.start(["reset"])
  }

  // `value = ...` / `default = ...`, one per line. Tolerant of a line it does
  // not know, so a later version of the script can answer more without this
  // having to be taught each field first.
  function absorb(text) {
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var at = lines[i].indexOf("=")
      if (at < 0) continue
      var key = lines[i].substring(0, at).trim()
      var val = lines[i].substring(at + 1).trim()
      if (key === "value") root.value = val
      else if (key === "default") root.defaultValue = val
    }
  }

  // `exited` and `onStreamFinished` have no guaranteed order, so each run
  // records what it was handed and commits only once all three have landed --
  // the same three-way settle ToggleFlag explains, and for the same reasons.
  component Run: QtObject {
    property string out: ""
    property string err: ""
    property int code: -1
    property bool exited: false
    property bool outDone: false
    property bool errDone: false
    readonly property bool ready: exited && outDone && errDone

    function reset() {
      out = ""
      err = ""
      code = -1
      exited = false
      outDone = false
      errDone = false
    }
  }

  Run { id: probeState }

  Process {
    id: probe

    function start(args) {
      command = root.keybindCommand.concat(args)
      probeState.reset()
      running = true
    }

    function settle() {
      if (!probeState.ready) return
      if (probeState.code === 0) root.absorb(probeState.out)
      root.loaded = true
    }

    onExited: function(exitCode) { probeState.code = exitCode; probeState.exited = true; settle() }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { probeState.out = String(text); probeState.outDone = true; probe.settle() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { probeState.err = String(text); probeState.errDone = true; probe.settle() }
    }
  }

  Run { id: saveState }

  Process {
    id: saver

    function start(args) {
      command = root.keybindCommand.concat(args)
      saveState.reset()
      running = true
    }

    function settle() {
      if (!saveState.ready) return
      root.busy = false
      if (saveState.code === 0) {
        root.absorb(saveState.out)
        root.error = ""
        root.loaded = true
      } else {
        // The script explains a rejected binding on stderr -- "a shortcut needs
        // at least one modifier", and so on -- and that sentence is the whole
        // point of showing an error here, so it is preferred over a code.
        root.error = saveState.err.trim() || ("omari-keybind " + root.bindName + " exited " + saveState.code)
        // Nothing was written, so `value` is still right. Say so, rather than
        // leaving the field showing what the user typed as if it had taken.
        root.refresh()
      }
    }

    onExited: function(exitCode) { saveState.code = exitCode; saveState.exited = true; settle() }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { saveState.out = String(text); saveState.outDone = true; saver.settle() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { saveState.err = String(text); saveState.errDone = true; saver.settle() }
    }
  }

  // Reading the config is a file read, not a compositor round trip, so there
  // is no reason to wait for the popup to open before knowing the answer.
  Component.onCompleted: refresh()
}
