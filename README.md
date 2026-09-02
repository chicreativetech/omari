# Omari

A plugin for Omarchy that adds Niri-like functionality: an Omarchy shell
bar plugin that toggles Hyprland's native `scrolling` layout, a 3-finger
horizontal swipe, column-aware `SUPER+arrows` focus that doesn't disappear
behind a maximized column, and `SUPER+PageDown`/`SUPER+PageUp` workspace
switching — plus a niri-style overview on a stageless 4-finger swipe: up to
zoom out into it, down to zoom into whatever you are looking at, both tracking
your fingers and reversible mid-swipe. `SUPER+ALT+O` opens it from the keyboard.
Every workspace is a row of live window thumbnails.

## What it does

Omarchy's default `SUPER+arrows` use Hyprland's classic `movefocus`
dispatcher. It no-ops when the active column is fullscreened/maximized
("Full width", `SUPER+ALT+F`) — pressing it won't move to a neighboring
column at all, so the other windows stay hidden until you un-maximize.
Hyprland's scrolling layout has its own layout-aware focus command
(`hl.dsp.layout("focus l/r/u/d")`) that moves to the next column and brings
it into view even when the current column is maximized, without clearing
that column's maximized state — the same effect a 3-finger swipe already
has. Omari rebinds `SUPER+arrows` to that command while the mode is on.

Workspaces are this mode's vertical axis — the 3-finger vertical swipe
switches them, the overview stacks them as rows scrolling down, and Omari
turns the `workspaces` animation back on so the switch slides along that
same axis. That swipe is Omari's own — Omarchy ships all three of its
3-finger gesture lines commented out in `hypr/input.lua`, and the only
workspace one among them is horizontal, so nothing bound 3-finger vertical
until `omari-mode.lua` did. It uses Hyprland's built-in `workspace` action,
so the workspaces travel under your fingers and a half-swipe can be pushed
back, rather than a threshold firing a switch once you let go. `SUPER+PageDown`/`SUPER+PageUp` are the keyboard version of it:
Down to the next workspace, Up to the previous, dispatching the same
`e+1`/`e-1` as Omarchy's own `SUPER+TAB`, which keeps working alongside
them. Both bindings appear and disappear with the mode.

A bar icon opens a popup explaining the mode with three toggles — scrolling
layout, overview, and Alt-Tab — styled with Omarchy's native panel components
(`Panel`, `PanelHero`, `Ui.Toggle`). The overview and Alt-Tab hang off the
mode: their switches are only shown while it is on, turning it off takes both
features down with it, and turning it back on restores the ones that were up.
The overview draws the scrolling layout's workspaces and Alt-Tab walks the same
tape, so neither is meant to be left running on a stock Hyprland layout.

The overview (`OmariOverview.qml`) is a full-screen layer-shell surface: one
row per workspace that has windows, rows scrolling vertically. It opens
centred on the workspace you were on. Click a window to jump to it; click the
background or press Escape to close.

**A row is a scaled replica of that workspace's monitor.** The wallpaper
thumbnail is the monitor rectangle itself, and every window is a live
thumbnail (`Quickshell.Wayland.ScreencopyView`) drawn at its true size and
offset within it, from Hyprland's own `at`/`size` — so a half-width window is
half the width of the wallpaper behind it, and the reserved strip under the
bar shows as a band of bare wallpaper along the top. Nothing is sized from the
screencopy buffer's aspect ratio, which arrives a frame or two late and would
relayout the row when it did.

Because omari mode is a scrolling layout, a workspace's windows routinely run
past both edges of their monitor: workspace strips here are commonly 2.5× the
monitor's width. So the strip, not the monitor, is what scrolls horizontally,
and it is free to overhang both edges of the screen.

**The wallpaper thumbnail is what the strip scrolls behind**, not the display.
Travel runs from the first window's left edge lining up with the thumbnail's
left edge to the last window's right edge lining up with its right one — so a
row never stops with the last window pinned to the edge of the display and a
band of empty desktop still showing inside the wallpaper. Windows scrolled past
either edge stay drawn against the backdrop, the way they overhang a real
monitor; it is only the limits that the wallpaper frames.

