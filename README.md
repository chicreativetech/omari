# Omari

A plugin for Omarchy that adds Niri-like functionality: an Omarchy shell
bar plugin that toggles Hyprland's native `scrolling` layout, a 3-finger
horizontal swipe, and column-aware `SUPER+arrows` focus that doesn't
disappear behind a maximized column.

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

A bar icon opens a popup explaining the mode with a toggle to switch it on
or off, styled with Omarchy's native panel components (`Panel`, `PanelHero`,
`Ui.Toggle`).

## Install

1. Copy the Quickshell plugin into your user plugins directory (pick your
   own id, e.g. `<username>.omari`):

   ```bash
   mkdir -p ~/.config/omarchy/plugins/<username>.omari
   cp manifest.json Panel.qml OmariIcon.qml ~/.config/omarchy/plugins/<username>.omari/
   ```

   Edit `id` in `manifest.json` to match the directory name if you change it.

2. Copy the Hyprland mode file and the toggle script:

   ```bash
   cp hypr/omari-mode.lua ~/.config/hypr/omari-mode.lua
   cp bin/omari-mode-toggle ~/.config/omarchy/bar/scripts/omari-mode-toggle
   chmod +x ~/.config/omarchy/bar/scripts/omari-mode-toggle
   ```

3. Rescan and enable the plugin:

   ```bash
   omarchy-shell shell rescanPlugins
   omarchy plugin enable <username>.omari --section left
   ```

## How it works

- `hypr/omari-mode.lua` is not loaded directly. Toggling copies it into
  `~/.local/state/omarchy/toggles/hypr/omari-mode.lua`, a directory
  Omarchy's default toggle loader already sources on every Hyprland reload.
- `bin/omari-mode-toggle` flips that flag file's presence and runs
  `hyprctl reload`.
- `Panel.qml` shells out to the toggle script and polls the flag file's
  presence to reflect current state in the bar icon and popup.

## License

MIT
