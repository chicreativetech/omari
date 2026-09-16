import QtQuick
import Quickshell
import Quickshell.Io

// Owns one of Omari's own on/off preferences -- the third sibling of
// ToggleFlag and Keybind, and the one that never leaves QML. Read those two
// first; only the differences are spelled out here.
//
// The difference is who is on the other end. A ToggleFlag installs a Hyprland
// config and a Keybind changes the key one of those configs binds, so both are
// a script run and a `hyprctl reload`. A setting like the overview's scroll
// direction is answered entirely inside this shell -- the overview is
// OmariOverview.qml, the popup is Panel.qml, and nothing outside either one
// has an opinion about it. So there is no script: this reads and writes
// ~/.config/omari/settings.conf directly, in the same `key = value` shape
// bin/omari-keybind uses for keybinds.conf next to it, and a hand edit of that
// file is as good as a click in the popup.
//
// The file is also how the two sides reach each other. The popup's widget and
// the overview are separate objects -- and the popup is instantiated once per
// monitor -- with no singleton between them, so the write is the message:
// watchChanges brings every other instance the new value within a frame of it
// landing on disk. That is a round trip through the filesystem for a boolean,
// and it is worth it for a setting flipped by hand a handful of times, in
// exchange for the state living in one place that survives a shell restart.
Item {
  id: root

  // The key in settings.conf. One instance per key, wherever that key is
  // needed: two instances of the same key stay in step through the file.
  required property string settingName

  // What the setting means with the file saying nothing, which is the state
  // every install starts in.
  property bool defaultValue: false

  property bool value: root.defaultValue
  property bool loaded: false

  // Empty while healthy; otherwise why the last save did not land. Only saves
  // can fail in a way worth showing: a missing settings.conf is not an error,
  // it is a fresh install, and reading one is what defaultValue is for.
  property string error: ""

  readonly property string configDir: {
    var base = Quickshell.env("XDG_CONFIG_HOME")
    if (!base) base = Quickshell.env("HOME") + "/.config"
    return base + "/omari"
  }
  readonly property string configPath: root.configDir + "/settings.conf"

  function set(target) {
    if (root.value === target && root.loaded) return
    // Move immediately so the switch tracks the click; the file is still the
    // authority and the reload below corrects this if the write was refused.
    root.value = target
    root.error = ""
    retried = false
    save(target)
  }

  function toggle() {
    root.set(!root.value)
  }

  // Rewrite the file without this key, then append it -- the shape
  // bin/omari-keybind's write_config uses, and for the same reason: a line
  // this version has never heard of, including another setting written by
  // another instance, has to survive a save.
  function save(target) {
    var lines = String(settingsFile.text() || "").split("\n")
    var kept = []
    for (var i = 0; i < lines.length; i++) {
      if (keyOf(lines[i]) === root.settingName) continue
      kept.push(lines[i])
    }
    while (kept.length > 0 && kept[kept.length - 1].trim() === "") kept.pop()
    if (kept.length === 0) {
      kept.push("# Omari settings. Written by the Omari bar popup and read by")
      kept.push("# the overview. Hand edits are picked up as they are saved.")
    }
    kept.push(root.settingName + " = " + (target ? "on" : "off"))
    settingsFile.setText(kept.join("\n") + "\n")
  }

  // The assignment a line makes, or "" for a comment, a blank, or anything
  // else without one. Comments are stripped first so a commented-out
  // assignment is not mistaken for a live one -- in the parser and, more to
  // the point, in save(), which would otherwise drop someone's note.
  function keyOf(line) {
    var text = String(line)
    var hash = text.indexOf("#")
    if (hash >= 0) text = text.substring(0, hash)
    var at = text.indexOf("=")
    if (at < 0) return ""
    return text.substring(0, at).trim()
  }

  // Last assignment wins, as in keybinds.conf, so a file that somehow grew a
  // duplicate reads the same way here as it would there.
  function absorb(text) {
    var lines = String(text || "").split("\n")
    var found = null
    for (var i = 0; i < lines.length; i++) {
      if (keyOf(lines[i]) !== root.settingName) continue
      var at = lines[i].indexOf("=")
      found = lines[i].substring(at + 1).replace(/#.*/, "").trim().toLowerCase()
    }
    if (found === null) root.value = root.defaultValue
    else root.value = found === "on" || found === "true" || found === "1" || found === "yes"
    root.loaded = true
  }

  // A fresh install has no ~/.config/omari at all -- nothing here has run and
  // no shortcut has been saved -- and FileView will not create it. Rather than
  // spend a mkdir at every startup for a directory that exists on every run
  // but the first, let the first save fail and answer that one failure with
  // the mkdir and a retry. One flag, because a second failure is a real one
  // (a read-only home, a file where the directory should be) and retrying
  // forever would just hide it.
  property bool retried: false

  Process {
    id: ensureDir
    command: ["mkdir", "-p", root.configDir]
    onExited: function(exitCode) {
      if (exitCode === 0) root.save(root.value)
      else root.error = "Could not create " + root.configDir
    }
  }

  FileView {
    id: settingsFile
    path: root.configPath
    watchChanges: true
    // The file is rewritten whole, and the overview reads it on the other side
    // of a watch: a torn read would be read as the setting having changed.
    atomicWrites: true
    printErrors: false
    onLoaded: root.absorb(text())
    // Not an error -- see `error` above. The file not being there is the
    // default, and saying so is what makes the first read on a fresh install
    // land on it rather than leaving `loaded` false forever.
    onLoadFailed: root.absorb("")
    onFileChanged: reload()
    onSaved: root.error = ""
    onSaveFailed: {
      if (!root.retried) {
        root.retried = true
        ensureDir.running = true
        return
      }
      root.error = "Could not save " + root.configPath
      // The write was refused, so `value` is a guess about a file that never
      // changed. Ask the file what it actually says.
      reload()
    }
  }
}