**The wallpaper does not scroll with it.** It is centred horizontally in the
row and pinned there, so panning a workspace's windows slides them across a
background that stays put — the way the real desktop behaves under a scrolling
layout, where moving through the columns never moves the wallpaper. Every row's
wallpaper therefore lines up down the middle of the screen. It is declared
before the scrolling strip so it draws behind the windows, and outside it so
its drop shadow is not clipped away at the row's top and bottom edges.

**The last row is always an empty one**: bare wallpaper, no windows, standing
for the next workspace with nothing on it — the lowest id no row is using,
since a workspace without windows gets no row of its own. Clicking it (or
pressing Enter with it centred) switches there. It is a plain stand-in object
in the same row list rather than a real workspace, answering the only three
things the row delegate ever asks a row for — `id`, `monitor` and
`toplevels.values` — so counting, centring, snapping and selection need no
special case for it. An overview with nothing open at all is therefore a
single bare wallpaper, which is exactly what it is describing.

At rest the strip is positioned so the **monitor rectangle** — not the selected
window — lands exactly on that centred wallpaper, which is what makes a row
show what you would actually be looking at were you on that workspace. It is
nudged off that only as far as it must be to bring the ringed window inside the
wallpaper, for when left/right has walked past the part of the strip the
monitor covers.

**Scrolling a row is a real change to that workspace, and it sticks.** A row
the user has scrolled remembers where to, keyed by workspace id, and holds it
after the row stops being the centred one — rows used to snap back to
Hyprland's own focused window the instant you moved off them, so scrolling row
1 to its last window and then dropping to row 3 undid the scroll on the way
past. Untouched rows still follow Hyprland's focus, which is what makes an
untouched row a truthful picture of its workspace.

Every scrolled row is then handed to the compositor in the same batch that
leaves the overview, in front of the destination dispatch. There is no
dispatcher for "scroll this workspace to here": a scrolling layout is scrolled
by focusing something, and focusing follows the workspace — so each of those
switches the active workspace as it runs, which is precisely why they go first
and the destination goes last. The batch runs in order inside Hyprland, all of
it inside the round trip the leave was already making, behind a backdrop that
is already opaque. Rows whose remembered window is already the focused one are
dropped, so an overview that was only looked at sends nothing extra. Escape and
a click on the backdrop are still a cancel and commit nothing.

One consequence worth knowing: Hyprland reports a monitor's size in *physical*
pixels but window geometry in *logical* ones, so the monitor is divided back
down by its scale before the two are compared. Getting that wrong is not a
small error — on a 2× monitor it draws the monitor rectangle at the right size
but every window at half of it.

**That geometry has to be asked for.** Every rectangle here comes from
Hyprland's own `at`/`size`, read off `HyprlandToplevel.lastIpcObject`, and that
field is filled in by an IPC query and by nothing else: Quickshell builds a
toplevel from the `openwindow` event with no geometry at all, and one built by
the query at startup keeps the geometry it had at that moment however many times
the scrolling layout has moved it since. With no geometry, `rectFor` returns
null and the fallback is the monitor rectangle — so a workspace's windows all
stack on the same spot at the same size, only the topmost visible, and it takes
every click whichever thumbnail was aimed at. So `Hyprland.refreshToplevels()`
runs on the way in, and again (coalesced through a 50ms timer) on the Hyprland
events that move windows. Every rectangle is a binding over `lastIpcObject`, so
the rows lay themselves out again when the answer arrives.

## Look

Modelled on niri's overview, and the deliberate choices are mostly things
that are *not* drawn:

- **No workspace labels and no title bars over the thumbnails.** Both are the
  chrome that makes the screen read as a list of workspaces rather than as the
  desktops themselves. At this size a window already shows its own titlebar or
  tab strip, so an overlaid title was a second, uglier one covering the content
  that makes the window recognisable.
- **No border on a window unless it is ringed.** Each row rings the one window
  it is centred on; the centred row's ring is the accent colour because that
  one is the keyboard cursor, the others are a neutral grey stating a fact
  about their workspace. Outlining every thumbnail turns a row of windows into
  a strip of framed tiles.
- **The viewport has no margin**, so the rows above and below run off the top
  and bottom edges instead of being framed inside a backdrop border.
- **The backdrop is flat, opaque, and lighter than `Color.background`**, not
  darker. Everything in the overview is a dark app thumbnail carrying a drop
  shadow; against near-black the shadows and the windows' own edges vanish and
  the rows smear together.
