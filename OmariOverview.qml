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
  property var pluginRegistry: null

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

  // Where the user has scrolled each row to, keyed by workspace id -- and only
  // rows the user has actually scrolled or arrowed are in here.
  //
  // selectedApp is the *centred* row's selection and nothing else's; every
  // other row draws itself from rowItem.focusedIndex, i.e. from whatever
  // Hyprland has focused on that workspace. That is the right default for a
  // row nobody has touched -- it is what the workspace really looks like --
  // and it was flatly wrong for one that had been scrolled, because moving
  // off the row put it straight back: scroll row 1 to its last window, drop
  // to row 3, and row 1 glided home the moment it stopped being centred. The
  // selection carrying it lived in selectedApp, and selectedApp had moved on.
  //
  // Ids rather than row indices, for the reason defaultAppIndexForWorkspace
  // gives at length. Cleared on every open, so a fresh overview is never
  // wearing the last one's scrolls.
  property var rowSelections: ({})

  // Current desktop background image, resolved from the same symlink the
  // background plugin follows. Refreshed each time the overview opens.
  property string backgroundImagePath: ""

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    try { url = decodeURIComponent(url) } catch (e) {}
    return url.replace(/\/+$/, "")
  }

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
    bgProbe.restart()
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
    root.zoomOpenAt = Date.now()
    // And ask the compositor whether the rectangles that measuring will be
    // done from are still the ones it is drawing the desktop from. See
    // probeGeometry: refreshGeometry() above has asked for fresh ones, and the
    // whole of what this waits for is that answer arriving.
    root.probeGeometry()
    root.grabsKeyboard = true
    root.exitOpacity = 1
    // `opened` goes up before `leaving` comes down, and that order is not
    // cosmetic -- see panel.visible.
    root.opened = true
    root.leaving = false
    root.gestureAxis = ""
    // A fresh overview is never wearing the last one's scrolls, for the same
    // reason vScroll.reset() is here: it opens on the desktop as it is.
    root.rowSelections = ({})
    vScroll.reset()
    root.viewReset()
    // The zoom's target, ahead of the budget and ahead of everything else
    // on screen. Every other thumbnail can wait for the rotation to reach it;
    // this is the one the opening zoom magnifies to full size, so it is the
    // one whose staleness would actually be legible.
    //
    // Asked for, not waited on. viewReset() has just refreshed any thumbnail
    // that had no picture at all, and a target that survived the last summon
    // still has that picture -- so the transition starts on what is already
    // there and this arrives behind it. zoomOpener does the waiting, and only
    // for a thumbnail that is genuinely blank.
    root.captureTarget(root.selectedRow, root.selectedApp)
    // Guarded rather than left to dbg()'s own test: the argument is built
    // whether or not it is printed, and this one maps and stringifies every
    // row in the overview on the way into the frame the open is measured from.
    if (root.omariDebug) root.dbg("open focusedWs=" + (focused ? focused.id : "?")
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
    root.rowSelections = ({})
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
  //
  // Monitors along with them, and not as an afterthought: the surface's own
  // corner is read off the monitor's reserved area (see surfaceLeft), so a
  // stale monitor is a dive aimed at where the bar used to be.
  function refreshGeometry() {
    Hyprland.refreshToplevels()
    Hyprland.refreshMonitors()
  }

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

  // The wallpaper path is resolved by a process, and a process spawn is one of
  // the few things in here expensive enough to be worth not doing at the
  // moment the overview opens: it is fork+exec+readlink competing for a slow
  // machine's CPU with the two frames the opening zoom is measured from, for
  // an answer that is the same one it gave last time on every open but the one
  // after a theme change.
  //
  // So the summon starts a timer rather than the process, and the probe lands
  // in the quiet after the zoom. The rows draw the path they already had
  // meanwhile, which is the right one; only the first summon of a session has
  // none, and Component.onCompleted below covers that from shell start, where
  // there is nothing to compete with.
  Timer {
    id: bgProbe
    interval: 320
    onTriggered: bgPathProc.running = true
  }

  Component.onCompleted: bgPathProc.running = true

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

  // Like rowHeight, a ratio: the gap between two workspaces reads relative to
  // how big a workspace is, not in absolute pixels.
  readonly property real rowSpacing: Math.round(root.rowHeight * 0.104)

  // How far outside the viewport a row still counts as "on screen" -- which
  // now means "first in line for the capture budget" rather than "streaming".
  // One row's worth of slack means a row is already being refreshed by the
  // time it scrolls into view and stays so well after it has left, so a
  // scroll hovering around a boundary never thrashes a thumbnail between the
  // scheduler's on-screen rotation and its slower prefetch one.
  //
  // Narrowing this to a third of a row was tried and reverted. A screencopy
  // takes a frame or two to arrive, so a margin thinner than a row starts
  // refreshing at the moment the row appears rather than before it, and the
  // row scrolls in showing a picture from whenever it was last on screen.
  readonly property real nearMargin: root.rowHeight

  // How far outside the viewport a row is still *drawn*. Wider than
  // nearMargin, and the order of the two is the point: a row starts being
  // rendered before it is close enough to be seen, so the frame that brings
  // it on screen is never also the frame that builds its layers.
  //
  // Past this a row is `visible: false` rather than merely clipped away.
  // Clipping is not free the way it looks: a row that is only scrolled off
  // screen still keeps every one of its thumbnails' offscreen layers and its
  // wallpaper's shadow layer allocated and up to date, and on a machine with
  // ten workspaces that is ten screens' worth of texture the overview never
  // shows. A workspace is half the viewport, so this keeps roughly the two
  // rows either side of the visible pair and drops the rest.
  //
  // It no longer has anything to do with what captures. Being drawn used to
  // be what re-armed a capture, so this doubled as the outer bound on
  // screencopy traffic; captureFrame() is not paint-driven -- an undrawn view
  // refreshes perfectly well when asked -- so the scheduler's prefetch band
  // rides on this rather than being enforced by it. It is a texture budget
  // now and nothing else.
  readonly property real renderMargin: root.rowStride * 1.6

  // Rows are a plain uniform height — no label, no per-row chrome — which is
  // what lets every "where is row i" question in here be arithmetic rather
  // than a live geometry read off a delegate that may not exist yet.
  readonly property real rowStride: root.rowHeight + root.rowSpacing

  // ---- the capture scheduler ----
  //
  // Every ScreencopyView in here is permanently `live: false`. This is where
  // their frames come from instead.
  //
  // A live capture is not a stream the compositor pushes at us, it is a loop
  // we hold open: each frame that arrives dirties the view, the view
  // repaints, Quickshell re-arms the capture from updatePaintNode, and the
  // next frame arrives to dirty it again. So a visible thumbnail renders at
  // the display's refresh rate for as long as it is on screen, whether or not
  // the window it shows has changed a single pixel -- and in here every one
  // of those frames also re-renders a supersampled offscreen layer and
  // rebuilds its mipmap chain, which for a full-screen window on this panel
  // is a 2572x1720 texture (see captureBox). Measured: two thumbnails at
  // overview geometry held the renderer at 66fps with the overview open,
  // still, and untouched. The same two frozen sat at 1.2fps.
  //
  // What replaces it is a budget -- a fixed number of captures per second,
  // handed to whichever thumbnail most needs one. The reason it is a budget
  // rather than a tighter version of nearRow is that a budget's cost does not
  // scale with how many thumbnails are on screen and live capture's does, and
  // a machine with a lot of windows is exactly the one that cannot afford the
  // difference.

  // Captures per second, shared across the whole overview.
  //
  // Six is off the measured curve rather than off the feel of it: idle cost
  // falls about linearly up to ~12/s and is indistinguishable from fully live
  // at 30/s and above, so a faster budget pays live's price without live's
  // freshness. At six, a screen showing six or eight thumbnails refreshes
  // each about once a second -- invisible on a static window, alive on a
  // terminal, a slideshow on video. That last one is the honest cost of not
  // being live, and it is a great deal smaller than every thumbnail being
  // frozen for as long as the overview is up.
  readonly property real captureBudget: 6

  // How long a thumbnail is left alone after a capture. Only binds when very
  // few thumbnails are on screen -- with a normal screenful the rotation is
  // already slower than this -- and what it prevents is the budget being
  // spent six times a second on a single visible window.
  readonly property int captureCooldownMs: 500

  // The same, for a thumbnail inside the render margin but not yet near the
  // viewport -- and for windows off the side of a row that is otherwise on
  // screen. These get the budget only when nothing on screen wants it.
  //
  // Which, on a full screen, is rarely: six visible thumbnails against a
  // budget of six come round about once a second each, so they are past the
  // cooldown above whenever they are looked at and the leftovers never
  // appear. That is deliberate rather than a shortfall. A row scrolling in
  // still has whatever picture it had when it was last on screen -- rows are
  // kept, not rebuilt -- and the moment it becomes near it enters the
  // rotation with the oldest picture on screen, so it is refreshed first by
  // the ordinary path. This tier is a bonus for a quiet overview, not a
  // guarantee, and nothing depends on it running.
  readonly property int capturePrefetchMs: 3000

  // Deliberately a Timer, and deliberately NOT a FrameAnimation.
  //
  // A FrameAnimation asks the renderer for a frame on every frame -- that is
  // the whole of what it is -- so driving this from one would pin the render
  // loop at refresh rate and hand back none of what the scheduler exists to
  // save. It is not a small effect and it is not theoretical: measured, a
  // FrameAnimation issuing no captures at all cost 67fps of idle rendering,
  // which is exactly what leaving every thumbnail live costs. A wall-clock
  // Timer wakes the event loop and nothing else; at rest this whole mechanism
  // measured 1.2fps.
  //
  // The interval is not the rate. Tokens below are what set the rate, so this
  // can tick often enough to stay responsive to motion ending without the
  // tick itself deciding how many captures happen.
  Timer {
    id: captureTick
    interval: 100
    repeat: true
    running: root.opened && !root.leaving
    onTriggered: root.captureTock()
  }

  // Never more than one, which is the whole of "no burst when motion
  // settles": whatever the overview was doing, the frame it stops on can
  // spend at most a single capture, and the rest arrive at the ordinary rate
  // behind it.
  property real captureTokens: 0

  // Whether the overview is holding still enough to spend the budget.
  //
  // Written as a function rather than a binding on purpose. The inputs are
  // scroll positions and delegate state, and a binding over those would
  // re-evaluate on every pixel of every scroll -- during precisely the motion
  // it exists to stand back from.
  function captureQuiet() {
    if (!root.opened || root.leaving || root.diving) return false
    if (zoomRamp.running) return false
    if (root.gestureMode !== "") return false
    if (vScroll.moving) return false
    // Any row may be gliding, not just the selected one: a row's restPosition
    // moves when the selection inside it does, and it glides there on its own.
    var rows = root.workspaceRows
    for (var i = 0; i < rows.length; i++) {
      var row = rowRepeater.itemAt(i)
      if (row && row.renderNear && row.hScroll && row.hScroll.moving) return false
    }
    return true
  }

  // The thumbnail most worth spending a capture on, or null.
  //
  // Oldest-first rather than a cursor walked round the rows: a cursor has to
  // survive delegates being rebuilt underneath it -- which happens every time
  // a window opens or closes -- and picking the stalest picture is both fairer
  // and stateless. The counts here are a handful of rows by a handful of
  // windows, ten times a second.
  function captureNext() {
    var now = Date.now()
    var rows = root.workspaceRows
    var blank = null                       // on screen with nothing in it
    var stale = null, staleAge = -1        // on screen, oldest picture
    var far = null, farAge = -1            // warm for a scroll that may come

    for (var i = 0; i < rows.length; i++) {
      var row = rowRepeater.itemAt(i)
      if (!row || !row.renderNear) continue
      var near = row.nearViewport
      var apps = row.sortedToplevels
      var n = apps ? apps.length : 0
      for (var j = 0; j < n; j++) {
        var t = row.thumbItemAt(j)
        if (!t || !t.requestCapture) continue
        var age = now - t.lastCaptureMs
        if (near && t.nearRow) {
          // A thumbnail with no picture is the one case worth jumping the
          // queue for: it is drawn as a flat rectangle until it has one, and
          // it is what zoomOpener waits on rather than uncover.
          if (!t.hasPicture) { if (!blank) blank = t; continue }
          if (age >= root.captureCooldownMs && age > staleAge) { staleAge = age; stale = t }
        } else if (age >= root.capturePrefetchMs && age > farAge) {
          farAge = age; far = t
        }
      }
    }
    return blank || stale || far
  }

  function captureTock() {
    if (!root.captureQuiet()) return
    root.captureTokens = Math.min(1, root.captureTokens + root.captureBudget * (captureTick.interval / 1000))
    if (root.captureTokens < 1) return
    var t = root.captureNext()
    if (!t) return
    root.captureTokens -= 1
    t.requestCapture()
  }

  // The one capture that does not wait for the budget: whatever the overview
  // is about to zoom into or out of.
  //
  // It is asked for and then not waited on. The retained picture is already
  // there and the transition starts on it -- see zoomOpener -- so this is the
  // fresh frame arriving a beat later into a thumbnail that was never blank,
  // rather than a round trip anything is held up by.
  function captureTarget(rowIndex, appIndex) {
    var row = rowRepeater.itemAt(rowIndex)
    if (!row) return
    var t = row.thumbItemAt(appIndex)
    if (t && t.requestCapture) t.requestCapture()
  }

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
    //
    // What is held is this same array of these same rows, not a copy of it --
    // which is the whole of what makes freezing free. See frozenRows.
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
    return ws ? root.sortToplevelsBySpatialOrder(root.toplevelsFor(ws)) : []
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

  // ---- remembering what the user scrolled a row to ----
  //
  // Recorded only from a deliberate move -- an arrow key, or a strip coming to
  // rest under the fingers. Never from the automatic re-pick below, which is a
  // *default* rather than a choice: recording that would mark every row merely
  // passed over as changed, and commitFocusArgs would then dispatch focus at
  // workspaces the user never touched.
  function noteSelectedApp(index) {
    root.selectedApp = index
    // A fresh object rather than a write into the old one. QML compares var
    // properties by reference, so mutating in place moves what every dependent
    // binding would read without telling one of them to read it again -- and
    // the whole point of this is a binding in every non-centred row.
    var next = {}
    for (var k in root.rowSelections) next[k] = root.rowSelections[k]
    next[root.selectedWorkspaceId] = index
    root.rowSelections = next
  }

  // The index the user put this workspace's row on, or -1 for "never touched".
  function rowSelectionFor(id) {
    var v = root.rowSelections[id]
    return v === undefined ? -1 : v
  }

  // Keyed on the workspace *id*, not on selectedRow. selectedRow is a binding
  // over workspaceRows, which Hyprland re-evaluates on every model update — a
  // window opening anywhere, or just a title changing — and any of those that
  // shifts the row index, even transiently, would fire this and silently throw
  // away a left/right selection the user had just made. The id only ever moves
  // when something actually chooses a different workspace.
  //
  // Coming *back* to a row lands on where the user left it, not on Hyprland's
  // focus there. Anything else contradicts the row itself, which has been
  // sitting at that scroll the whole time you were away (see
  // rowItem.selectedIndex) -- the centred row would jump on arrival.
  onSelectedWorkspaceIdChanged: {
    var remembered = root.rowSelectionFor(root.selectedWorkspaceId)
    root.selectedApp = remembered >= 0
      ? remembered
      : root.defaultAppIndexForWorkspace(root.selectedWorkspaceId)
  }

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
    root.noteSelectedApp(Math.max(0, Math.min(apps.length - 1, root.selectedApp + delta)))
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

  // When the current summon started, and how long the zoom may wait for its
  // target thumbnail to have a picture in it before opening without one.
  //
  // Measured rather than counted in frames on purpose: what is being waited
  // for is a round trip to the compositor, so the budget is in milliseconds,
  // and on a machine slow enough to matter a frame is not a fixed number of
  // them. Long enough to cover a capture that is merely late, short enough
  // that a capture which is never coming does not hold the overview shut.
  property real zoomOpenAt: 0
  readonly property int zoomWaitMs: 220

  // The budget for the other round trip an open waits on; see probeGeometry.
  // A tenth of what that one costs, because it is a different kind of wait: a
  // screencopy that is late is late for reasons out here, while this is a
  // socket round trip measured in single-digit milliseconds against a
  // compositor that is by definition answering. What it really guards against
  // is the two ends never agreeing at all -- some future rounding that makes
  // the comparison in geometryIsCurrent permanently false -- and there the
  // whole point is that it costs a few frames of desktop rather than a fifth
  // of a second of one.
  readonly property int geometryWaitMs: 80

  // ---- is the picture current? ----
  //
  // Whether the rectangles the overview draws itself from describe the layout
  // Hyprland has now, or the one it had the last time anything asked.
  //
  // Nothing moves a window in Quickshell's model on its own: lastIpcObject is
  // filled in by an IPC query and by nothing else (see refreshGeometry), and a
  // scrolling layout scrolls the whole workspace every time the focus moves
  // between columns -- with nothing on the event socket to say so, because no
  // window has been opened, closed, or moved between workspaces. The tape has
  // simply been drawn somewhere else. So by the time the overview is summoned,
  // the layout it holds can be several focus changes out of date, and the
  // further the tape has run since, the further out it is.
  //
  // open() asks for it again, and that answer used to be safe to assume was in
  // hand by the time anything read it: the query was written when a summon
  // spent ~200ms per frame mapping its layer surface, which is a very long
  // time for a reply that takes one or two milliseconds. The surface stays
  // mapped now and the zoom is measured on the first frame the renderer
  // produces (see zoomOpener), so the reply and that frame are in a race -- and
  // on the frames it loses, everything the zoom is built from is measured off
  // the old layout: the strip is drawn where the workspace used to be, and the
  // window the zoom is anchored on is aimed at where that window used to be.
  // The overview then falls back out of a picture of the desktop that is a
  // whole scroll out of register with the desktop underneath it, which reads
  // exactly as what it is -- the zoom pivoting on some other window, generally
  // the one now standing where the focused one stood before.
  //
  // It is the same trap the dive walks around by asking Hyprland where the
  // window went (see aimZoom) instead of trusting what it has, and the answer
  // is put to the same use: not drawn from -- the rows draw from Quickshell's
  // model and only it -- but compared against. Hyprland describing the focused
  // window exactly as the model already has it is that model's refresh having
  // landed.
  property bool geometryLanded: true

  function probeGeometry() {
    root.geometryLanded = false
    root.hyprSend("j/activewindow", "open")
  }

  // One window, because one query answers for all of them: the refresh asked
  // for above is a single request for every client, whose reply writes the
  // whole model at once, so one rectangle that agrees is that reply having
  // been processed.
  function geometryIsCurrent(win) {
    var top = Hyprland.activeToplevel
    // Nothing to compare against is not a reason to hold the overview shut: an
    // empty workspace has no focused window, and a reply that would not parse
    // is an answer that is not coming.
    if (!win || !win.address || !top) return true
    var ipc = top.lastIpcObject
    if (!ipc || !ipc.address || String(ipc.address) !== String(win.address)) return false
    var real = root.rectFromIpc(win)
    var cached = root.liveRectFor(top)
    if (!real || !cached) return true
    return Math.abs(cached.x - real.x) < 0.5 && Math.abs(cached.y - real.y) < 0.5
      && Math.abs(cached.w - real.w) < 0.5 && Math.abs(cached.h - real.h) < 0.5
  }

  function openProbeLanded(reply) {
    if (!root.opened || root.geometryLanded) return
    var current = root.geometryIsCurrent(root.parseWindow(reply))
    // And bounded, for the same reason the paint wait is: an overview that
    // cannot be shown the current layout has to open on the layout it has
    // rather than not open. See geometryWaitMs for why this one's budget is
    // the smaller of the two.
    if (current || Date.now() - root.zoomOpenAt >= root.geometryWaitMs) {
      root.geometryLanded = true
      root.dbg("geometry " + (current ? "landed" : "GAVE UP") + " after "
        + Math.round(Date.now() - root.zoomOpenAt) + "ms")
      return
    }
    geometryProbeRetry.restart()
  }

  // Ask again rather than sit on an answer that says the model has not caught
  // up yet. Same interval as aimRetry, for the same reason it has one.
  Timer {
    id: geometryProbeRetry
    interval: 8
    onTriggered: if (root.opened && !root.geometryLanded) root.probeGeometry()
  }

  // Where the overlay's own top-left sits on the monitor, which since the
  // surface started respecting exclusion zones is no longer the monitor's
  // top-left: the compositor hands back the monitor less whatever the bar and
  // anything beside it have reserved, and the overlay begins at the corner of
  // what is left. Every real-window rectangle in here is in layout
  // coordinates, so it has to come off them before they mean anything as a
  // position inside this surface -- see zoomRealX/Y, which are the only two
  // measurements in the file that cross that line. Get it wrong and every
  // dive lands the height of the bar out of place, which is the one frame in
  // the whole interaction where being out of place is visible.
  //
  // Read from Hyprland's own reserved area rather than measured off the
  // surface, because a size can't be told apart from a position: a surface
  // shortened by 26px looks the same whether the bar is at the top or the
  // bottom. `reserved` is [left, top, right, bottom] in logical pixels -- the
  // same units as a window's `at` -- and is the very quantity the compositor
  // subtracted to place this surface, so the two cannot drift.
  readonly property var panelReserved: {
    var mon = panel.screen ? Hyprland.monitorFor(panel.screen) : null
    var ipc = mon ? mon.lastIpcObject : undefined
    var r = ipc ? ipc.reserved : undefined
    return (r && r.length === 4) ? r : [0, 0, 0, 0]
  }
  readonly property real surfaceLeft: Number(root.panelReserved[0]) || 0
  readonly property real surfaceTop: Number(root.panelReserved[1]) || 0

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

  // ---- the row's shift, and the rate the zoom already assumes for it ----
  //
  // How much of the row's own scroll has been performed at this progress, as a
  // fraction of it. See aimZoom for what that scroll is, and rowItem.diveShift
  // for where it is applied.
  //
  // It used to be the progress itself, and that is the whole of a dive out of a
  // scrolled row looking like a zoom anchored on some other window.
  //
  // The two halves of the dive disagreed about *when* the shift happens. The
  // row performs it in row pixels: rowContent slides by shift x progress, which
  // on screen is that again multiplied by the zoom factor, so it starts slowly
  // and accelerates as the strip grows. The transform's compensation for it is
  // not a matching curve -- it is a single number, the thumbnail's position at
  // the end of the dive (aimZoom moves the capture there), which zoomOffset
  // ramps linearly. So the offset carries the shift at a constant rate in
  // screen pixels while the row delivers it at an accelerating one, and the
  // difference between them, in screen pixels, is
  //
  //     shift x progress x (zoomScale - zoomFactor)
  //
  // which is zero at both ends of the ramp and largest in the middle -- three
  // quarters of the whole shift, at a quarter-size thumbnail. The endpoints
  // being exact is why this was never a dive that landed wrong: the window
  // arrived precisely where it belonged, having swung most of a screen's width
  // sideways and back on the way. That swing is the "wrong pivot", and it grows
  // with the shift, which is why it takes scrolling a row away from its
  // workspace's own position before diving out of it to see.
  //
  // Dividing the factor back out is what makes the row's slide linear in screen
  // pixels too -- constant velocity, the same thing every other term in the
  // transform travels at. The zoomScale factor renormalises it so progress 1
  // still performs the whole shift, which every endpoint here depends on, and
  // it stays monotonic in progress for any scale above zero, so the row never
  // backs up.
  readonly property real diveShiftPhase: root.zoomFactor > 0
    ? root.zoomProgress * root.zoomScale / root.zoomFactor
    : root.zoomProgress

  // The shift as the row is drawing it right now, in row pixels.
  readonly property real diveShiftNow: root.diveShiftPx * root.diveShiftPhase

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

  // Nothing at all until the strip is showing, and that leading term is not a
  // refinement of the curve below -- it is the whole of the grey flash on an
  // opening swipe.
  //
  // The strip is held invisible until zoomReady (see zoomLayer.opacity), and
  // an opening swipe writes zoomProgress from the fingers from the very first
  // event, before the surface has been drawn once. backdropRise is a tenth, so
  // some thirty pixels of finger travel took this to fully opaque -- and with
  // the strip not yet drawing, fully opaque is a flat mid grey over the whole
  // screen with nothing on it. That is the grey flash, and it got wider the
  // longer the first frame took, which is to say it was worst on exactly the
  // machines that could least afford it.
  //
  // Held at zero instead, an open that is not ready yet shows the real desktop
  // through a transparent overlay -- which is what the frame before the swipe
  // showed, and the frame the zoom is supposed to start from anyway.
  readonly property real backdropOpacity: !root.zoomReady
    ? 0
    : root.diving
      ? 1 - root.zoomProgress * root.zoomProgress
      : Math.min(1, (1 - root.zoomProgress) / root.backdropRise)

  // Ramping the scale alone would drag the target away from both endpoints in
  // between; this holds its top-left on the straight line from thumbnail to
  // real window for the whole ramp.
  //
  // Straight line including the row's own scroll, which is worth saying
  // because it is not obvious from here: the term this subtracts is the
  // thumbnail's position at the *end* of the dive (aimZoom moves the capture
  // there), so the offset is already carrying the whole of the row's shift, at
  // a rate linear in progress and therefore in screen pixels. What the row
  // performs has to match that. See diveShiftPhase.
  function zoomOffset(thumbPos, realPos) {
    return thumbPos + (realPos - thumbPos) * root.zoomProgress
      - root.zoomFactor * thumbPos
  }

  // Measures the thumbnail's live on-screen box rather than recomputing the
  // layout from the model, so it stays correct when a row has been scrolled
  // away from its resting position.
  //
  // Must be called BEFORE freezeGeometry. The freeze used to hand the Repeater
  // a fresh array of snapshot rows (see freezeToplevels), which rebuilt every
  // row delegate, and a delegate that has just been created used to sit at y 0
  // whatever its index:
  // a Column positions its children in a later pass, so measuring inside the
  // same statement returned the *first* row's place for whichever row was
  // actually being dived into:
  //
  //   probe BEFORE freeze rowY=503 thumbAt=348,251
  //   probe AFTER  freeze rowY=0   thumbAt=348,-252
  //
  // exactly one rowStride out, per row of index. The zoom was then anchored on
  // row 0's slot, so a dive from any row at all ended with the *first*
  // workspace filling the screen -- and only a dive from row 0 was ever right,
  // because there the stale position and the real one are the same number.
  //
  // Both halves of that trap are sprung now. A row's y is a plain binding on
  // its own index rather than a positioner's output (see the Item that replaced
  // the Column), so it is right from the instant a delegate is created -- and
  // the freeze no longer creates any, since it holds the row list it was
  // already answering with instead of a copy of it. The ordering stays as it
  // is regardless: measuring the picture before pinning it is the statement
  // being made, and there is nothing to be gained by making it the other way
  // round.
  //
  // Nothing else the freeze does disturbs the measurement either: it stops the
  // scrollers rather than moving them, and the strips keep their positions
  // (hPos and stripOffset are unchanged above), so a capture taken a statement
  // earlier describes the same picture the freeze then pins.
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
    // A window's place inside this surface is its layout rectangle less the
    // monitor's origin and less the corner the surface actually starts at --
    // see surfaceLeft/surfaceTop. The overlay used to cover the monitor
    // exactly, and then the second term was zero and went unwritten.
    root.zoomRealX = r.x - row.monX - root.surfaceLeft
    root.zoomRealY = r.y - row.monY - root.surfaceTop
    root.zoomScale = r.w / item.width
    return true
  }

  // Whether the thumbnail the zoom is anchored on has a frame in it yet.
  // Missing delegates answer false: there is nothing to wait for that the
  // deadline in zoomOpener will not resolve on its own.
  function zoomTargetPainted() {
    var row = rowRepeater.itemAt(root.selectedRow)
    if (!row) return false
    var item = row.thumbItemAt(root.selectedApp)
    return !!item && item.hasPicture
  }

  function clearZoom() {
    zoomRamp.halt()
    diveDeadline.stop()
    aimRetry.stop()
    geometryProbeRetry.stop()
    root.geometryLanded = true
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
    // The dive's target, one fresh frame, now -- and then nothing more until
    // the overview is back. captureQuiet() refuses while root.diving, so this
    // is the last capture this thumbnail takes before it is magnified to full
    // size, and the dive runs on it frozen.
    //
    // The timing is better than it looks. The dispatch goes out before a
    // pixel of the dive is drawn and the overview then stands still for a
    // couple of frames under an opaque backdrop waiting for Hyprland to
    // answer -- so the frame asked for here lands during those, which is the
    // least visible moment in the whole transition rather than the most.
    root.captureTarget(rowIndex, appIndex)
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
  // Which of the two askers the answer in flight belongs to; see hyprSend.
  property string hyprReplyTo: "dive"

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
        + root.hyprReply.length + " bytes for " + root.hyprReplyTo)
      if (root.hyprReplyTo === "open") root.openProbeLanded(root.hyprReply)
      else root.beginDive(root.hyprReply)
    }
    onError: function(err) { root.dbg("socket error " + err) }
  }

  // `replyTo` names what the answer is for, because there are two things it can
  // be for now and the socket carries one at a time. Defaulted rather than
  // required: everything that does not say is the dive, which is everything
  // that ever sent on this socket before the open began asking too.
  function hyprSend(request, replyTo) {
    root.hyprReplyTo = replyTo || "dive"
    if (root.hyprReplyTo === "dive") {
      // A dive has started, and it both owns the socket and answers the
      // question the open was still asking -- it measures the layout its own
      // dispatch produced, which is a later answer than any the probe could
      // bring back. So the open stops waiting for one.
      geometryProbeRetry.stop()
      root.geometryLanded = true
    }
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
  function dispatchAndAim(pre, arg) {
    root.hyprSend("[[BATCH]]" + root.dispatchChain(pre.concat([arg])) + ";j/activewindow")
  }

  // One `dispatch` per argument, joined by the batch separator. Hyprland runs
  // them in the order given, so the last one is the one that decides where
  // focus and the active workspace end up; everything before it is passed
  // through. Nothing a focus argument contains is a `;` (see focusArg), so the
  // separator is unambiguous.
  function dispatchChain(args) {
    return args.map(function(a) { return "dispatch " + a }).join(";")
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

    // Same crossing as captureZoom's, and for the same reason.
    root.zoomRealX = r.x - row.monX - root.surfaceLeft
    root.zoomRealY = r.y - row.monY - root.surfaceTop
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
      // Built only when it is wanted; see open(). This one runs on the first
      // frame of every summon, which is the frame with the least to spare.
      if (root.omariDebug) root.dbg("zoomOpener frame: selectedRow=" + root.selectedRow
        + " selectedApp=" + root.selectedApp
        + " rows=" + JSON.stringify(root.workspaceRows.map(function(r) { return r.id }))
        + " gestureActive=" + root.gestureActive)
      if (root.captureZoom(root.selectedRow, root.selectedApp)) {
        // Geometry is not a picture. captureZoom answers as soon as the
        // delegate has been laid out, which is a frame or more before its
        // screencopy has arrived -- and uncovering there hands the zoom a
        // thumbnail with nothing in it, blown up over the whole screen. That
        // is a flat Color.background rectangle with the backdrop's grey around
        // it, held for as long as the capture takes, and it is the same defect
        // as the backdrop flash seen one layer further in.
        //
        // So the measurement is kept -- it is re-taken every frame anyway and
        // stays current while we wait -- and the uncovering waits. Until it
        // happens the backdrop is transparent and the strip is invisible, so
        // what is on screen is the real desktop, still, which is what the
        // fingers started the swipe on.
        //
        // Geometry is not a picture either, and it is the other half of the
        // same statement: a measurement taken off a layout the compositor has
        // already scrolled away from is a zoom anchored on where the window
        // used to be. That one is waited on here rather than in the capture
        // because it is the *uncovering* both of them are about -- see
        // probeGeometry, which is what geometryLanded is the answer to.
        //
        // The deadline is the important half of both: a window the compositor
        // will never hand over, or a layout it will never describe, must open
        // the overview *without* a zoom rather than hold it shut, so a stream
        // or a socket that has died takes an extra fifth of a second and
        // nothing worse.
        if (!(root.geometryLanded && root.zoomTargetPainted())
            && Date.now() - root.zoomOpenAt < root.zoomWaitMs) return
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

  // Decorated rather than sorted through spatialXFor directly. Every call of
  // that walks rectFor, which allocates a fresh rectangle, and a comparator
  // runs O(n log n) times against O(n) windows -- so the naive version
  // measured each window's position several times over and threw all but one
  // of the answers away. This asks once per window. It is the same order, and
  // it is re-derived every time Hyprland answers a geometry query with the
  // overview up, per row.
  function sortToplevelsBySpatialOrder(values) {
    var n = values ? values.length : 0
    if (n < 2) return values ? values.slice() : []
    var keyed = new Array(n)
    for (var i = 0; i < n; i++) keyed[i] = { t: values[i], x: root.spatialXFor(values[i]) }
    keyed.sort(function(a, b) { return a.x - b.x })
    var out = new Array(n)
    for (var j = 0; j < n; j++) out[j] = keyed[j].t
    return out
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

  // Each frozen row's windows, keyed by workspace id. The list of rows is
  // pinned by holding the array; the lists *inside* the rows cannot be, since
  // they belong to Hyprland -- see freezeToplevels.
  property var frozenToplevels: null

  // Whether the picture is pinned. The scrollers bind their own `frozen` to
  // this rather than being told once, so nothing that arrives later can start
  // them moving again -- see KineticScroll.
  readonly property bool viewIsFrozen: root.frozenRects !== null

  // Each row's window list as it stands right now, keyed by workspace id.
  //
  // Holding root.workspaceRows is enough to pin the rows themselves, but not
  // what is in them: the entries are real HyprlandWorkspace objects, and
  // `toplevels.values` on one of those is as live as anything else here -- the
  // focus dispatch moves the active workspace, Quickshell rebuilds that model,
  // and a row silently gains or loses a window mid-dive, which re-runs the
  // Repeater over it and re-lays out every thumbnail beside it.
  //
  // This used to be done by replacing the rows with plain snapshot objects,
  // and that cost the overview every picture in it. A Repeater rebuilds when
  // its model is a *different* list and it compares by value, so an array of
  // the same workspace objects in the same order is the same list however many
  // times the binding re-runs -- which is what lets the live model be
  // re-evaluated on every geometry event for nothing. An array of freshly
  // built snapshot objects is a different list every time. So the freeze threw
  // away every row delegate, the thaw threw them away again, and each of those
  // took every ScreencopyView in the overview with it: thumbnails back to bare
  // grey at the first frame of the dive, and again on the summon after it,
  // since the thaw in finish() rebuilds them with the overview down and
  // nothing drawing to re-arm a capture. That is the flash.
  //
  // Freezing the window lists on their own leaves the row objects, and so the
  // model, untouched.
  function freezeToplevels(rows) {
    var out = ({})
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (!row) continue
      out[row.id] = (row.toplevels ? row.toplevels.values.slice() : [])
    }
    return out
  }

  // What everything that draws a row asks for its windows, and rectFor's
  // counterpart in every way: pinned once the dive has started, live until
  // then. Answers with the same toplevel objects either side of the freeze,
  // which is what keeps the thumbnail Repeaters from rebuilding across it.
  function toplevelsFor(row) {
    if (!row) return []
    if (root.frozenToplevels) {
      var frozen = root.frozenToplevels[row.id]
      if (frozen) return frozen
    }
    return row.toplevels ? row.toplevels.values : []
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
    // All four are handed the value the live binding is answering with right
    // now, so raising the flags changes nothing that is on screen: the freeze
    // is invisible going in, and only shows up as the things that stop
    // happening after it. Rows last, and by reference -- the list handed over
    // is the one workspaceRows was already answering with, so the Repeater
    // over it sees no change at all and not one delegate is rebuilt.
    root.frozenFocus = focus
    root.frozenRects = frozen
    root.frozenToplevels = root.freezeToplevels(root.workspaceRows)
    root.frozenRows = root.workspaceRows.slice()
    // The rectangles are only half of it: a strip still coasting from a flick,
    // or gliding towards a rest position, moves under the zoom just as surely
    // as a re-layout would.
    vScroll.stop()
    root.viewFrozen()
  }

  function thawGeometry() {
    root.frozenRects = null
    root.frozenRows = null
    root.frozenToplevels = null
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
    // Every row the user scrolled goes out in front of the destination, in the
    // same batch, so leaving the overview leaves the workspaces arranged the
    // way it was showing them. Cleared here rather than at the end of the
    // leave: this is the moment they stop being pending and start being true,
    // and a gesture dive that is pushed back up after this point should find
    // its rows agreeing with the compositor rather than asking for the same
    // dispatches a second time. See commitFocusArgs.
    var pre = root.commitFocusArgs()
    root.rowSelections = ({})
    root.dbg("dispatch after restore at " + (Date.now() - root.dbgClickMs) + "ms"
      + (pre.length > 0 ? " with " + pre.length + " row commit(s)" : ""))
    // A dive needs the reply as much as it needs the dispatch, so it takes the
    // longer way round; everything else fires and forgets. The un-dived
    // hand-off starts holding still for the switch from here too, since here
    // is where the switch actually begins.
    if (root.awaitingLanding) {
      // From here, and not from the click: see diveDeadline.
      diveDeadline.restart()
      root.dispatchAndAim(pre, arg)
    } else {
      root.hyprSend(pre.length > 0
        ? "[[BATCH]]" + root.dispatchChain(pre.concat([arg]))
        : "dispatch " + arg)
      switchHold.restart()
    }
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

  // The rows the user scrolled, as focus dispatches, for the batch that leaves
  // the overview -- everything except the row being left on, which is the
  // destination dispatch those go in front of.
  //
  // A scrolling layout has no dispatcher for "scroll this workspace to here"
  // (the same wall rowScroll.onSettled runs into): the only way to put a
  // workspace where the overview is showing it is to focus the window the
  // overview has ringed there, and Hyprland focuses a window by going to it.
  // So each of these switches the active workspace as it runs, which is
  // exactly why they go first and the destination goes last -- the batch runs
  // in order inside the compositor and the last dispatch is the one that
  // decides where you come out. All of it happens in the one round trip that
  // was already being made, behind a backdrop that is already opaque.
  //
  // A row whose remembered index is what Hyprland has focused there anyway is
  // dropped: the scroll it asks for has already happened, and dispatching it
  // would move that window up the focus history (see focusedIndexFor) for
  // nothing. An overview that was only looked at therefore sends nothing extra
  // and this costs nothing at all.
  function commitFocusArgs() {
    var args = []
    var rows = root.windowedRows
    for (var i = 0; i < rows.length; i++) {
      var want = root.rowSelectionFor(rows[i].id)
      if (want < 0) continue
      var apps = root.sortToplevelsBySpatialOrder(rows[i].toplevels.values)
      if (apps.length === 0) continue
      // The row being left on is skipped both ways it can be identified: it is
      // the centred one for everything that leaves by the selection, and it is
      // whichever row holds the clicked window for a click, which can land on
      // a row that was never centred at all. Either way its scroll is the
      // destination dispatch's own business and that one goes last.
      if (rows[i].id === root.selectedWorkspaceId) continue
      if (root.pendingActivation && apps.indexOf(root.pendingActivation) >= 0) continue
      want = Math.max(0, Math.min(apps.length - 1, want))
      if (want === root.focusedIndexFor(apps)) continue
      var arg = root.focusArg(apps[want])
      if (arg) args.push(arg)
    }
    return args
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
    // Was Ignore, and Ignore is what put the overview over the bar. The two
    // modes are not a preference about exclusion zones, they are two different
    // rectangles: Quickshell sends exclusive_zone -1 for Ignore and 0 for
    // Normal, and Hyprland lays a -1 surface out against the whole monitor and
    // a 0 one against what is left of it (arrangeLayerArray: `bounds =
    // full_area` against `bounds = *usableArea`). So this one line is the
    // whole of showing the bar. Nothing here draws around it, punches a hole
    // in an input region, or has to know how tall it is -- the surface simply
    // is not there any more, and the bar is as visible and as clickable
    // underneath the overview as it is with the overview down.
    //
    // Reserves nothing itself: Normal is "respect the others and optionally
    // set one", and exclusiveZone defaults to 0, which is the "not one" half.
    // An overview that reserved space would be reserving it from the windows
    // it is a picture of.
    exclusionMode: ExclusionMode.Normal

    // Nothing at all is clickable while the overview is down. The surface
    // covers the usable screen the whole time it is up, which is now all of
    // the time,
    // so without this the desktop under it would stop taking clicks the moment
    // the shell started. An empty region is the documented way to ask for that:
    // Quickshell sets Qt::WindowTransparentForInput for a mask that is present
    // but empty, and treats a null mask as "the whole window".
    property Region noInput: Region {}
    mask: root.surfaceLive ? null : panel.noInput
    // The compositor resizing this surface is the only notice that the
    // reserved area changed -- hiding the bar is a layer-shell rearrange, not
    // a Hyprland event, so there is nothing on the socket to listen for. The
    // resize itself is the event: whatever moved, our corner moved with it.
    onHeightChanged: Hyprland.refreshMonitors()
    onWidthChanged: Hyprland.refreshMonitors()

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

        // Asked once for the whole overview rather than through a Screen
        // attachment per thumbnail and per row. Every texture size in here is
        // in device pixels and every one of them used to instantiate its own
        // attached object to find that out.
        readonly property real dpr: Screen.devicePixelRatio
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
          // Exactly undoes Hyprland's global touchpad scroll_factor
          // (Omarchy default 0.4), so the content tracks raw finger travel
          // 1:1 -- see the property's own comment in KineticScroll.qml. The
          // previous 4 over-corrected to 1.6x, which is what made the pad
          // read as twitchy: a small flick crossed several rows.
          dragScale: 2.5

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

        // A plain Item, not a Column, and the rows place themselves at
        // index * rowStride inside it. Rows are a uniform height, so a
        // positioner was computing a number the rest of the file already
        // derives arithmetically -- viewport.centerPositionFor, the snap
        // points, rowItem.viewportY are all `index * rowStride` and always
        // were. What the positioner cost was the one thing that mattered: a
        // Column lays out only its *visible* children and closes the gap left
        // by an invisible one, so with it there no row could be dropped from
        // the scene without every row below it sliding up a slot. See
        // rowItem.renderNear, which is what that buys.
        Item {
          id: column
          width: viewport.width
          height: root.workspaceRows.length * root.rowStride
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
              y: rowItem.index * root.rowStride

              // How root.selectedRowScroll() reaches this row's horizontal axis.
              property alias hScroll: rowScroll

              // Windows in real on-screen (left-to-right) order, so the
              // thumbnails either side of the focused one match how the
              // actual windows are laid out on the workspace.
              readonly property var sortedToplevels: root.sortToplevelsBySpatialOrder(root.toplevelsFor(rowItem.modelData))
              readonly property int focusedIndex: root.focusedIndexFor(rowItem.sortedToplevels)

              readonly property bool current: rowItem.index === root.selectedRow

              // The trailing stand-in row. It draws exactly like any other —
              // the same wallpaper at the same size — because that *is* what
              // an empty workspace looks like; it just has no strip to scroll
              // and a click target of its own instead of thumbnails.
              readonly property bool isEmptyRow: root.isEmptyRowModel(rowItem.modelData)

              // Which thumbnail this row centres on, and so -- through restX --
              // where its strip comes to rest.
              //
              // The centred row follows the live left/right selection. Every
              // other row follows what the user last scrolled *it* to, and
              // falls back to whatever Hyprland considers focused there only
              // if the user never touched it: an untouched row should show the
              // workspace as it really is, so arrowing onto it lands somewhere
              // sensible; a touched one should stay where it was put. Reading
              // Hyprland's focus in both cases is what used to snap a row back
              // to its original scroll the instant you moved off it -- see
              // root.rowSelections.
              readonly property int selectedIndex: {
                var n = rowItem.sortedToplevels.length
                if (rowItem.current)
                  return Math.max(0, Math.min(n - 1, root.selectedApp))
                var remembered = rowItem.modelData
                  ? root.rowSelectionFor(rowItem.modelData.id)
                  : -1
                if (remembered < 0) return rowItem.focusedIndex
                return Math.max(0, Math.min(n - 1, remembered))
              }

              // This row's top edge in viewport coordinates, and whether
              // that puts it close enough to matter. Rows are a uniform
              // height, so this is arithmetic rather than a live geometry
              // read — no dependency on delegates existing yet.
              // This row's share of the dive's scroll; zero for every row but
              // the one being dived into, and zero at both ends of every other
              // zoom. See root.aimZoom.
              readonly property real diveShift: rowItem.index === root.diveRow
                ? root.diveShiftNow
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
                && rowItem.viewportY + root.rowHeight > -root.nearMargin
                && rowItem.viewportY < viewport.height + root.nearMargin

              // Whether this row is drawn at all. A row scrolled well clear of
              // the viewport is clipped away either way, but a clipped row is
              // still a row: its wallpaper's shadow layer and every one of its
              // thumbnails' supersampled, mipmapped layers stay allocated and
              // stay up to date, and on a ten-workspace machine that is most
              // of the overview's texture footprint spent on rows nobody can
              // see. `visible: false` takes the whole subtree out of the scene
              // graph instead.
              //
              // Deliberately NOT gated on surfaceLive, unlike nearViewport.
              // The surface is never unmapped and its children are already
              // held invisible while the overview is down (see the backdrop's
              // own `visible`), so folding that in here would change nothing
              // on screen -- and would cost the reopen every layer this drops,
              // rebuilt on the first frame of the summon, which is the frame
              // the whole opening zoom is measured from.
              readonly property bool renderNear:
                rowItem.viewportY + root.rowHeight > -root.renderMargin
                && rowItem.viewportY < viewport.height + root.renderMargin

              // Nothing below this line exists as far as the renderer is
              // concerned for a row that is far enough away. The row Item
              // itself keeps its place and its height -- everything that
              // counts, centres or snaps rows is arithmetic over the index,
              // and captureZoom's mapToItem is a transform walk, so all of it
              // still answers for a row that is not being drawn.
              visible: rowItem.renderNear

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
                  sourceSize.height: Math.round(root.rowHeight * viewport.dpr)
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
                  // Shorter coast than the component default. This is the
                  // only axis that ever runs momentum at all -- vScroll
                  // snaps, so its release goes straight to a glide -- and a
                  // strip of windows is a short travel to begin with, so a
                  // coast tuned for a long list overshot the window you
                  // flicked toward and kept sliding after you were done.
                  momentumTau: 0.45
                  // Exactly undoes Hyprland's global touchpad scroll_factor
                  // (Omarchy default 0.4) -- see vScroll.dragScale above.
                  dragScale: 2.5

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
                    // noteSelectedApp rather than a bare write: the row has to
                    // hold this scroll after it stops being the centred one,
                    // and the compositor has to be told about it on the way
                    // out. See root.rowSelections and commitFocusArgs.
                    if (i >= 0) root.noteSelectedApp(i)
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

                      // Nothing at all behind a thumbnail that has a picture,
                      // so a window's own alpha lands on the wallpaper drawn
                      // behind the row -- which is exactly what it lands on
                      // when the window is on the desktop.
                      //
                      // A flat fill here made every transparent window opaque.
                      // In a row of thumbnails that reads as a slightly darker
                      // terminal and nobody notices; at the top of a zoom it is
                      // the whole picture, because there the strip is standing
                      // in for the desktop pixel for pixel and the desktop is
                      // still visible around it. So a window you were looking
                      // *through* went solid for the length of the zoom and
                      // came back the instant the real one took over -- the
                      // transparency "disappearing" on the way in.
                      //
                      // Still the flat fill while the capture is empty: that is
                      // the placeholder a thumbnail with nothing in it needs,
                      // and the one zoomOpener waits on rather than uncover.
                      color: thumb.hasPicture ? "transparent" : Color.background

                      readonly property real ringWidth: Style.space(2)

                      // Whether there is anything in this thumbnail yet, as
                      // opposed to whether it has been laid out. The zoom asks
                      // its target this before uncovering; see zoomOpener.
                      readonly property bool hasPicture: capture.hasContent

                      // When this thumbnail last asked for a frame. The
                      // scheduler picks the stalest picture on screen, so this
                      // is what "stalest" is measured on -- and it lives on
                      // the delegate rather than in a map at the root so that
                      // it cannot outlive the thumbnail it describes. Rows are
                      // rebuilt every time a window opens or closes.
                      //
                      // Zero, not Date.now(): a delegate that has just been
                      // built has either no picture at all or one retained
                      // from a previous summon, and both want a frame sooner
                      // than a thumbnail that was refreshed a moment ago.
                      property real lastCaptureMs: 0

                      // The one way a frame is ever asked for. Everything --
                      // the scheduler's rotation, the zoom target, the grab a
                      // freshly built delegate needs -- comes through here, so
                      // that nothing can refresh without the scheduler being
                      // able to see that it did.
                      function requestCapture() {
                        capture.captureFrame()
                        thumb.lastCaptureMs = Date.now()
                      }

                      // Whether this window is anywhere near the part of its
                      // row that is on screen.
                      //
                      // The vertical half of this has always been here
                      // (rowItem.nearViewport); this is the half a scrolling
                      // layout makes necessary. A workspace strip here is
                      // routinely two and a half monitors wide and the row
                      // shows about two of them, so a visible row would
                      // otherwise be putting windows a screen's width past its
                      // own edge into the scheduler's on-screen rotation --
                      // spending the budget on pictures nobody can see, which
                      // is the same traffic nearViewport refuses on the other
                      // axis.
                      //
                      // Measured against rowViewport rather than the
                      // wallpaper: what is drawn is the whole clipped row, and
                      // windows overhanging the wallpaper are half the point
                      // of the picture.
                      readonly property bool nearRow: {
                        var left = thumb.geom.x + rowContent.x
                        var slack = rowItem.monWidthPx * 0.5
                        return left + thumb.geom.w > -slack
                          && left < rowViewport.width + slack
                      }

                      // A thumbnail is a long way down from the window it
                      // shows -- better than 2x on a 1080p panel, more than
                      // that on anything bigger, measured in device pixels
                      // rather than the layout's -- and ScreencopyView draws
                      // its capture with plain bilinear filtering,
                      // hardcoded, with no mipmaps. Past 2x
                      // minification bilinear reads four of the sixteen
                      // source texels each output pixel covers, so which part
                      // of a glyph survives depends on exactly where the
                      // thumbnail lands: text crawls and sparkles on every
                      // sub-pixel move, and an overview that opens on a zoom
                      // and scrolls kinetically in two axes is moving almost
                      // all the time.
                      //
                      // So take the shrink away from the view. The layer
                      // renders the capture offscreen at up to twice the
                      // thumbnail's device size -- never past what the
                      // capture itself has to give -- where bilinear is at or
                      // near 1:1 and exact, mipmaps that buffer, and samples
                      // the mipmap for the final step down. That last sample
                      // is the box filter the shimmer was missing.
                      //
                      // It also costs less to scroll than it looks: a layer
                      // re-renders when its contents change, not when it
                      // moves, so a row sliding past redraws one cached
                      // texture per thumbnail rather than the capture itself.
                      Item {
                        id: captureBox
                        // Deliberately the full thumbnail, and deliberately
                        // not inset by the ring. The ring used to be the
                        // Rectangle's own border with this box tracking its
                        // width, which drew correctly and cost a great deal
                        // more than it looked: the ring appears and disappears
                        // on *hover*, so every pointer crossing resized this
                        // item by two pixels, and this item's size is the
                        // layer's texture size -- a fresh offscreen buffer
                        // allocated and re-rendered for each thumbnail the
                        // mouse passed over, at up to twice its device size.
                        // Moving the pointer across the overview was
                        // reallocating textures the whole way.
                        //
                        // The ring is a sibling drawn after this instead, so
                        // it covers the same outer two pixels it used to
                        // occupy -- the same pixels, the same colour, and
                        // nothing under it moves when it comes and goes.
                        anchors.fill: parent

                        // 1 for a thumbnail already at or above the capture's
                        // own resolution: supersampling past the source buys
                        // no detail, and the buffer is quadratic in this --
                        // every live thumbnail keeps one -- which is what the
                        // ceiling is for. At 2 a 4x shrink becomes a box
                        // filter followed by a 2x bilinear step, which is
                        // already most of the way to clean.
                        readonly property real superSample: {
                          var src = capture.sourceSize
                          var devW = captureBox.width * viewport.dpr
                          if (!capture.hasContent || !(src.width > 0) || !(devW > 0)) return 1
                          return Math.max(1, Math.min(2, src.width / devW))
                        }

                        layer.enabled: true
                        layer.smooth: true
                        layer.mipmap: true
                        layer.textureSize: Qt.size(
                          Math.max(1, Math.round(captureBox.width * viewport.dpr * captureBox.superSample)),
                          Math.max(1, Math.round(captureBox.height * viewport.dpr * captureBox.superSample)))

                        ScreencopyView {
                          id: capture
                          anchors.fill: parent
                          captureSource: thumb.modelData.wayland
                          // Never live. Frames come from the capture
                          // scheduler at the top of this file, which hands a
                          // fixed budget of captures per second to whichever
                          // thumbnail most needs one.
                          //
                          // The gating this replaces was on position alone,
                          // and position was never the expensive part. A live
                          // view re-arms itself from its own repaint, so a
                          // thumbnail that is merely *visible* renders at the
                          // display's refresh rate forever -- rebuilding the
                          // mipmapped layer around it every time -- with the
                          // overview open and nobody touching anything. The
                          // old comment here argued that freezing during
                          // motion was the reverse of a saving, and it was
                          // right: setLive(true) fires captureFrame() on every
                          // visible thumbnail at once on the single frame the
                          // motion stops. That is an argument against the
                          // on/off switch, not against stopping the loop --
                          // and it is why the budget is metered by a token
                          // bucket that holds at most one, so the settle frame
                          // can spend a single capture and no more.
                          //
                          // captureFrame() leaves the picture that is already
                          // there alone until the new one lands, so a refresh
                          // is never a flicker and never a grey frame; the
                          // only thing that clears a thumbnail is the
                          // captureSource round trip in captureRevive below,
                          // which is for a context the compositor has already
                          // torn down.
                          live: false
                          paintCursor: false

                          // No constraintSize. It reads like a cap on how big a
                          // buffer the compositor is asked for, and it is not
                          // one: Quickshell feeds it to the view's *implicit*
                          // size and nothing else, and an anchors.fill view has
                          // no use for an implicit size. Every thumbnail here
                          // was streaming its window at full native resolution
                          // the whole time it claimed to be capped at 1000x400.
                          // Nothing in the protocol offers a smaller capture
                          // either -- hyprland_toplevel_export hands over the
                          // window at the size it is -- so the shrink has to
                          // happen on this side, which is what captureBox does.

                          // A row created off-screen has no last frame to
                          // keep, so grab one still for it up front -- but only
                          // while the overview is actually up. The plugin is
                          // keepLoaded, so these delegates also exist, and are
                          // rebuilt every time a window opens or closes, with
                          // the overview closed and no recording context to
                          // capture into: asking then is work that can only
                          // fail, and it logged a warning per thumbnail for the
                          // privilege.
                          //
                          // Not gated on being drawn. captureFrame() is not
                          // the paint-driven path that live re-arming is: a
                          // view whose whole subtree is `visible: false`
                          // refreshes perfectly well when asked, which is what
                          // lets the scheduler keep the render margin warm.
                          // Only the overview being *down* is a real
                          // obstacle, and that is what the guard is for.
                          Component.onCompleted:
                            if (root.opened) thumb.requestCapture()

                          // The same grab, for a thumbnail that was built while
                          // the overview was down -- which leaves it with no
                          // picture in it at all, held grey until something
                          // asks. Nothing asks on its own any more: with the
                          // scheduler in charge there is no live stream to
                          // wander in and fill it.
                          //
                          // Rows are meant to survive between summons and now
                          // do (see freezeToplevels), so this is the rare case
                          // rather than the usual one: a window opened or
                          // closed while the overview was down, which rebuilds
                          // the rows it was in. viewReset() is emitted by
                          // open() itself, which is early enough to be in hand
                          // for the frame the zoom is measured from.
                          Connections {
                            target: root
                            function onViewReset() {
                              if (root.opened && !capture.hasContent) thumb.requestCapture()
                            }
                          }

                          // A stream that comes back is a stream that gets to
                          // fail again.
                          onHasContentChanged: if (capture.hasContent) captureRevive.tries = 0
                        }
                      }

                      // Puts a dead screencopy back on its feet.
                      //
                      // Quickshell tears the recording context down when the
                      // compositor ends a stream -- and hyprland_toplevel_export
                      // ends them for ordinary reasons, a toplevel being
                      // remapped or moved between monitors among them. Tearing
                      // it down clears hasContent, which drops the thumbnail
                      // back to the bare Color.background rectangle underneath:
                      // the thumbnail that "goes grey".
                      //
                      // Nothing brings it back. There is no retry inside the
                      // view, and its `stopped` signal is declared but never
                      // emitted, so hasContent falling is the only notice we
                      // get. createContext() is reachable from exactly one
                      // place in the public API -- assigning captureSource --
                      // so that is what this does, and the assignment has to
                      // actually change the value to count, hence the round
                      // trip through null.
                      //
                      // Capped, and only for a thumbnail on screen with the
                      // overview up: a window that genuinely cannot be captured
                      // must cost four attempts and then be left alone, not
                      // become a permanent timer.
                      Timer {
                        id: captureRevive
                        property int tries: 0
                        interval: 450
                        repeat: true
                        running: root.opened && !capture.hasContent
                          && rowItem.nearViewport && thumb.nearRow
                          && captureRevive.tries < 4
                        onTriggered: {
                          var src = thumb.modelData ? thumb.modelData.wayland : null
                          if (!src) return
                          captureRevive.tries++
                          capture.captureSource = null
                          capture.captureSource = src
                          // Creating a context asks for a frame by itself, so
                          // this counts as one against the budget: without it
                          // the scheduler sees a thumbnail whose picture is as
                          // old as the failure and spends a capture chasing
                          // the one already on its way.
                          thumb.lastCaptureMs = Date.now()
                        }
                      }

                      // The ring, drawn over the capture rather than beside
                      // it. Same two pixels the Rectangle's own border used to
                      // paint and the capture used to be inset out of -- see
                      // captureBox, which is a fixed size now precisely so
                      // that this can come and go on hover without anything
                      // underneath being resized.
                      Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        radius: thumb.radius
                        border.width: thumb.ringed ? thumb.ringWidth : 0
                        border.color: thumb.active
                          ? Color.accent
                          : Util.alpha(Color.foreground, 0.4)
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
                // Not negated -- see the vertical drag below, which now says
                // the same thing on its own axis. Two fingers move the strip
                // of columns, the way niri does and the way the scrolling
                // layout answers this same gesture with the overview closed.
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
              // Not negated, and neither is the horizontal drag above: two
              // fingers move the *stack of workspaces* rather than the view
              // over it, so pushing up carries the stack up and brings the
              // row below into the centre. Both touchpad axes now say the
              // same thing -- the thing under your fingers is the content,
              // not a viewport over it.
              //
              // The mouse wheel above stays negated, on both axes, and that
              // is not an inconsistency left lying around: a wheel notch is a
              // request to go somewhere, not a grip on the content, and it
              // keeps the sense every other wheel on the machine has.
              vScroll.dragBy(wheel.pixelDelta.y)
            }
            wheel.accepted = true
          }
        }
      }
    }
  }

  // Omari's other overlay, which is not an overlay entry point of its own
  // because there is only one of those to have: shell.qml's computePanelEntries
  // builds exactly one Loader per plugin id, and Omari's is this file. The
  // switcher does not want the host's summon/hide anyway -- it opens on a
  // `custom>>` line from hypr/omari-alttab.lua and closes when the modifier
  // holding it up comes back up, and neither of those is something the host
  // can say. It is entirely self-contained: nothing here talks to it, and it
  // touches nothing here, least of all `opened`, which the host reads to mean
  // "the overview is showing".
  //
  // Inert until its toggle is on, since with no omari-alttab.lua in Omarchy's
  // toggles directory nothing ever emits the event that opens it.
  OmariAltTab {
    id: altTab
    overview: root
  }

  // Omarchy intentionally has no install/uninstall hooks. It does, however,
  // disable a plugin before removing its checkout. That destroys this
  // keepLoaded overlay while the files still exist. Clean the generated
  // Hyprland toggles only in that case: normal shell shutdown and hot reload
  // both destroy this object too, but the registry still reports it enabled.
  Component.onDestruction: {
    if (!root.pluginRegistry || !root.manifest || !root.manifest.id
        || root.pluginRegistry.isEnabled(root.manifest.id)) return
    Quickshell.execDetached([
      "bash", root.pluginDir + "/bin/omari-toggle", "all", "off"
    ])
  }
}
