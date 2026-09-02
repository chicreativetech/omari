import QtQuick

// One axis of touchpad-first scroll physics, shared by the overview's
// vertical workspace list and each workspace row's horizontal strip.
//
// Why this exists: the overview used to scroll by moving a target offset and
// letting `Behavior on x/y` ease toward it. A touchpad emits a pixelDelta
// event roughly every frame, so every frame restarted a fresh 130ms easing
// curve from wherever the previous one had got to. The content never caught
// up with the fingers, and every new event yanked the curve somewhere else
// mid-flight -- which is exactly the rubbery, stuttering feel to fix.
//
// Here a touchpad gesture moves `position` 1:1 with the fingers with no
// animation anywhere in that path. The only animation is what happens after
// the fingers lift, and there are two flavours of that:
//
//   free (snapStride 0)  -- momentum decaying at a constant rate, plus a
//     critically-damped spring back to the edge if the gesture ended (or the
//     momentum ran) past one. This is what the horizontal strips use.
//   snapped (snapStride > 0) -- the axis always comes to rest on a multiple
//     of snapStride from minPosition, glided into place. The vertical list
//     uses this so a workspace row is centred whenever the fingers are off
//     the touchpad. A flick still counts: its remaining speed is projected
//     forward to choose the landing point, so a nudge moves one row and a
//     firm swipe crosses several.
//
// A discrete mouse wheel has no fingers to track, so it gets its own mode: a
// fixed step (or exactly one snap point) glided into place.
Item {
  id: root

  // ---- geometry in ----
  property real viewportSize: 0
  property real contentSize: 0

  // Travel limits. The defaults are plain "scroll the content through the
  // viewport" bounds, which is what the horizontal strips want, but both are
  // overridable: the vertical list centres a row rather than filling the
  // viewport, so its range runs from "first row centred" (negative whenever a
  // row is shorter than the viewport) to "last row centred". Deriving the
  // limits from content size is what used to make centring the first and last
  // rows impossible -- clamping simply pinned them to the top and bottom.
  property real minPosition: 0
  property real maxPosition: Math.max(0, root.contentSize - root.viewportSize)

  // Offset this axis wants to be at when nothing is being dragged: the
  // centred row, or the centred thumbnail. Followed instantly while the view
  // is still resolving its geometry and glided to once it has settled (see
  // `interactive`) -- which is what makes arrow-key navigation animate while
  // screencopy resolving a thumbnail's real aspect ratio does not flash.
  property real restPosition: 0

  // Spacing of the snap points, measured from minPosition. 0 leaves this axis
  // free-scrolling.
  property real snapStride: 0

  // Emitted whenever a gesture or wheel step settles on a snap point, so the
  // owner can keep its own selection in step with whatever is now centred.
  signal snapped(int index)

  // The free axis' answer to the same question, and it has to be asked at a
  // different moment. A snapped axis knows its landing point at the release,
  // before the glide to it has started, so snapped() can fire there; a free
  // one does not know where it is going until the momentum has run out, the
  // rubber band has settled, or the glide has arrived. So this fires at rest.
  //
  // Only for movement the *user* started. A glide that is merely following
  // restPosition is the view catching up with a selection that has already
  // been made, and re-deriving that selection from where it lands is a loop.
  signal settled()

  // Whether the movement in flight is one that owes a settled() when it ends.
  // Raised by the two inputs a person can perform, cleared by anything that
  // cancels rather than completes.
  property bool announceSettle: false

  // ---- feel ----
  // Touchpad drags arrive already scaled by Hyprland's global
  // input.touchpad.scroll_factor (Omarchy default: 0.4, i.e. 40% of the raw
  // finger travel) before this component ever sees a pixelDelta. That's the
  // right feel for scrolling ordinary window content, which is what the
  // setting is tuned for, but it makes a dedicated scroll surface like this
  // one feel sluggish under the same fingers. Terminals hit the identical
  // problem and Omarchy compensates per-window with a `scroll_touchpad`
  // window rule (see hypr/input.lua) -- not available here since this is a
  // layer-shell surface, not a tracked window, so dragScale compensates
  // directly in dragBy() instead.
  property real dragScale: 1
  property real notchPixels: 110    // travel per discrete mouse-wheel notch, free axes only
  // Momentum decay is exponential (velocity loses a fraction of itself per
  // unit time, like the glide/band eases below) rather than the constant
  // px/s^2 this used to subtract every frame. Constant deceleration keeps
  // full braking force right up to the moment it snaps to a stop, which
  // reads as abrupt; decaying proportional to the current speed brakes hard
  // while fast and tapers off the harder it already slowed, so the coast
  // eases out instead of cutting off. Shortened from 1.6s: a coast that long
  // kept drifting well after the fingers were off the pad, which is half of
  // what read as an over-sensitive touchpad.
  property real momentumTau: 0.85   // s, momentum decay time constant
  property real maxVelocity: 18000  // px/s, cap on a flick
  property real minVelocity: 25     // px/s, below this momentum has stopped
  // bandTau doubles as the edge spring's stiffness (w = 1/bandTau below): the
  // original 0.085s made for a very stiff, tightly-wound spring that snapped
  // back rigidly the instant a drag or flick went past an edge. A longer time
  // constant is a softer spring -- more give, a gentler settle. 0.35 was that
  // correction overshooting the other way: the ease-out read as slow once
  // every row bounced. Tuned down from there by feel toward the stiff end,
  // but deliberately still above 0.085 -- the point is that the row eases
  // home, not that it snaps.
  property real bandTau: 0.13       // s, rubber-band spring time constant
  property real glideTau: 0.12      // s, discrete-wheel / snap glide time constant
  // How much of the release speed is carried into a snapped axis' landing
  // point. Long enough that a deliberate flick travels past the row it was
  // over, short enough that letting go of a slow drag lands on the nearest
  // one rather than sailing away.
  property real snapProjection: 0.2 // s

  // ---- state out ----

  // Scroll offset in content pixels: the content should be drawn at
  // -position along this axis. Steps outside [minPosition, maxPosition] only
  // while rubber-banding past an edge.
  property real position: 0

  // Whether this axis has anywhere to go. Only the discrete wheel consults
  // it: a notch is a request to land somewhere else, and there is nowhere
  // else. A touchpad drag deliberately does not — see dragBy().
  readonly property bool overflows: root.maxPosition - root.minPosition > 0.5
  readonly property bool snaps: root.snapStride > 0.5

  readonly property int lastSnapIndex: root.snaps
    ? Math.max(0, Math.round((root.maxPosition - root.minPosition) / root.snapStride))
    : 0

  // True for as long as the fingers are down, so a restPosition that moves
  // mid-gesture (a thumbnail's aspect ratio landing, a row appearing) cannot
  // fight the drag.
  property bool dragging: false

  // True for every kind of motion this component can produce. Owners use this
  // to hold back work that can wait while the scene graph is already busy
  // translating their last frame -- the overview's capture scheduler reads it
  // on both axes and spends none of its budget until every one of them is
  // false. `dragging` alone misses momentum, snapping, and keyboard/wheel
  // glides, which is most of the motion that matters here.
  readonly property bool moving: root.dragging || runner.running

  // False for the first frames after the view opens, while geometry and
  // thumbnail aspect ratios are still resolving and restPosition therefore
  // moves several times; following it instantly keeps all of that invisible.
  // It flips on a short timer, or immediately on the first input, since past
  // that point restPosition only ever moves because the user navigated
  // somewhere — and that should animate.
  property bool interactive: false

  // Pinned: this axis is showing a picture that something else is now drawn
  // from, and it may not move for any reason at all.
  //
  // stop() alone was not that. It ends whatever is running at the instant it
  // is called, and then the very next thing to touch restPosition -- a rest
  // position is a *binding*, and the things it is built from keep arriving --
  // glides the axis somewhere new through onRestPositionChanged. That is a
  // state, not an event, so it is held as one, and the overview binds it to
  // its own freeze rather than setting it (see viewIsFrozen there).
  property bool frozen: false

  function clamp(p) { return Math.max(root.minPosition, Math.min(root.maxPosition, p)) }

  // The edge `p` has gone past, or undefined if it is in range. Doubles as
  // the "are we in the rubber-band zone" test.
  function edgeFor(p) {
    if (p < root.minPosition) return root.minPosition
    if (p > root.maxPosition) return root.maxPosition
    return undefined
  }

  function snapIndexFor(p) {
    if (!root.snaps) return 0
    var i = Math.round((p - root.minPosition) / root.snapStride)
    return Math.max(0, Math.min(root.lastSnapIndex, i))
  }

  function snapPositionFor(index) {
    return root.clamp(root.minPosition + index * root.snapStride)
  }

  function reset() {
    runner.mode = ""
    runner.running = false
    root.announceSettle = false
    idle.stop()
    root.velocity = 0
    root.samples = []
    root.notchAccum = 0
    root.dragging = false
    root.interactive = false
    settleTimer.restart()
    root.position = root.clamp(root.restPosition)
  }

  function stop() {
    root.velocity = 0
    root.announceSettle = false
    runner.mode = ""
    runner.running = false
  }

  // stop(), for the case where the movement has *finished* rather than been
  // called off: the one that owes settled() pays it here. Reading the flag
  // before stop() clears it is the whole of the difference.
  function settleNow() {
    var announce = root.announceSettle
    root.stop()
    if (announce) root.settled()
  }

  // ---- input ----

  // A touchpad gesture step: `delta` is raw pixels, applied straight through.
  //
  // Deliberately not gated on `overflows`. An axis with no travel still
  // follows the fingers out into the rubber band and springs back when they
  // lift: a workspace whose windows all fit inside its monitor has nothing to
  // bring into view, but refusing its drag outright made the row read as a
  // dead surface rather than as one that is simply already showing
  // everything. The bounce is what says which of the two it is — and it is
  // also what guarantees a window can never be left parked off the wallpaper.
  function dragBy(delta) {
    if (root.frozen || delta === 0) return
    // Fingers are back down; whatever the last gesture left coasting is over.
    root.stop()
    root.announceSettle = true
    root.dragging = true
    root.interactive = true

    var d = delta * root.dragScale
    var over = root.edgeFor(root.position)
    // Past an edge the content follows the fingers less and less the further
    // out it goes, so the end of the list feels like something you can lean
    // on rather than a wall you hit. Only resists motion that goes further
    // out -- pulling back toward the content is always 1:1.
    if (over !== undefined && (root.position - over < 0) === (d < 0)) {
      d *= root.bandResistance(root.position - over)
    }

    root.position += d
    root.track(d)
    idle.restart()
  }

  // The fingers lifted: on a free axis hand whatever speed they had over to
  // momentum, on a snapped one use it to pick which snap point they were
  // heading for.
  function endDrag() {
    idle.stop()
    root.dragging = false
    if (root.frozen) { root.samples = []; return }
    // No `overflows` check here either, and it matters more than in dragBy:
    // this is what hands a drag that went nowhere over to the spring, and
    // returning early would leave the content parked wherever the fingers
    // dropped it, outside the travel limits, with nothing running to bring
    // it back.
    root.velocity = root.measureVelocity()
    root.samples = []
    if (root.snaps) {
      var i = root.snapIndexFor(root.position + root.velocity * root.snapProjection)
      root.glideTo(root.snapPositionFor(i))
      root.snapped(i)
      return
    }
    runner.mode = "momentum"
    runner.running = true
  }

  // One or more discrete mouse-wheel notches. No fingers to track, so this
  // glides into place instead: one snap point per notch on a snapped axis,
  // a fixed step on a free one (accumulating onto any glide already in flight
  // so spinning the wheel keeps building speed).
  function stepBy(notches) {
    if (root.frozen || !root.overflows || notches === 0) return
    root.interactive = true
    root.announceSettle = true

    if (root.snaps) {
      // High-resolution wheels report fractions of a notch, so accumulate
      // rather than treating every event as a whole row.
      root.notchAccum += notches
      var whole = root.notchAccum > 0
        ? Math.floor(root.notchAccum)
        : Math.ceil(root.notchAccum)
      if (whole === 0) return
      root.notchAccum -= whole
      var from = runner.mode === "glide" ? runner.target : root.position
      var i = Math.max(0, Math.min(root.lastSnapIndex, root.snapIndexFor(from) + whole))
      root.glideTo(root.snapPositionFor(i))
      root.snapped(i)
      return
    }

    var base = runner.mode === "glide" ? runner.target : root.position
    root.glideTo(base + notches * root.notchPixels)
  }

  // Ease to an exact offset. The path taken by everything that navigates
  // rather than drags: wheel steps, a snapped gesture's landing point, and
  // restPosition moving under arrow-key navigation.
  // `quiet` marks a glide that is following restPosition rather than one the
  // user asked for; see settled().
  function glideTo(target, quiet) {
    if (root.frozen) return
    if (quiet) root.announceSettle = false
    var t = root.clamp(target)
    root.velocity = 0
    if (Math.abs(t - root.position) < 0.5) {
      root.position = t
      root.settleNow()
      return
    }
    runner.target = t
    runner.mode = "glide"
    runner.running = true
  }

  // ---- internals ----

  property real velocity: 0
  property real notchAccum: 0

  // Recent gesture deltas, so the flick speed at release is measured over a
  // short window rather than taken from the single last event (which on a
  // slowing finger is close to zero and kills every flick).
  property var samples: []
  readonly property int velocityWindow: 90 // ms

  // How much of a drag still reaches the content once it is `over` pixels past
  // an edge: 1:1 at the edge itself, tapering to a floor that never quite
  // stops. Both numbers are a quarter of what they were (0.55 / 0.12), which
  // is the same quarter of the stretch a given drag produces across both
  // regimes -- the taper and the floor beyond it. The wide version was tuned
  // when only a long strip ever hit an edge and the give was the whole signal;
  // now that every row rubber-bands, including ones with nowhere to go, the
  // band is only there to say "this end, and it does move" and wants to be
  // barely felt. Roughly a tenth of the wallpaper's width at full stretch.
  function bandResistance(over) {
    var reach = Math.max(1, root.viewportSize * 0.1375)
    return Math.max(0.03, 1 - Math.abs(over) / reach)
  }

  function track(d) {
    var now = Date.now()
    var s = root.samples
    s.push({ t: now, d: d })
    while (s.length > 0 && now - s[0].t > root.velocityWindow) s.shift()
  }

  function measureVelocity() {
    var s = root.samples
    if (s.length < 2) return 0
    var span = Date.now() - s[0].t
    if (span < 8) return 0
    // Skip s[0]'s own delta: it was travelled before the window opened.
    var sum = 0
    for (var i = 1; i < s.length; i++) sum += s[i].d
    var v = sum * 1000 / span
    return Math.max(-root.maxVelocity, Math.min(root.maxVelocity, v))
  }

  // Not every touchpad stack delivers a Qt.ScrollEnd phase when the fingers
  // lift. Without one the axis would never settle -- on a snapped one it
  // would just halt between two rows. A short idle timeout is the fallback.
  Timer {
    id: idle
    interval: 140
    onTriggered: root.endDrag()
  }

  Timer {
    id: settleTimer
    interval: 150
    onTriggered: root.interactive = true
  }

  // Vsync-locked: one tick per rendered frame, with the real frame delta, so
  // momentum advances by wall-clock distance instead of by frame count.
  FrameAnimation {
    id: runner
    running: false

    property string mode: ""
    property real target: 0

    onTriggered: {
      // A stalled frame (compositor hiccup, another workspace's thumbnails
      // arriving) must not teleport the content half a screen.
      var dt = Math.min(0.05, runner.frameTime)

      if (runner.mode === "glide") {
        var kg = 1 - Math.exp(-dt / root.glideTau)
        root.position += (runner.target - root.position) * kg
        if (Math.abs(runner.target - root.position) < 0.5) {
          root.position = runner.target
          root.settleNow()
        }
        return
      }

      var edge = root.edgeFor(root.position)
      if (edge !== undefined) {
        // Critically-damped spring home: a deliberate over-drag eases back,
        // and a flick that runs off the end bounces briefly instead of
        // stopping dead.
        var w = 1 / root.bandTau
        root.velocity += (-(w * w) * (root.position - edge) - 2 * w * root.velocity) * dt
        root.position += root.velocity * dt
        if (Math.abs(root.position - edge) < 0.5 && Math.abs(root.velocity) < root.minVelocity) {
          root.position = edge
          root.settleNow()
        }
        return
      }

      if (Math.abs(root.velocity) < root.minVelocity) {
        root.settleNow()
        return
      }

      root.position += root.velocity * dt
      var km = 1 - Math.exp(-dt / root.momentumTau)
      root.velocity -= root.velocity * km

      // Crossing an edge under momentum: bleed most of the speed on the way
      // out so the bounce is a nod, not a lunge. The spring branch above
      // takes it from the next frame.
      if (root.edgeFor(root.position) !== undefined) root.velocity *= 0.25
    }
  }

  onRestPositionChanged: {
    if (root.frozen || root.dragging) return
    if (root.interactive) root.glideTo(root.restPosition, true)
    else root.position = root.clamp(root.restPosition)
  }

  function reclamp() {
    if (root.frozen || root.dragging || runner.running) return
    root.position = root.clamp(root.interactive ? root.position : root.restPosition)
  }

  onMinPositionChanged: root.reclamp()
  onMaxPositionChanged: root.reclamp()

  // Freezing is also a stop: whatever was coasting or gliding when the click
  // landed ends where it stands, which is what the capture measured.
  onFrozenChanged: if (root.frozen) root.stop()

  Component.onCompleted: root.position = root.clamp(root.restPosition)
}