- **A workspace occupies half the viewport height**, and the gap between two
  workspaces a tenth of that — both ratios rather than pixel counts, since how
  much of your neighbouring workspaces you can see is inherently a fraction of
  the screen. The same fixed `Style.space()` figure filled 58% of a laptop
  panel and a third of a large monitor.

## Zoom

The overview is the desktop seen from further away, so it arrives by falling
back from the window you were on and leaves by diving into the one you pick.
Both directions are one transform on a single progress value: at 0 the strip
sits where the overview lays it out; at 1 the target window's thumbnail covers
the *real* window's own place on screen at real size, so at the moment the
overlay goes away nothing jumps. Scaling about a fixed origin would not do
that — a thumbnail grown to full size around its own centre still ends up
wherever the overview happened to put it, which is not where the window is.

Every term is identity until a capture fills it in, so a capture that fails
leaves the overview behaving exactly as it does with none of this.

Two things here are easy to get wrong and were both got wrong first:

- **The capture needs a laid-out surface, not merely existing delegates.**
  While the layer surface is still unsized `panel.height` is 0, so `rowHeight`
  sits on its floor and a thumbnail measures a fraction of its eventual size —
  which lands in the scale factor as a seven rather than a two and flings the
  strip off screen. A fixed delay is not a fix either, since the compositor
  decides when the surface gets its size. It is measured on the first rendered
  frame instead; see *Opening cost* below for why that is both early enough and
  late enough.
- **`transform: [Scale, Translate]` is not `s*p + t`.** Transform lists
  post-multiply, so that pair maps a child point to `s*(p + t)` — the
  translation comes out scaled too. The layer uses `x`/`y`/`scale` with
  `transformOrigin: Item.TopLeft` instead, which is exactly `s*p + t` with no
  order to get wrong.

**The backdrop's two directions do not share a curve.** They ask for opposite
things, and for a while they shared one because the opening was too quick to
argue with.

Diving, the desktop underneath is *moving* — the workspace slide the click
dispatched is running behind the overlay, and hiding it is what the overlay is
for. So the backdrop holds opaque through almost all of the dive (`1 - p²`) and
clears only at the very end, where the strip has become a near-match for the
desktop behind it and the two can be crossed without anything being seen to
move. Clearing in step with the progress instead showed the workspace sliding in
behind a half-transparent overview.

Opening, the desktop underneath is *still*, and the strip is pulling away from
it — so everything the strip uncovers as it shrinks is the real desktop showing
through, in register with the replica drawn on top of it. Two copies of the same
picture at different sizes. Squared, the backdrop is barely there for the first
third of the pull-back, which nobody could see at 260ms and everybody can see
when the fingers hold the zoom halfway out. This direction goes opaque within
`backdropRise` (0.1) of leaving progress 1 instead — a few tens of pixels of
travel. It cannot simply *start* opaque: at progress 1 exactly the strip stands
in for the desktop pixel for pixel, and painting over it there would put a grey
flash at both ends of every swipe.

Escape and a background click do not dive — there is no window being dived
into — but they do not cut away either: the whole overlay fades over 110ms and
then stops drawing. `opened` goes false at the *start* of that fade and the
surface is held up by a separate `leaving` flag, because `opened` is what the
host answers "is this plugin open?" with: leaving it true would swallow a swipe
arriving during the fade, which is exactly where one arrives. As it stands that
swipe reopens a surface that was never torn down, which is instant.

## The opening swipe

The 4-finger swipe does not *start* the opening zoom, it **is** the opening
zoom. `zoomProgress` is written straight from how far the fingers have
travelled, so the overview pulls back under them and stands wherever they
stand; letting go only finishes the direction it was already going, and pushing
back down before letting go returns the desktop without the overview ever
having committed to opening. This is niri's behaviour, and it is the whole
difference between a stageless gesture and an animation a gesture triggers.

Hyprland does the tracking. `hl.gesture` takes a table of `start`/`update`/
`finish` callbacks rather than a single function, and calls them for every
trackpad event of the gesture instead of once when it completes.
`hypr/omari-overview.lua` accumulates the travel — `delta` is the *per-event*
delta, not the running total — and puts it on Hyprland's event socket with
`hl.dsp.event`, one `custom>>` line per update. That is cheap enough to do at
touchpad rate, which spawning a process per frame very much is not. Only the
raw pixel travel is sent: turning it into a fraction of a zoom wants the height
of the screen and the state of the overview, and both live at the QML end.

