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
// the fingers lift: momentum that decays at a constant rate, and a
// critically-damped spring back to the edge if the gesture ended (or the
// momentum ran) past one. A discrete mouse wheel has no fingers to track, so
// it gets its own mode: a fixed step glided into place.
Item {
  id: root

  // ---- geometry in ----
  property real viewportSize: 0
  property real contentSize: 0

  // Offset this axis rests at until the user scrolls it. The overview
  // recomputes this as screencopy resolves real thumbnail aspect ratios, so
  // it has to be a live binding target rather than a one-shot assignment --
  // but only until the user takes over, after which it is ignored.
  property real restPosition: 0

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
  property real notchPixels: 110    // travel per discrete mouse-wheel notch
  // Momentum decay is exponential (velocity loses a fraction of itself per
  // unit time, like the glide/band eases below) rather than the constant
  // px/s^2 this used to subtract every frame. Constant deceleration keeps
  // full braking force right up to the moment it snaps to a stop, which
  // reads as abrupt; decaying proportional to the current speed brakes hard
  // while fast and tapers off the harder it already slowed, so the coast
  // eases out instead of cutting off.
  property real momentumTau: 1.6    // s, momentum decay time constant
  property real maxVelocity: 18000  // px/s, cap on a flick
  property real minVelocity: 25     // px/s, below this momentum has stopped
  // bandTau doubles as the edge spring's stiffness (w = 1/bandTau below): the
  // old 0.085s made for a very stiff, tightly-wound spring that snapped back
  // rigidly the instant a drag or flick went past an edge. A longer time
  // constant is a softer spring -- more give, a gentler settle.
  property real bandTau: 0.35       // s, rubber-band spring time constant
  property real glideTau: 0.18      // s, discrete-wheel glide time constant

  // ---- state out ----

  // Scroll offset in content pixels: the content should be drawn at
  // -position along this axis. Steps outside [0, maxPosition] only while
  // rubber-banding past an edge.
  property real position: 0

  readonly property real maxPosition: Math.max(0, root.contentSize - root.viewportSize)
  readonly property bool overflows: root.contentSize - root.viewportSize > 0.5

  // True once the user has scrolled this axis, which is what stops
  // restPosition from yanking it back to centre mid-scroll.
  property bool engaged: false

  function clamp(p) { return Math.max(0, Math.min(root.maxPosition, p)) }

  // The edge `p` has gone past, or undefined if it is in range. Doubles as
  // the "are we in the rubber-band zone" test.
  function edgeFor(p) {
    if (p < 0) return 0
    if (p > root.maxPosition) return root.maxPosition
    return undefined
  }

  function reset() {
    runner.mode = ""
    runner.running = false
    idle.stop()
    root.velocity = 0
    root.samples = []
    root.engaged = false
    root.position = root.clamp(root.restPosition)
  }

  function stop() {
    root.velocity = 0
    runner.mode = ""
    runner.running = false
  }

  // ---- input ----

  // A touchpad gesture step: `delta` is raw pixels, applied straight through.
  function dragBy(delta) {
    if (!root.overflows || delta === 0) return
    root.engaged = true
    // Fingers are back down; whatever the last gesture left coasting is over.
    root.stop()

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

  // The fingers lifted: hand whatever speed they had over to momentum.
  function endDrag() {
    idle.stop()
    if (!root.overflows) return
    root.velocity = root.measureVelocity()
    root.samples = []
    runner.mode = "momentum"
    runner.running = true
  }

  // One or more discrete mouse-wheel notches. No fingers to track, so this
  // glides a fixed step instead, accumulating onto any glide already in
  // flight so spinning the wheel keeps building speed.
  function stepBy(notches) {
    if (!root.overflows || notches === 0) return
    root.engaged = true
    var base = runner.mode === "glide" ? runner.target : root.position
    runner.target = root.clamp(base + notches * root.notchPixels)
    root.velocity = 0
    runner.mode = "glide"
    runner.running = true
  }

  // ---- internals ----

  property real velocity: 0

  // Recent gesture deltas, so the flick speed at release is measured over a
  // short window rather than taken from the single last event (which on a
  // slowing finger is close to zero and kills every flick).
  property var samples: []
  readonly property int velocityWindow: 90 // ms

  function bandResistance(over) {
    var reach = Math.max(1, root.viewportSize * 0.55)
    return Math.max(0.12, 1 - Math.abs(over) / reach)
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
  // lift. Without one, `engaged` would never hand off to momentum and the
  // content would just halt dead. A short idle timeout is the fallback.
  Timer {
    id: idle
    interval: 140
    onTriggered: root.endDrag()
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
          root.stop()
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
          root.stop()
        }
        return
      }

      if (Math.abs(root.velocity) < root.minVelocity) {
        root.stop()
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

  onRestPositionChanged: if (!root.engaged) root.position = root.clamp(root.restPosition)

  onMaxPositionChanged: {
    if (runner.running) return
    root.position = root.engaged ? root.clamp(root.position) : root.clamp(root.restPosition)
  }

  Component.onCompleted: root.position = root.clamp(root.restPosition)
}
