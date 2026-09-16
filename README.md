# Omari — Niri-inspired navigation for Omarchy

If you like the Niri wayland compositor but don't want to leave the cool world of Omarchy. Omari adds Niri-inspired scrolling, gestures, Workspace overview and Alt-Tab switcher of course styled with your Omarchy theme.

## Screenshots

### Scrolling desktop

![Omari desktop with horizontally arranged window columns](assets/omari.png)

### Workspace overview

![Omari overview with vertically arranged workspaces and window previews](assets/omari-overview.png)

### Alt-Tab switcher

![Omari Alt-Tab switcher with window previews and scope filters](assets/omari-alttab.png)

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

The bar popup has two tabs. **Info** says what Omari is and carries all three
switches — **Enable Omari**, the overview, and Alt-Tab — each under the
sentence describing what it turns on. **Keys** carries the shortcuts, one field
per feature that is switched on, plus the overview's **Reverse scroll direction
in overview** switch.

### Keyboard shortcuts

`SUPER` is the Windows/Command key. Enable the corresponding Omari feature
in the bar popup to use its shortcuts.

**Desktop navigation**

| Shortcut | Action |
| --- | --- |
| SUPER+Left / Right | Focus the previous / next window column |
| SUPER+Up / Down | Focus the window above / below within a column |
| SUPER+PageDown | Go to the next workspace |
| SUPER+PageUp | Go to the previous workspace |
| SUPER+ALT+O | Open the overview (configurable) |
| ALT+Tab | Open the window switcher and select the next window (configurable) |
| ALT+SHIFT+Tab | Open the window switcher and select the previous window |

The arrow keys follow the layout the focused workspace is running. Omarchy's
SUPER+L still flips a single workspace back to dwindle while Omari mode is on,
and there they behave exactly as they do in stock Omarchy.

**While the overview is open**

| Shortcut | Action |
| --- | --- |
| Up / Down | Select the previous / next workspace row |
| Left / Right | Select the previous / next window in the row |
| Enter or Space | Activate the selected window or empty workspace |
| SUPER+ALT+O | Activate the selection and close the overview |
| Escape | Cancel and return to the original desktop |

**While the Alt-Tab switcher is open**

Keep `ALT` held while browsing or changing the scope.

| Shortcut | Action |
| --- | --- |
| Tab / SHIFT+Tab | Select the next / previous window |
| Left / Right | Select the previous / next window |
| A | Show windows from all workspaces |
| W | Show windows from the current workspace |
| O | Show windows from the current display |
| Release ALT | Activate the selected window |
| Enter or Space | Activate the selected window immediately |
| Escape | Cancel without switching windows |

### Changing the shortcuts

The overview's and Alt-Tab's shortcuts are editable in the popup's **Keys**
tab, under each feature's heading (the feature has to be switched on in
**Info** for its field to show). Type modifiers and a key separated by `+`
(`SUPER + ALT + O`, `CTRL + ALT + TAB`) and press Enter or click the check
button beside the field; the restore button next to it puts the default back.
A shortcut needs at least one modifier, because both features are
held-modifier shortcuts — the Alt-Tab switcher stays up for exactly as long as
its modifier does, and the row is walked backwards by adding `SHIFT`.

Shortcuts are stored in `${XDG_CONFIG_HOME:-$HOME/.config}/omari/keybinds.conf`
and read by `hypr/omari-overview.lua` and `hypr/omari-alttab.lua` on every
Hyprland reload, so they survive a feature being switched off and back on. The
same edits from a terminal:

```sh
cd "$HOME/.config/omarchy/plugins/bergdahlchi.omari"
bash bin/omari-keybind overview set 'SUPER + ALT + O'
bash bin/omari-keybind alttab reset
bash bin/omari-keybind alttab get
```

Rebinding Alt-Tab elsewhere hands `ALT+Tab` back to Omarchy's own bindings.
`ALT` is the default for a reason worth knowing before moving it: on `SUPER`,
the switcher's `A` / `W` / `O` scope filters collide with Omarchy's own
`SUPER+A/W/O` bindings and never reach the switcher.

### Reversing the overview's scroll direction

**Keys** > **Overview** > **Reverse scroll direction in overview** flips what a
two-finger swipe means inside the overview, on both axes at once. Off, the swipe
moves the content under your fingers: push up and the stack of workspaces comes
up with you, push left and the strip of windows goes left. On, both axes answer
the opposite way — which is the right setting if the rest of your desktop is on
natural scrolling and this one reads backwards. The mouse wheel is deliberately
left alone either way: a notch is a request to go somewhere rather than a grip
on the content, and it keeps the sense every other wheel on the machine has.

The setting lives in `${XDG_CONFIG_HOME:-$HOME/.config}/omari/settings.conf` as
`overview-reverse-scroll = on|off` and the overview watches that file, so a hand
edit takes effect as it is saved — no reload, and no Hyprland involved, since
this one never leaves the shell.

### Gestures and mouse

| Control | Action |
| --- | --- |
| Three-finger horizontal swipe | Scroll along window columns |
| Three-finger vertical swipe | Change workspace |
| Four-finger swipe up | Open the overview |
| Four-finger swipe down in the overview | Activate the selection and close the overview |
| Two-finger scrolling in the overview | Browse workspaces vertically or windows horizontally (direction is switchable, see above) |
| Click a window preview | Activate that window |
| Click the empty workspace in the overview | Switch to that workspace |

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
bash -n bin/omari-toggle bin/omari-keybind
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
