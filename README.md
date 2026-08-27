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

1. Copy the Quickshell plugin into your user plugins directory (pick your
   own id, e.g. `<username>.omari`):

   ```bash
   mkdir -p ~/.config/omarchy/plugins/<username>.omari
   cp manifest.json Panel.qml OmariOverview.qml KineticScroll.qml \
     ToggleFlag.qml OmariIcon.qml \
     ~/.config/omarchy/plugins/<username>.omari/
   ```

   Edit `id` in `manifest.json` to match the directory name if you change it.

2. Copy the Hyprland mode/overview files and the toggle scripts:

   ```bash
   cp hypr/omari-mode.lua ~/.config/hypr/omari-mode.lua
   cp hypr/omari-overview.lua ~/.config/hypr/omari-overview.lua
   cp bin/omari-mode-toggle ~/.config/omarchy/bar/scripts/omari-mode-toggle
   cp bin/omari-overview-toggle ~/.config/omarchy/bar/scripts/omari-overview-toggle
   chmod +x ~/.config/omarchy/bar/scripts/omari-mode-toggle \
     ~/.config/omarchy/bar/scripts/omari-overview-toggle
   ```

3. Rescan and enable the plugin:

   ```bash
   omarchy-shell shell rescanPlugins
   omarchy plugin enable <username>.omari --section left
   ```

## How it works

- `hypr/omari-mode.lua` and `hypr/omari-overview.lua` are not loaded
  directly. Toggling one copies it into
  `~/.local/state/omarchy/toggles/hypr/omari-{mode,overview}.lua`, a
  directory Omarchy's default toggle loader already sources on every
  Hyprland reload.
- `bin/omari-mode-toggle` and `bin/omari-overview-toggle` flip their flag
  file's presence and run `hyprctl reload`. `ToggleFlag.qml` is the shared
  state machine Panel.qml instantiates once per mode: it polls the flag
  file's presence and runs the toggle script.
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