The gesture is registered as `up`, not `vertical`, so a downward 4-finger swipe
still matches nothing, exactly as before. That does not stop a swipe being
*reversed*: Hyprland picks the matching gesture once, on the first 5px of
travel, and keeps feeding that one every event afterwards whichever way the
fingers then go.

Releasing commits if the overview is a third of the way out, **or** if the
fingers were still moving fast enough when they lifted — the second is what
lets a quick flick open it without dragging all the way. The release timestamp
is part of the event for a reason: a touchpad reports only motion, so a swipe
that stops on the pad and is held there sends nothing at all and the last speed
measured would otherwise stay on the books however long it was held. A gap
wider than 50ms between the last movement and the release means the fingers had
come to rest, and only the distance counts.

Swiping *up* on an overview that is already open does nothing at all, for its
whole length. Up is the way in and down is the way out; letting one stroke mean
both puts the two halves of the gesture on the same side, so over-shooting the
opening swipe and easing back reads as asking to leave. Escape and a background
click still dismiss without going anywhere.

## The closing swipe

Swiping **down** is the opening swipe's mirror in feel and nothing like it
underneath, because leaving is not only a zoom. It lands you on the workspace
you are *looking at*, so it is a workspace switch as well — and a switch moves
the very thing the zoom has to land on, since focusing a window in a scrolling
layout scrolls its workspace to bring that column into view. The dive has to be
aimed at where the window is *about to be*, and nothing knows that until the
focus dispatch has landed. That is why the click path takes a round trip through
Hyprland rather than measuring what is on screen, and the gesture needs the same
answer.

So the gesture front-loads everything the click does at its click: freeze,
capture, hand the keyboard grab back, dispatch, ask where the window went. That
is roughly **100ms**, most of it waiting for Hyprland to finish restoring focus
after the grab goes back, and for that beat the fingers move and the zoom does
not. The alternative — aiming at where the window is now and correcting when the
answer arrives — puts a jerk in the middle of the one transition that has to be
seamless. Standing still under an opaque backdrop is the cheaper place to spend
it. The travel origin is taken when the answer lands, so the wait costs a beat
rather than a jump. From there the fingers drive exactly the ramp `beginDive`
would have run.

Unlike the opening swipe, this one has something to undo if it is abandoned: the
workspace has really been switched by the time you change your mind. Cancelling
ramps back to the overview and dispatches the focus back, which is why the
window to return to is captured before anything is sent. Released inside the
arranging beat, before there is any aim to ramp from, it degrades to exactly
what a click does — the round trip finishes and animates the dive itself.

Three things do not have a window to dive into: the empty row, a thumbnail that
cannot be measured, and an overview that is not open. The first two hold still
and switch plainly on release, down the same fallback chain a click takes. The
third does nothing at all, so a 4-finger swipe down on the bare desktop stays
free.

The gesture is registered as its own `down`, not as a shared `vertical`, so each
direction keeps its own travel and its own meaning. Hyprland allows the pair:
`addGesture` only refuses a registration whose axis collides with an existing one
for the same finger count, and `UP` and `DOWN` collide with neither each other
nor `VERTICAL`.

## Opening cost

Opening the overview used to mean mapping a fresh full-screen layer-shell
surface, and the two frames that takes were measured at **~200ms each**. That
cost is in the surface, not in what is drawn on it: taking the row shadows out
of the scene, then the screencopy streams, then the wallpaper, each changed it
by nothing.

**So the surface is never unmapped.** It is created once at shell start and
kept, because a gesture cannot track fingers 1:1 through a third of a second of
surface creation — it can only sit still and then jump to wherever they got to.
With the surface already up, the first event of a swipe finds a laid-out scene
it can measure and start moving on the same frame.

