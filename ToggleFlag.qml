import QtQuick
import Quickshell.Io

// Owns one Omari config's on/off state. Everything it needs ships inside the
// plugin directory: it resolves that directory from its own QML url and runs
// bin/omari-toggle out of it, and that script copies the matching hypr/*.lua
// into Omarchy's toggles directory. So a fresh install is just the plugin
// directory -- flipping the switch applies the config on a machine that has
// never seen Omari before, with nothing to copy into ~/.config/hypr or
// ~/.config/omarchy/bar/scripts first.
//
// Panel.qml instantiates one of these per config ("mode", "overview"), which
// is why the state machine lives here rather than being written twice.
Item {
  id: root

  // "mode" or "overview" -- the suffix in hypr/omari-<name>.lua, the toggles
  // directory's flag file, and the script's own argument.
  required property string flagName

  property bool enabled: false
  property bool loaded: false
  property bool busy: false
  // Empty while healthy; otherwise what went wrong, so the popup can say so
  // instead of silently flipping the switch back. Two slots, because the two
  // failures are independent: a failing status probe means the install itself
  // is broken, a failing toggle means that one attempt failed. Clearing them
  // together would let a probe that still works erase the toggle's message.
  readonly property string error: toggleError || probeError
  property string probeError: ""
  property string toggleError: ""

  // This file sits in the plugin root, so its own directory is the plugin's.
  // Resolving it here rather than hardcoding ~/.config/omarchy/plugins/<id> is
  // what lets the plugin work under any install path or directory name.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    // Qt percent-encodes the url; a path holding a stray '%' would make
    // decodeURIComponent throw, and an undecoded path beats no path at all.
    try { url = decodeURIComponent(url) } catch (e) {}
    return url.replace(/\/+$/, "")
  }

  // Run through bash rather than exec'ing the script directly. The plugin
  // directory can arrive without its executable bits (a zip download, a copy
  // across filesystems), and a script that cannot be exec'd fails to *start*
  // rather than exiting -- precisely the case that used to leave `busy` stuck
  // true and the switch dead until the shell restarted. bash is always there,
  // so a broken install now comes back as an exit code and a stderr message.
  readonly property var toggleCommand: ["bash", root.pluginDir + "/bin/omari-toggle", root.flagName]

  function refresh() {
    if (!statusProbe.running) statusProbe.start()
  }

  function toggle() {
    if (busy) return
    busy = true
    toggleError = ""
    // Flip immediately so the switch tracks the click, then let the script's
    // own answer correct it. The script is the authority on the real state.
    enabled = !enabled
    toggleProcess.start()
  }

  // `exited` and `onStreamFinished` have no guaranteed order, so no single
  // handler can assume it has the other's data. All three record what they
  // were given and call settle(), which commits only once all three have
  // landed. Waiting for the streams rather than reading the collectors at exit
  // also avoids reading text left over from the previous run: a collector
  // holds its last value until the new stream ends.
  QtObject {
    id: probeState
    property string out: ""
    property string err: ""
    property int code: -1
    property bool exited: false
    property bool outDone: false
    property bool errDone: false
    readonly property bool ready: exited && outDone && errDone
  }

  // The script answers "on"/"off" for `status`, so the flag file's path is
  // spelled out in exactly one place instead of being repeated here.
  Process {
    id: statusProbe
    command: root.toggleCommand.concat(["status"])

    function start() {
      probeState.out = ""
      probeState.err = ""
      probeState.code = -1
      probeState.exited = false
      probeState.outDone = false
      probeState.errDone = false
      running = true
    }

    function settle() {
      if (!probeState.ready) return
      var out = probeState.out.trim()
      var err = probeState.err.trim()
      if (probeState.code === 0) {
        root.enabled = out === "on"
        root.probeError = ""
      } else {
        // A failing status probe means the install itself is broken, and
        // saying so on open beats waiting for someone to click a dead switch.
        root.probeError = err || ("omari-toggle " + root.flagName + " status exited " + probeState.code)
      }
      root.loaded = true
    }

    onExited: function(exitCode) {
      probeState.code = exitCode
      probeState.exited = true
      settle()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { probeState.out = String(text); probeState.outDone = true; statusProbe.settle() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { probeState.err = String(text); probeState.errDone = true; statusProbe.settle() }
    }
  }

  QtObject {
    id: toggleState
    property string out: ""
    property string err: ""
    property int code: -1
    property bool exited: false
    property bool outDone: false
    property bool errDone: false
    readonly property bool ready: exited && outDone && errDone
  }

  Process {
    id: toggleProcess
    command: root.toggleCommand.concat(["toggle"])

    function start() {
      toggleState.out = ""
      toggleState.err = ""
      toggleState.code = -1
      toggleState.exited = false
      toggleState.outDone = false
      toggleState.errDone = false
      running = true
    }

    function settle() {
      if (!toggleState.ready) return
      var out = toggleState.out.trim()
      var err = toggleState.err.trim()
      root.busy = false
      if (toggleState.code === 0) {
        root.enabled = out === "on"
        root.toggleError = ""
        root.loaded = true
      } else {
        root.toggleError = err || ("omari-toggle " + root.flagName + " exited " + toggleState.code)
        // The optimistic flip was a guess and the script rejected it; ask what
        // the truth is. The probe only ever touches probeError, so the message
        // just set here survives it.
        root.refresh()
      }
    }

    onExited: function(exitCode) {
      toggleState.code = exitCode
      toggleState.exited = true
      settle()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { toggleState.out = String(text); toggleState.outDone = true; toggleProcess.settle() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { toggleState.err = String(text); toggleState.errDone = true; toggleProcess.settle() }
    }
  }

  // The flag only ever changes because something on this machine ran the
  // toggle script, so a slow poll is purely a safety net for a toggle made
  // outside the bar (the keybinding, the gesture, an edit by hand) -- the
  // popup's own toggles update their state from the script's reply.
  Timer {
    interval: 20000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()
}
