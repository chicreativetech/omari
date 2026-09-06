# Omari — Niri-inspired navigation for Omarchy

Omari brings horizontal scrolling columns, a vertically arranged workspace
overview, and a live Alt-Tab switcher to Omarchy's Hyprland desktop.
It uses the current Omarchy palette, font, spacing, wallpaper, and corner
rounding. Niri supplies the navigation inspiration; Omari runs on Hyprland.

## Requirements

- Omarchy with the Quattro shell and `omarchy plugin` commands.
- Hyprland with Lua configuration, the scrolling layout, gesture callbacks,
  `hl.timer`, and `hl.is_key_down` support (the Lua APIs used by this plugin).
- Omarchy's default Hyprland toggle loader (`default.hypr.toggles`).
- Quickshell with QtQuick, QtQuick.Controls, QtQuick.Effects, Quickshell.Io,
  Quickshell.Wayland, and Quickshell.Hyprland, plus Omarchy's `qs.Commons` and
  `qs.Ui` modules.
- Bash, coreutils, and `hyprctl`, supplied by Omarchy. A multitouch trackpad is
  needed for gestures; keyboard controls also work.

Older Hyprland installations using only `hyprland.conf` are not supported.
There is no Niri dependency, remote build, package installer, extra service,
network request, or privileged command. The plugin runs inside the existing
Omarchy shell process with your user permissions.

## Install

```sh
omarchy plugin add https://github.com/chicreativetech/omari.git --enable
omarchy bar move bergdahlchi.omari --section left
```

Click the Omari bar icon and turn on **Enable Omari**. This also enables
the overview and Alt-Tab; each can then be switched off separately.
Right-clicking the icon toggles the mode directly.

Enabling mode copies the three bundled `hypr/omari-*.lua` files into
`${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/toggles/hypr/` and reloads
Hyprland. These files persist across login. They change the layout, gestures,
animations, and navigation bindings, including Omarchy's Alt-Tab bindings.
Review `hypr/` for the full configuration; custom bindings may conflict.
Existing configuration files are not edited.

## Controls

| Action | Control |
| --- | --- |
| Move along window columns | Three-finger horizontal swipe or SUPER+arrows |
| Change workspace | Three-finger vertical swipe or SUPER+PageDown/PageUp |
| Toggle overview | Four-finger swipe up or SUPER+ALT+O |
| Browse overview | Two-finger scrolling, arrow keys, or click a window |
| Close overview | Escape |
| Switch windows | Hold ALT, press Tab (SHIFT reverses), release ALT |
| Filter switcher | A: all windows, W: workspace, O: display |

## Disable and remove

Turn off **Enable Omari** before disabling or removing the plugin.
For explicit cleanup, including when the shell is not running:

```sh
bash "$HOME/.config/omarchy/plugins/bergdahlchi.omari/bin/omari-toggle" all off
omarchy plugin remove bergdahlchi.omari
```

Cleanup deletes only Omari's generated toggle files and reloads Hyprland,
restoring the underlying configuration. If Hyprland is stopped, the next
session loads without those toggles. The loaded overlay also attempts cleanup
when the registry disables it; the explicit command above works without it.

## Development and publishing

Keep the permanent plugin ID `bergdahlchi.omari`. The root manifest declares
`Panel.qml` as the bar widget and `OmariOverview.qml` as the overlay; the latter
loads `OmariAltTab.qml` internally. Do not launch a second Quickshell process.

```sh
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" ./*.qml
bash -n bin/omari-toggle
for source in hypr/*.lua; do luac -p "$source"; done
```

On Arch, `qmllint` may be at `/usr/lib/qt6/bin/qmllint`. The shell's `qs.*`
imports must be resolvable by the linter. Inspect runtime errors with
`qs log -p "$OMARCHY_PATH/shell" --tail 100`.

Before release, test a fresh install, all toggles and controls, light and dark
themes, multiple displays, shell reload, and removal in a live Omarchy session.
Confirm that removal leaves no `omari-*.lua` toggle files. Update the manifest
version when releasing changes, and keep all plugin files free of symlinks.

Publishing requires a public GitHub repository with a valid root manifest,
README, and license. An actual desktop preview is optional. Follow the
[development guide](https://plugins.omarchy.org/develop.html) and
[publishing guide](https://plugins.omarchy.org/publish.html), then submit the
repository through the publishing guide's issue form for maintainer review.

## License

MIT — see [LICENSE](LICENSE).