Keeping it costs nothing to look at — the children draw nothing while the
overview is down (`visible: false`, not `opacity: 0`, which is still laid out
and still drawn), an empty `mask` region makes the whole screen click through
it, and the keyboard grab is gated on the overview being up rather than on the
window existing. But it is not free on the *compositor* side: Hyprland refuses
direct scanout on any monitor that has a mapped overlay-layer surface at all
(`CMonitor::isSolitaryBlocked` checks that list for emptiness and, unlike the
top layer beside it, does not look at alpha), and refuses tearing along with it.
Left on the overlay layer permanently this would cost every fullscreen game and
video on the machine its scanout path, forever, to save the overview a few
hundred milliseconds. So it is *parked on the background layer* while the
overview is down and raised to overlay when it goes up — a layer nothing in
that check looks at. Quickshell applies the change as a plain `set_layer` on
the surface that is already up rather than by remapping, so the raise costs a
commit and not two 200ms frames, which is the whole reason the trade is
available.

The plugin is `keepLoaded`, so the QML is instantiated once at shell start
rather than on every summon — worth another ~250ms per open, measured — and the
rows survive between summons already laid out, which is what lets the zoom be
measured on the very first frame.

**No thumbnail is ever a live stream.** A live `ScreencopyView` is not something
the compositor pushes at you, it is a loop you hold open: each arriving frame
dirties the view, the view repaints, Quickshell re-arms the capture from that
repaint, and the next frame arrives to dirty it again. So a visible thumbnail
renders at the display's refresh rate for as long as it is on screen — whether
or not the window in it has changed a single pixel — and here every one of
those frames also re-renders a supersampled offscreen layer and rebuilds its
mipmap chain, which for a full-screen window on a 2736×1824 panel is a
2572×1720 texture. Measured: two thumbnails at overview geometry held the
renderer at 66fps with the overview open, still, and untouched. The same two
frozen sat at 1.2fps.

Instead there is a **capture budget** — six captures a second for the whole
overview, handed to whichever thumbnail most needs one. The reason it is a
budget rather than tighter position gating is that a budget's cost does not
scale with how many thumbnails are on screen and live capture's does, and a
machine with a lot of windows is exactly the one that cannot afford the
difference. Six is off the measured curve rather than off the feel of it: idle
cost falls about linearly up to ~12/s and is indistinguishable from fully live
at 30/s and above, so a faster budget pays live's price without live's
freshness. On a screenful of six or eight thumbnails each is refreshed about
once a second — invisible on a static window, alive on a terminal, a slideshow
on video.

The budget is spent in priority order: the zoom's target ahead of everything
(it bypasses the budget entirely, on both the opening and the dive), then any
on-screen thumbnail with no picture at all, then the stalest on-screen picture,
then the render margin kept warm for a scroll that may never arrive. Nothing is
spent at all while the overview is moving on any of its three axes, and the
token bucket holds at most one — so the frame a gesture settles on can spend a
single capture and no more, which is the burst that made the older
freeze-during-motion attempts worse than doing nothing.

It is driven by a `Timer` and deliberately not by a `FrameAnimation`. A
`FrameAnimation` asks the renderer for a frame on every frame — that is the
whole of what it is — so one driving the scheduler would pin the render loop at
refresh rate and hand back none of the saving. Measured, a `FrameAnimation`
issuing no captures at all cost 67fps of idle rendering, which is exactly what
leaving every thumbnail live costs.

**What is off the screen is not drawn, not merely clipped.** A row past the
viewport keeps its wallpaper's shadow layer and every one of its thumbnails'
supersampled, mipmapped layers allocated and up to date for as long as it
exists, so on a ten-workspace machine most of the overview's texture footprint
was rows nobody could see. Rows more than a stride out are `visible: false`
instead, which takes the whole subtree out of the scene graph — and they come
back a stride *before* they start capturing, so the frame that brings a row on
screen is never also the frame that builds its layers.

That is why the rows are not in a `Column` any more. A positioner lays out only
its visible children and closes the gap an invisible one leaves, so with one
there no row could be dropped without every row below it sliding up a slot. The
rows place themselves at `index * rowStride` inside a plain `Item`, which is the
number `centerPositionFor`, the snap points and `viewportY` were all computing
anyway. It also removes a trap the dive used to fall into: a delegate's `y` is
now a binding on its own index, right from the instant it is created, rather
than a positioner's output that arrives a pass later.

**A window scrolled off its own row is not refreshed either.** The vertical half
of that test was always here; a scrolling layout is what makes the horizontal
half necessary. A workspace strip is routinely two and a half monitors wide and
a row shows about two of them, so a visible row would otherwise be spending the
capture budget on windows sitting a screen's width past its own edge.

