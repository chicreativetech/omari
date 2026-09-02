import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

// Omari Alt-Tab: niri's window switcher.
//
// One long row of live window thumbnails, most-recently-used first, held up
// for exactly as long as the ALT that opened it is held down. Tab walks along
// the row, releasing ALT focuses whatever it stopped on, and A/W/O narrow the
// row to all windows, this workspace's, or this monitor's.
//
// ALT and only ALT. The switcher used to open on SUPER+TAB as well, and the
// scope filter could not work there: SUPER+A/W/O are Omarchy's own binds, so
// the compositor ate the three keys that make this niri's switcher rather than
// a nicer ALT+TAB. See hypr/omari-alttab.lua.
//
// Instantiated by OmariOverview.qml rather than being an entry point of its
// own: Omarchy's plugin host mounts exactly one Loader per plugin id (see
// shell.qml's computePanelEntries), so a plugin gets one overlay, and Omari's
// is already the overview. Nothing here goes through the host's summon/hide
// anyway -- the switcher opens on a `custom>>` line from hypr/omari-alttab.lua
// and closes on the modifier coming back up, and neither of those is a thing
// the host knows how to say. It is deliberately not wired into root.opened
// either: the host reads that property to decide whether the *overview* is up.
Item {
  id: root

  // The overview instance that owns this one, so the switcher can refuse to
  // open on top of it. Both are full-screen surfaces that take an exclusive
  // keyboard grab, and ALT+TAB is a compositor keybind that fires whoever has
  // the keyboard -- so without this, opening one over the other is a keypress
  // away, and the one that loses the grab never sees the release that would
  // have closed it.
  property var overview: null

  // ---- session state ----
  //
  // A "session" is one press-and-hold of ALT. It starts on the first
  // `omari:alttab step` event, and ends when ALT is released, which commits,
  // or on Escape/a click, which does not.
  property bool active: false
  property bool leaving: false

  // Whether the surface is showing anything at all. The layer surface itself
  // stays mapped for the life of the shell -- see panel.visible -- so "is the
  // window up" is not the same question as "is the switcher up", and
  // everything that means the second one asks this.
  readonly property bool surfaceLive: root.active || root.leaving

  // ---- the capture scheduler ----
  //
  // The same mechanism as OmariOverview.qml's, and for the same reason: a
  // live ScreencopyView re-arms itself from its own repaint, so a card that
  // is merely on screen renders at the display's refresh rate for as long as
  // the switcher is up, whether or not the window in it has changed. A
  // switcher held open on ALT for a few seconds was doing that for every card
  // in the row at once.
  //
  // Smaller and simpler than the overview's, because the surfaces are: there
  // is no zoom, no mipmapped layer, and nothing here is watched -- a switcher
  // is looked at to tell windows apart, not to see what they are doing. One
  // reasonably fresh picture per card is the whole requirement.
  readonly property real captureBudget: 12
  readonly property int captureCooldownMs: 1500
  property real captureTokens: 0

  // A Timer, never a FrameAnimation: a FrameAnimation asks the renderer for a
  // frame on every frame, which would hold the render loop up at exactly the
  // rate this exists to stop. See the longer note in OmariOverview.qml.
  Timer {
    id: captureTick
    interval: 80
    repeat: true
    running: root.surfaceLive
    onTriggered: root.captureTock()
  }

  // Blank first, then stalest. A card that has never been captured is drawn
  // as an empty rectangle, so it is worth jumping the queue for; everything
  // else already has a picture and is only being freshened.
  function captureNext() {
    var now = Date.now()
    var blank = null
    var stale = null, staleAge = -1
    for (var i = 0; i < cards.count; i++) {
      var c = cards.itemAt(i)
      if (!c || !c.requestCapture || !c.near) continue
      if (!c.hasPicture) { if (!blank) blank = c; continue }
      var age = now - c.lastCaptureMs
      if (age >= root.captureCooldownMs && age > staleAge) { staleAge = age; stale = c }
    }
    return blank || stale
  }

  function captureTock() {
    if (!root.surfaceLive || root.leaving) return
    root.captureTokens = Math.min(1, root.captureTokens + root.captureBudget * (captureTick.interval / 1000))
    if (root.captureTokens < 1) return
    var c = root.captureNext()
    if (!c) return
    root.captureTokens -= 1
    c.requestCapture()
  }

  // "all" | "workspace" | "output" -- niri's three scopes, on A, W and O.
  property string scope: "all"
  property int selected: 0

  // The row, snapshotted when the session opens and not rebuilt while it is
  // up. A switcher whose list re-sorts under the fingers is a switcher that
  // lands you somewhere you did not aim at: Tab moves an *index*, and every
  // window title change, geometry event or focus renumber in Hyprland would
  // otherwise move the row out from under it. Windows that close mid-session
  // are dropped at draw time instead; see entryAlive.
  property var entries: []

  // The workspace and monitor the session opened on, so W and O keep meaning
  // what they meant when the row was taken even if focus wanders.
  property int sessionWorkspaceId: -1
  property int sessionMonitorId: -1

  property real exitOpacity: 1
  property bool grabsKeyboard: false

  // ---- most-recently-used order ----
  //
  // Alt-Tab is a list in focus order, and Hyprland's own `focusHistoryID` is
  // only as fresh as the last time Quickshell re-read every client -- it is
  // renumbered on every focus change, and no event announces the renumber, so
  // reading it at the instant the switcher opens can hand back an order one or
  // more focus changes stale. That is invisible in the overview, which uses it
  // to decide which thumbnail wears a ring; here it is the whole list, and
  // "the window I was just on" being in the wrong place makes the feature
  // useless.
  //
  // So the order is kept here instead, off the one thing that is announced:
  // the active toplevel changing. `focusHistoryID` still seeds the tail --
  // windows that have not been focused since the shell started have never been
  // seen by this and have to be ordered somehow -- but everything the shell
  // has actually watched happen is ordered by what it watched.
  property var mru: []

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() { root.noteFocus(Hyprland.activeToplevel) }
  }

  Component.onCompleted: {
    root.targetScreen = root.pickScreen()
    root.noteFocus(Hyprland.activeToplevel)
  }

  function addressOf(toplevel) {
    var ipc = toplevel && toplevel.lastIpcObject
    return (ipc && ipc.address) ? String(ipc.address) : ""
  }

  function noteFocus(toplevel) {
    var address = root.addressOf(toplevel)
    if (address === "") return
    if (root.mru.length > 0 && root.mru[0] === address) return
    var next = [address]
    for (var i = 0; i < root.mru.length; i++) {
      if (root.mru[i] !== address) next.push(root.mru[i])
    }
    // Unbounded growth is not a risk worth code: an entry is one short string
    // per window ever focused in this shell session, and closed windows fall
    // out of the row anyway because they are no longer toplevels.
    root.mru = next
  }

  // ---- the row ----

  // Every open window, most recently focused first. Plain objects rather than
  // the toplevels themselves: the geometry, workspace and monitor a scope
  // filter reads all have to be the values they had when the session opened,
  // and the toplevel is only kept alongside them for its thumbnail.
  function snapshot() {
    var values = (Hyprland.toplevels && Hyprland.toplevels.values) ? Hyprland.toplevels.values : []
    var out = []
    for (var i = 0; i < values.length; i++) {
      var toplevel = values[i]
      var ipc = toplevel ? toplevel.lastIpcObject : null
      if (!ipc || !ipc.address) continue
      var size = ipc.size
      var w = (size && size.length >= 2) ? Number(size[0]) : 0
      var h = (size && size.length >= 2) ? Number(size[1]) : 0
      var aspect = (isFinite(w) && isFinite(h) && w > 0 && h > 0) ? (w / h) : (16 / 9)
      var address = String(ipc.address)
      var rank = root.mru.indexOf(address)
      var history = Number(ipc.focusHistoryID)
      out.push({
        toplevel: toplevel,
        address: address,
        title: String(ipc.title || ""),
        workspaceId: ipc.workspace ? Number(ipc.workspace.id) : 0,
        monitorId: Number(ipc.monitor),
        // Clamped, because the row is laid out from this. One 5:1 terminal
        // strip is allowed to be the widest thing in the row; it is not
        // allowed to be the only thing that fits on screen.
        aspect: Math.max(0.4, Math.min(3.2, aspect)),
        // Windows the shell has watched get focus sort by when that happened;
        // the rest keep Hyprland's own relative order, behind all of them.
        order: rank >= 0 ? rank : root.mru.length + (isFinite(history) ? history : 9999)
      })
    }
    out.sort(function(a, b) { return a.order - b.order })
    return out
  }

  // A window that closed while the switcher was up. Its snapshot entry is
  // still in the frozen row, but the toplevel behind it is gone, and asking a
  // destroyed object for a capture source is how a switcher takes the shell
  // down with it.
  function entryAlive(entry) {
    return !!(entry && entry.toplevel && entry.toplevel.wayland)
  }

  // A function rather than only a binding, because both the binding below and
  // the imperative code that has just assigned `entries` or `scope` need the
  // same answer -- and the second cannot wait for a binding to catch up.
  function filtered(list, scope) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (!root.entryAlive(entry)) continue
      if (scope === "workspace" && entry.workspaceId !== root.sessionWorkspaceId) continue
      if (scope === "output" && entry.monitorId !== root.sessionMonitorId) continue
      out.push(entry)
    }
    return out
  }

  readonly property var visibleEntries: root.filtered(root.entries, root.scope)
  readonly property int count: root.visibleEntries.length

  function currentEntry() {
    var list = root.visibleEntries
    if (list.length === 0) return null
    return list[Math.max(0, Math.min(list.length - 1, root.selected))]
  }

  // ---- opening, stepping, closing ----

  // The event from hypr/omari-alttab.lua, whether or not a session is already
  // up: the first one opens the switcher, every one after it walks the row.
  function step(dir) {
    if (!root.active) { root.begin(dir); return }
    if (root.count === 0) return
    var delta = (dir === "prev") ? -1 : 1
    root.selected = ((root.selected + delta) % root.count + root.count) % root.count
  }

  function begin(dir) {
    if (root.overview && root.overview.opened) return
    // Fresh geometry and titles for the row about to be drawn. Asynchronous,
    // so the row is built from what is already known and corrects itself a
    // frame or two later -- which moves thumbnails by a pixel, and never
    // moves the *order*, because that comes from `mru` and not from this.
    Hyprland.refreshToplevels()

    var workspace = Hyprland.focusedWorkspace
    var monitor = Hyprland.focusedMonitor
    root.sessionWorkspaceId = workspace ? Number(workspace.id) : -1
    root.sessionMonitorId = monitor ? Number(monitor.id) : -1

    root.scope = "all"
    root.entries = root.snapshot()

    var list = root.filtered(root.entries, "all")
    // Nothing to switch between is not worth a full-screen overlay. The lua
    // side is told, so its watchdog stops polling for a release that is not
    // holding anything up.
    if (list.length === 0) { root.entries = []; root.notifyClosed(); return }

    // Where a switcher starts is the whole convention: one tap of ALT+TAB goes
    // to the window you were on before this one, which is index 1 in a list
    // that starts at the window you are on now. Backwards starts at the end of
    // the row, which is the least recently used window.
    root.selected = (dir === "prev") ? (list.length - 1) : (list.length > 1 ? 1 : 0)

    root.targetScreen = root.pickScreen()
    exitFade.stop()
    root.exitOpacity = 1
    root.grabsKeyboard = true
    // `active` up before `leaving` comes down, so surfaceLive never reads
    // false for the width of two statements -- see panel.visible.
    root.active = true
    root.leaving = false
    strip.settleNow()
  }

  function move(delta) {
    if (!root.active || root.count === 0) return
    root.selected = ((root.selected + delta) % root.count + root.count) % root.count
  }

  // A/W/O. The window that was selected stays selected if the new scope still
  // contains it -- narrowing to "this workspace" while pointing at a window on
  // this workspace should not move the aim -- and otherwise the index is
  // clamped into the shorter row.
  function setScope(next) {
    if (!root.active || next === root.scope) return
    var before = root.currentEntry()
    var list = root.filtered(root.entries, next)
    root.scope = next
    if (list.length === 0) { root.selected = 0; return }
    var index = -1
    if (before) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].address === before.address) { index = i; break }
      }
    }
    root.selected = index >= 0 ? index : Math.max(0, Math.min(list.length - 1, root.selected))
  }

  // Releasing the modifier, pressing Enter, or clicking a thumbnail.
  function commit(entry) {
    if (!root.active) return
    var target = entry || root.currentEntry()
    root.notifyClosed()
    if (!target) { root.dismiss(); return }
    root.beginHandOff("hl.dsp.focus({ window = 'address:" + target.address + "' })")
  }

  // Escape, or a click past the row. Leaves the desktop exactly as it found
  // it -- the same distinction the overview draws between close() and
  // dismiss().
  function dismiss() {
    if (!root.surfaceLive) return
    root.notifyClosed()
    root.leaving = true
    root.active = false
    root.grabsKeyboard = false
    exitFade.restart()
  }

  function finish() {
    root.leaving = false
    root.exitOpacity = 1
    root.entries = []
    root.selected = 0
    root.scope = "all"
  }

  NumberAnimation {
    id: exitFade
    target: root
    property: "exitOpacity"
    from: 1
    to: 0
    duration: 110
    easing.type: Easing.OutQuad
    onFinished: root.finish()
  }

  // ---- handing the desktop back ----
  //
  // Exactly the dance OmariOverview.beginHandOff describes, and for exactly
  // its reason: giving up an exclusive keyboard grab makes Hyprland restore
  // focus to whatever held it before, about 40ms later, and a focus dispatch
  // sent in the same breath as the release is not ignored but *overwritten*.
  // So the grab goes back first, the restore is waited out, and only then does
  // the switch go out -- with the overlay still drawn over the whole thing, so
  // none of it is seen.
  property string pendingDispatch: ""

  function beginHandOff(arg) {
    root.leaving = true
    root.active = false
    root.grabsKeyboard = false
    root.pendingDispatch = arg
    restoreFallback.restart()
  }

  Connections {
    target: Hyprland
    enabled: root.pendingDispatch !== ""
    function onRawEvent(event) {
      if (event.name === "activewindow" || event.name === "activewindowv2"
        || event.name === "workspace" || event.name === "workspacev2") {
        root.runPendingDispatch()
      }
    }
  }

  // Backstop for the restore being a no-op and no event coming -- committing
  // onto the window you were already on, most of all.
  Timer {
    id: restoreFallback
    interval: 90
    onTriggered: root.runPendingDispatch()
  }

  function runPendingDispatch() {
    if (root.pendingDispatch === "") return
    var arg = root.pendingDispatch
    root.pendingDispatch = ""
    restoreFallback.stop()
    root.hyprSend("dispatch " + arg)
    exitFade.restart()
  }

  // ---- Hyprland request socket ----
  //
  // Fire and forget: nothing here needs an answer, and both things it sends
  // are one line. Down Hyprland's own socket rather than spawned as `hyprctl`
  // for the reason OmariOverview gives -- sub-millisecond against ~10ms, and
  // no process at all on a path the eye is following.
  property string hyprRequest: ""

  Socket {
    id: hyprIpc
    path: Hyprland.requestSocketPath
    onConnectionStateChanged: {
      if (!hyprIpc.connected) return
      hyprIpc.write(root.hyprRequest)
      hyprIpc.flush()
    }
  }

  function hyprSend(request) {
    root.hyprRequest = request
    if (hyprIpc.connected) hyprIpc.connected = false
    hyprIpc.connected = true
  }

  // Tell the compositor half that this session is over, so its release
  // watchdog stops polling. `hyprctl dispatch` evaluates its argument as
  // `hl.dispatch(<expr>)`, which is why omari_alttab_closed() hands back a
  // no-op dispatcher. Harmless when the toggle is off and the function does
  // not exist: Hyprland logs a lua error and nothing else happens -- and a
  // session cannot be open in the first place unless that file ran.
  function notifyClosed() {
    root.hyprSend("dispatch omari_alttab_closed()")
  }

  // ---- events from hypr/omari-alttab.lua ----
  //
  // `custom` is what hl.dsp.event puts on the socket, and every shell on the
  // machine sees all of them -- hence the prefix test before anything is
  // parsed. Not gated on `active`: the event that opens the switcher arrives
  // while it is down, which is the entire point of it.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "custom") return
      var data = String(event.data || "")
      if (data.indexOf("omari:alttab ") !== 0) return
      var parts = data.split(" ")
      switch (parts[1]) {
      case "step":
        root.step(parts[2])
        break
      case "commit":
        root.commit(null)
        break
      }
    }
  }

  // ---- which screen ----
  //
  // The switcher belongs on the monitor you are looking at, and O ("this
  // output") only means anything if it agrees with where the row is drawn.
  // Resolved when a session opens rather than bound live, so the surface is
  // never moved between monitors while it is on screen -- Quickshell remaps a
  // layer surface to change its output, and a remap costs frames the switcher
  // does not have. On a single-monitor machine it never changes at all.
  property var targetScreen: null

  function pickScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name) : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === name) return screens[i]
    }
    return root.targetScreen
  }

  PanelWindow {
    id: panel
    // Mapped once, at shell start, and never unmapped -- the same trade
    // OmariOverview.panel spells out, for a sharper reason. Mapping a
    // full-screen layer surface costs two frames of ~200ms, and a switcher
    // that appears a third of a second after the key that asked for it is one
    // you stop reaching for. Nothing is drawn, clickable or focusable while
    // the switcher is down; see the layer, the mask, and `visible` below.
    visible: true
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omari-alttab"
    // Overlay only while it is showing something. A mapped overlay layer costs
    // its monitor direct scanout even when it draws nothing -- Hyprland's
    // isSolitaryBlocked only asks whether the overlay list is empty, not
    // whether anything in it is opaque -- so parking it on the background
    // layer is what makes an always-mapped surface affordable. Quickshell
    // applies the change as a plain set_layer on the surface that is already
    // up, not as a remap.
    WlrLayershell.layer: root.surfaceLive ? WlrLayer.Overlay : WlrLayer.Background
    // The grab is what delivers the modifier release that ends the session --
    // see Keys.onReleased. Dropped the instant the switcher starts leaving, by
    // either route, because the focus dispatch has to go out behind it rather
    // than in front of it (see beginHandOff).
    WlrLayershell.keyboardFocus: (root.surfaceLive && root.grabsKeyboard)
      ? WlrKeyboardFocus.Exclusive
      : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // An empty region is the documented way to ask for "nothing here is
    // clickable": Quickshell sets Qt::WindowTransparentForInput for a mask
    // that is present but empty, and treats a null mask as the whole window.
    // Without it the desktop under this would stop taking clicks the moment
    // the shell started.
    property Region noInput: Region {}
    mask: root.surfaceLive ? null : panel.noInput

    // ---- geometry ----
    //
    // Ratios of the screen rather than Style.space() pixel counts, for the
    // reason OmariOverview.rowHeight gives: what a switcher is for is showing
    // enough of a window to recognise it, and that is inherently a fraction of
    // the display, not a number that means one thing on a laptop panel and
    // another on a 32" monitor.
    readonly property real tileHeight: Math.max(Style.space(96), Math.round(panel.height * 0.24))
    readonly property real selectedTileHeight: Math.round(panel.tileHeight * 1.24)
    readonly property real cardPadding: Style.space(10)
    readonly property real tileGap: Style.space(26)
    readonly property real titleGap: Style.space(16)
    readonly property real titleHeight: Math.round(Style.font.subtitle * 1.5)
    // Every card is bottom-aligned inside a band tall enough for the biggest
    // one, so the titles under them share a baseline and only the selected
    // card grows upward. A row whose captions bob up and down as the selection
    // moves is a row you cannot read while it is moving.
    readonly property real bandHeight: panel.selectedTileHeight + 2 * panel.cardPadding
    readonly property real stripHeight: panel.bandHeight + panel.titleGap + panel.titleHeight
    // A window narrower than this still gets a caption worth reading.
    readonly property real minCardWidth: Style.space(120)

    function cardWidthAt(index) {
      var list = root.visibleEntries
      var entry = list[index]
      if (!entry) return 0
      var h = (index === root.selected) ? panel.selectedTileHeight : panel.tileHeight
      return Math.max(panel.minCardWidth, Math.round(h * entry.aspect) + 2 * panel.cardPadding)
    }

    function cardXAt(index) {
      var x = 0
      for (var i = 0; i < index; i++) x += panel.cardWidthAt(i) + panel.tileGap
      return x
    }

    readonly property real stripWidth: {
      var n = root.count
      if (n === 0) return 0
      return panel.cardXAt(n - 1) + panel.cardWidthAt(n - 1)
    }

    Rectangle {
      anchors.fill: parent
      visible: root.surfaceLive
      // Dimmed, not opaque. Unlike the overview -- which replaces the desktop
      // with a scaled replica of it and needs a backdrop the replica can be
      // told apart from -- the switcher is drawn *over* the desktop it is
      // about to move you around, and seeing where you are is half of knowing
      // where you are going.
      //
      // Darkened well past Color.background rather than being it. A scrim the
      // colour of the theme's own background is invisible over every window
      // that uses that background, which on this desktop is most of them: at
      // 0.8 over a Nord terminal it measured a brightness change of under one
      // level. What the dim is for is pushing the whole desktop behind the
      // row, so it has to go somewhere the desktop is not.
      color: Util.alpha(Qt.darker(Color.background, 2.4), 0.8)
      opacity: root.exitOpacity
    }

    // Clicking past the row is a cancel: nothing was aimed at.
    MouseArea {
      anchors.fill: parent
      visible: root.surfaceLive
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      visible: root.surfaceLive
      focus: root.active
      opacity: root.exitOpacity

      // TAB itself is not here. Hyprland's own ALT+TAB bind consumes the key
      // before any surface sees it, so every step after the first arrives as a
      // `custom>>` line, the same way the first one did -- which also keeps
      // the compositor's repeat rate in charge of holding TAB down. The keys
      // below are the ones nothing in Hyprland is bound to, so the grab is
      // what delivers them.
      Keys.onPressed: function(event) {
        switch (event.key) {
        case Qt.Key_Escape:
          root.dismiss()
          break
        case Qt.Key_A:
          root.setScope("all")
          break
        case Qt.Key_W:
          root.setScope("workspace")
          break
        case Qt.Key_O:
          root.setScope("output")
          break
        case Qt.Key_Left:
          root.move(-1)
          break
        case Qt.Key_Right:
          root.move(1)
          break
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
          root.commit(null)
          break
        default:
          return
        }
        event.accepted = true
      }

      // The release that ends the session, and the fast half of how it is
      // noticed. The other half is the watchdog in hypr/omari-alttab.lua,
      // which polls the keyboard's own state and does not depend on this
      // surface having the grab, or on the release surviving the trip through
      // the compositor into Qt. Both call commit(), which is idempotent --
      // whichever gets there first ends the session and the other finds
      // `active` already false.
      Keys.onReleased: function(event) {
        if (!root.active || event.isAutoRepeat) return
        if (event.key !== Qt.Key_Alt) return
        root.commit(null)
        event.accepted = true
      }

      // ---- scope indicator ----
      //
      // niri's, and it earns the space: A/W/O are invisible otherwise, and a
      // filtered row with nothing to say it is filtered reads as windows
      // having gone missing.
      Rectangle {
        id: scopePill
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(parent.height * 0.055)
        width: scopeRow.implicitWidth + Style.space(28)
        height: scopeRow.implicitHeight + Style.space(14)
        radius: Style.space(8)
        color: Util.alpha(Color.background, 0.92)
        border.width: Math.max(1, Style.space(1))
        border.color: Util.alpha(Color.foreground, 0.28)

        Row {
          id: scopeRow
          anchors.centerIn: parent
          spacing: Style.space(12)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Scope:"
            color: Qt.darker(Color.foreground, 1.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
          }

          Repeater {
            model: [
              { key: "all", label: "All" },
              { key: "workspace", label: "Workspace" },
              { key: "output", label: "Output" }
            ]

            // The mnemonic split out as its own Text rather than markup: the
            // letter is underlined on all three, always, because that is the
            // only thing on screen that says A, W and O do anything at all --
            // marking only the active one would say it about the one scope you
            // are already in. Which scope that is, is carried by brightness.
            Row {
              required property var modelData
              readonly property bool current: root.scope === modelData.key
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                text: parent.modelData.label.charAt(0)
                color: parent.current ? Color.foreground : Qt.darker(Color.foreground, 1.7)
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.underline: true
                font.bold: parent.current
              }

              Text {
                text: parent.modelData.label.substring(1)
                color: parent.current ? Color.foreground : Qt.darker(Color.foreground, 1.7)
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: parent.current
              }
            }
          }
        }
      }

      // ---- the row ----

      Item {
        id: viewport
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: panel.stripHeight
        clip: true

        Item {
          id: strip
          y: 0
          width: panel.stripWidth
          height: panel.stripHeight
          x: root.count === 0 ? 0 : strip.restX

          // Where the row has to sit for the selected card to be on screen,
          // and no further. Deliberately reveal-and-no-more rather than
          // centre-the-selection: a row that fits on screen should not move at
          // all as you walk along it, and one that does not fit should give
          // back exactly as much as it takes -- which is what makes the far
          // end of a long row feel like somewhere you scrolled to rather than
          // somewhere the row jumped to.
          property real restX: 0

          // The edges the selected card is kept inside. A margin rather than
          // flush, so the card either side of the one you are on is visible
          // and you can see what the next Tab is going to land on.
          readonly property real revealMargin: panel.tileGap * 1.6

          // Jump rather than glide, for the first frame of a session: there is
          // no previous position to travel from, and animating in from wherever
          // the last session happened to leave the row reads as the switcher
          // scrolling before you have touched it.
          function settleNow() {
            slide.enabled = false
            strip.restX = panel.tileGap
            strip.reveal()
            slide.enabled = true
          }

          function reveal() {
            var n = root.count
            if (n === 0) { strip.restX = 0; return }
            var viewportWidth = viewport.width
            var content = panel.stripWidth
            // Shorter than the screen: centred, and it stays centred. There is
            // nothing to scroll to.
            if (content <= viewportWidth) {
              strip.restX = Math.round((viewportWidth - content) / 2)
              return
            }
            var index = Math.max(0, Math.min(n - 1, root.selected))
            var left = panel.cardXAt(index)
            var right = left + panel.cardWidthAt(index)
            var margin = Math.min(strip.revealMargin, (viewportWidth - panel.cardWidthAt(index)) / 2)
            var x = strip.restX
            if (left + x < margin) x = margin - left
            else if (right + x > viewportWidth - margin) x = viewportWidth - margin - right
            // The ends of a long row stop at the screen edge with a gap the
            // size of the gap between two cards, so the first and last window
            // are not shaved by the bezel.
            var minX = viewportWidth - content - panel.tileGap
            var maxX = panel.tileGap
            strip.restX = Math.round(Math.max(minX, Math.min(maxX, x)))
          }

          Behavior on x {
            id: slide
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
          }

          Repeater {
            id: cards
            model: root.visibleEntries

            Item {
              id: card
              required property var modelData
              required property int index

              readonly property bool current: card.index === root.selected
              readonly property real tileHeight: card.current
                ? panel.selectedTileHeight
                : panel.tileHeight
              readonly property real tileWidth: Math.round(card.tileHeight * card.modelData.aspect)

              // Whether this card is anywhere near the screen.
              //
              // A row of every window open is routinely several screens long,
              // and every card on it is a full-resolution capture of its
              // window. Opening the switcher used to start a live stream for
              // all of them at once, in the same breath as the keypress: on a
              // machine with fifteen windows that is fifteen streams begun to
              // draw the four you can see, at the one moment a switcher has to
              // be instant. A card past the edge is neither drawn nor eligible
              // for the capture budget, and becomes both as the strip slides
              // it in -- a card's width of slack ahead of the edge, so it has
              // a picture before it is looked at.
              //
              // strip.x is animated, so this follows the slide rather than
              // being decided once when the selection moves.
              readonly property bool near: {
                var left = card.x + strip.x
                var slack = panel.tileHeight * 2
                return left + card.width > -slack && left < viewport.width + slack
              }

              visible: card.near

              // What the scheduler above reads. Kept on the delegate so it
              // cannot outlive the card it describes.
              property real lastCaptureMs: 0
              readonly property bool hasPicture: shotView.hasContent
              function requestCapture() {
                shotView.captureFrame()
                card.lastCaptureMs = Date.now()
              }

              x: panel.cardXAt(card.index)
              y: 0
              width: panel.cardWidthAt(card.index)
              height: panel.stripHeight

              // Widths and positions are arithmetic off the model (cardXAt,
              // cardWidthAt) rather than read back off a Row, so growing the
              // selected card and sliding the strip to keep it on screen are
              // the same number computed the same way at the same moment --
              // and the two never disagree about where the row is.
              Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
              Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

              Rectangle {
                id: plate
                anchors.horizontalCenter: parent.horizontalCenter
                // Bottom-aligned in the band: only the selected card grows,
                // and it grows upward, so the captions stay on one line.
                y: panel.bandHeight - plate.height
                width: card.tileWidth + 2 * panel.cardPadding
                height: card.tileHeight + 2 * panel.cardPadding
                radius: Style.space(12)
                // The plate is the selection. Unselected windows are the bare
                // thumbnail with nothing around it, so the row reads as
                // windows rather than as a strip of framed tiles -- the same
                // choice the overview makes about its rings.
                color: card.current ? Util.alpha(Color.foreground, 0.16) : "transparent"
                border.width: card.current ? Math.max(1, Style.space(1)) : 0
                border.color: Util.alpha(Color.accent, 0.75)

                Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                Rectangle {
                  id: shot
                  anchors.centerIn: parent
                  width: card.tileWidth
                  height: card.tileHeight
                  radius: Style.space(6)
                  color: Color.background
                  clip: true
                  opacity: card.current ? 1.0 : 0.72

                  Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                  Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                  ScreencopyView {
                    id: shotView
                    anchors.fill: parent
                    captureSource: card.modelData.toplevel.wayland
                    // Never live; the scheduler at the top of this file hands
                    // out frames instead. The gating this replaces was on
                    // position, and position was never the expensive part: a
                    // live view re-arms from its own repaint, so a card that
                    // is on screen at all renders at refresh rate for as long
                    // as the switcher is held open.
                    //
                    // A card that has never been captured is the one case the
                    // scheduler treats as urgent -- see captureNext -- because
                    // until it has a picture it is an empty rectangle with a
                    // title under it. Cards keep their pictures between
                    // invocations (the surface stays mapped for the life of
                    // the shell), so a reopened switcher is refreshing rather
                    // than filling, and nothing pops in.
                    live: false
                    paintCursor: false

                    // No constraintSize. It reads like a cap on how big a
                    // buffer the compositor is asked for and it is not one:
                    // Quickshell feeds it to the view's *implicit* size and
                    // nothing else, and an anchors.fill view has no use for an
                    // implicit size -- so every card here was streaming its
                    // window at full native resolution the whole time this
                    // claimed to be capping it. The same discovery is written
                    // up at greater length in OmariOverview.qml; what that
                    // file does about it (a supersampled, mipmapped layer to
                    // take the shrink away from the view's hardcoded bilinear
                    // filter) is deliberately not done here, because this
                    // surface is up for a second at a time and never moves
                    // under a zoom, so there is nothing for the shimmer to
                    // crawl across.
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  // A click is a choice, so it commits rather than only
                  // selecting: there is no second click coming, because
                  // letting go of ALT is what usually ends this.
                  onClicked: root.commit(card.modelData)
                }
              }

              Text {
                y: panel.bandHeight + panel.titleGap
                width: parent.width
                height: panel.titleHeight
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                // Live off the toplevel where there is one, so a terminal that
                // renames itself while the switcher is up says what it is now;
                // the snapshot's copy is the fallback for a window whose
                // wayland handle has not answered yet.
                text: (card.modelData.toplevel && card.modelData.toplevel.wayland
                  && card.modelData.toplevel.wayland.title)
                  ? card.modelData.toplevel.wayland.title
                  : card.modelData.title
                color: card.current ? Color.foreground : Qt.darker(Color.foreground, 1.6)
                font.family: Style.font.family
                font.pixelSize: card.current ? Style.font.subtitle : Style.font.body
              }
            }
          }
        }
      }

      // An empty row is only reachable by filtering into one -- a session that
      // opens with nothing to show never opens at all (see begin) -- so this
      // says which filter did it rather than "no windows".
      Text {
        anchors.centerIn: viewport
        visible: root.count === 0
        text: root.scope === "workspace" ? "No windows on this workspace"
          : root.scope === "output" ? "No windows on this monitor"
          : "No windows"
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
      }
    }
  }

  // The row follows the selection rather than the other way round, so one
  // handler covers Tab, the arrows and a scope change alike.
  onSelectedChanged: strip.reveal()
  onCountChanged: strip.reveal()

  // Last resort. Every way a session is meant to end goes through commit() or
  // dismiss(), and two independent mechanisms watch for the modifier coming
  // back up -- but this surface holds an exclusive keyboard grab while it is
  // open, and a grab that outlives its session takes the keyboard away from
  // the whole desktop. Nobody holds ALT+TAB for twenty seconds; anything that
  // gets here is broken, and the safe answer to broken is to let go.
  Timer {
    interval: 20000
    running: root.active
    onTriggered: root.dismiss()
  }
}
