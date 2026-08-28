# Omari

A plugin for Omarchy that adds Niri-like functionality: an Omarchy shell
bar plugin that toggles Hyprland's native `scrolling` layout, a 3-finger
horizontal swipe, and column-aware `SUPER+arrows` focus that doesn't
disappear behind a maximized column — plus a niri-style overview, opened
with a 4-finger swipe up or `SUPER+ALT+O`, showing every workspace as a row
of live window thumbnails.

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

A bar icon opens a popup explaining the mode with two independent toggles —
one for the scrolling-layout mode, one for the overview — styled with
Omarchy's native panel components (`Panel`, `PanelHero`, `Ui.Toggle`).

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

At rest the strip is positioned so the **monitor rectangle** — not the selected
window — lands exactly on that centred wallpaper, which is what makes a row
show what you would actually be looking at were you on that workspace. It is
nudged off that only as far as it must be to bring the ringed window inside the
wallpaper, for when left/right has walked past the part of the strip the
monitor covers.

One consequence worth knowing: Hyprland reports a monitor's size in *physical*
pixels but window geometry in *logical* ones, so the monitor is divided back
down by its scale before the two are compared. Getting that wrong is not a
small error — on a 2× monitor it draws the monitor rectangle at the right size
but every window at half of it.

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
  decides when the surface gets its size. So it polls, and requires a real size
  to have held for two consecutive ticks, giving `Column` a polish pass in
  between to position the rows `mapToItem` is about to be asked about.
- **`transform: [Scale, Translate]` is not `s*p + t`.** Transform lists
  post-multiply, so that pair maps a child point to `s*(p + t)` — the
  translation comes out scaled too. The layer uses `x`/`y`/`scale` with
  `transformOrigin: Item.TopLeft` instead, which is exactly `s*p + t` with no
  order to get wrong.

Escape and a background click just close, with no animation — there is no
window being dived into.

**Focus must be dispatched after the overlay closes, never before.** This
surface holds the keyboard grab (`WlrKeyboardFocus.Exclusive`), and when it
unmaps Hyprland refocuses on its own — undoing any focus dispatched while the
overlay was still up. The failure is deceptive because that refocus lands on
the window under the cursor: click a thumbnail whose window really is at that
spot on the live workspace and you appear to get what you asked for, so only
windows scrolled off the monitor look broken. Dispatching early to overlap the
workspace switch with the dive was tried, and is exactly this bug.

The dispatch is spawned bare rather than through `Util.execArgv`, which runs
everything under `bash -lc`. A login shell costs **~280ms** here sourcing
profile scripts, against ~10ms for `hyprctl` itself; it was most of the lag
between picking a window and the workspace actually changing. Nothing on that
command line needs a shell. That delay was also, accidentally, what made the
old ordering work: the dispatch was written before `close()` but did not land
until long after the unmap. Removing the delay removed the focus with it —
hence the explicit ordering above rather than a lucky one.

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
  fingers drag the *stack of workspaces* rather than the view over it, so
  pushing up brings the row below into the centre — deliberately the opposite
  sense to the mouse wheel below, which is the split most people already run
  between a touchpad set to natural scrolling and a wheel that is not.
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

Thumbnails capture live only while their row is at or near the viewport.
Every thumbnail is its own screencopy stream against the compositor, so
keeping all of them running for rows scrolled off-screen is sustained GPU and
Wayland buffer traffic competing with the frames a smooth scroll needs.

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
`manifest.json` to match — and also the two `bergdahlchi.omari` references in
`hypr/omari-overview.lua`, which is what the swipe and `SUPER+ALT+O` summon.

## Uninstall

Turn both switches off (that removes the Hyprland config and reloads), then:

```bash
omarchy plugin disable bergdahlchi.omari
rm -rf ~/.config/omarchy/plugins/bergdahlchi.omari
```

## How it works

- `hypr/omari-mode.lua` and `hypr/omari-overview.lua` are not loaded
  directly. Turning one on copies it into
  `~/.local/state/omarchy/toggles/hypr/omari-{mode,overview}.lua`, a
  directory Omarchy's default toggle loader already sources on every
  Hyprland reload — the same contract `omarchy-hyprland-toggle` uses for
  Omarchy's own flags, just sourced from the plugin instead of
  `$OMARCHY_PATH`.
- `bin/omari-toggle <mode|overview> [on|off|toggle|status]` is what does
  that. It finds the lua sources relative to its own path, which is what
  makes the plugin directory self-contained: an install that has never seen
  Omari before can apply the config from the switch alone. `ToggleFlag.qml`
  is the state machine `Panel.qml` instantiates once per switch; it resolves
  the plugin directory from its own QML url and runs the script out of it.
- The script is run as `bash <path>/omari-toggle` rather than executed
  directly, so a plugin directory that arrived without its executable bits
  still works. A failure now surfaces in the popup instead of the switch
  silently flipping back.
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