**Hovering a thumbnail no longer reallocates its texture.** The ring used to be
the thumbnail's own border, with the capture inset by its width so the video
did not paint over it — and since the ring appears on hover, every pointer
crossing resized the capture by two pixels. That item's size *is* its layer's
texture size, so moving the mouse across the overview allocated and re-rendered
a fresh offscreen buffer, at up to twice device size, for every thumbnail it
passed over. The ring is a sibling drawn over the capture now: the same two
pixels, the same colour, and nothing underneath moves when it comes and goes.

The wallpaper path is resolved by a process (`readlink` on the symlink the
background plugin follows), and that spawn used to happen at the summon, racing
the two frames the opening zoom is measured from for an answer that is the same
one it gave last time on every open but the one after a theme change. It is
probed at shell start and then a third of a second into each summon instead,
which is after the zoom rather than across it.

The Alt-Tab row does the same accounting for the same reason, minus the zoom it
does not have: a card past the edge of the screen neither draws nor streams, and
starts doing both as the strip slides it in. A row of every window open is
several screens long, and starting fifteen streams to draw the four you can see
is a cost paid in the same breath as the keypress.

Sorting a row's windows into left-to-right order asks Hyprland's geometry for
each window once, rather than once per comparison. The sort is re-derived per
row every time a geometry query lands with the overview up, and the comparator
form of it measured every window several times over and discarded all but one
of the answers.

The three feature flags are probed once at startup and whenever the popup is
opened. They are not polled while the keep-loaded plugin sits in the bar, which
avoids nine short-lived shell processes per minute doing invisible work.

The zoom itself is driven by a `FrameAnimation` rather than a `NumberAnimation`,
because a wall-clock animation started for that first frame is simply over by
the time the second one is drawn: the overview snapped into place instead of
falling back into it. Capping how far one frame may carry the ramp (a sixth)
turns that into a slower zoom rather than no zoom. On a healthy 60Hz frame the
cap is nowhere near reached and it is exactly the animation it replaces.

The ramp also starts one capped step in rather than at the very start. At
progress 1 the strip is a pixel-exact stand-in for the window it covers, so a
ramp starting there spends that hard-won first frame drawing something
indistinguishable from the desktop already on screen. A step in, and the first
thing drawn is the overview visibly pulling back — at ~200-300ms after the
swipe rather than the ~550ms it used to take to start moving.

**Focus is dispatched with the grab handed back, and the overlay held across
the switch.** This surface takes the keyboard grab
(`WlrKeyboardFocus.Exclusive`), and while it holds one, a focus dispatch does
not stick: when the surface unmaps Hyprland refocuses on its own and undoes it.
The failure is deceptive because that refocus lands on the window under the
cursor — click a thumbnail whose window really is at that spot on the live
workspace and you appear to get what you asked for, so only windows scrolled off
the monitor look broken.

Closing first avoids that but buys a flicker: the unmap happens before the
workspace switch lands, so a frame of the workspace you are *leaving* shows
between the dive ending and the new one arriving. Setting `keyboardFocus` to
`None` hands the grab back without unmapping, so the dispatch is the last word
and the surface can stay up across the switch — holding its final zoomed frame,
which is the destination window at real size in its real place, so what it
covers is exactly the switch. It stops drawing 110ms later.

The dispatch is spawned bare rather than through `Util.execArgv`, which runs
everything under `bash -lc`. A login shell costs **~280ms** here sourcing
profile scripts, against ~10ms for `hyprctl` itself; it was most of the lag
between picking a window and the workspace actually changing. Nothing on that
command line needs a shell. That delay was also, accidentally, what made an
earlier dispatch-then-close ordering appear to work: the dispatch was written
first but did not land until long after the unmap.

## Navigation

One row is always centred vertically. Which row that is, and which of its
windows is highlighted, is the overview's entire state — everything below
moves that selection, and the scrolling follows it rather than the other way
around:

- **Arrow keys** move up/down between workspace rows and left/right between
  the windows in the centred row; Enter (or Space) jumps to the highlighted
  one.
