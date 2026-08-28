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
    bgPathProc.running = true
    root.clearZoom()
    // Start fully zoomed in, onto nothing yet: the surface has to exist and be
    // laid out before there is a thumbnail to measure, so zoomOpenTimer does
    // the measuring a couple of frames from now. Until then the strip is held
    // invisible and the backdrop is fully transparent, so what shows through
    // is the real desktop — which is exactly the frame the zoom-out should
    // start from anyway.
    root.zoomProgress = 1
    root.zoomReady = false
    root.opened = true
    root.gestureAxis = ""
    vScroll.reset()
    zoomOpenTimer.begin()
  }

  // Reset rather than just hide: a flick still coasting when the overview
  // closes would otherwise keep a FrameAnimation ticking behind an invisible
  // surface, and would still be mid-glide the next time it opens.
  function close() {
    root.opened = false
    root.gestureAxis = ""
    zoomOpenTimer.stop()
    root.clearZoom()
    vScroll.reset()
  }
  function toggle() { if (root.opened) root.close(); else root.open() }
  function ping() { return "ok" }

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

  function activateSelection() {
    var row = root.workspaceRows[root.selectedRow]
    if (root.isEmptyRowModel(row)) {
      root.activateWorkspace(row.id)
      return
    }
    var apps = root.selectedToplevels
    if (apps.length === 0) return
    var i = Math.max(0, Math.min(apps.length - 1, root.selectedApp))
    root.activateToplevel(apps[i], root.selectedRow, i)
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

  readonly property real zoomFactor: 1 + root.zoomProgress * (root.zoomScale - 1)

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
  function captureZoom(rowIndex, appIndex) {
    var row = rowRepeater.itemAt(rowIndex)
    if (!row) return false
    var item = row.thumbItemAt(appIndex)
    if (!item || item.width <= 0 || item.height <= 0) return false
    var r = root.rectFor(item.modelData)
    if (!r) return false
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
    zoomOutAnim.stop()
    zoomInAnim.stop()
    root.pendingActivation = null
    root.zoomProgress = 0
    root.zoomScale = 1
    root.zoomThumbX = 0
    root.zoomThumbY = 0
    root.zoomRealX = 0
    root.zoomRealY = 0
    root.zoomReady = true
  }

  // The dive runs first and the focus goes out at the end of it, once the
  // overlay has been torn down — see focusToplevel for why that order is not
  // negotiable. Dispatching early to overlap the workspace switch with the
  // animation was tried and is wrong: the focus lands while the keyboard grab
  // is still held, and the unmap takes it straight back.
  function activateToplevel(toplevel, rowIndex, appIndex) {
    if (!toplevel) return
    if (root.pendingActivation) return
    if (!root.captureZoom(rowIndex, appIndex)) {
      root.focusToplevel(toplevel)
      return
    }
    root.pendingActivation = toplevel
    root.zoomProgress = 0
    zoomInAnim.restart()
  }

  function finishActivation() {
    var toplevel = root.pendingActivation
    root.pendingActivation = null
    root.focusToplevel(toplevel)
  }

  // The capture needs a surface that has been *laid out*, not merely one whose
  // delegates exist. Measuring too early is not a near miss: while the layer
  // surface is still unsized panel.height is 0, so rowHeight sits on its floor
  // and a thumbnail measures a fraction of its eventual size — which lands in
  // zoomScale as a factor of seven rather than two and flings the strip off
  // screen. Waiting a fixed couple of frames is not enough either, since the
  // compositor decides when the surface gets its size.
  //
  // So: poll, and require a real size to have held for two consecutive ticks,
  // which gives Column a polish pass in between to position the rows that
  // mapToItem is about to be asked about.
  Timer {
    id: zoomOpenTimer
    interval: 16
    repeat: true
    property int ticks: 0
    property bool wasSized: false

    function begin() {
      zoomOpenTimer.ticks = 0
      zoomOpenTimer.wasSized = false
      zoomOpenTimer.restart()
    }

    onTriggered: {
      if (!root.opened) { zoomOpenTimer.stop(); return }
      zoomOpenTimer.ticks++

      var sized = panel.height > 0 && column.height > 0
      if (sized && zoomOpenTimer.wasSized) {
        zoomOpenTimer.stop()
        if (root.captureZoom(root.selectedRow, root.selectedApp)) {
          root.zoomReady = true
          zoomOutAnim.restart()
        } else {
          root.clearZoom()
        }
        return
      }
      zoomOpenTimer.wasSized = sized

      // Never leave the strip hidden waiting for a size that isn't coming:
      // give up after a quarter second and just show the overview.
      if (zoomOpenTimer.ticks > 15) {
        zoomOpenTimer.stop()
        root.clearZoom()
      }
    }
  }

  NumberAnimation {
    id: zoomOutAnim
    target: root
    property: "zoomProgress"
    from: 1
    to: 0
    duration: 260
    easing.type: Easing.OutCubic
  }

  NumberAnimation {
    id: zoomInAnim
    target: root
    property: "zoomProgress"
    from: 0
    to: 1
    duration: 200
    easing.type: Easing.InCubic
    onFinished: root.finishActivation()
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
  function focusHistoryIdFor(toplevel) {
    var raw = toplevel && toplevel.lastIpcObject ? toplevel.lastIpcObject.focusHistoryID : undefined
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
  function spatialXFor(toplevel) {
    var at = toplevel && toplevel.lastIpcObject ? toplevel.lastIpcObject.at : undefined
    var n = at && at.length > 0 ? Number(at[0]) : NaN
    return isFinite(n) ? n : Number.MAX_SAFE_INTEGER
  }

  function sortToplevelsBySpatialOrder(values) {
    var arr = values ? values.slice() : []
    arr.sort(function(a, b) { return root.spatialXFor(a) - root.spatialXFor(b) })
    return arr
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
  function rectFor(toplevel) {
    var ipc = toplevel ? toplevel.lastIpcObject : undefined
    var at = ipc ? ipc.at : undefined
    var size = ipc ? ipc.size : undefined
    if (!at || !size || at.length < 2 || size.length < 2) return null
    var x = Number(at[0]), y = Number(at[1])
    var w = Number(size[0]), h = Number(size[1])
    if (!isFinite(x) || !isFinite(y) || !isFinite(w) || !isFinite(h)) return null
    if (w <= 0 || h <= 0) return null
    return { x: x, y: y, w: w, h: h }
  }

  // Dispatches through Hyprland itself (hl.dsp.focus({ window = ... })),
  // rather than the generic wlr-foreign-toplevel activate() request that
  // used to run here: activate() only asks for keyboard focus and leaves it
  // up to the compositor whether that also raises the window's workspace,
  // and doing it while this overlay still holds exclusive keyboard focus
  // (WlrKeyboardFocus.Exclusive above) races root.close() unmapping that
  // same surface. Hyprland's own focus dispatcher switches the active
  // workspace to the window's as an intrinsic part of focusing it, so this
  // reaches both the app and its workspace deterministically.
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
  function dispatchFocus(hyprlandToplevel) {
    var ipc = hyprlandToplevel && hyprlandToplevel.lastIpcObject
    var address = ipc ? ipc.address : undefined
    if (!address) return
    Quickshell.execDetached(
      ["hyprctl", "dispatch", "hl.dsp.focus({ window = 'address:" + address + "' })"])
  }

  // Close *first*, then dispatch. This overlay holds the keyboard grab
  // (WlrKeyboardFocus.Exclusive), and when that surface unmaps Hyprland
  // restores focus to whatever held it before the overlay opened — undoing a
  // focus dispatched while the overlay was still up. The old code appeared to
  // dispatch first, but routed it through `bash -lc`, whose ~280ms of login
  // shell meant it actually landed well after the unmap; making the spawn fast
  // removed that accidental delay and with it the focus.
  function focusToplevel(hyprlandToplevel) {
    root.close()
    root.dispatchFocus(hyprlandToplevel)
  }

  // Switching to the empty row's workspace. Same dispatcher family as
  // dispatchFocus, and the same close-then-dispatch order for the same
  // reason: this overlay holds the keyboard grab, and focus dispatched while
  // it is still mapped is taken straight back when it unmaps. There is no
  // zoom here — a dive is a dive *into a window*, and the point of this row
  // is that there is no window on it.
  //
  // hl.dsp.focus({ workspace = ... }) rather than hl.dsp.workspace, which in
  // 0.55 is a table of sub-dispatchers (move, toggle_special, ...) and not
  // callable; it is also what Omarchy's own SUPER+1..9 bindings use.
  function activateWorkspace(id) {
    if (root.pendingActivation) return
    root.close()
    Quickshell.execDetached(
      ["hyprctl", "dispatch", "hl.dsp.focus({ workspace = '" + id + "' })"])
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omari-overview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore
    // Same workaround as the background layer (Background.qml): a
    // layer-shell surface that toggles visible has been observed to come
    // back showing its last committed frame instead of a fresh one. This
    // surface is only ever composited while root.opened is true, so keeping
    // updates enabled unconditionally costs nothing while closed.
    updatesEnabled: true

    Rectangle {
      anchors.fill: parent
      // Flat, opaque, and *lighter* than the theme's Color.background, not
      // darker. The overview is nothing but dark app thumbnails, and the
      // wallpaper thumbnail behind each row carries its own drop shadow —
      // against a near-black backdrop both the shadows and the windows' own
      // edges disappear, and the rows read as one continuous smear. A mid
      // grey is what separates them. Opaque for the same reason: letting the
      // real desktop show through put live wallpaper detail directly behind
      // thumbnails of that same wallpaper.
      color: Qt.lighter(Color.background, 1.75)
      // Fades out as the view dives into a window, so what the strip is
      // growing against is the real desktop it is about to become.
      opacity: 1 - root.zoomProgress
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: panel.visible

      Keys.onPressed: function(event) {
        switch (event.key) {
        case Qt.Key_Escape:
          root.close()
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
              readonly property real viewportY: rowItem.index * root.rowStride + viewport.columnOffset
              readonly property bool nearViewport: root.opened
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


              // For captureZoom, which needs the thumbnail's real on-screen box
              // and cannot reach into the Repeater from outside.
              function thumbItemAt(i) { return thumbRepeater.itemAt(i) }

              // A fresh overview always opens centred on the focused window,
              // never wherever the last one happened to be left scrolled to —
              // and nothing is left coasting behind a closed one.
              Connections {
                target: root
                function onOpenedChanged() { rowScroll.reset() }
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

                // Where the strip comes to rest: the *monitor* rectangle over
                // the wallpaper, not the selected window. That is what makes a
                // row show what you would actually be looking at were you on
                // that workspace — windows fall where the layout puts them,
                // spilling off both edges as they do on a scrolling layout.
                //
                // Nudged off that only as far as it must be to bring the ringed
                // window inside the wallpaper, for when left/right has walked
                // past the part of the strip the monitor covers.
                readonly property real restX: {
                  var monOffset = (rowItem.monX - rowItem.strip.left) * rowItem.geomScale
                  var pos = monOffset - rowViewport.monLeft
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
                  notchPixels: root.rowHeight * 0.6
                  // Undoes Hyprland's global touchpad scroll_factor (Omarchy
                  // default 0.4) -- see the property's own comment in
                  // KineticScroll.qml.
                  dragScale: 4
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
                  x: -rowScroll.position
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
                        live: rowItem.nearViewport
                        paintCursor: false
                        constraintSize: Qt.size(
                          Math.round(root.captureBaseHeight * 2.5 * Screen.devicePixelRatio),
                          Math.round(root.captureBaseHeight * Screen.devicePixelRatio))

                        // A row created off-screen has no last frame to
                        // keep, so grab one still for it up front.
                        Component.onCompleted: if (!capture.live) capture.captureFrame()
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
                hDrag.dragBy(-wheel.pixelDelta.x)
              }
              wheel.accepted = true
              return
            }

            if (wheel.phase === Qt.ScrollEnd) {
              root.gestureAxis = ""
              gestureIdle.stop()
              vScroll.endDrag()
            } else {
              // Not negated, unlike every other axis here: two fingers drag
              // the *stack of workspaces* rather than the view over it, so
              // pushing up brings the row below into the centre. The mouse
              // wheel above keeps the opposite, conventional sense — which is
              // the same split most people already run between a touchpad set
              // to natural scrolling and a wheel that is not.
              vScroll.dragBy(wheel.pixelDelta.y)
            }
            wheel.accepted = true
          }
        }
      }
    }
  }
}
