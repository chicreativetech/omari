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

  // The workspace that was active the moment the overview was opened. Used
  // once, at open time, to vertically center that row — not kept in sync
  // afterward, since nothing inside the overview changes the active
  // workspace without also closing it.
  property int openedWorkspaceId: -1

  // Current desktop background image, resolved from the same symlink the
  // background plugin follows. Refreshed each time the overview opens.
  property string backgroundImagePath: ""

  function open(payloadJson) {
    var focused = Hyprland.focusedWorkspace
    root.openedWorkspaceId = focused ? focused.id : -1
    bgPathProc.running = true
    root.opened = true
    root.gestureAxis = ""
    vScroll.reset()
  }

  // Reset rather than just hide: a flick still coasting when the overview
  // closes would otherwise keep a FrameAnimation ticking behind an invisible
  // surface, and would still be mid-glide the next time it opens.
  function close() {
    root.opened = false
    root.gestureAxis = ""
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

  readonly property real rowHeight: Style.space(200) * 2.5 // 150% larger than the original thumbnail size

  // Screencopy capture resolution is deliberately NOT tied to rowHeight.
  // Thumbnails capture live while their row is on screen, so requesting a
  // 2.5x-larger buffer per thumbnail multiplies sustained GPU/compositor
  // load a lot. A thumbnail this size doesn't need more source pixels than
  // it always did — only the on-screen presentation got bigger.
  readonly property real captureBaseHeight: Style.space(200)
  readonly property real rowSpacing: Style.space(28)
  readonly property real thumbSpacing: Style.space(16)
  readonly property real fallbackAspect: 16 / 10
  readonly property real bgOversize: 1.05 // background thumbnail vs. app thumbnail height

  // How far outside the viewport a row still counts as "on screen" for the
  // purpose of capturing live. One row's worth of slack means a row is
  // already streaming by the time it scrolls into view, and stops streaming
  // well after it has left — so a scroll that hovers around a boundary never
  // thrashes captures on and off.
  readonly property real liveMargin: root.uniformRowHeight

  // Every row is the same height (the label uses one fixed font regardless
  // of its text), so this can be computed once via FontMetrics instead of
  // asking a live rowRepeater delegate for its size — the latter is racy
  // right after the model changes, since a delegate may not exist yet the
  // instant Repeater.count ticks up.
  FontMetrics {
    id: rowLabelMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
  readonly property real rowLabelHeight: rowLabelMetrics.height
  readonly property real uniformRowHeight: root.rowLabelHeight + Style.space(10) + root.rowHeight
  readonly property real rowStride: root.uniformRowHeight + root.rowSpacing

  // Only workspaces that actually have windows are worth a row; reading
  // toplevels.values here during evaluation is what keeps this reactive to
  // both new/closed workspaces and windows opening/closing within one,
  // mirroring the bar's own Workspaces.qml.
  readonly property var workspaceRows: {
    var values = Hyprland.workspaces ? Hyprland.workspaces.values : []
    var rows = []
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      if (ws && ws.toplevels && ws.toplevels.values.length > 0) rows.push(ws)
    }
    rows.sort(function(a, b) { return a.id - b.id })
    return rows
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

  function focusToplevel(hyprlandToplevel) {
    if (hyprlandToplevel && hyprlandToplevel.wayland) hyprlandToplevel.wayland.activate()
    root.close()
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
      color: Color.background
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
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        }
      }

      Text {
        visible: root.workspaceRows.length === 0
        anchors.centerIn: parent
        text: "No open windows"
        color: Color.foreground
        opacity: 0.5
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
      }

      Item {
        id: viewport
        anchors.fill: parent
        anchors.margins: Style.space(48)
        clip: true

        // Index of the workspace that was focused when the overview opened,
        // recomputed reactively (not read once imperatively) so this is
        // never at the mercy of evaluation order against viewport.height or
        // root.workspaceRows during the first frame after opening.
        readonly property int openedRowIndex: {
          for (var i = 0; i < root.workspaceRows.length; i++) {
            if (root.workspaceRows[i].id === root.openedWorkspaceId) return i
          }
          return -1
        }

        // Scroll offset that puts the focused workspace's row in the middle
        // of the viewport. KineticScroll clamps it into range.
        readonly property real centeredPosition: viewport.openedRowIndex >= 0
          ? viewport.openedRowIndex * root.rowStride + root.uniformRowHeight / 2 - viewport.height / 2
          : 0

        // Where the column sits relative to the viewport's top edge. When
        // every row already fits there is nothing to scroll, so the column
        // is simply centred as a block — clamping a scroll offset instead
        // would pin it to the top, which is the exact bug the old unclamped
        // centring was working around.
        readonly property real columnOffset: vScroll.overflows
          ? -vScroll.position
          : (viewport.height - column.height) / 2 - vScroll.position

        KineticScroll {
          id: vScroll
          viewportSize: viewport.height
          contentSize: column.height
          restPosition: viewport.centeredPosition
          notchPixels: root.rowStride * 0.55
        }

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
              height: root.uniformRowHeight

              // Windows in real on-screen (left-to-right) order, so the
              // thumbnails either side of the focused one match how the
              // actual windows are laid out on the workspace.
              readonly property var sortedToplevels: root.sortToplevelsBySpatialOrder(rowItem.modelData.toplevels.values)
              readonly property int focusedIndex: root.focusedIndexFor(rowItem.sortedToplevels)

              // This row's top edge in viewport coordinates, and whether
              // that puts it close enough to matter. Rows are a uniform
              // height, so this is arithmetic rather than a live geometry
              // read — no dependency on delegates existing yet.
              readonly property real viewportY: rowItem.index * root.rowStride + viewport.columnOffset
              readonly property bool nearViewport: root.opened
                && rowItem.viewportY + root.uniformRowHeight > -root.liveMargin
                && rowItem.viewportY < viewport.height + root.liveMargin

              // Bumped once by each thumbnail delegate as it's created (see
              // thumb's Component.onCompleted below) purely so
              // focusedCenterX has something to depend on across that
              // moment. Repeater.itemAt(i) can still return null on the
              // very first evaluation right after Repeater.count ticks up
              // (delegate creation is deferred a beat past the count
              // change), and since a null hit short-circuits before ever
              // reading ".width", that first evaluation never touches a
              // property that fires again later — the binding would
              // otherwise go stale at whatever it computed during that gap
              // (typically treating the focused thumbnail as zero-width)
              // and never recompute once the real item exists.
              property int thumbReadyTick: 0

              // Sum of widths (plus spacing) of every thumbnail before the
              // focused one, so the row viewport knows where to scroll to
              // put the focused thumbnail's center in the middle. Reads
              // thumbRepeater items' widths directly so it stays reactive as
              // real aspect ratios arrive asynchronously from screencopy.
              readonly property real focusedCenterX: {
                var _tick = rowItem.thumbReadyTick // establishes the dependency described above
                var sum = 0
                for (var i = 0; i < thumbRepeater.count; i++) {
                  var it = thumbRepeater.itemAt(i)
                  if (!it) continue
                  if (i < rowItem.focusedIndex) sum += it.width + root.thumbSpacing
                  else { sum += it.width / 2; break }
                }
                return sum
              }

              // The monitor this workspace lives on, so the background
              // thumbnail's shape always matches the real screen instead of
              // an arbitrary guess.
              readonly property real monitorAspect: {
                var mon = rowItem.modelData.monitor
                return (mon && mon.width > 0 && mon.height > 0)
                  ? (mon.width / mon.height)
                  : root.fallbackAspect
              }

              // A fresh overview always opens centred on the focused window,
              // never wherever the last one happened to be left scrolled to —
              // and nothing is left coasting behind a closed one.
              Connections {
                target: root
                function onOpenedChanged() { rowScroll.reset() }
              }

              Text {
                id: rowLabel
                anchors.top: parent.top
                anchors.left: parent.left
                text: rowItem.modelData.name || ("Workspace " + rowItem.modelData.id)
                color: Color.foreground
                opacity: 0.6
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              // Background wallpaper thumbnail: centered in the row, fixed
              // behind the app thumbnails (doesn't pan with them), slightly
              // larger, with a drop shadow against the solid overview
              // background. Sized from root.rowHeight and the workspace's
              // real monitor aspect ratio (never from the image's own
              // decoded size) so this Item's geometry is stable from the
              // first frame — only the pixmap swaps in once decoded, never
              // the layout.
              Item {
                id: bgThumbBox
                anchors.horizontalCenter: parent.horizontalCenter
                y: rowLabel.implicitHeight + Style.space(10) + (root.rowHeight - height) / 2
                height: root.rowHeight * root.bgOversize
                width: height * rowItem.monitorAspect
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
                  // Decode the wallpaper at thumbnail size rather than at
                  // its native resolution — a 4K background costs ~32MB of
                  // texture and a full-size decode otherwise, for something
                  // drawn a few hundred pixels tall. Every row asks for the
                  // same height, so they all share one cached texture.
                  sourceSize.height: Math.round(root.rowHeight * root.bgOversize * Screen.devicePixelRatio)
                }
              }

              Item {
                id: rowViewport
                anchors.top: rowLabel.bottom
                anchors.topMargin: Style.space(10)
                anchors.left: parent.left
                anchors.right: parent.right
                height: root.rowHeight
                clip: true

                // When the row's thumbnails all fit there is nothing to
                // scroll, so the strip is offset to put the focused
                // thumbnail on the viewport midpoint — which lines up with
                // the background thumbnail's horizontal center. Once it
                // overflows, that same position becomes the scroller's
                // resting offset and the user can drag away from it.
                readonly property real centeredX: rowViewport.width / 2 - rowItem.focusedCenterX

                KineticScroll {
                  id: rowScroll
                  viewportSize: rowViewport.width
                  contentSize: rowContent.width
                  restPosition: rowItem.focusedCenterX - rowViewport.width / 2
                  notchPixels: root.rowHeight * 0.6
                }

                Row {
                  id: rowContent
                  x: rowScroll.overflows ? -rowScroll.position : rowViewport.centeredX
                  spacing: root.thumbSpacing

                  Repeater {
                    id: thumbRepeater
                    model: rowItem.sortedToplevels

                    Rectangle {
                      id: thumb
                      required property var modelData

                      readonly property real aspect: capture.hasContent && capture.sourceSize.height > 0
                        ? capture.sourceSize.width / capture.sourceSize.height
                        : root.fallbackAspect

                      // Deliberately not animated. The real aspect ratio
                      // arrives asynchronously, a frame or two after the
                      // overview opens, for every thumbnail at once —
                      // easing each width change relayouts the Row and
                      // re-runs focusedCenterX on every frame of every
                      // animation, precisely during the frames the overview
                      // most needs to be cheap. Unanimated, the correction
                      // lands before there is anything to see.
                      width: Math.round(root.rowHeight * aspect)
                      height: root.rowHeight
                      radius: Style.space(6)
                      color: Color.background
                      border.width: hoverArea.containsMouse ? 2 : 1
                      border.color: hoverArea.containsMouse
                        ? Color.accent
                        : Util.alpha(Color.foreground, 0.15)
                      clip: true

                      Component.onCompleted: rowItem.thumbReadyTick += 1

                      ScreencopyView {
                        id: capture
                        anchors.fill: parent
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

                      Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: titleLabel.implicitHeight + Style.space(8)
                        color: Qt.rgba(0, 0, 0, 0.55)

                        Text {
                          id: titleLabel
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          anchors.margins: Style.space(8)
                          text: thumb.modelData.title
                          color: "#ffffff"
                          elide: Text.ElideRight
                          font.family: Style.font.family
                          font.pixelSize: Style.font.bodySmall
                        }
                      }

                      MouseArea {
                        id: hoverArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.focusToplevel(thumb.modelData)
                      }
                    }
                  }
                }

                // Wheel-only overlay: acceptedButtons: NoButton means clicks
                // and hover pass straight through to the thumbnails
                // underneath, so this only ever intercepts scrolling. It
                // sees an event only when the viewport-level handler below
                // has already decided the gesture belongs to this axis.
                MouseArea {
                  anchors.fill: parent
                  acceptedButtons: Qt.NoButton
                  hoverEnabled: false
                  onWheel: function(wheel) {
                    if (!rowScroll.overflows) { wheel.accepted = false; return }

                    if (!root.isTouchpadWheel(wheel)) {
                      if (Math.abs(wheel.angleDelta.x) < Math.abs(wheel.angleDelta.y)) {
                        wheel.accepted = false
                        return
                      }
                      rowScroll.stepBy(-wheel.angleDelta.x / 120)
                      wheel.accepted = true
                      return
                    }

                    if (wheel.phase === Qt.ScrollEnd) rowScroll.endDrag()
                    else rowScroll.dragBy(-wheel.pixelDelta.x)
                    wheel.accepted = true
                  }
                }
              }
            }
          }
        }

        // Topmost wheel handler, and so the one that arbitrates: it takes
        // the gesture when the axis lock says vertical and declines it
        // (accepted = false, which lets the event fall through to the row
        // strip underneath) when it says horizontal.
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.NoButton
          hoverEnabled: false
          onWheel: function(wheel) {
            if (!root.isTouchpadWheel(wheel)) {
              if (Math.abs(wheel.angleDelta.y) < Math.abs(wheel.angleDelta.x)) {
                wheel.accepted = false
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

            if (root.gestureAxis === "x") { wheel.accepted = false; return }

            if (wheel.phase === Qt.ScrollEnd) {
              root.gestureAxis = ""
              gestureIdle.stop()
              vScroll.endDrag()
            } else {
              vScroll.dragBy(-wheel.pixelDelta.y)
            }
            wheel.accepted = true
          }
        }
      }
    }
  }
}