- **Two fingers** drag the rows freely up/down, and on release the row nearest
  the centre snaps to it — carrying a flick's remaining speed into the choice,
  so a nudge moves one row and a firm swipe crosses several. Vertically the
  fingers drag the *view over the stack of workspaces* rather than the stack
  itself, so pushing up brings the row above into the centre — the same sense
  as the horizontal drag and the mouse wheel below, so nothing in the overview
  reverses direction depending on which way you happen to be swiping.
  Left/right scrolls a row's windows freely, since windows are different widths
  and a swipe across a row should be able to stop wherever it likes.
- **The mouse wheel** steps one row per notch vertically (fractions of a notch
  from a high-resolution wheel are accumulated), and scrolls a row's windows
  horizontally.

The selected app resets to a row's own focused window when the *workspace id*
changes, never when `selectedRow` changes. `selectedRow` is a binding over
`workspaceRows`, which Hyprland re-evaluates on every model update — a window
opening anywhere, or just a title changing — and any of those that shifted the
row index, even for a frame, silently threw away a left/right selection the
user had just made. It showed up as arrow keys intermittently activating the
wrong window.

Horizontal scrolling always acts on the **centred row**, whatever the pointer
is over. Routing it by pointer position — a wheel handler per row, each seeing
the event only when the cursor was inside it — meant a two-finger swipe scrolled
whichever row the mouse happened to have been left on. A touchpad gesture has
no pointer to speak of, and everything else here already acts on the centred
row. Note that a row whose windows all fit on screen has nothing to scroll and
will not move: a strip only overflows once it is wider than the viewport, which
at half scale means the workspace must span more than two monitors' width.

The vertical axis is not "scroll the column through the viewport" — its travel
runs from *first row centred* to *last row centred*, which is what lets the
first and last rows reach the middle at all. Deriving the limits from the
column height, as it used to, pinned them to the top and bottom edges instead.

## Scrolling

`KineticScroll.qml` is the one-axis physics both directions share, and it is
deliberately not built out of animated offsets:

- A touchpad gesture moves the content **1:1 with the fingers**, with no
  animation anywhere in that path. Easing toward a moving target instead —
  the obvious `Behavior on x/y` approach — restarts a fresh curve on every
  pixelDelta event, i.e. roughly every frame, so the content permanently
  trails the fingers and reads as rubbery.
- Momentum (or, on the snapped vertical axis, the choice of which row to
  settle on) only starts once the fingers lift, from the speed measured across
  a short window rather than from the single last event (on a decelerating
  finger that last delta is near zero, which kills every flick).
- Overscrolling past either end is resisted progressively and springs back
  under a critically-damped spring, so the ends of the list feel like
  something you can lean on.
- **Every row takes the drag, including one with nowhere to go.** A workspace
  whose windows all fit inside its monitor has nothing to bring into view, but
  refusing its gesture outright made the row read as a dead surface rather than
  as one already showing everything. It follows the fingers into the band and
  springs home instead, which also means a window can never be left parked off
  its wallpaper.
- Which axis a gesture owns is decided once, from its first delta, and held
  until the fingers lift. Re-deciding per event lets a gesture that wobbles a
  couple of degrees hand itself back and forth between a row and the
  workspace list mid-scroll.
- A discrete mouse wheel has no fingers to track, so it gets its own mode: one
  snap point, or a fixed step on a free axis, glided into place.
- Arrow-key navigation goes through the same glide. The scrollers expose a
  "rest position" the owner points at whatever should be centred; it is
  followed instantly for the first frames after opening, while geometry and
  screencopy aspect ratios are still resolving, and animated after that.

Thumbnails are refreshed first while their row is at or near the viewport, and
while they are near the part of that row which is on screen; everything else
inside the render margin is kept warm at a much slower rate. Both bounds are
about where the budget is *spent*, not about what is allowed to capture —
`captureFrame()` is not paint-driven, so a thumbnail whose whole subtree is
`visible: false` refreshes perfectly well when asked. See *Opening cost*.

## Install

The plugin directory is the whole install — the Hyprland config and the
script that applies it ship inside it, so there is nothing to copy into
`~/.config/hypr` or `~/.config/omarchy/bar/scripts`.

```bash
git clone https://github.com/chicreativetech/omari.git \
  ~/.config/omarchy/plugins/bergdahlchi.omari
omarchy-shell shell rescanPlugins
omarchy plugin enable bergdahlchi.omari --section left
```

