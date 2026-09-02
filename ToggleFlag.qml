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
// Panel.qml instantiates one per config ("mode", "overview", "alttab"), which
// is why the state machine lives here rather than being written twice.
Item {
  id: root

  // The suffix in hypr/omari-<name>.lua, the toggles
  // directory's flag file, and the script's own argument.
  required property string flagName

  // Emitted once a toggle attempt has landed, whatever it landed on. One
  // script run can change more than one flag -- `mode off` takes the overview
  // and Alt-Tab down with it, `mode on` puts them back -- and the flags that
  // did not run the script have no way to notice. Panel.qml hangs the other
  // two's refresh off the mode flag's copy of this.
  signal settled()

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

  // Ask for a specific state rather than a flip. `enabled` is false until the
  // first status probe lands, so anything arriving in that window -- the IPC
  // enable/disable methods, most of all -- would flip away from the default
  // and turn a config off when it was asked to turn it on. The script's `on`
  // and `off` actions are idempotent, so naming the state we want is always
  // safe, whatever this side happens to believe right now.
  function apply(target) {
    if (busy) return
    busy = true
    toggleError = ""
    // Move the switch immediately so it tracks the click, then let the
    // script's own answer correct it. The script is the authority.
    enabled = target
    toggleProcess.start(target ? "on" : "off")
  }

  // The switch in the popup: the user is acting on the state they can see, so
  // flipping what we are showing is the right request to send.
  function toggle() {
    apply(!enabled)
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

    // Set in start() rather than bound, because the action varies per call.
    function start(action) {
      command = root.toggleCommand.concat([action])
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
      // Also on failure: a cascade that got halfway leaves the other flags
      // wrong on screen, and a failed run is exactly when that is likeliest.
      root.settled()
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

  // Panel.qml refreshes every flag whenever the popup opens. Polling while it
  // is closed used to spawn three bash processes every 20 seconds for the
  // lifetime of the shell, despite there being no visible switch to update.
  // The initial probe below keeps the bar icon correct at startup; the popup
  // open is the synchronization point for changes made externally.
  Component.onCompleted: refresh()
}
