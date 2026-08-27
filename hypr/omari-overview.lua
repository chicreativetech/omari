-- Omari overview: niri's "all apps" overview, opened with a 4-finger swipe
-- up or SUPER+ALT+O. Every workspace becomes a row, windows in that
-- workspace laid out side by side as thumbnails; scroll down for more
-- workspaces. Swipe/press again, click the background, or press Escape to
-- close it.
--
-- This file is NOT loaded directly, and does not need to be copied anywhere.
-- It ships inside the Omari plugin directory; turning the overview on (the
-- bar popup's switch, or bin/omari-toggle overview on) copies it into
-- ~/.local/state/omarchy/toggles/hypr/omari-overview.lua, a directory
-- Omarchy's default toggle loader (default.hypr.toggles, required from
-- hyprland.lua) already sources on every reload -- see
-- /usr/share/omarchy/default/hypr/toggles.lua.

hl.gesture({
  fingers = 4,
  direction = "up",
  action = function()
    hl.dispatch(hl.dsp.exec_cmd("omarchy-shell shell toggle bergdahlchi.omari"))
  end,
})

-- Keyboard equivalent of the swipe, for when your hands are on the keys.
-- Not SUPER+CTRL+O: Omarchy already binds that to "Toggle menu". SUPER+O,
-- SUPER+SHIFT+O and SUPER+CTRL+O are all taken; SUPER+ALT+O is free and
-- keeps O for "overview". Lives here rather than in bindings.lua so it
-- appears and disappears with the overview toggle itself.
o.bind("SUPER + ALT + O", "Overview", "omarchy-shell shell toggle bergdahlchi.omari")