Then click the Omari icon in the bar and turn on whichever switches you
want. Each one writes its config and reloads Hyprland for you; nothing else
has to be set up first.

To install under a different id, rename the directory and change `id` in
`manifest.json` to match — and update the hard-coded id in `Panel.qml` and
`hypr/omari-overview.lua`, which route panel IPC and overview summon requests.

## Uninstall

Use Omarchy's plugin remover:

```bash
omarchy plugin remove bergdahlchi.omari
```

Omarchy disables the plugin before deleting it. Omari uses that lifecycle
boundary to remove all three generated Hyprland toggle files and reload
Hyprland, while deliberately leaving them alone during normal shell restarts
and plugin hot reloads. Nothing remains active after removal.

There is exactly one thing left behind, and only by the one uninstall Omarchy
does not perform: deleting the plugin directory by hand. The cleanup is the
plugin's own code, so a checkout removed without ever being disabled never runs
it, and the three copies in `~/.local/state/omarchy/toggles/hypr/` stay there —
sourced on every Hyprland reload, by a plugin that is no longer installed. Turn
the switches off first, or run the cleanup before deleting:

```bash
bash ~/.config/omarchy/plugins/bergdahlchi.omari/bin/omari-toggle all off
```

## How it works

- The three `hypr/omari-*.lua` files are not loaded
  directly. Turning one on copies it into
  `~/.local/state/omarchy/toggles/hypr/omari-{mode,overview,alttab}.lua`, a
  directory Omarchy's default toggle loader already sources on every
  Hyprland reload — the same contract `omarchy-hyprland-toggle` uses for
  Omarchy's own flags, just sourced from the plugin instead of
  `$OMARCHY_PATH`.
- `bin/omari-toggle <mode|overview|alttab> [on|off|toggle|status]` is what does
  that, and the cascade lives here rather than in the popup, so the CLI and the
  plugin's IPC `enable`/`disable` get it too: `mode off` removes the overview
  and Alt-Tab flags after recording which of them were on in
  `$XDG_STATE_HOME/omari/suspended`, and `mode on` puts exactly those back and
  deletes the memo. One `hyprctl reload` covers the whole cascade. The memo
  lives outside the toggles directory because that directory is sourced as lua,
  and only the two names this script writes are honoured when it is read back.
  `all off` clears it, so nothing resurrects on the next `mode on`. It finds the
  lua sources relative to its own path, which is what makes the plugin
  directory self-contained: an install that has never seen
  Omari before can apply the config from the switch alone. `ToggleFlag.qml`
  is the state machine `Panel.qml` instantiates once per switch; it resolves
  the plugin directory from its own QML url and runs the script out of it.
- The script is run as `bash <path>/omari-toggle` rather than executed
  directly, so a plugin directory that arrived without its executable bits
  still works. A failure now surfaces in the popup instead of the switch
  silently flipping back.
- `omari-mode.lua` binds `SUPER+PageDown`/`SUPER+PageUp` to
  `hl.dsp.focus({ workspace = "e+1"/"e-1" })`. `e+1`/`e-1` rather than
  `+1`/`-1` walks only the workspaces that exist, plus one empty one at the
  end, instead of running off into empty workspace 11, 12, 13. Both are
  unbound in Omarchy's defaults, so nothing has to be unbound first. `SUPER`
  is not optional here: a bare `Page_Down` would be grabbed
  compositor-wide and stop paging in every editor, browser and terminal.
- `omari-overview.lua` binds both a 4-finger swipe up and `SUPER+ALT+O` to
  `omarchy-shell shell toggle bergdahlchi.omari`. Because the manifest
  declares an `overlay` entry point (`OmariOverview.qml`) alongside the
  `bar-widget` one (`Panel.qml`), the shell's global toggle routes to the
  overview surface — the bar icon's own click still opens the small
  `Panel.qml` popup, a separate, purely local toggle. The keybinding lives
  in `omari-overview.lua` rather than `bindings.lua` so it appears and
  disappears with the overview toggle itself. It is not `SUPER+CTRL+O`:
  Omarchy already binds that to "Toggle menu", as it does `SUPER+O` and
  `SUPER+SHIFT+O`.

## License

MIT
