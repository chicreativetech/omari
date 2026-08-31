import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

// Omari overview: niri's "all apps" overview. Full-screen, one row per
// workspace, windows in that workspace shown as live thumbnails side by
// side. Rows stack vertically and scroll. Opened by the omari-overview
// Hyprland gesture (4-finger swipe up) or keybinding (SUPER+ALT+O), see
// hypr/omari-overview.lua, via `omarchy-shell shell toggle bergdahlchi.omari`,
// which the host routes here because this plugin declares an "overlay" entry
// point.
//
// Scrolling is deliberately not built out of animated offsets -- see
// KineticScroll.qml for why, and for the physics both axes share.
Item {
  id: root

  // Injected by omarchy-shell when this plugin is loaded as a panel/overlay.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false

  // Whether the surface is showing anything at all. The layer surface itself
  // stays mapped from the moment the shell starts — see panel.visible, which
  // is what lets the opening swipe track the fingers from the first
  // millimetre — so "is the window up" stopped being the same question as "is
  // the overview up", and everything that means the second one asks this.
  readonly property bool surfaceLive: root.opened || root.leaving

  // ---- selection ----
  //
  // The whole overview hangs off these two. The selected workspace is stored
  // by id rather than by row index so it survives the row list resolving
  // late, or a workspace opening/closing while the overview is up; the row
  // index is derived from it. It starts as whatever workspace was active when
  // the overview opened, and from then on tracks whichever row is centred —
  // by arrow key, by wheel, or by a two-finger swipe snapping to rest.
  property int selectedWorkspaceId: -1
  property int selectedApp: 0

  // Current desktop background image, resolved from the same symlink the
  // background plugin follows. Refreshed each time the overview opens.
  property string backgroundImagePath: ""

  function open(payloadJson) {
    // A workspace with no windows has no row of its own, so opening from one
    // selects the empty row rather than falling back to the top of the list.
    var focused = Hyprland.focusedWorkspace
    root.selectedWorkspaceId = root.hasWindows(focused)
      ? focused.id
      : root.emptyWorkspaceId
    // onSelectedRowChanged covers the case where this lands on a different
    // row than last time; this covers reopening on the same row, where the
    // focused window may still have changed underneath us.
    root.selectedApp = root.defaultAppIndexForWorkspace(root.selectedWorkspaceId)
    root.refreshGeometry()
    bgPathProc.running = true
    // Whatever the last leave had got as far as, it is cancelled rather than
    // left to run: close() promises that a swipe arriving during the fade
    // brings the overview straight back, and a NumberAnimation still ticking
    // on exitOpacity would have faded it out again from under that promise —
    // and then called finish() on a surface that had just been reopened.
    exitFade.stop()
    switchHold.stop()
    handOffTimer.stop()
    root.thawGeometry()
    root.clearZoom()
    // Start fully zoomed in, onto nothing yet: there is no thumbnail to
    // measure until the surface has been laid out, so zoomOpener does the
    // measuring on the first frame that is actually drawn. Until then the
    // strip is held invisible and the backdrop is fully transparent, so what
    // shows through is the real desktop — which is exactly the frame the
    // zoom-out should start from anyway.
    root.zoomProgress = 1
    root.zoomReady = false
    root.grabsKeyboard = true
    root.exitOpacity = 1
    // `opened` goes up before `leaving` comes down, and that order is not
    // cosmetic -- see panel.visible.
    root.opened = true
    root.leaving = false
    root.gestureAxis = ""
    vScroll.reset()
    root.viewReset()
    root.dbg("open focusedWs=" + (focused ? focused.id : "?")
      + " selectedWsId=" + root.selectedWorkspaceId
      + " selectedRow=" + root.selectedRow
      + " selectedApp=" + root.selectedApp
      + " rows=" + JSON.stringify(root.workspaceRows.map(function(r) { return r.id }))
      + " frozenRows=" + (root.frozenRows ? "YES" : "no"))
  }

  // What the host's hide() reaches, and so what SUPER+ALT+O reaches: the
  // keyboard's half of the closing swipe. It lands you on the workspace you
  // are looking at, with the same dive, for the same reason the swipe does.
  //
  // The host's toggle() is `isPluginOpen(id) ? hide(id) : summon(id)` and
  // never calls the plugin's own toggle(), so hide() is the only place this
  // can be said. It used to be the plain dismissal below, which meant the key
  // that had just taken you out to look at workspace 4 put you back down on
  // the workspace you started from -- no zoom, no switch, nothing to show for
  // the trip. Enter has always dived; the key that opens now does too.
  //
  // Escape and a click on the backdrop go to dismiss() instead and still mean
  // "never mind". That is the distinction hide() cannot make and the plugin
  // can: a cancel leaves the desktop exactly as it found it.
  function close() {
    if (!root.opened || root.leaving) return
    // A row with nothing to activate has nowhere to dive, so it leaves the
    // only way it can.
    if (!root.activateSelection()) root.dismiss()
  }

  // The cancel, and the shape every exit still takes underneath: fade, then
  // tear down. A hard unmap reads as a glitch rather than as leaving — one
  // frame an opaque backdrop, the next the desktop — and by the time anyone
  // cancels, the surface is long past the expensive frames that open it and
  // has 60Hz to spend on a fade.
  //
  // `opened` goes false here rather than at the end of the fade, and the
  // surface is held up by `leaving` instead. It is what the host answers
  // "is this plugin open?" with, so leaving it true through the fade would
  // swallow a swipe that arrives during it — and this is precisely where one
  // arrives, since the fade is the tail of the gesture that closed it. Now
  // that swipe reaches open(), which cancels the fade on a surface that never
  // unmapped: the overview comes back instantly.
  //
  // The keyboard grab goes back here too rather than at the end, so the window
  // underneath is live again the moment you ask to leave.
  function dismiss() {
    if (!root.opened || root.leaving) return
    root.freezeGeometry()
    // `leaving` first, then `opened` -- see panel.visible.
    root.leaving = true
    root.opened = false
    root.grabsKeyboard = false
    exitFade.restart()
  }

  // Reset rather than just hide: a flick still coasting when the overview
  // closes would otherwise keep a FrameAnimation ticking behind an invisible
  // surface, and would still be mid-glide the next time it opens.
  function finish() {
    exitFade.stop()
    switchHold.stop()
    handOffTimer.stop()
    root.opened = false
    root.leaving = false
    root.grabsKeyboard = true
    root.exitOpacity = 1
    root.gestureAxis = ""
    // Any swipe still thought to own the overview does not, now that there is
    // no overview for it to own. Everything that tears the surface down
    // arrives here, so this is the one place that covers a gesture outliving
    // what it was driving -- Escape or a click landing between the fingers
    // moving and the fingers lifting. Without it those last few events would
    // go on writing zoomProgress on a closed overview, and the release would
    // ramp it back open.
    root.gestureMode = ""
    root.gestureAimed = false
    root.gestureTravelOrigin = 0
    root.gestureRestoreArg = ""
    geometryRefresh.stop()
    root.clearZoom()
    root.thawGeometry()
    vScroll.reset()
    root.viewReset()
  }

  function toggle() { if (root.opened) root.close(); else root.open() }
  function ping() { return "ok" }

  // Broadcast to the row delegates, which cannot be reached by name from out
  // here. viewReset() puts every row's strip back where a fresh overview
  // starts; viewFrozen() only stops whatever it is doing, leaving it exactly
  // where it stands. The difference matters a great deal -- see the row's own
  // handlers, and freezeGeometry below.
  signal viewReset()
  signal viewFrozen()

  // ---- leaving ----
  //
  // True from the moment a dismissal or an activation starts until the
  // surface actually goes away. Everything that would otherwise fire twice —
  // a second swipe during the fade, Escape on top of a click — checks it.
  property bool leaving: false

  // Whether this surface still holds the keyboard grab. Dropped before a
  // focus dispatch goes out; see handOff.
  property bool grabsKeyboard: true

  // Multiplied into everything the overview draws while it leaves.
  property real exitOpacity: 1

  NumberAnimation {
    id: exitFade
    target: root
    property: "exitOpacity"
    from: 1
    to: 0
    duration: 110
    easing.type: Easing.InQuad
    onFinished: root.finish()
  }

  // ---- window geometry ----
  //
  // Every rectangle in a row -- the strip, the travel limits, each thumbnail's
  // size and place -- is derived from Hyprland's own `at`/`size` for that
  // window, read off HyprlandToplevel.lastIpcObject. That field is filled in
  // by an IPC *query* and by nothing else: Quickshell builds a toplevel from
  // the `openwindow` event with no geometry at all, and one built by the query
  // at startup keeps the geometry it had at that moment however many times the
  // window has moved since. Neither is a small error here. rectFor returns null
  // for a window with no geometry and rectInRow falls back to the monitor
  // rectangle, so a workspace's windows stack on the same spot at the same
  // size: only the topmost is visible, and it is the one every click lands on
  // whichever thumbnail was aimed at -- which is exactly what a shell that has
  // been up long enough for its windows to have been opened after it shows.
  //
  // So query on the way in, and again whenever the layout moves underneath.
  // The reply is asynchronous, but it lands in a couple of milliseconds --
  // well inside the first frames of the surface being mapped --
  // and every rectangle in here is a binding over lastIpcObject, so the rows
  // lay themselves out again the moment it arrives.
  function refreshGeometry() { Hyprland.refreshToplevels() }

  // Events that can move or resize a window, and so invalidate the geometry
  // the rows are drawn from. Deliberately a list rather than "any event": a
  // busy terminal emits windowtitle continuously, and re-querying on those
  // would re-evaluate every rectangle in the overview several times a second,
  // against the very frames a smooth scroll needs.
  readonly property var geometryEvents: [
    "openwindow", "closewindow", "movewindow", "movewindowv2",
    "changefloatingmode", "fullscreen", "pin", "moveworkspace", "monitoradded",
    "monitorremoved", "configreloaded"
  ]

  Connections {
    target: Hyprland
    enabled: root.opened
    function onRawEvent(event) {
      if (root.geometryEvents.indexOf(event.name) !== -1) geometryRefresh.restart()
    }
  }

  // Coalesces a burst into one query: closing a single window in a scrolling
  // layout emits a closewindow and then a movewindow per column it shifted,
  // and one query answers all of them.
  Timer {
    id: geometryRefresh
    interval: 50
    onTriggered: root.refreshGeometry()
  }

  Process {
    id: bgPathProc
    command: ["readlink", "-f", Quickshell.env("HOME") + "/.local/state/omarchy/current/background"]
    stdout: StdioCollector {
      onStreamFinished: root.backgroundImagePath = String(text || "").trim()
    }
  }

  // A workspace takes up half the screen, and that is a *ratio*, not a pixel
  // count: what the overview is for is showing how much of the workspaces
  // either side of you there is to see, and that is inherently a fraction of
  // the viewport. Pinning it to Style.space() instead made rows fill 58% of a
  // laptop panel and a third of a large monitor — the same numbers, a
  // different overview. The floor keeps it sane before the layer surface has
  // been given its size, and on a very short screen.
  //
  // A row *is* the monitor rectangle, drawn at this height, so this is both
  // the wallpaper thumbnail's height and the scale everything in the row is
  // drawn at (see geomScale in the row delegate).
  readonly property real rowHeight: Math.max(Style.space(120), panel.height * 0.5)

  // Screencopy capture resolution is deliberately NOT tied to rowHeight.
  // Thumbnails capture live while their row is on screen, so requesting a
  // proportionally larger buffer per thumbnail multiplies sustained
  // GPU/compositor load a lot. A thumbnail this size doesn't need more source
  // pixels than it always did — only the on-screen presentation got bigger.
  readonly property real captureBaseHeight: Style.space(200)

  // Like rowHeight, a ratio: the gap between two workspaces reads relative to
  // how big a workspace is, not in absolute pixels.
  readonly property real rowSpacing: Math.round(root.rowHeight * 0.104)

  // How far outside the viewport a row still counts as "on screen" for the
  // purpose of capturing live. One row's worth of slack means a row is
  // already streaming by the time it scrolls into view, and stops streaming
  // well after it has left — so a scroll that hovers around a boundary never
  // thrashes captures on and off.
  readonly property real liveMargin: root.rowHeight

  // Rows are a plain uniform height — no label, no per-row chrome — which is
  // what lets every "where is row i" question in here be arithmetic rather
  // than a live geometry read off a delegate that may not exist yet.
  readonly property real rowStride: root.rowHeight + root.rowSpacing

  // Only workspaces that actually have windows are worth a row; reading
  // toplevels.values here during evaluation is what keeps this reactive to
  // both new/closed workspaces and windows opening/closing within one,
  // mirroring the bar's own Workspaces.qml.
  readonly property var windowedRows: {
    var values = Hyprland.workspaces ? Hyprland.workspaces.values : []
    var rows = []
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      if (ws && ws.toplevels && ws.toplevels.values.length > 0) rows.push(ws)
    }
    rows.sort(function(a, b) { return a.id - b.id })
    return rows
  }

  // The workspace the empty row stands for: the lowest id no windowed row is
  // using. Since a workspace with no windows gets no row, "not on the list"
  // and "empty" are the same statement, and this is the one Hyprland's own
  // `empty` selector would take you to next.
  readonly property int emptyWorkspaceId: {
    var used = {}
    var rows = root.windowedRows
    for (var i = 0; i < rows.length; i++) used[rows[i].id] = true
    var id = 1
    while (used[id]) id++
    return id
  }

  // Which monitor the empty row is a replica of. It has no workspace of its
  // own to ask, so it borrows the last row's — that keeps its wallpaper the
  // same size as the row above it, which is the whole point of drawing it.
  readonly property var emptyRowMonitor: {
    var rows = root.windowedRows
    var last = rows.length > 0 ? rows[rows.length - 1] : null
    return (last && last.monitor) ? last.monitor : Hyprland.focusedMonitor
  }

  // One row past the real ones, standing for the next empty workspace: bare
  // wallpaper, no windows, so the overview always ends on somewhere to go
  // rather than on the last thing already open.
  //
  // Deliberately a plain object rather than a real HyprlandWorkspace, and
  // deliberately inside the same list: the row delegate only ever asks a row
  // for `id`, `monitor` and `toplevels.values`, so a stand-in that answers
  // those three needs no special case anywhere the rows are counted, indexed,
  // centred, snapped to or selected. `omariEmpty` is what the two places that
  // do care — the click target and Enter — recognise it by.
  readonly property var workspaceRows: {
    // Held while the overview is leaving. Focusing a window on another
    // workspace can destroy the empty one being left and create the one being
    // arrived at, and Hyprland says so on the event socket: the workspace
    // model changes, this list is rebuilt, and the Repeater over it throws
    // away every row and every screencopy stream in it -- in the middle of the
    // dive that is drawn from them. Nothing that happens after the click can
    // change what the overview is a picture of, so nothing after the click is
    // allowed to.
    if (root.frozenRows) return root.frozenRows
    var rows = root.windowedRows.slice()
    rows.push({
      id: root.emptyWorkspaceId,
      omariEmpty: true,
      monitor: root.emptyRowMonitor,
      toplevels: { values: [] }
    })
    return rows
  }

  function isEmptyRowModel(row) { return !!(row && row.omariEmpty) }

  // Whether a workspace has a row of its own, i.e. whether it has windows.
  function hasWindows(ws) {
    if (!ws) return false
    var rows = root.windowedRows
    for (var i = 0; i < rows.length; i++) if (rows[i].id === ws.id) return true
    return false
  }

  // Row currently centred in the viewport. Falls back to the first row when
  // the selected workspace has gone away (its last window closed while the
  // overview was open), which is also the sensible answer before anything has
  // been selected.
  readonly property int selectedRow: {
    for (var i = 0; i < root.workspaceRows.length; i++) {
      if (root.workspaceRows[i].id === root.selectedWorkspaceId) return i
    }
    return 0
  }

  readonly property var selectedToplevels: {
    var ws = root.workspaceRows[root.selectedRow]
    return ws ? root.sortToplevelsBySpatialOrder(ws.toplevels.values) : []
  }

  // Arrowing onto a row lands on whichever of its windows Hyprland would
  // focus if you switched there, not on its leftmost one.
  //
  // Takes the workspace *id*, and that is not a style preference. selectedRow
  // is a binding over selectedWorkspaceId, and a changed handler on a property
  // runs before that property's own dependent bindings have been
  // re-evaluated -- it lags by exactly one change. So reading selectedRow from
  // onSelectedWorkspaceIdChanged computed the newly centred row's app index
  // from the row just left: land on a three-window row from a five-window one
  // and selectedApp came out 4, clamped to that row's last window, and restX
  // glided the row all the way right to bring it inside the wallpaper -- then
  // slid it back the moment it stopped being the centred row and its ring
  // reverted to Hyprland's own focused window. Nothing downstream was wrong;
  // the index handed to it was.
  function defaultAppIndexForWorkspace(id) {
    var rows = root.windowedRows
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].id !== id) continue
      return root.focusedIndexFor(root.sortToplevelsBySpatialOrder(rows[i].toplevels.values))
    }
    return 0
  }

  // Keyed on the workspace *id*, not on selectedRow. selectedRow is a binding
  // over workspaceRows, which Hyprland re-evaluates on every model update — a
  // window opening anywhere, or just a title changing — and any of those that
  // shifts the row index, even transiently, would fire this and silently throw
  // away a left/right selection the user had just made. The id only ever moves
  // when something actually chooses a different workspace.
  onSelectedWorkspaceIdChanged:
    root.selectedApp = root.defaultAppIndexForWorkspace(root.selectedWorkspaceId)

  // ---- keyboard navigation ----
  //
  // Up/down move between workspace rows, left/right between the apps in the
  // centred row. Neither moves the scrollers directly: they move the
  // selection, and the scrollers follow it through their restPosition
  // bindings. Marking the vertical scroller interactive first is what makes
  // that follow a glide rather than a jump on the very first key press, back
  // when the overview has only just opened.
  function moveRow(delta) {
    var rows = root.workspaceRows
    if (rows.length === 0) return
    var next = Math.max(0, Math.min(rows.length - 1, root.selectedRow + delta))
    if (next === root.selectedRow) return
    vScroll.interactive = true
    root.selectedWorkspaceId = rows[next].id
  }

  function moveApp(delta) {
    var apps = root.selectedToplevels
    if (apps.length === 0) return
    root.selectedApp = Math.max(0, Math.min(apps.length - 1, root.selectedApp + delta))
  }

  // Answers whether it found anything to activate, so a caller with a fallback
  // of its own -- see toggle() -- can tell "gone there" from "nothing to go to".
  function activateSelection() {
    var row = root.workspaceRows[root.selectedRow]
    if (root.isEmptyRowModel(row)) {
      root.activateWorkspace(row.id)
      return true
    }
    var apps = root.selectedToplevels
    if (apps.length === 0) return false
    var i = Math.max(0, Math.min(apps.length - 1, root.selectedApp))
    root.activateToplevel(apps[i], root.selectedRow, i)
    return true
  }

  // ---- zoom ----
  //
  // The overview *is* the desktop seen from further away, so it should arrive
  // by falling back from the window you were on and leave by diving into the
  // one you picked. Both directions are one transform driven by a single
  // progress: at 0 the strip sits exactly where the overview lays it out, and
  // at 1 the target window's thumbnail covers the real window's own place on
  // screen at real size — so at the moment the overlay goes away, nothing
  // jumps. Scaling about a fixed origin would not do that: a thumbnail grown
  // to real size around its own centre still ends up wherever the overview
  // happened to put it, which is not where the window is.
  //
  // Every term is identity until a capture fills them in, so a capture that
  // fails leaves the overview behaving exactly as it does with none of this.
  property real zoomProgress: 0   // 0 = overview, 1 = target at real size and place
  property real zoomScale: 1      // scale at progress 1, i.e. 1 / the row's geomScale
  property real zoomThumbX: 0     // target thumbnail's top-left, in zoomLayer coords
  property real zoomThumbY: 0
  property real zoomRealX: 0      // where that window actually is on screen
  property real zoomRealY: 0
  property bool zoomReady: true
  property var pendingActivation: null

  // Which thumbnail the in-flight dive is aimed at. Kept so aimZoom can find
  // it again once Hyprland has answered, without the click having to be
  // replayed.
  property int diveRow: -1
  property int diveApp: -1

  // How far the dive's own row has to scroll, in row pixels, to end up showing
  // what its workspace is about to show. See aimZoom -- this is the miniature
  // of the scroll Hyprland is performing at full size behind the overlay, and
  // the row performs it on the same progress the zoom runs on.
  property real diveShiftPx: 0

  // Between the focus dispatch going out and the layout it produced coming
  // back. See activateToplevel.
  property bool awaitingLanding: false

  // Long enough to cover what runs behind it. Two things do: the workspace
  // slide, which omari-mode.lua sets to speed 3 — deciseconds, so 300ms — and
  // the scrolling layout pulling the focused column into view, which is
  // windowsMove, 600ms on Omarchy's defaults. The slide is matched exactly.
  // The column scroll is not, and does not need to be: it is an easeOutQuint,
  // so 300ms in it has already covered 97% of its distance and the rest of it
  // is a few pixels of creep, which is what the beat after the dive is for.
  readonly property int diveMs: 300

  // The other direction: falling back out of the window into the overview.
  // Shorter than the dive because it has nothing to stay in step with — the
  // dive is timed to the workspace slide running behind it, this is timed to
  // itself. Also what the tail of a released swipe is measured against; see
  // gestureFinish.
  readonly property int openMs: 260

  // Frame and phase tracing for the open/dive transitions, off by default.
  // Turning it on prints the timings that found the unmap described at
  // panel.visible: how long each phase of the click took, when Hyprland's
  // reply actually arrived, and every frame interval of both ramps. Worth
  // keeping -- the failure it diagnosed was invisible from the outside and
  // looked exactly like "the zoom is too expensive".
  property bool omariDebug: false
  property real dbgClickMs: 0
  function dbg(msg) { if (root.omariDebug) console.warn("OMARI " + msg) }
  function dbgCounts() {
    var rows = root.workspaceRows.length
    var wins = 0
    for (var i = 0; i < rows; i++) {
      var r = root.workspaceRows[i]
      if (r && r.toplevels) wins += r.toplevels.values.length
    }
    return "rows=" + rows + " windows=" + wins
  }

  readonly property real zoomFactor: 1 + root.zoomProgress * (root.zoomScale - 1)

  // ---- the backdrop's own curve ----
  //
  // The two directions of the zoom want opposite things from the backdrop, and
  // for a while they shared one curve because one of them was too quick to
  // argue with.
  //
  // Diving, the desktop underneath is *moving* — the workspace slide the click
  // dispatched is running behind the overlay, and that is the thing the
  // overview is up to hide. So the backdrop stays opaque through almost all of
  // it and only clears at the very end, where the strip has become a near-match
  // for the desktop behind it and the two can be crossed without anything being
  // seen to move. A backdrop clearing in step with the progress showed the
  // workspace sliding in behind a half-transparent overview.
  //
  // Opening, the desktop underneath is *still*, and the strip is pulling away
  // from it. Everything the strip uncovers as it shrinks is the real desktop
  // showing through, in register with the replica drawn on top of it — two
  // copies of the same picture at different sizes. Squared, the backdrop is
  // barely there for the first third of the pull-back, which was invisible at
  // 260ms and is not invisible at all when the fingers hold the zoom halfway
  // out. So this direction hides the desktop almost at once instead: within
  // backdropRise of leaving progress 1, which is a few tens of pixels of
  // travel. It cannot simply start opaque — at progress 1 exactly the strip
  // stands in for the desktop pixel for pixel, and painting over it there would
  // put a grey flash at both ends of every swipe.
  readonly property real backdropRise: 0.1

  // Whether a dive is what is driving the zoom rather than an open or a swipe.
  // pendingActivation is set for the whole of one, from the click until
  // clearZoom, and for nothing else.
  readonly property bool diving: root.pendingActivation !== null

  readonly property real backdropOpacity: root.diving
    ? 1 - root.zoomProgress * root.zoomProgress
    : Math.min(1, (1 - root.zoomProgress) / root.backdropRise)

  // Ramping the scale alone would drag the target away from both endpoints in
  // between; this holds its top-left on the straight line from thumbnail to
  // real window for the whole ramp.
  function zoomOffset(thumbPos, realPos) {
    return thumbPos + (realPos - thumbPos) * root.zoomProgress
      - root.zoomFactor * thumbPos
  }

  // Measures the thumbnail's live on-screen box rather than recomputing the
  // layout from the model, so it stays correct when a row has been scrolled
  // away from its resting position.
  //
  // Must be called BEFORE freezeGeometry, and that ordering is the whole of a
  // dive landing on the row it was aimed at. The freeze hands the Repeater a
  // fresh array (see frozenRows), which rebuilds every row delegate -- and a
  // delegate that has just been created has not been positioned by its Column
  // yet, so it sits at y 0 whatever its index. Measuring there returned the
  // *first* row's place for whichever row was actually being dived into:
  //
  //   probe BEFORE freeze rowY=503 thumbAt=348,251
  //   probe AFTER  freeze rowY=0   thumbAt=348,-252
  //
  // exactly one rowStride out, per row of index. The zoom was then anchored on
  // row 0's slot, so a dive from any row at all ended with the *first*
  // workspace filling the screen -- and only a dive from row 0 was ever right,
  // because there the stale position and the real one are the same number.
  //
  // Nothing else the freeze does disturbs the measurement: it stops the
  // scrollers rather than moving them, and the strips keep their positions
  // across the rebuild (hPos and stripOffset are unchanged above), so a
  // capture taken a statement earlier describes the same picture the freeze
  // then pins.
  function captureZoom(rowIndex, appIndex) {
    var row = rowRepeater.itemAt(rowIndex)
    if (!row) { root.dbg("captureZoom: no row delegate at " + rowIndex); return false }
    var item = row.thumbItemAt(appIndex)
    if (!item || item.width <= 0 || item.height <= 0) {
      root.dbg("captureZoom: no thumb at " + appIndex
        + " (item=" + (item ? item.width + "x" + item.height : "null") + ")")
      return false
    }
    var r = root.rectFor(item.modelData)
    if (!r) { root.dbg("captureZoom: no rect for thumb " + appIndex); return false }
    var p = item.mapToItem(zoomLayer, 0, 0)
    root.zoomThumbX = p.x
    root.zoomThumbY = p.y
    // The overlay covers the monitor, so a window's place on screen is just
    // its layout rectangle less the monitor's own origin.
    root.zoomRealX = r.x - row.monX
    root.zoomRealY = r.y - row.monY
    root.zoomScale = r.w / item.width
    return true
  }

  function clearZoom() {
    zoomRamp.halt()
    diveDeadline.stop()
    aimRetry.stop()
    root.aimRetries = 0
    root.pendingDispatch = ""
    restoreFallback.stop()
    root.pendingActivation = null
    root.diveRow = -1
    root.diveApp = -1
    root.diveShiftPx = 0
    root.awaitingLanding = false
    root.zoomProgress = 0
    root.zoomScale = 1
    root.zoomThumbX = 0
    root.zoomThumbY = 0
    root.zoomRealX = 0
    root.zoomRealY = 0
    root.zoomReady = true
  }

  // Clicking a window is a dive *and* a workspace switch, and the whole trick
  // is making them the same event rather than one after the other.
  //
  // The dispatch goes out first, before a pixel of the dive has been drawn.
  // Hyprland answers it with a workspace slide, and — because this is a
  // scrolling layout — with a scroll that brings the focused column into view,
  // and those two animations are precisely what the overview is here to hide.
  // Dispatching at the end of the dive instead ran them *after* the overlay
  // had gone: the strip was cut away and the desktop then visibly assembled
  // itself, sliding and scrolling into place in full view. Dispatching first
  // puts all of it behind the backdrop, and the dive is timed to end as it
  // does.
  //
  // Where the dive is aimed has to wait on the same dispatch, since it is the
  // dispatch that decides where the window ends up — so the ramp does not
  // start until Hyprland has answered with the layout it produced (see
  // diveDispatch and aimZoom). That answer costs a couple of frames, and the
  // overview spends them standing perfectly still under an opaque backdrop,
  // which is the least visible moment in the whole transition to spend them
  // in.
  //
  // Standing *still* is not free either: the click freezes the overview
  // outright — see freezeGeometry — because everything the dispatch sets off
  // arrives back through Quickshell's models as well, and a row that
  // re-lays itself out, or a Repeater that rebuilds its delegates, does so
  // inside a layer on its way to twice size and with the screencopy streams
  // that the dive is drawn from inside it.
  function activateToplevel(toplevel, rowIndex, appIndex) {
    if (!toplevel) return
    if (root.pendingActivation || root.leaving) return
    root.dbgClickMs = Date.now()
    var arg = root.focusArg(toplevel)
    var tArg = Date.now()
    // Measured first, frozen second -- see captureZoom.
    var captured = root.captureZoom(rowIndex, appIndex)
    var tCapture = Date.now()
    if (!arg || !captured) {
      root.focusToplevel(toplevel)
      return
    }
    root.freezeGeometry()
    var tFreeze = Date.now()
    root.dbg("phases focusArg=" + (tArg - root.dbgClickMs) + "ms capture="
      + (tCapture - tArg) + "ms freeze=" + (tFreeze - tCapture) + "ms")
    root.dbg("click " + root.dbgCounts()
      + " thumb=(" + Math.round(root.zoomThumbX) + "," + Math.round(root.zoomThumbY) + ")"
      + " capturedReal=(" + Math.round(root.zoomRealX) + "," + Math.round(root.zoomRealY) + ")"
      + " scale=" + root.zoomScale.toFixed(3))
    root.pendingActivation = toplevel
    root.aimRetries = 0
    root.diveRow = rowIndex
    root.diveApp = appIndex
    root.awaitingLanding = true
    root.beginHandOff(arg)
    diveDeadline.restart()
  }

  // The dispatch and the aim in one request. `hyprctl --batch` runs its
  // commands in order inside Hyprland, and `at` is a goal rather than an
  // animated value, so the window that comes back with the reply is already
  // described as it will be when the compositor has finished moving it: the
  // focused column pulled into view, and — since a scrolling layout brings a
  // column into view by translating all of them — every one of its neighbours
  // carried the same distance, which is why one measurement lands the whole
  // frozen row and not just the window that was clicked.
  //
  // Measured at ~7ms end to end with the process spawn included, against ~30ms
  // and two things to get right for the alternative of dispatching blind and
  // then waiting on the event socket to hear that it had landed.
  //
  // Not Util.execArgv, for the reason beginHandOff gives: a login shell costs
  // ~280ms here and nothing on this command line needs one.

  property string hyprRequest: ""
  property string hyprReply: ""
  property bool hyprPending: false

  Socket {
    id: hyprIpc
    path: Hyprland.requestSocketPath
    // Hyprland answers and then closes, and Quickshell reports that close as
    // an error rather than as the end of a stream -- so StdioCollector, which
    // only hands its text over on a clean end, never hands it over at all.
    // The chunks are collected as they arrive instead, and the disconnect is
    // what says the answer is complete.
    parser: SplitParser {
      splitMarker: ""
      onRead: function(data) {
        root.dbg("socket chunk " + data.length + " bytes at "
          + (Date.now() - root.dbgClickMs) + "ms")
        root.hyprReply += data
      }
    }
    onConnectionStateChanged: {
      if (hyprIpc.connected) {
        root.hyprReply = ""
        hyprIpc.write(root.hyprRequest)
        hyprIpc.flush()
        root.dbg("socket connected+written at " + (Date.now() - root.dbgClickMs) + "ms")
        return
      }
      if (!root.hyprPending) return
      root.hyprPending = false
      root.dbg("socket reply at " + (Date.now() - root.dbgClickMs) + "ms, "
        + root.hyprReply.length + " bytes")
      root.beginDive(root.hyprReply)
    }
    onError: function(err) { root.dbg("socket error " + err) }
  }

  function hyprSend(request) {
    root.dbg("hyprSend at " + (Date.now() - root.dbgClickMs) + "ms REQ="
      + JSON.stringify(request))
    root.hyprRequest = request
    root.hyprPending = true
    if (hyprIpc.connected) hyprIpc.connected = false
    hyprIpc.connected = true
  }

  // The dispatch and the aim in one request, once pendingDispatch says the
  // moment is right. `hyprctl --batch` runs its commands in order inside
  // Hyprland, and `at` is a goal rather than an animated value, so the window
  // that comes back with the reply is already described as it will be when the
  // compositor has finished moving it: the focused column pulled into view,
  // and -- since a scrolling layout brings a column into view by translating
  // all of them -- every one of its neighbours carried the same distance,
  // which is why one measurement lands the whole frozen row and not just the
  // window that was clicked.
  //
  // Sent down Hyprland's own request socket rather than spawned as a `hyprctl`
  // process: sub-millisecond against ~10ms, and the reply is the whole point.
  // It was briefly suspected of not working at all -- Hyprland answering "ok"
  // and moving nothing -- but that was the focus restore described at
  // pendingDispatch overwriting a dispatch that had in fact landed. Sent after
  // the restore instead, it lands and stays, and the aim comes back with it.
  function dispatchAndAim(arg) {
    root.hyprSend("[[BATCH]]dispatch " + arg + ";j/activewindow")
  }

  // Whether an answer describes some window other than the one that was
  // clicked, which is Hyprland saying "not yet" rather than "not that one".
  //
  // The dispatch reliably lands -- the workspace does switch and the right
  // window does end up focused -- but the answer to the `j/activewindow` in
  // the same batch can still be the window that had focus *before* the click.
  // The overlay gives its keyboard grab back one statement before the dispatch
  // goes out (see beginHandOff), and giving it back is a Wayland commit that
  // Hyprland has not necessarily processed by the time it reads the batch. Run
  // the identical batch with no overview up and it matches every time in half
  // a millisecond; run it from here and it can describe the old focus.
  //
  // This was always true and was never visible, because the reply used to be
  // read ~700ms late (see panel.visible) -- by which point Hyprland had long
  // since settled and the answer was right for the wrong reason. Fixing the
  // stall is what surfaced it: the aim was silently falling back to the
  // pre-scroll capture, which is precisely the "dived at a place the window
  // was about to stop being" failure aimZoom was written to end.
  function aimIsStale(win) {
    if (!win || !win.address) return false
    var ipc = root.pendingActivation ? root.pendingActivation.lastIpcObject : undefined
    if (!ipc || !ipc.address) return false
    return String(win.address) !== String(ipc.address)
  }

  property int aimRetries: 0

  // Just a query this time: the dispatch has already gone out and must not be
  // sent twice, and what is still wanted is the layout it produced.
  Timer {
    id: aimRetry
    interval: 8
    onTriggered: root.hyprSend("j/activewindow")
  }

  // Hyprland has answered with the layout the dispatch produced: aim, and go.
  function beginDive(reply) {
    if (!root.awaitingLanding) return
    var win = root.parseWindow(reply)
    root.dbg("reply after " + Math.round(Date.now() - root.dbgClickMs) + "ms"
      + " retries=" + root.aimRetries
      + " deadline=" + (diveDeadline.running ? "no" : "YES-FIRED")
      + " parsed=" + (win ? "yes" : "NO")
      + " raw=" + JSON.stringify((reply || "").slice(0, 60)))
    // Ask again rather than aim at an answer known to be about the wrong
    // window. Bounded by diveDeadline alone, which is the one thing that must
    // decide when the overview stops waiting: a retry budget of its own would
    // be a second deadline to keep in step with the first.
    if (root.aimIsStale(win) && diveDeadline.running) {
      root.aimRetries++
      aimRetry.restart()
      return
    }
    root.awaitingLanding = false
    diveDeadline.stop()
    aimRetry.stop()
    root.aimZoom(win)
    root.dbg("aimed shift=" + root.diveShiftPx.toFixed(1)
      + " real=(" + Math.round(root.zoomRealX) + "," + Math.round(root.zoomRealY) + ")"
      + " scale=" + root.zoomScale.toFixed(3))
    // A swipe still on the pad takes the ramp itself; this is the moment it has
    // been waiting for and the only thing it was waiting for. A swipe already
    // released, or a click, falls through and is animated as it always was.
    if (root.gestureDiving) { root.gestureDiveAimed(); return }
    zoomRamp.run(0, 1, root.diveMs, root.finishActivation)
  }

  // The reply carries the dispatcher's own "ok" ahead of the JSON.
  function parseWindow(reply) {
    var text = reply || ""
    var start = text.indexOf("{")
    if (start < 0) return null
    try { return JSON.parse(text.slice(start)) } catch (e) { return null }
  }

  // The far end of the dive: where the window will actually be, rather than
  // where it was when it was clicked. Aiming at the latter is what used to
  // send the dive somewhere the window was about to stop being — a column
  // waiting off the right-hand edge of its workspace was dived into at its
  // off-screen place, so the strip flew off the screen, the overlay vanished,
  // and the window was found most of a screen's width to the left, having
  // scrolled there in full view.
  //
  // Leaves the aim as captured if anything about the reply is unexpected: a
  // dive to where the window was is still better than no dive at all.
  function aimZoom(win) {
    if (!win || !win.address) return
    var ipc = root.pendingActivation ? root.pendingActivation.lastIpcObject : undefined
    // Whatever Hyprland ended up focusing is not what was clicked; measuring
    // it would aim the dive at a different window entirely.
    if (!ipc || String(win.address) !== String(ipc.address)) return
    var row = rowRepeater.itemAt(root.diveRow)
    if (!row) return
    var item = row.thumbItemAt(root.diveApp)
    if (!item || item.width <= 0) return
    var r = root.rectFromIpc(win)
    if (!r) return

    // The row scrolls too, and it has to.
    //
    // A row is a workspace drawn twice over: a wallpaper fixed under the
    // middle of it, standing for the monitor, and a strip of windows that
    // slides across that wallpaper exactly as a scrolling layout slides its
    // columns across a screen that does not move. Landing the dive is
    // therefore two claims at once, not one -- this window on that window,
    // *and* this wallpaper on that monitor -- and the zoom is a single rigid
    // transform, so it can only satisfy both if the window already sits at the
    // right offset from the wallpaper before the transform is applied.
    //
    // It does not. The whole reason the dive is aimed at Hyprland's answer is
    // that focusing a window scrolls its workspace, and the row is still drawn
    // from the layout as it was before that scroll. Aiming at the new place
    // and leaving the row alone satisfies the first claim by breaking the
    // second: the transform slides the entire row, wallpaper included, by the
    // distance the layout is about to travel -- 790px of a 1600px screen in
    // the case that prompted this -- so the dive ended on the right window
    // over half a screen of wallpaper that did not belong there, complete with
    // the shadow along its edge, and all of it vanished at the unmap.
    //
    // So the row performs the same scroll, in miniature, on the same progress
    // the zoom runs on: by the time the transform is at full size the window
    // has moved to its new offset from the wallpaper, and both claims hold.
    //
    // Two distances, not one, and missing the second is what made a row with
    // more windows than fit on its monitor snap back to its opening state the
    // moment a dive started.
    //
    //   the layout's scroll -- how far the compositor is about to carry this
    //     workspace's columns to bring the focused one into view.
    //   the row's own offset -- how far the strip already stands from the
    //     position at which it is a rigid replica of the workspace
    //     (rowItem.stripOffset).
    //
    // The second is not zero as soon as the overview is used. Ring a window
    // the monitor does not cover and restX nudges the strip by the very scroll
    // the compositor is about to perform, so the row is *already* showing the
    // layout the dive is aimed at; adding the first distance on top then
    // performed that scroll a second time, sliding the windows back past the
    // wallpaper to where they stood when the overview opened -- while the
    // wallpaper, which lives outside the strip, stayed put and was carried off
    // the monitor by the transform. Scrolling a row by hand puts the same
    // offset there by a different route.
    //
    // Subtracting it means the row always ends the dive at its base, which is
    // the only place the wallpaper and the windows can both be right.
    var pre = root.rectFor(root.pendingActivation)
    root.diveShiftPx = (pre ? (pre.x - r.x) * row.geomScale : 0) - row.stripOffset
    // Where that leaves the thumbnail when the ramp is done, which is what the
    // zoom has to be aimed from -- see zoomOffset. At progress 0 the shift is
    // zero and the strip is untouched, so nothing moves under the capture.
    root.zoomThumbX -= root.diveShiftPx

    root.zoomRealX = r.x - row.monX
    root.zoomRealY = r.y - row.monY
    root.zoomScale = r.w / item.width
  }

  // The dispatch went out a whole dive ago and the desktop behind has already
  // stopped moving, so all that is left is to stop holding the frame over it.
  function finishActivation() { handOffTimer.restart() }

  // The backstop, for a reply that never comes: an overview that has already
  // handed the keyboard back and dispatched its focus cannot be left sitting
  // on the screen waiting for one.
  //
  // Armed twice, and the second time is the one that matters. It used to be
  // started once, at the click or at the start of the gesture, and sized to
  // cover the restore wait (see pendingDispatch) *plus* the round trip after
  // it -- so any overrun in the first came out of the second's budget. Diving
  // into a window on another workspace overruns both: the focus restore was
  // measured at ~163ms rather than the ~40ms this was written against, and the
  // round trip at ~142ms rather than ~12ms, because the dispatch at the head of
  // that batch is a workspace switch and Hyprland answers the socket around it.
  // 305ms of arranging against a 200ms deadline meant the deadline fired
  // *before* the reply, every single time, on every cross-workspace dive:
  // beginDive ran on an empty string, aimZoom returned without measuring
  // anything, and the dive silently fell back to the pre-dispatch capture --
  // exactly the "dived at a place the window was about to stop being" failure
  // aimZoom exists to end.
  //
  // So runPendingDispatch re-arms it when the dispatch actually goes out, and
  // this is a deadline on the round trip alone. The arming at the click still
  // stands, and still covers the one thing the other cannot: a restore that
  // never completes, so the dispatch never leaves.
  Timer {
    id: diveDeadline
    interval: 300
    onTriggered: {
      root.dbg("DEADLINE fired at " + (Date.now() - root.dbgClickMs) + "ms")
      root.beginDive("")
    }
  }

  // Measures the zoom and starts the fall-back on the first frame the
  // compositor could actually show, and not one frame later.
  //
  // This used to be a 16ms Timer that waited for panel.height and
  // column.height to be non-zero on two consecutive ticks, and it was starved
  // by exactly the work it was waiting on. Opening the overview means mapping
  // a fresh full-screen layer surface, and the two frames that takes were
  // measured at ~200ms each -- a cost in the surface itself, not in what is
  // drawn on it: taking the row shadows out, then the screencopy streams, then
  // the wallpaper, each changed it by nothing. So the timer's ticks landed
  // around half a second after the swipe, and the strip was held invisible for
  // every one of them. That half second of nothing is what made the overview
  // feel slow to open; it was never the animation.
  //
  // A FrameAnimation ticks with the renderer instead, so its first trigger is
  // the first frame. Measuring there needs the scene laid out, which it is
  // from the second summon onwards because the plugin is keepLoaded and the
  // rows survive between them. On the very first open of a session it is not,
  // and rather than hold the surface blank for another ~200ms frame, the zoom
  // is skipped and the overview simply appears whole.
  FrameAnimation {
    id: zoomOpener
    running: root.opened && !root.zoomReady
    onTriggered: {
      root.dbg("zoomOpener frame: selectedRow=" + root.selectedRow
        + " selectedApp=" + root.selectedApp
        + " rows=" + JSON.stringify(root.workspaceRows.map(function(r) { return r.id }))
        + " gestureActive=" + root.gestureActive)
      if (root.captureZoom(root.selectedRow, root.selectedApp)) {
        root.dbg("zoomOpener captured thumb=("
          + Math.round(root.zoomThumbX) + "," + Math.round(root.zoomThumbY)
          + ") real=(" + Math.round(root.zoomRealX) + "," + Math.round(root.zoomRealY)
          + ") scale=" + root.zoomScale.toFixed(3))
        root.zoomReady = true
        // A swipe has been driving zoomProgress since before this frame
        // existed, and all it wanted from here was the measurement. Running
        // the ramp as well would put two writers on the same property, and
        // the one that is not the fingers would win.
        if (root.gestureActive) return
        // One capped step in, rather than at the very start. The frame this
        // runs for is the first one the compositor can show, and at progress 1
        // the strip is a pixel-exact stand-in for the window it covers — so
        // starting the ramp at 1 spends that hard-won first frame drawing
        // something indistinguishable from the desktop that was already there,
        // and the earliest anything can be seen to move is the frame after it,
        // which is the other expensive one. Starting a step in means the first
        // thing drawn is the overview already pulling back. It is not a cheat
        // either: a good fraction of a second of real time passed while the
        // surface was being mapped, which is a great deal more than the one
        // frame of ramp it is credited with.
        zoomRamp.run(1, 0, root.openMs, null, zoomRamp.maxStep)
      } else {
        root.dbg("zoomOpener CAPTURE FAILED -- no zoom this open")
        // No zoom to drive, so no gesture to drive it with: the overview
        // simply appears whole, which is what this fallback has always meant.
        // The mode is dropped here rather than left to the fingers lifting,
        // because a swipe still thought to be in flight would be read as a
        // gesture still in flight when it ended, and let its last events go on
        // writing zoomProgress on an overview that had already given up on it.
        root.gestureMode = ""
        root.clearZoom()
      }
    }
  }

  // Both zooms run through here rather than through a NumberAnimation, and
  // the reason is the same two expensive frames.
  //
  // A wall-clock animation advances by however long the last frame took, so a
  // 260ms zoom started for the first frame of a fresh surface is simply over
  // by the time the second one is drawn: the overview snapped into place
  // instead of falling back into it, and the transition the animation exists
  // to show was never on screen. Capping how far a single frame may carry the
  // ramp turns that into a slower zoom rather than no zoom.
  //
  // On a healthy 60Hz frame the cap is nowhere near reached (16ms of 260 is a
  // sixteenth) and this is exactly the animation it replaces.
  FrameAnimation {
    id: zoomRamp
    running: false
    property real fromValue: 0
    property real toValue: 0
    property real durationMs: 260
    property real t: 0
    property var whenDone: null

    // A sixth of the ramp: the slowest frame imaginable still leaves five
    // more steps of visible motion after it.
    readonly property real maxStep: 1 / 6

    // `head` starts the ramp already that far along, for a ramp whose first
    // frame is also the first frame anyone can see.
    property var dbgTimes: []
    property int dbgFrames: 0
    property real dbgMaxFrame: 0
    property real dbgStart: 0

    function run(a, b, ms, done, head) {
      zoomRamp.dbgFrames = 0
      zoomRamp.dbgTimes = []
      zoomRamp.dbgMaxFrame = 0
      zoomRamp.dbgStart = Date.now()
      zoomRamp.fromValue = a
      zoomRamp.toValue = b
      zoomRamp.durationMs = Math.max(1, ms)
      zoomRamp.whenDone = done || null
      zoomRamp.t = head || 0
      root.zoomProgress = a + (b - a) * zoomRamp.eased(zoomRamp.t)
      zoomRamp.restart()
    }

    // Stops without running the completion: for clearZoom, which is undoing
    // the ramp rather than finishing it.
    function halt() {
      zoomRamp.whenDone = null
      zoomRamp.stop()
    }

    // OutCubic falling back into the overview, InOutCubic diving into a
    // window, written out because a FrameAnimation has no easing curve of its
    // own.
    //
    // The dive was an InCubic, and a cubic ease-*in* puts almost all of its
    // travel in the last third of the ramp. Now that the dive crosses whatever
    // distance the layout is about to scroll (see aimZoom) rather than a
    // thumbnail's width, that meant three or four frames carrying a couple of
    // hundred pixels each -- the choppiest possible way to arrive, at the one
    // moment that has to be invisible, since arriving is where the strip and
    // the real window have to become the same picture. Easing out into the
    // landing spends those frames a pixel or two at a time instead.
    function eased(x) {
      if (zoomRamp.toValue < zoomRamp.fromValue) return 1 - Math.pow(1 - x, 3)
      return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2
    }

    onTriggered: {
      if (root.omariDebug) {
        zoomRamp.dbgFrames++
        if (zoomRamp.frameTime * 1000 > zoomRamp.dbgMaxFrame)
          zoomRamp.dbgMaxFrame = zoomRamp.frameTime * 1000
        zoomRamp.dbgTimes.push(Math.round(zoomRamp.frameTime * 1000))
      }
      // frameTime is seconds since the previous frame.
      var step = Math.min(zoomRamp.frameTime * 1000 / zoomRamp.durationMs,
                          zoomRamp.maxStep)
      zoomRamp.t = Math.min(1, zoomRamp.t + step)
      root.zoomProgress = zoomRamp.fromValue
        + (zoomRamp.toValue - zoomRamp.fromValue) * zoomRamp.eased(zoomRamp.t)
      if (zoomRamp.t < 1) return
      root.dbg((zoomRamp.toValue > zoomRamp.fromValue ? "dive" : "open")
        + " ramp done: " + zoomRamp.dbgFrames + " frames over "
        + Math.round(Date.now() - zoomRamp.dbgStart) + "ms"
        + " (asked " + Math.round(zoomRamp.durationMs) + "ms)"
        + " worst frame " + zoomRamp.dbgMaxFrame.toFixed(1) + "ms"
        + " avg " + ((Date.now() - zoomRamp.dbgStart) / Math.max(1, zoomRamp.dbgFrames)).toFixed(1) + "ms"
        + " frames=[" + zoomRamp.dbgTimes.join(",") + "]")
      zoomRamp.stop()
      var done = zoomRamp.whenDone
      zoomRamp.whenDone = null
      if (done) done()
    }
  }

  // ---- the opening swipe ----
  //
  // The 4-finger swipe does not start the opening zoom, it *is* the opening
  // zoom. zoomProgress is written straight from how far the fingers have
  // travelled, so the overview pulls back under them and stands wherever they
  // stand; letting go only finishes the direction it was already going, and
  // pushing back down before letting go returns the desktop without the
  // overview ever having committed to opening. That is the whole difference
  // between this and an animation a gesture triggers.
  //
  // The compositor does the tracking. Hyprland's Lua gestures take a table of
  // start/update/finish callbacks rather than one function, and hypr/
  // omari-overview.lua turns each update into a `custom` line on the event
  // socket carrying the accumulated upward travel in pixels. This end turns
  // pixels into progress, because this end is the one that knows how tall the
  // screen is and what the overview is currently doing.
  //
  // None of it would be worth having without panel.visible: a swipe that has
  // to wait for a layer surface to be mapped is a swipe that does nothing for
  // a third of a second and then jumps.

  // What the swipe currently in flight means:
  //
  //   ""       nothing owns the overview
  //   "open"   a swipe up is driving the zoom out of the desktop
  //   "dive"   a swipe down is driving the zoom into the centred window
  //   "leave"  a swipe down that found nothing to dive into
  //
  // A swipe up that arrives on an overview already open sets nothing at all
  // and is ignored for its whole length: up is the way in, down is the way
  // out, and neither doubles as the other.
  //
  // Decided when the swipe starts and never re-read: a gesture that begins as
  // a dismissal stays one however far the fingers then wander, which is what
  // stops a wobble halfway through from changing what letting go will mean.
  property string gestureMode: ""
  readonly property bool gestureActive: root.gestureMode === "open"
  readonly property bool gestureDiving: root.gestureMode === "dive"

  // Finger travel for a full zoom out. A fraction of the screen rather than a
  // pixel count, for the same reason rowHeight is one: the gesture should ask
  // for the same *stroke* on a laptop panel and on a large monitor. The floor
  // keeps it sane before the surface has been given its size.
  readonly property real gestureDistance: Math.max(Style.space(180), panel.height * 0.3)

  // What counts as meaning it. Either the overview is a third of the way out,
  // or the fingers were still moving fast enough at the moment they lifted —
  // the second is what lets a quick flick open it without dragging all the
  // way, and it is measured over the last events rather than across the whole
  // swipe, so a fast stroke that stops dead before lifting does not count.
  readonly property real gestureCommitRatio: 0.32
  readonly property real gestureFlickSpeed: 0.4   // px per ms

  // How long after the last movement the fingers still count as travelling.
  // A touchpad only reports motion, so a swipe that stops on the pad and is
  // held there sends nothing at all, and the last speed measured stays on the
  // books however long it is held. Without this, swiping a couple of
  // centimetres, resting, and letting go would be read as the flick the swipe
  // *started* as, and would open an overview the fingers had plainly decided
  // against.
  readonly property int gestureIdleMs: 50

  // Whether the dive gesture has been told where it is going yet, and the
  // travel reading at the moment it was. See gestureDiveBegin: the fingers
  // move for something like a tenth of a second before the zoom may follow
  // them, and measuring from here rather than from the start of the swipe is
  // what keeps that beat from becoming a jump.
  property bool gestureAimed: false
  property real gestureTravelOrigin: 0

  // How to put the focus back if a dive gesture is abandoned. Captured before
  // anything is dispatched, because by the time it is wanted the compositor
  // has already been moved.
  property string gestureRestoreArg: ""

  property real gestureVelocity: 0
  property real gestureLastTravel: 0
  property real gestureLastTime: 0

  function gestureBegin() {
    if (root.gestureMode !== "") return
    // A dive owns zoomProgress from the click until the surface goes away and
    // a fade owns the surface itself. Neither wants a second writer, and a
    // swipe arriving on one is a swipe at nothing in particular.
    if (root.leaving || root.pendingActivation) return
    // Up is the way *in*, and only that. Swiping further up on an overview
    // already open used to dismiss it, which made the same stroke mean
    // "open" and "close" depending on a state you cannot see from your
    // fingers — and put the two halves of the gesture on the same side, so
    // reversing an over-shot swipe read as asking to leave. Down is the way
    // out now, and it is the only way out; see gestureDiveBegin.
    if (root.opened) return

    root.gestureMode = "open"
    root.gestureVelocity = 0
    root.gestureLastTravel = 0
    root.gestureLastTime = 0
    root.open()
    // No keyboard grab yet. Taking one makes Hyprland restore focus when it
    // is handed back ~40ms later (see pendingDispatch), and a swipe that is
    // pushed back down before it commits should cost the window underneath
    // nothing whatsoever. The grab is taken when the open is committed.
    root.grabsKeyboard = false
  }

  function gestureAt(travel, timeMs) {
    if (!root.gestureActive) return
    if (root.gestureLastTime > 0 && timeMs > root.gestureLastTime) {
      // Half the running value, half the new reading, rather than the reading
      // alone: a touchpad puts the occasional 1px event between two 20px ones,
      // and a raw speed sampled at the instant the fingers lift is as likely
      // to catch one of those as not — which would turn a genuine flick into
      // a revert.
      root.gestureVelocity = 0.5 * root.gestureVelocity
        + 0.5 * (travel - root.gestureLastTravel) / (timeMs - root.gestureLastTime)
    }
    root.gestureLastTravel = travel
    root.gestureLastTime = timeMs
    // Clamped rather than wrapped or rubber-banded: past a full zoom there is
    // nothing further out to show, and short of zero the desktop is already
    // all there is.
    root.zoomProgress = 1 - Math.max(0, Math.min(1, travel / root.gestureDistance))
  }

  function gestureFinish(cancelled, timeMs) {
    // Only ever clears a mode this handler owns. Hyprland runs one gesture at a
    // time, so the two directions cannot genuinely overlap — but a stray end
    // event that cleared a dive halfway through would leave the compositor
    // switched, the geometry frozen, and nothing holding the thread.
    var mode = root.gestureMode
    if (mode !== "open") return
    root.gestureMode = ""

    var resting = root.gestureLastTime > 0 && timeMs > 0
      && (timeMs - root.gestureLastTime) > root.gestureIdleMs
    var speed = resting ? 0 : root.gestureVelocity

    var shown = 1 - root.zoomProgress
    var commit = !cancelled
      && (shown >= root.gestureCommitRatio || speed >= root.gestureFlickSpeed)

    // Both tails are timed by what is left to travel rather than by a fixed
    // duration. Releasing at nine tenths open and then watching a full-length
    // ramp play out the last tenth reads as the overview hesitating after the
    // fingers have already finished with it. The floor is there so that a
    // release at the very end is still a frame or two of motion and not a cut.
    if (commit) {
      root.grabsKeyboard = true
      zoomRamp.run(root.zoomProgress, 0,
        Math.round(root.openMs * Math.max(0.15, root.zoomProgress)), null)
    } else {
      // Straight to finish() and not through close(): the exit fade exists to
      // keep a dismissal from cutting, and there is nothing here to cut. At
      // progress 1 the strip is already a pixel-exact stand-in for the desktop
      // underneath it, so the surface can simply stop being drawn.
      zoomRamp.run(root.zoomProgress, 1,
        Math.round(root.openMs * Math.max(0.15, 1 - root.zoomProgress)),
        root.finish)
    }
  }

  // ---- the closing swipe ----
  //
  // Swiping down is the opening swipe's mirror in feel and nothing like it in
  // machinery, because leaving is not only a zoom. It lands you on the
  // workspace you are *looking at*, so it is a workspace switch as well, and a
  // switch moves the very thing the zoom has to land on: focusing a window in a
  // scrolling layout scrolls its workspace to bring that column into view. The
  // dive therefore has to be aimed at where the window is about to be, and
  // nothing knows that until the focus dispatch has landed — see aimZoom, which
  // is the whole reason the click path takes a round trip through Hyprland
  // rather than measuring what is on screen.
  //
  // So this gesture front-loads the arrangement the click does at its click:
  // freeze, capture, hand the keyboard grab back, dispatch, ask where the
  // window went. All of that is ~100ms, most of it waiting for Hyprland to
  // finish restoring focus after the grab goes back (see pendingDispatch), and
  // for that ~100ms the fingers move and the zoom does not. The alternative is
  // aiming at where the window is *now* and correcting when the answer comes
  // back, which is a jerk in the middle of the one transition that has to be
  // seamless. Standing still under an opaque backdrop is the cheaper place to
  // spend it, and the travel origin is taken when the answer lands so that the
  // wait costs a beat rather than a jump.
  //
  // What the fingers then drive is exactly the ramp beginDive would have run.
  //
  // Unlike the opening swipe, this one has something to undo if it is
  // abandoned: the workspace has really been switched by then. Cancelling
  // ramps back to the overview and dispatches the focus back, which is why the
  // window to return to is captured before anything is sent.
  function gestureDiveBegin() {
    if (root.gestureMode !== "") return
    if (!root.opened || root.leaving || root.pendingActivation) return

    // A ramp still running from the swipe that opened this would be a second
    // writer on zoomProgress. Rare enough to want no ceremony -- it takes
    // starting a downward swipe inside the ~260ms tail of an upward one -- and
    // the dive is measured from the overview, so it starts from there.
    zoomRamp.halt()
    root.zoomProgress = 0

    var row = root.workspaceRows[root.selectedRow]
    var apps = root.selectedToplevels
    var index = Math.max(0, Math.min(apps.length - 1, root.selectedApp))
    var toplevel = apps.length > 0 ? apps[index] : null
    var arg = root.isEmptyRowModel(row)
      ? (row ? "hl.dsp.focus({ workspace = '" + row.id + "' })" : "")
      : root.focusArg(toplevel)

    root.dbg("diveBegin row=" + root.selectedRow
      + " wsId=" + (row ? row.id : "?")
      + " empty=" + root.isEmptyRowModel(row)
      + " apps=" + apps.length + " index=" + index
      + " arg=" + JSON.stringify(arg))

    if (!arg) { root.dbg("diveBegin ABORT: no focus arg"); return }

    // The empty row is a workspace with nothing on it, so there is no window to
    // dive into and nothing for the fingers to drive. It still switches — it
    // just decides on release, the way it does from a click.
    if (root.isEmptyRowModel(row) || !toplevel) {
      root.dbg("diveBegin LEAVE: empty row or no toplevel")
      root.gestureMode = "leave"
      return
    }

    // Measured first, frozen second -- see captureZoom.
    if (!root.captureZoom(root.selectedRow, index)) {
      root.dbg("diveBegin LEAVE: captureZoom failed")
      // Nothing measurable to zoom, which is the same position the click path
      // finds itself in and answers the same way: switch on release, plainly.
      // Nothing to thaw: the freeze has not happened yet.
      root.gestureMode = "leave"
      return
    }
    root.freezeGeometry()

    root.dbg("diveBegin captured thumb=(" + Math.round(root.zoomThumbX)
      + "," + Math.round(root.zoomThumbY) + ") real=(" + Math.round(root.zoomRealX)
      + "," + Math.round(root.zoomRealY) + ") scale=" + root.zoomScale.toFixed(3)
      + " -- expected thumbY near 247 for the centred row")
    root.gestureMode = "dive"
    root.gestureAimed = false
    root.gestureTravelOrigin = 0
    root.gestureVelocity = 0
    root.gestureLastTravel = 0
    root.gestureLastTime = 0
    root.gestureRestoreArg = root.focusArg(Hyprland.activeToplevel)
    root.dbgClickMs = Date.now()

    root.pendingActivation = toplevel
    root.aimRetries = 0
    root.diveRow = root.selectedRow
    root.diveApp = index
    root.awaitingLanding = true

    // Deliberately not beginHandOff. That raises `leaving` and drops `opened`,
    // which is right for a click -- a click has already decided -- and wrong
    // for a gesture that may still be pushed back up. The overview is still
    // open until the fingers say otherwise, and the surface no longer needs
    // `leaving` to keep it mapped. Only the grab goes, because only the grab
    // stands between the dispatch and its landing.
    root.grabsKeyboard = false
    root.pendingDispatch = arg
    restoreFallback.restart()
    diveDeadline.restart()
  }

  function gestureDiveAt(travel, timeMs) {
    if (root.gestureMode !== "dive") return
    if (root.gestureLastTime > 0 && timeMs > root.gestureLastTime) {
      root.gestureVelocity = 0.5 * root.gestureVelocity
        + 0.5 * (travel - root.gestureLastTravel) / (timeMs - root.gestureLastTime)
    }
    root.gestureLastTravel = travel
    root.gestureLastTime = timeMs
    // Still arranging the dive. The travel keeps being read, so the speed at
    // the release is honest, but the zoom does not move until it knows where
    // it is going.
    if (!root.gestureAimed) return
    root.zoomProgress = Math.max(0, Math.min(1,
      (travel - root.gestureTravelOrigin) / root.gestureDistance))
  }

  // Hyprland has answered with the layout the dispatch produced and aimZoom has
  // pointed the dive at it. From here the fingers own the ramp.
  function gestureDiveAimed() {
    root.gestureAimed = true
    root.gestureTravelOrigin = root.gestureLastTravel
    root.dbg("dive gesture aimed after "
      + Math.round(Date.now() - root.dbgClickMs) + "ms, origin "
      + Math.round(root.gestureTravelOrigin) + "px")
  }

  function gestureDiveFinish(cancelled, timeMs) {
    root.dbg("diveFinish cancelled=" + cancelled + " mode=" + JSON.stringify(root.gestureMode)
      + " aimed=" + root.gestureAimed + " progress=" + root.zoomProgress.toFixed(3)
      + " vel=" + root.gestureVelocity.toFixed(3))
    // Its own modes only; see gestureFinish.
    var mode = root.gestureMode
    if (mode !== "dive" && mode !== "leave") return
    root.gestureMode = ""

    if (mode === "leave") {
      // Nothing was arranged, so nothing has to be undone and nothing was
      // stored: activateSelection recomputes the target and walks the same
      // fallback chain a click does, ending at a plain hand-off.
      if (!cancelled) root.activateSelection()
      return
    }

    var resting = root.gestureLastTime > 0 && timeMs > 0
      && (timeMs - root.gestureLastTime) > root.gestureIdleMs
    var speed = resting ? 0 : root.gestureVelocity

    // How far down the fingers ended up, as a fraction of a full zoom, whether
    // or not the zoom was free to follow them at the time.
    //
    // zoomProgress alone is not that, and on a dive it can be a great deal
    // less. The zoom cannot move until the aim comes back (see
    // gestureDiveBegin), and gestureTravelOrigin then quite rightly discounts
    // everything travelled before that so the zoom picks up from where the
    // fingers are rather than jumping to it. But arranging a dive into another
    // workspace is not the ~100ms this was written for -- measured at ~305ms,
    // which on a firm 400px swipe is 288px of it spent standing still. Asking
    // for a third of a zoom *on top of* that asked for a stroke half again as
    // long as the same gesture needs anywhere else, and a perfectly ordinary
    // swipe onto a neighbouring workspace was read as a swipe that had thought
    // better of it: the overview restored, and the workspace you had plainly
    // asked for never arrived.
    //
    // Travel is the accumulated signed total, so this is not simply "did the
    // fingers move a lot" -- pushing back up brings it down again, and a swipe
    // that goes down and returns still reads as cancelled. Where the beat is
    // short, origin is near zero and this says the same thing zoomProgress
    // does; it only starts to matter where the overview was too busy to answer.
    var stroke = root.gestureDistance > 0
      ? root.gestureLastTravel / root.gestureDistance
      : 0

    var commit = !cancelled
      && (root.zoomProgress >= root.gestureCommitRatio
        || stroke >= root.gestureCommitRatio
        || speed >= root.gestureFlickSpeed)

    if (!root.gestureAimed) {
      // Released inside the arranging beat. There is no ramp to finish because
      // there is no aim yet, so hand it back to the machinery that was already
      // going to do this: clearing the mode above is what lets beginDive run
      // its own ramp when the answer arrives, exactly as it does for a click.
      if (commit) {
        // `leaving` first, then `opened` -- see panel.visible.
        root.leaving = true
        root.opened = false
        return
      }
      root.gestureDiveRestore()
      return
    }

    if (commit) {
      root.leaving = true
      root.opened = false
      zoomRamp.run(root.zoomProgress, 1,
        Math.round(root.diveMs * Math.max(0.15, 1 - root.zoomProgress)),
        root.finishActivation)
      return
    }

    zoomRamp.run(root.zoomProgress, 0,
      Math.round(root.diveMs * Math.max(0.15, root.zoomProgress)),
      root.gestureDiveRestore)
  }

  // Putting back everything gestureDiveBegin moved. The zoom is already home
  // by the time this runs; what is left is the compositor, which has really
  // switched workspace behind the backdrop and has to be switched back.
  function gestureDiveRestore() {
    var back = root.gestureRestoreArg
    root.gestureRestoreArg = ""
    root.gestureAimed = false
    root.gestureTravelOrigin = 0

    // Before hyprSend, and not only for tidiness: the socket's reply lands in
    // beginDive, and `awaitingLanding` is the flag that makes it ignore one it
    // was not waiting for.
    root.awaitingLanding = false
    diveDeadline.stop()
    aimRetry.stop()
    root.pendingActivation = null
    root.diveRow = -1
    root.diveApp = -1
    root.diveShiftPx = 0
    root.zoomProgress = 0
    root.zoomScale = 1
    root.zoomThumbX = 0
    root.zoomThumbY = 0
    root.zoomRealX = 0
    root.zoomRealY = 0
    root.thawGeometry()

    if (root.pendingDispatch !== "") {
      // Abandoned before the dispatch ever went out — Hyprland was still
      // restoring focus from the grab going back. Nothing switched, so there is
      // nothing to switch back, and the restore still in flight is aimed at the
      // window this would have asked for anyway.
      root.pendingDispatch = ""
      restoreFallback.stop()
    } else if (back !== "") {
      root.hyprSend("dispatch " + back)
    }

    // Last, and after the dispatch rather than before it. Taking the grab does
    // not schedule a focus restore the way giving it back does — that hazard
    // runs the other way (see pendingDispatch) — but the dispatch above is the
    // statement that has to be the last word about where focus ends up, and
    // sending it into a surface that has just re-asserted exclusive focus is
    // the one ordering nobody has to reason about.
    root.grabsKeyboard = true
  }

  // Deliberately not gated on `opened`, unlike the geometry listener above:
  // the first event of a swipe arrives while the overview is still down, and
  // that is the entire point of it.
  //
  // `custom` is what hl.dsp.event puts on the socket, and every shell on the
  // machine sees all of them — hence the prefix test before anything is parsed.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "custom") return
      var data = String(event.data || "")
      if (data.indexOf("omari:overview-") !== 0) return
      var parts = data.split(" ")
      switch (parts[0]) {
      case "omari:overview-begin":
        root.gestureBegin()
        break
      case "omari:overview-at":
        root.gestureAt(Number(parts[1]), Number(parts[2]))
        break
      case "omari:overview-end":
        root.gestureFinish(parts[1] === "1", Number(parts[2]))
        break
      case "omari:overview-down-begin":
        root.gestureDiveBegin()
        break
      case "omari:overview-down-at":
        root.gestureDiveAt(Number(parts[1]), Number(parts[2]))
        break
      case "omari:overview-down-end":
        root.gestureDiveFinish(parts[1] === "1", Number(parts[2]))
        break
      }
    }
  }

  // ---- scroll input routing ----

  // A touchpad delivers pixel deltas tagged with a scroll phase; a mouse
  // wheel delivers angle deltas and no phase at all. They want completely
  // different handling — the first tracks fingers 1:1, the second glides a
  // fixed step — so classify once, here.
  function isTouchpadWheel(wheel) {
    return wheel.phase !== Qt.NoScrollPhase
      || wheel.pixelDelta.x !== 0
      || wheel.pixelDelta.y !== 0
  }

  // Which axis the in-flight touchpad gesture owns: decided from the first
  // delta big enough to have a direction, and held until the fingers lift.
  // Deciding per event instead — comparing |dx| against |dy| every time —
  // lets a gesture that wobbles a couple of degrees hand itself back and
  // forth between a workspace row and the workspace list mid-scroll, which
  // is its own kind of stutter.
  property string gestureAxis: ""

  function axisFor(dx, dy) {
    if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return ""
    return Math.abs(dx) > Math.abs(dy) ? "x" : "y"
  }

  // The scroller a horizontal gesture drives: the centred row's, always.
  //
  // This used to be routed by pointer position — each row carried its own
  // wheel handler and got the event only when the cursor was over it — which
  // meant a two-finger swipe scrolled whichever row the mouse happened to have
  // been left on, and did nothing at all if that row had nothing to scroll.
  // A touchpad gesture has no pointer to speak of, and everything else in here
  // (left/right, Enter, the ring) already acts on the centred row.
  function selectedRowScroll() {
    var row = rowRepeater.itemAt(root.selectedRow)
    return row ? row.hScroll : null
  }

  // Releases the axis lock if the gesture's Qt.ScrollEnd never arrives.
  Timer {
    id: gestureIdle
    interval: 160
    onTriggered: root.gestureAxis = ""
  }

  // Hyprland's own idea of "the app in focus" per workspace: the lowest
  // focusHistoryID among that workspace's windows (0 is the single globally
  // focused window; on every other workspace this is whichever window would
  // regain focus if you switched there). Falls back to the first window if
  // the field is ever missing.
  // Frozen along with the rectangles, and for a sharper reason than they are.
  // A focus dispatch renumbers focusHistoryID across *every* workspace, not
  // just the one being switched to, so a live read here moved the ring on rows
  // the click never touched -- and the ring is not decoration: it feeds
  // rowItem.selectedIndex, which feeds restX, which is a KineticScroll rest
  // position, so each of those rows glided its strip somewhere new in the
  // middle of the dive.
  function focusHistoryIdFor(toplevel) {
    var ipc = toplevel ? toplevel.lastIpcObject : undefined
    if (root.frozenFocus && ipc && ipc.address) {
      var frozen = root.frozenFocus[ipc.address]
      if (frozen !== undefined) return frozen
    }
    var raw = ipc ? ipc.focusHistoryID : undefined
    var n = Number(raw)
    return isFinite(n) ? n : Number.MAX_SAFE_INTEGER
  }

  function focusedIndexFor(values) {
    var bestIndex = 0
    var bestScore = Infinity
    for (var i = 0; i < values.length; i++) {
      var score = root.focusHistoryIdFor(values[i])
      if (score < bestScore) { bestScore = score; bestIndex = i }
    }
    return bestIndex
  }

  // Real on-screen x position of a window, as Hyprland reports it (top-left
  // corner, in layout/monitor coordinates), so thumbnails can be ordered the
  // same way the actual windows are arranged on the workspace rather than
  // whatever order Hyprland's toplevels list happens to hold.
  //
  // Through rectFor rather than off lastIpcObject directly, so the sort is
  // frozen with everything else. It was the one measurement the freeze did not
  // reach, and being a *sort* it was the most visible thing that could still
  // move: the instant the dispatch landed, Hyprland's goal `at` for the
  // destination workspace's windows was already the post-scroll layout, the
  // row re-sorted, and its thumbnails swapped places outright -- a jump, not a
  // slide, inside a layer on its way to twice size.
  function spatialXFor(toplevel) {
    var r = root.rectFor(toplevel)
    return r ? r.x : Number.MAX_SAFE_INTEGER
  }

  function sortToplevelsBySpatialOrder(values) {
    var arr = values ? values.slice() : []
    arr.sort(function(a, b) { return root.spatialXFor(a) - root.spatialXFor(b) })
    return arr
  }

  // What everything the overview *draws* asks. Answers with the frozen
  // rectangle once the overview is leaving, and with Hyprland's live one until
  // then; see frozenRects below for why the two have to be different.
  function rectFor(toplevel) {
    if (root.frozenRects) {
      var ipc = toplevel ? toplevel.lastIpcObject : undefined
      var frozen = (ipc && ipc.address) ? root.frozenRects[ipc.address] : undefined
      if (frozen) return frozen
    }
    return root.liveRectFor(toplevel)
  }

  // A window's real rectangle in Hyprland's layout coordinates, or null when
  // it has no usable geometry yet. This is what lets a row be drawn as a
  // scaled replica of the workspace rather than a strip of same-height tiles:
  // every window keeps its true size and position relative to the monitor, so
  // a half-width window is half the width of the wallpaper behind it.
  //
  // Note these are *logical* pixels, while HyprlandMonitor reports its size in
  // physical ones — see geomScale in the row delegate, which divides the
  // monitor back down before the two are compared.
  function liveRectFor(toplevel) {
    return root.rectFromIpc(toplevel ? toplevel.lastIpcObject : undefined)
  }

  // The same measurement off a bare window object, for the one that comes back
  // from Hyprland by hand rather than through Quickshell's model; see
  // diveDispatch.
  function rectFromIpc(ipc) {
    var at = ipc ? ipc.at : undefined
    var size = ipc ? ipc.size : undefined
    if (!at || !size || at.length < 2 || size.length < 2) return null
    var x = Number(at[0]), y = Number(at[1])
    var w = Number(size[0]), h = Number(size[1])
    if (!isFinite(x) || !isFinite(y) || !isFinite(w) || !isFinite(h)) return null
    if (w <= 0 || h <= 0) return null
    return { x: x, y: y, w: w, h: h }
  }

  // ---- frozen geometry ----
  //
  // Activating a window moves the very layout the overview is a picture of.
  // Hyprland reports a window's *goal* rectangle rather than its animated one,
  // so the instant the focus dispatch lands, `at` for every window on the
  // destination workspace is already the place the scrolling layout is about
  // to slide it to. That is exactly what the dive needs to aim at (aimZoom),
  // and exactly what the rows underneath the dive must not follow: a row that
  // re-lays itself out mid-dive drags the thumbnail being dived into sideways
  // inside a layer scaled by 2x or more, and every window in the row with it.
  //
  // So the rows are pinned to the rectangles they had at the moment of the
  // click, and the fresh geometry is read straight from IPC by the dive alone.
  // Pinning them is also what makes the landing exact for the whole row rather
  // than for one window: a scrolling layout brings a column into view by
  // translating every column by the same amount, so a frozen row is a rigid
  // replica, and putting the target on its real place puts every one of its
  // neighbours on theirs too.
  property var frozenRects: null
  property var frozenRows: null
  property var frozenFocus: null

  // Whether the picture is pinned. The scrollers bind their own `frozen` to
  // this rather than being told once, so nothing that arrives later can start
  // them moving again -- see KineticScroll.
  readonly property bool viewIsFrozen: root.frozenRects !== null

  // A row list that answers the three questions the delegates ask -- `id`,
  // `monitor`, `toplevels.values` -- out of plain snapshots rather than out of
  // live Hyprland objects.
  //
  // Holding root.workspaceRows itself was not enough. The *list* stopped being
  // rebuilt, but the entries in it were the real HyprlandWorkspace objects,
  // and `toplevels.values` on one of those is as live as anything else here:
  // the focus dispatch moves the active workspace, Quickshell rebuilds that
  // model, and a row silently gained or lost a window mid-dive -- which
  // re-runs the Repeater over it and re-lays out every thumbnail beside it.
  function snapshotRows(rows) {
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var vals = (row && row.toplevels) ? row.toplevels.values : []
      out.push({
        id: row.id,
        omariEmpty: !!row.omariEmpty,
        monitor: row.monitor,
        toplevels: { values: vals.slice() }
      })
    }
    return out
  }

  function freezeGeometry() {
    if (root.frozenRects) return
    geometryRefresh.stop()
    var frozen = ({})
    var focus = ({})
    var rows = root.windowedRows
    for (var i = 0; i < rows.length; i++) {
      var vals = rows[i].toplevels.values
      for (var j = 0; j < vals.length; j++) {
        var ipc = vals[j] ? vals[j].lastIpcObject : undefined
        if (!ipc || !ipc.address) continue
        var r = root.liveRectFor(vals[j])
        if (r) frozen[ipc.address] = r
        var h = Number(ipc.focusHistoryID)
        if (isFinite(h)) focus[ipc.address] = h
      }
    }
    // All three are handed the value the live binding is answering with right
    // now, so raising the flags changes nothing that is on screen: the freeze
    // is invisible going in, and only shows up as the things that stop
    // happening after it. Rows last, since snapshotRows sorts through
    // rectFor and wants the rectangles already pinned when it does.
    root.frozenFocus = focus
    root.frozenRects = frozen
    root.frozenRows = root.snapshotRows(root.workspaceRows)
    // The rectangles are only half of it: a strip still coasting from a flick,
    // or gliding towards a rest position, moves under the zoom just as surely
    // as a re-layout would.
    vScroll.stop()
    root.viewFrozen()
  }

  function thawGeometry() {
    root.frozenRects = null
    root.frozenRows = null
    root.frozenFocus = null
  }

  // Dispatches through Hyprland itself (hl.dsp.focus({ window = ... })),
  // rather than the generic wlr-foreign-toplevel activate() request that
  // used to run here: activate() only asks for keyboard focus and leaves it
  // up to the compositor whether that also raises the window's workspace,
  // and doing it while this overlay still holds exclusive keyboard focus
  // races the unmap of that same surface. Hyprland's own focus dispatcher
  // switches the active workspace to the window's as an intrinsic part of
  // focusing it, so this reaches both the app and its workspace
  // deterministically.
  //
  // Shells out to `hyprctl dispatch` instead of calling Quickshell's own
  // Hyprland.dispatch() QML method: that method silently has no effect here,
  // most likely because it still speaks Hyprland's pre-0.55 two-part
  // "dispatch <name> <args>" wire format, while 0.55+ parses
  // `hyprctl dispatch <arg>` as a Lua expression fed to hl.dispatch() --
  // exactly what this line sends. `hyprctl dispatch` itself was verified
  // directly against a live window and does switch focus + workspace.
  //
  // Spawned bare, NOT through Util.execArgv: that helper runs everything under
  // `bash -lc`, and a login shell costs ~280ms here sourcing profile scripts —
  // against ~10ms for hyprctl itself. It was the whole of the lag between the
  // overview closing and the workspace actually changing. Nothing on this
  // command line needs a shell: no globbing, no variables, no PATH lookup
  // beyond /usr/bin, which the shell process already has.
  //
  // The order around that dispatch is the delicate part: hand the keyboard
  // grab back, dispatch, and only *then* unmap, a good deal later. It matters
  // in both directions and this is the only order that satisfies both.
  //
  // Dispatching while the grab is still held does not stick: Hyprland restores
  // focus to whatever held it before the overlay opened when this surface
  // unmaps, which undoes it. That is why the old code closed first. But
  // closing first means the unmap happens before the workspace switch has
  // landed, and what is behind the overlay at that moment is still the
  // workspace being left — so there was a flash of the old desktop between the
  // overview going away and the new workspace arriving.
  //
  // Setting keyboardFocus to None gives the grab back on its own, without
  // unmapping. Hyprland has already returned focus by the time the dispatch
  // goes out, so the dispatch is the last word, and the surface can stay up
  // across the switch — which is what the whole transition now rests on. The
  // switch and everything Hyprland animates as part of it happen *underneath*
  // an overlay that is still there, and what it is showing while they do is
  // either the overview itself, held still, or a dive that ends on the
  // destination window at real size in its real place.
  //
  // This end of it says nothing about how the overlay then leaves: a dive
  // holds its own last frame (activateToplevel), everything else fades
  // (handOff).
  function beginHandOff(dispatchArg) {
    root.freezeGeometry()
    // `leaving` first, then `opened` -- see panel.visible.
    root.leaving = true
    root.opened = false
    // Give the grab back, and then wait to be dispatched *after* what that
    // sets off, rather than in front of it. See pendingDispatch.
    root.grabsKeyboard = false
    root.pendingDispatch = dispatchArg
    restoreFallback.restart()
  }

  // The dispatch, held until Hyprland has finished taking focus back.
  //
  // Handing the keyboard grab back is not a quiet operation. Hyprland responds
  // to this surface stopping its exclusive grab by restoring focus to whatever
  // held it before the overview opened -- and that restore lands about 40ms
  // after the release, which is comfortably after any dispatch sent in the
  // same breath as it. So the dispatch was not being ignored, it was being
  // *overwritten*: sampling the compositor every 40ms across a click shows the
  // workspace switch land at 41ms and revert at 81ms, every time. What looked
  // from in here like "Hyprland answers ok and does nothing" was Hyprland
  // doing it and then undoing it.
  //
  // This is the same hazard beginHandOff has always described -- it is why the
  // grab is given back before dispatching at all -- but "before" was two
  // statements, and the restore takes rather longer than two statements. The
  // ~650ms of blocked event loop at panel.visible used to sit between them and
  // paper over it; nothing does now, so the wait is made explicit.
  //
  // Waited out by event and not by clock: the restore *is* an activewindow
  // change, so Hyprland says when it has happened. The timer is only a
  // backstop for the case where the restore is a no-op and no event comes --
  // dismissing onto the window you were already on, say.
  property string pendingDispatch: ""

  Connections {
    target: Hyprland
    enabled: root.pendingDispatch !== ""
    function onRawEvent(event) {
      if (event.name === "activewindow" || event.name === "activewindowv2"
        || event.name === "workspace" || event.name === "workspacev2") {
        root.dbg("restore via event " + event.name + " at "
          + (Date.now() - root.dbgClickMs) + "ms")
        root.runPendingDispatch()
      }
    }
  }

  Timer {
    id: restoreFallback
    interval: 90
    onTriggered: {
      root.dbg("restoreFallback fired at " + (Date.now() - root.dbgClickMs) + "ms")
      root.runPendingDispatch()
    }
  }

  function runPendingDispatch() {
    if (root.pendingDispatch === "") return
    var arg = root.pendingDispatch
    root.pendingDispatch = ""
    restoreFallback.stop()
    root.dbg("dispatch after restore at " + (Date.now() - root.dbgClickMs) + "ms")
    // A dive needs the reply as much as it needs the dispatch, so it takes the
    // longer way round; everything else fires and forgets. The un-dived
    // hand-off starts holding still for the switch from here too, since here
    // is where the switch actually begins.
    if (root.awaitingLanding) {
      // From here, and not from the click: see diveDeadline.
      diveDeadline.restart()
      root.dispatchAndAim(arg)
    } else { root.hyprSend("dispatch " + arg); switchHold.restart() }
  }

  // A hand-off with no dive behind it: the empty row, or a window whose
  // thumbnail could not be measured. There is no zoomed frame to hold, so the
  // overview simply stays put — opaque, exactly as it was — while the switch
  // happens behind it, and only then fades off the settled desktop. Cutting
  // straight to the fade instead uncovered the switch halfway through it.
  function handOff(dispatchArg) {
    if (root.leaving) return
    root.beginHandOff(dispatchArg)
  }

  // How long the un-dived overview holds still over the switch. A workspace
  // slide is 300ms (see diveMs) and this is deliberately shorter: the fade
  // that follows covers the tail of it, and an overview that sits there for a
  // third of a second having plainly stopped responding reads as a hang.
  Timer {
    id: switchHold
    interval: 190
    onTriggered: exitFade.restart()
  }

  // The tail of a dive: the overlay holding its last frame — the destination
  // window, at real size, in the place Hyprland is putting it — over the real
  // thing while the last of windowsMove's easeOutQuint runs out underneath.
  // See diveMs. Cheap to hold and cheap to err long on, since what is being
  // held is a picture of what it covers.
  Timer {
    id: handOffTimer
    interval: 100
    onTriggered: root.finish()
  }

  // The dispatcher argument that focuses a window, or "" when the toplevel has
  // no address to focus by.
  function focusArg(hyprlandToplevel) {
    var ipc = hyprlandToplevel && hyprlandToplevel.lastIpcObject
    var address = ipc ? ipc.address : undefined
    return address ? "hl.dsp.focus({ window = 'address:" + address + "' })" : ""
  }

  function focusToplevel(hyprlandToplevel) {
    var arg = root.focusArg(hyprlandToplevel)
    // dismiss(), not close(): this is already the fallback *from* activation,
    // and close() now routes back into it -- which would be a loop, not a
    // fallback. A window with no address to focus by is nothing to land on.
    if (!arg) { root.dismiss(); return }
    root.handOff(arg)
  }

  // Switching to the empty row's workspace. Same dispatcher family and the
  // same hand-off as focusToplevel, for the same reasons. There is no zoom
  // here — a dive is a dive *into a window*, and the point of this row is that
  // there is no window on it — so the overlay simply holds its last frame
  // across the switch and fades from there.
  //
  // hl.dsp.focus({ workspace = ... }) rather than hl.dsp.workspace, which in
  // 0.55 is a table of sub-dispatchers (move, toggle_special, ...) and not
  // callable; it is also what Omarchy's own SUPER+1..9 bindings use.
  function activateWorkspace(id) {
    if (root.pendingActivation) return
    root.handOff("hl.dsp.focus({ workspace = '" + id + "' })")
  }

  PanelWindow {
    id: panel
    // Mapped once, at shell start, and never unmapped.
    //
    // This used to be `root.opened || root.leaving`, and unmapping was
    // expensive in a way that was easy to underestimate. Mapping a fresh
    // full-screen layer surface costs two frames measured at ~200ms each here
    // (see zoomOpener), and bringing one back is a fresh configure -- a
    // blocking round trip to a compositor that, on a click, is at exactly that
    // moment busy animating the workspace switch the click just dispatched. It
    // cost ~650ms of dead event loop: the dive's own deadline timer fired at
    // 799ms, the Hyprland reply the dive is aimed from sat unread in the socket
    // for 700ms (0.2ms to answer when it is actually read), and every
    // ScreencopyView in here was torn down and rebuilt for the privilege.
    //
    // Holding it up was already worth it for that alone, and it is what the
    // opening swipe rests on: a gesture cannot track fingers 1:1 through a
    // third of a second of surface creation, it can only sit still and then
    // jump to wherever they got to. With the surface already up, the first
    // event of a swipe finds a laid-out scene it can measure and start moving
    // on the same frame.
    //
    // Nothing is drawn, clickable or focusable while the overview is down --
    // see the layer and mask below and `visible` on the children -- so what is
    // left mapped is an empty transparent surface on a layer nothing looks at.
    //
    // The `opened`/`leaving` pair still matters for exactly the reason it
    // always did, and every writer of it must still raise the new flag before
    // dropping the old one: QML evaluates a binding synchronously the instant a
    // dependency is assigned, so `opened = false` followed by `leaving = true`
    // is not one transition but two, and for the width of those two statements
    // surfaceLive reads false. It no longer unmaps anything, but it does blank
    // the overview for a frame in the middle of a dive.
    visible: true
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omari-overview"
    // Overlay only while it is actually showing something.
    //
    // A mapped overlay layer is not free even when it draws nothing: Hyprland
    // refuses direct scanout on any monitor that has one at all
    // (CMonitor::isSolitaryBlocked checks the overlay list for emptiness, and
    // unlike the top layer beside it does not look at alpha), and refuses
    // tearing along with it. Leaving this on the overlay layer permanently
    // would cost every fullscreen game and video on the machine its scanout
    // path, forever, to save the overview a few hundred milliseconds.
    //
    // Parked on the background layer it is not looked at by any of that. The
    // change is cheap in the way that matters: Quickshell applies it as a plain
    // set_layer on the surface that is already up (LayerSurface::setState in
    // wlr_layershell/surface.cpp) rather than by remapping, so the raise costs
    // a commit and not two 200ms frames -- which is the whole reason this trade
    // is available.
    WlrLayershell.layer: root.surfaceLive ? WlrLayer.Overlay : WlrLayer.Background
    // Dropped the moment the overview starts leaving, by either route: a
    // dismissal wants the window underneath live again straight away, and a
    // hand-off needs the grab gone before its dispatch goes out. See handOff.
    //
    // Gated on surfaceLive as well, and that is not belt and braces: finish()
    // puts grabsKeyboard back up ready for the next open, and on a surface that
    // no longer unmaps to end the grab, this would hold exclusive keyboard
    // focus over the whole desktop from the first close onwards.
    WlrLayershell.keyboardFocus: (root.surfaceLive && root.grabsKeyboard)
      ? WlrKeyboardFocus.Exclusive
      : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Nothing at all is clickable while the overview is down. The surface
    // covers the screen the whole time it is up, which is now all of the time,
    // so without this the desktop under it would stop taking clicks the moment
    // the shell started. An empty region is the documented way to ask for that:
    // Quickshell sets Qt::WindowTransparentForInput for a mask that is present
    // but empty, and treats a null mask as "the whole window".
    property Region noInput: Region {}
    mask: root.surfaceLive ? null : panel.noInput
    // Same workaround as the background layer (Background.qml): a
    // layer-shell surface that toggles visible has been observed to come
    // back showing its last committed frame instead of a fresh one. The
    // surface no longer toggles at all, and its children draw nothing while
    // the overview is down, so this costs nothing while closed.
    updatesEnabled: true

    Rectangle {
      anchors.fill: parent
      // The three children below are what the surface actually shows, and none
      // of them exists as far as the renderer is concerned while the overview
      // is down -- which is what makes an always-mapped surface affordable.
      // `visible` and not `opacity`, deliberately: an item at zero opacity is
      // still laid out, still batched and still drawn.
      visible: root.surfaceLive
      // Flat, opaque, and *lighter* than the theme's Color.background, not
      // darker. The overview is nothing but dark app thumbnails, and the
      // wallpaper thumbnail behind each row carries its own drop shadow —
      // against a near-black backdrop both the shadows and the windows' own
      // edges disappear, and the rows read as one continuous smear. A mid
      // grey is what separates them. Opaque for the same reason: letting the
      // real desktop show through put live wallpaper detail directly behind
      // thumbnails of that same wallpaper.
      color: Qt.lighter(Color.background, 1.75)
      // Clears as the view dives into a window, so what the strip is growing
      // against is the real desktop it is about to become, and comes up almost
      // at once as the view pulls back out of one, so nothing is ever seen
      // twice over. The two directions do not share a curve; see
      // root.backdropOpacity for why they cannot. Fades again, on top of
      // either, through exitOpacity on the way out of a dismissal.
      opacity: root.backdropOpacity * root.exitOpacity
    }

    // Clicking past the rows is a cancel, not a choice: nothing was aimed at.
    MouseArea {
      anchors.fill: parent
      visible: root.surfaceLive
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      visible: root.surfaceLive
      // Was panel.visible, which is now simply always true. The grab is only
      // ever held while the overview is up (see keyboardFocus above), so this
      // is the same statement it always was, said about the overview instead
      // of about the window.
      focus: root.opened
      // The strip's half of the exit fade; the backdrop above carries the
      // other half. Both are children of the window rather than of one item,
      // so the fade is applied to each rather than to the pair.
      opacity: root.exitOpacity

      Keys.onPressed: function(event) {
        switch (event.key) {
        case Qt.Key_Escape:
          root.dismiss()
          break
        case Qt.Key_Up:
          root.moveRow(-1)
          break
        case Qt.Key_Down:
          root.moveRow(1)
          break
        case Qt.Key_Left:
          root.moveApp(-1)
          break
        case Qt.Key_Right:
          root.moveApp(1)
          break
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
          root.activateSelection()
          break
        default:
          return
        }
        event.accepted = true
      }

      // No "No open windows" label any more: the empty row is always drawn,
      // so an overview with nothing open is one bare wallpaper centred on
      // screen — which says the same thing in the same language as every
      // other row, and can be clicked.

      Item {
        id: viewport
        anchors.fill: parent
        // No margin: the rows above and below the centred one are meant to
        // run off the top and bottom edges of the screen. Insetting the
        // viewport instead frames them inside a backdrop border, which reads
        // as "a list that happens to be cut off" rather than "one workspace
        // in focus with its neighbours just out of view".
        clip: true

        // Scroll offset that puts row `index` on the viewport's vertical
        // midpoint. This one function is the whole vertical coordinate
        // system: it is the resting offset, and spaced a rowStride apart it
        // is also the set of snap points, which together are what keep some
        // row centred whenever nobody is actively scrolling.
        //
        // Note it is negative for row 0 whenever a row is shorter than the
        // viewport. That is the point — the old model derived the travel
        // limits from the column height, so 0 was the lowest offset it could
        // reach and the first row could only ever sit against the top edge.
        function centerPositionFor(index) {
          return index * root.rowStride + root.rowHeight / 2 - viewport.height / 2
        }

        readonly property real columnOffset: -vScroll.position

        KineticScroll {
          id: vScroll
          // contentSize is deliberately not set: the travel limits below are
          // not "scroll the column through the viewport" but "centre the
          // first row" to "centre the last row". viewportSize is still wanted
          // for the rubber-band reach at those limits.
          viewportSize: viewport.height
          minPosition: viewport.centerPositionFor(0)
          maxPosition: viewport.centerPositionFor(Math.max(0, root.workspaceRows.length - 1))
          snapStride: root.rowStride
          restPosition: viewport.centerPositionFor(root.selectedRow)
          frozen: root.viewIsFrozen
          // Undoes Hyprland's global touchpad scroll_factor (Omarchy
          // default 0.4) -- see the property's own comment in
          // KineticScroll.qml.
          dragScale: 4

          // A swipe or a wheel step settling on a row *is* selecting it, so
          // the selection follows the scroll as well as driving it.
          onSnapped: function(index) {
            var rows = root.workspaceRows
            if (index >= 0 && index < rows.length) root.selectedWorkspaceId = rows[index].id
          }
        }

        // Everything that zooms, and nothing that shouldn't: the wheel handler
        // below stays outside so it keeps covering the whole screen whatever
        // the strip is doing, and the backdrop is outside the viewport
        // entirely so it can fade on its own.
        //
        // Deliberately x/y/scale rather than a `transform: [Scale, Translate]`
        // list. Transform lists post-multiply, so that pair maps a child point
        // to s*(p + t) — the translation comes out scaled too — while the
        // offsets above are derived for s*p + t. With transformOrigin at the
        // top left, x/y/scale give exactly s*p + t and there is no order to
        // get wrong.
        Item {
          id: zoomLayer
          width: viewport.width
          height: viewport.height
          transformOrigin: Item.TopLeft
          scale: root.zoomFactor
          x: root.zoomOffset(root.zoomThumbX, root.zoomRealX)
          y: root.zoomOffset(root.zoomThumbY, root.zoomRealY)
          opacity: root.zoomReady ? 1 : 0

        Column {
          id: column
          width: viewport.width
          spacing: root.rowSpacing
          y: viewport.columnOffset

          Repeater {
            id: rowRepeater
            model: root.workspaceRows

            delegate: Item {
              id: rowItem
              required property var modelData
              required property int index
              width: column.width
              height: root.rowHeight

              // How root.selectedRowScroll() reaches this row's horizontal axis.
              property alias hScroll: rowScroll

              // Windows in real on-screen (left-to-right) order, so the
              // thumbnails either side of the focused one match how the
              // actual windows are laid out on the workspace.
              readonly property var sortedToplevels: root.sortToplevelsBySpatialOrder(rowItem.modelData.toplevels.values)
              readonly property int focusedIndex: root.focusedIndexFor(rowItem.sortedToplevels)

              readonly property bool current: rowItem.index === root.selectedRow

              // The trailing stand-in row. It draws exactly like any other —
              // the same wallpaper at the same size — because that *is* what
              // an empty workspace looks like; it just has no strip to scroll
              // and a click target of its own instead of thumbnails.
              readonly property bool isEmptyRow: root.isEmptyRowModel(rowItem.modelData)

              // Which thumbnail this row centres on. Only the centred row
              // follows the live left/right selection; every other row stays
              // parked on whatever Hyprland considers focused there, so
              // arrowing onto it lands somewhere sensible rather than
              // wherever the last row happened to be scrolled to.
              readonly property int selectedIndex: rowItem.current
                ? Math.max(0, Math.min(rowItem.sortedToplevels.length - 1, root.selectedApp))
                : rowItem.focusedIndex

              // This row's top edge in viewport coordinates, and whether
              // that puts it close enough to matter. Rows are a uniform
              // height, so this is arithmetic rather than a live geometry
              // read — no dependency on delegates existing yet.
              // This row's share of the dive's scroll; zero for every row but
              // the one being dived into, and zero at both ends of every other
              // zoom. See root.aimZoom.
              readonly property real diveShift: rowItem.index === root.diveRow
                ? root.diveShiftPx * root.zoomProgress
                : 0

              // How far this row's strip stands from the position that draws
              // its workspace as the compositor actually has it -- see
              // rowViewport.restXBase. Non-zero in two cases, and the dive has
              // to undo both: the strip has been scrolled by hand, or restX has
              // been nudged off the base to bring the ringed window inside the
              // wallpaper.
              //
              // The zoom is one rigid transform over the whole row, wallpaper
              // included, so it can only put the window on its real place *and*
              // the wallpaper on the monitor if the two already sit at their
              // true offset from each other before it runs. Anywhere but the
              // base they do not. See root.aimZoom.
              readonly property real stripOffset: rowScroll.position - rowViewport.restXBase

              readonly property real viewportY: rowItem.index * root.rowStride + viewport.columnOffset
              // Stays true through the leave: the dive is drawn from these
              // rows, and a row that decides it is off-screen halfway through
              // one drops the thumbnail being dived into.
              readonly property bool nearViewport: root.surfaceLive
                && rowItem.viewportY + root.rowHeight > -root.liveMargin
                && rowItem.viewportY < viewport.height + root.liveMargin

              // ---- the workspace's real geometry ----
              //
              // A row is a scaled replica of this workspace's monitor: the
              // wallpaper is the monitor rectangle, and every window is drawn
              // at its true size and offset within it. Nothing here reads a
              // delegate's width, so none of it can go stale waiting for
              // screencopy or for Repeater to catch up with its own count.

              readonly property var monitor: rowItem.modelData.monitor

              // Hyprland reports a monitor's size in *physical* pixels but
              // window geometry in logical ones, so the monitor has to be
              // divided back down before the two can be compared at all.
              // Read through lastIpcObject when the typed property is absent:
              // getting this wrong is not a small error. Falling back to 1 on
              // a 2x monitor would draw the monitor rectangle at the right
              // size but every window at half of it.
              readonly property real monScale: {
                var mon = rowItem.monitor
                if (!mon) return 1
                var s = Number(mon.scale)
                if (!isFinite(s) || s <= 0) {
                  var ipc = mon.lastIpcObject
                  s = ipc ? Number(ipc.scale) : NaN
                }
                return (isFinite(s) && s > 0) ? s : 1
              }
              readonly property real monX: rowItem.monitor ? rowItem.monitor.x : 0
              readonly property real monY: rowItem.monitor ? rowItem.monitor.y : 0
              readonly property real monW: (rowItem.monitor && rowItem.monitor.width > 0)
                ? rowItem.monitor.width / rowItem.monScale : 0
              readonly property real monH: (rowItem.monitor && rowItem.monitor.height > 0)
                ? rowItem.monitor.height / rowItem.monScale : 0

              // Logical workspace pixels to row pixels. The row is the
              // monitor's height, so this is the one scale everything in the
              // row — wallpaper and windows alike — is drawn at.
              readonly property real geomScale: rowItem.monH > 0 ? root.rowHeight / rowItem.monH : 0

              // The wallpaper rectangle's width in row pixels. This is the
              // frame a row's horizontal scrolling is measured against — both
              // the monitorRect below and rowScroll's travel limits come from
              // it, so the strip can only ever come to rest with its edges on
              // the wallpaper's edges, never on the screen's.
              readonly property real monWidthPx: rowItem.monW * rowItem.geomScale

              // Omari mode is a scrolling layout, so a workspace's windows
              // routinely run past both edges of the monitor they are on —
              // that is the whole point of it. The strip is therefore the
              // union of the monitor and every window, and it is what scrolls
              // horizontally; the monitor rectangle just sits inside it,
              // marking the part you would actually be looking at.
              readonly property var strip: {
                var left = rowItem.monX
                var right = rowItem.monX + rowItem.monW
                var vals = rowItem.sortedToplevels
                for (var i = 0; i < vals.length; i++) {
                  var r = root.rectFor(vals[i])
                  if (!r) continue
                  if (r.x < left) left = r.x
                  if (r.x + r.w > right) right = r.x + r.w
                }
                return { left: left, right: right }
              }

              // The extent of the *windows alone*, without the monitor folded
              // in. The strip above is the union of the two, so on a side
              // where no window overhangs the monitor the strip's edge is the
              // monitor's edge — and scrolling the strip's edge onto the
              // wallpaper's edge would then stop with the last window short of
              // it, a band of empty desktop still showing. Travel is measured
              // from this instead. Windows with no geometry yet take the
              // monitor rectangle, matching where rectInRow puts them, so a
              // row of them is still reachable.
              readonly property var winSpan: {
                var left = NaN
                var right = NaN
                var vals = rowItem.sortedToplevels
                for (var i = 0; i < vals.length; i++) {
                  var r = root.rectFor(vals[i])
                  if (!r) r = { x: rowItem.monX, w: rowItem.monW }
                  if (isNaN(left) || r.x < left) left = r.x
                  if (isNaN(right) || r.x + r.w > right) right = r.x + r.w
                }
                if (isNaN(left)) return { left: rowItem.strip.left, right: rowItem.strip.right }
                return { left: left, right: right }
              }

              // Where a window sits in the row, in row pixels. Windows with
              // no geometry yet fall back to filling the monitor rectangle —
              // visible and roughly right beats vanishing.
              function rectInRow(toplevel) {
                var r = root.rectFor(toplevel)
                if (!r) r = { x: rowItem.monX, y: rowItem.monY, w: rowItem.monW, h: rowItem.monH }
                return {
                  x: (r.x - rowItem.strip.left) * rowItem.geomScale,
                  y: (r.y - rowItem.monY) * rowItem.geomScale,
                  w: r.w * rowItem.geomScale,
                  h: r.h * rowItem.geomScale
                }
              }


              // Which window the ring belongs on for wherever the strip has
              // been scrolled to. -1 for a row with no windows.
              //
              // Deliberately sticky, and restX's inverse: the ring stays where
              // it is until the window it is on has been scrolled far enough
              // that its own middle has left the wallpaper, and only then goes
              // to whatever is nearest the middle now.
              //
              // Re-picking on every settle instead reads as a twitch. A
              // half-width layout shows two columns and neither of them is
              // centred, so "nearest the middle" disagrees with the focused
              // window before the strip has moved at all -- and nudging the
              // strip a few pixels would then flip the ring to the neighbour
              // and glide the whole row after it. Requiring the ringed window's
              // middle to actually leave means the selection changes when the
              // scroll meant it to, and by then restX's nudge lands the strip
              // about where the fingers left it rather than somewhere else.
              //
              // A function rather than a binding on purpose: it walks every
              // window in the row and rowScroll.position moves every frame of a
              // gesture, so as a binding it would run the whole loop per frame
              // for an answer only wanted when the strip stops.
              function framedIndex() {
                var vals = rowItem.sortedToplevels
                if (vals.length === 0) return -1
                var left = rowScroll.position + rowViewport.monLeft
                var right = left + rowItem.monWidthPx
                var middle = (left + right) / 2

                var cur = rowItem.selectedIndex
                if (cur >= 0 && cur < vals.length) {
                  var c = rowItem.rectInRow(vals[cur])
                  var cMid = c.x + c.w / 2
                  if (cMid >= left && cMid <= right) return cur
                }

                var best = 0
                var bestDist = Infinity
                for (var i = 0; i < vals.length; i++) {
                  var r = rowItem.rectInRow(vals[i])
                  var d = Math.abs(r.x + r.w / 2 - middle)
                  if (d < bestDist) { bestDist = d; best = i }
                }
                return best
              }

              // For captureZoom, which needs the thumbnail's real on-screen box
              // and cannot reach into the Repeater from outside.
              function thumbItemAt(i) { return thumbRepeater.itemAt(i) }

              // A fresh overview always opens centred on the focused window,
              // never wherever the last one happened to be left scrolled to —
              // and nothing is left coasting behind a closed one.
              Connections {
                target: root
                function onViewReset() { rowScroll.reset() }
                // Whatever the strip was doing — coasting from a flick,
                // gliding towards a rest position that has just moved — it
                // stops where it stands when a dive begins. Resetting it, which
                // is what leaving used to do, snapped it back to its resting
                // position inside a layer on its way to twice size, in the one
                // frame that has to be seamless.
                function onViewFrozen() { rowScroll.stop() }
              }

              // Deliberately unlabelled. A workspace name over every row is
              // the one piece of chrome that reads as a *list* of workspaces;
              // without it the rows read as the desktops themselves, which is
              // the whole illusion. Which row you are on is already carried by
              // it being the centred one, and which window by its ring.

              // The wallpaper thumbnail: the monitor rectangle, centred in the
              // row and *fixed* there. It deliberately sits outside the
              // scrolling strip below, so panning a workspace's windows slides
              // them across a wallpaper that stays put — the way the real
              // desktop behaves under a scrolling layout, where moving through
              // the columns never moves the background.
              //
              // At rest the strip is positioned so the monitor's own slice of
              // it lands exactly here (see rowViewport.restX), so the two agree
              // until you scroll away. Declared before rowViewport so it draws
              // behind the windows, and outside it so its drop shadow is not
              // clipped away at the row's top and bottom edges.
              //
              // Sized from the monitor, never from the image's decoded size, so
              // the geometry is stable from the first frame — only the pixmap
              // swaps in later, never the layout.
              Item {
                id: monitorRect
                anchors.horizontalCenter: parent.horizontalCenter
                y: 0
                width: rowItem.monWidthPx
                height: root.rowHeight
                layer.enabled: true
                layer.effect: MultiEffect {
                  shadowEnabled: true
                  shadowColor: Qt.rgba(0, 0, 0, 0.6)
                  shadowBlur: 0.5
                  shadowOpacity: 0.7
                  shadowHorizontalOffset: 0
                  shadowVerticalOffset: 6
                }

                Image {
                  anchors.fill: parent
                  source: root.backgroundImagePath ? Util.fileUrl(root.backgroundImagePath) : ""
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                  smooth: true
                  visible: root.backgroundImagePath !== ""
                  // Decode the wallpaper at thumbnail size rather than at its
                  // native resolution — a 4K background costs ~32MB of texture
                  // and a full-size decode otherwise, for something drawn a few
                  // hundred pixels tall. Every row asks for the same height, so
                  // they all share one cached texture.
                  sourceSize.height: Math.round(root.rowHeight * Screen.devicePixelRatio)
                }
              }

              Item {
                id: rowViewport
                anchors.fill: parent
                clip: true

                readonly property real contentWidth:
                  (rowItem.strip.right - rowItem.strip.left) * rowItem.geomScale

                // The wallpaper rectangle's left edge in this item's
                // coordinates. It is centred in the row, and it — not this
                // item — is the window the strip scrolls behind, so every
                // position below is expressed against it. This item stays the
                // full width of the row and keeps clipping there, so windows
                // scrolled past the wallpaper's edges still show against the
                // backdrop the way they overhang a real monitor.
                readonly property real monLeft: (rowViewport.width - rowItem.monWidthPx) / 2

                // The windows' own extent in strip coordinates — the two edges
                // rowScroll's travel runs between.
                readonly property real winLeft:
                  (rowItem.winSpan.left - rowItem.strip.left) * rowItem.geomScale
                readonly property real winRight:
                  (rowItem.winSpan.right - rowItem.strip.left) * rowItem.geomScale

                // The strip position that draws this workspace exactly as the
                // compositor currently has it: the *monitor* rectangle over the
                // wallpaper, not the selected window. That is what makes a row
                // show what you would actually be looking at were you on that
                // workspace — windows fall where the layout puts them, spilling
                // off both edges as they do on a scrolling layout.
                //
                // Named on its own because it is not only where the strip rests.
                // It is the one position at which the row is a *rigid* replica
                // of the workspace — window offsets from the wallpaper equal to
                // window offsets from the monitor — and the dive's single
                // transform can only land the windows and the wallpaper at once
                // from there. See rowItem.stripOffset.
                readonly property real restXBase:
                  (rowItem.monX - rowItem.strip.left) * rowItem.geomScale
                    - rowViewport.monLeft

                // Where the strip comes to rest: restXBase, nudged off it only
                // as far as it must be to bring the ringed window inside the
                // wallpaper, for when the selection has walked past the part of
                // the strip the monitor covers.
                //
                // That nudge is a model of what the compositor does when the
                // ringed window is focused -- a scrolling layout brings the
                // focused column into view with the smallest scroll that will
                // do it -- which is why the dive has to treat it as travel the
                // row has *already* performed rather than as travel still to
                // come.
                readonly property real restX: {
                  var pos = rowViewport.restXBase
                  var vals = rowItem.sortedToplevels
                  var i = rowItem.selectedIndex
                  if (i < 0 || i >= vals.length) return pos
                  var r = rowItem.rectInRow(vals[i])
                  var left = pos + rowViewport.monLeft
                  if (r.x < left) return r.x - rowViewport.monLeft
                  if (r.x + r.w > left + rowItem.monWidthPx)
                    return r.x + r.w - rowViewport.monLeft - rowItem.monWidthPx
                  return pos
                }

                KineticScroll {
                  id: rowScroll
                  viewportSize: rowItem.monWidthPx
                  // The travel is framed by the wallpaper, not by the screen:
                  // it runs from the first window's left edge lining up with
                  // the wallpaper's left edge to the last window's right edge
                  // lining up with the wallpaper's right edge, widened to
                  // always contain restX. Measuring against the row's full
                  // width instead is what used to stop a scroll with the last
                  // window pinned to the screen edge, a band of empty backdrop
                  // still inside the wallpaper. Both ends carry the same
                  // -monLeft shift, which is what puts a strip position on the
                  // wallpaper rather than on this item.
                  //
                  // Widening to restX is not a fallback: a workspace whose
                  // windows leave a gap at one end of the monitor has a resting
                  // position past the window edge at that end, and that gap is
                  // the truth about the workspace. When the windows fit inside
                  // the monitor entirely both ends collapse onto restX and the
                  // row simply does not scroll.
                  minPosition: Math.min(rowViewport.winLeft - rowViewport.monLeft,
                                        rowViewport.restX)
                  maxPosition: Math.max(rowViewport.winRight - rowViewport.monLeft
                                          - rowItem.monWidthPx,
                                        rowViewport.restX)
                  // Left/right arrows move rowItem.selectedIndex, which moves
                  // this, which glides the strip along. The horizontal axis
                  // stays free-scrolling (no snapStride): windows are
                  // different widths, and a swipe across a row should be able
                  // to stop wherever it likes.
                  restPosition: rowViewport.restX
                  frozen: root.viewIsFrozen
                  notchPixels: root.rowHeight * 0.6
                  // Undoes Hyprland's global touchpad scroll_factor (Omarchy
                  // default 0.4) -- see the property's own comment in
                  // KineticScroll.qml.
                  dragScale: 4

                  // Scrolling a row sideways selects, exactly as scrolling the
                  // workspace list vertically does (see vScroll.onSnapped).
                  // Without this the horizontal axis was the one thing in the
                  // overview you could change that changed nothing: the strip
                  // moved, the ring stayed where it was, and the dive focused
                  // the window that was already focused -- so the workspace you
                  // landed on was the one you had before you scrolled at all.
                  //
                  // The compositor has no dispatcher for "scroll this workspace
                  // to here"; a scrolling layout is scrolled by focusing
                  // something. So what carries across is the selection, and
                  // restX then glides the strip to the scroll the compositor
                  // will really perform for it -- which is the truth about
                  // where the dive is going, and is the same nudge the dive
                  // itself now reads back off rowItem.stripOffset.
                  onSettled: {
                    if (!rowItem.current || root.viewIsFrozen || !root.opened) return
                    var i = rowItem.framedIndex()
                    if (i >= 0) root.selectedApp = i
                  }
                }

                // The strip: every window on the workspace at its real position
                // relative to the monitor, panned as one over the fixed
                // wallpaper above. Windows are placed rather than packed, so
                // this is a plain Item and not a Row — the layout is the
                // workspace's own.
                Item {
                  id: rowContent
                  // No "does it overflow" special case any more: when a
                  // workspace's windows all sit inside its monitor the travel
                  // limits collapse onto restX, so this is the centred
                  // position by construction.
                  x: -rowScroll.position - rowItem.diveShift
                  width: rowViewport.contentWidth
                  height: rowViewport.height

                  Repeater {
                    id: thumbRepeater
                    model: rowItem.sortedToplevels

                    Rectangle {
                      id: thumb
                      required property var modelData
                      required property int index

                      readonly property var geom: rowItem.rectInRow(thumb.modelData)
                      x: thumb.geom.x
                      y: thumb.geom.y

                      // Every row rings the window it is centred on — its own
                      // focused one, or on the centred row whatever left/right
                      // has moved to. Unringed windows get no border at all:
                      // an outline on all of them turns the row into a strip
                      // of framed tiles, where the point is a row of windows.
                      readonly property bool ringed: thumb.index === rowItem.selectedIndex
                        || hoverArea.containsMouse

                      // Only the centred row's ring is the *keyboard* ring, so
                      // only that one is worth the accent; the others are
                      // stating a fact about their workspace, not a selection,
                      // and a neutral grey is enough to say it.
                      readonly property bool active: thumb.ringed
                        && (rowItem.current || hoverArea.containsMouse)

                      // Size comes from Hyprland's own geometry, not from the
                      // screencopy buffer's aspect ratio: the buffer arrives a
                      // frame or two late and would relayout the whole row
                      // when it did, precisely during the frames the overview
                      // most needs to be cheap. The window's real rectangle is
                      // known before the first pixel is captured.
                      width: thumb.geom.w
                      height: thumb.geom.h
                      radius: Style.space(6)
                      color: Color.background
                      border.width: thumb.ringed ? Style.space(2) : 0
                      border.color: thumb.active
                        ? Color.accent
                        : Util.alpha(Color.foreground, 0.4)
                      clip: true

                      ScreencopyView {
                        id: capture
                        anchors.fill: parent
                        // Without this inset the capture paints edge-to-edge
                        // over the border above -- hover was firing correctly
                        // (containsMouse, the click, the border binding all
                        // worked) but the video was visually covering the ring
                        // the whole time. Tracking border.width means an
                        // unringed thumbnail is pure window, edge to edge.
                        anchors.margins: thumb.border.width
                        captureSource: thumb.modelData.wayland
                        // Live only while this row is at or near the
                        // viewport. Every thumbnail is its own screencopy
                        // stream against the compositor, so keeping all of
                        // them running for rows scrolled far off-screen is
                        // sustained GPU and Wayland buffer traffic
                        // competing with the very frames a smooth scroll
                        // needs. A row that goes off-screen keeps the last
                        // frame it captured and resumes streaming before it
                        // comes back into view.
                        //
                        // Deliberately still tied to nothing but the row's
                        // position, right through the leave. Stopping the
                        // streams the moment a dive starts looks like an
                        // obvious saving -- they are about to be scaled off the
                        // edge of the screen -- but it is a change of state at
                        // the exact frame that has to be unremarkable, on the
                        // one surface the eye is following.
                        live: rowItem.nearViewport
                        paintCursor: false
                        constraintSize: Qt.size(
                          Math.round(root.captureBaseHeight * 2.5 * Screen.devicePixelRatio),
                          Math.round(root.captureBaseHeight * Screen.devicePixelRatio))

                        // A row created off-screen has no last frame to
                        // keep, so grab one still for it up front -- but only
                        // while the overview is actually up. The plugin is
                        // keepLoaded, so these delegates also exist, and are
                        // rebuilt every time a window opens or closes, with
                        // the overview closed and no recording context to
                        // capture into: asking then is work that can only
                        // fail, and it logged a warning per thumbnail for the
                        // privilege.
                        Component.onCompleted:
                          if (root.opened && !capture.live) capture.captureFrame()
                      }

                      // No title bar over the bottom of the thumbnail. At this
                      // size every window already shows its own titlebar, tab
                      // strip or header, so the overlay was a second, uglier
                      // title stacked on the real one — and it covered the
                      // bottom of the very content that makes a window
                      // recognisable at a glance.

                      MouseArea {
                        id: hoverArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.activateToplevel(thumb.modelData, rowItem.index, thumb.index)
                      }
                    }
                  }
                }

                // No per-row wheel handler here any more. One that only fires
                // when the pointer is over its own row makes which row scrolls
                // depend on where the mouse was left — see
                // root.selectedRowScroll(), which the single handler at the
                // viewport level uses instead.
              }

              // The empty row's click target: the wallpaper itself, since
              // there is no thumbnail to aim at. Declared after rowViewport so
              // it takes the press rather than the backdrop's close handler,
              // and anchored to monitorRect rather than living inside it so
              // the ring is not drawn through that item's shadow layer.
              //
              // Rings on hover only. Every other row states which window it is
              // centred on by ringing it; this one has nothing to state, and
              // which row you are on is already carried by it being the centred
              // one — so the ring here is purely "this is a thing you can
              // click", and it uses the accent when it is also the keyboard
              // row for the same reason the thumbnails do.
              MouseArea {
                id: emptyTarget
                anchors.fill: monitorRect
                visible: rowItem.isEmptyRow
                enabled: rowItem.isEmptyRow
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.activateWorkspace(rowItem.modelData.id)

                Rectangle {
                  anchors.fill: parent
                  color: "transparent"
                  border.width: emptyTarget.containsMouse ? Style.space(2) : 0
                  border.color: rowItem.current
                    ? Color.accent
                    : Util.alpha(Color.foreground, 0.4)
                }
              }
            }
          }
        }
        } // zoomLayer

        // The only wheel handler, and so the one that routes both axes: it
        // drives the workspace list itself when the axis lock says vertical,
        // and the centred row's strip when it says horizontal. It covers the
        // whole viewport and sits outside zoomLayer, so it keeps seeing every
        // gesture whatever the strip underneath is scaled or scrolled to.
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.NoButton
          hoverEnabled: false
          onWheel: function(wheel) {
            if (!root.isTouchpadWheel(wheel)) {
              if (Math.abs(wheel.angleDelta.y) < Math.abs(wheel.angleDelta.x)) {
                var hWheel = root.selectedRowScroll()
                if (hWheel) hWheel.stepBy(-wheel.angleDelta.x / 120)
                wheel.accepted = true
                return
              }
              vScroll.stepBy(-wheel.angleDelta.y / 120)
              wheel.accepted = true
              return
            }

            if (wheel.phase === Qt.ScrollBegin) root.gestureAxis = ""
            if (root.gestureAxis === "") {
              root.gestureAxis = root.axisFor(wheel.pixelDelta.x, wheel.pixelDelta.y)
            }
            gestureIdle.restart()

            if (root.gestureAxis === "x") {
              var hDrag = root.selectedRowScroll()
              if (wheel.phase === Qt.ScrollEnd) {
                root.gestureAxis = ""
                gestureIdle.stop()
                if (hDrag) hDrag.endDrag()
              } else if (hDrag) {
                // Not negated, unlike the vertical axis below: niri moves the
                // *strip* under two fingers rather than the view over it, so
                // swiping left carries the columns left and brings the one to
                // the right into the centre. Matching it here matters more
                // than matching the axis beside it, because this is the same
                // gesture, on the same strip of columns, that the scrolling
                // layout answers when the overview is closed.
                hDrag.dragBy(wheel.pixelDelta.x)
              }
              wheel.accepted = true
              return
            }

            if (wheel.phase === Qt.ScrollEnd) {
              root.gestureAxis = ""
              gestureIdle.stop()
              vScroll.endDrag()
            } else {
              // Negated: two fingers drag the *view over the stack of
              // workspaces* rather than the stack itself, so pushing up
              // brings the row above into the centre. Same sense as the
              // mouse wheel above. The horizontal drag is the odd one out
              // on purpose -- it follows niri, which has no opinion about
              // this axis because it has no vertical stack.
              vScroll.dragBy(-wheel.pixelDelta.y)
            }
            wheel.accepted = true
          }
        }
      }
    }
  }
}
