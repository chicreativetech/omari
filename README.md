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
row per workspace that has windows, each window rendered as a live thumbnail
(`Quickshell.Wayland.ScreencopyView`) laid out next to its workspace
neighbors over a thumbnail of the desktop background, rows scrolling
vertically. It opens centred on the workspace you were on, with that
workspace's focused window centred in its row. Click a thumbnail to jump to
that window; click the background or press Escape to close it.

## Scrolling

Two fingers scroll the overview: up/down through workspace rows, left/right
through a row's windows when they don't all fit. `KineticScroll.qml` is the
one-axis physics both directions share, and it is deliberately not built out
of animated offsets:

- A touchpad gesture moves the content **1:1 with the fingers**, with no
  animation anywhere in that path. Easing toward a moving target instead —
  the obvious `Behavior on x/y` approach — restarts a fresh curve on every
  pixelDelta event, i.e. roughly every frame, so the content permanently
  trails the fingers and reads as rubbery.
- Momentum only starts once the fingers lift, from the speed measured across
  a short window rather than from the single last event (on a decelerating
  finger that last delta is near zero, which kills every flick).
- Overscrolling past either end is resisted progressively and springs back
  under a critically-damped spring, so the ends of the list feel like
  something you can lean on.
- Which axis a gesture owns is decided once, from its first delta, and held
  until the fingers lift. Re-deciding per event lets a gesture that wobbles a
  couple of degrees hand itself back and forth between a row and the
  workspace list mid-scroll.
- A discrete mouse wheel has no fingers to track, so it gets its own mode: a
  fixed step glided into place, accumulating if you keep spinning.

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
