-- Omari mode: niri-like scrolling-layout mode.
--
-- This file is NOT loaded directly, and does not need to be copied anywhere.
-- It ships inside the Omari plugin directory; turning the mode on (the bar
-- popup's switch, or bin/omari-toggle mode on) copies it into
-- ~/.local/state/omarchy/toggles/hypr/omari-mode.lua, a directory Omarchy's
-- default toggle loader (default.hypr.toggles, required from hyprland.lua)
-- already sources on every reload -- see /usr/share/omarchy/default/hypr/toggles.lua.

hl.config({
  general = {
    -- https://wiki.hypr.land/Configuring/Layouts/Scrolling-Layout/
    layout = "scrolling",
  },

  scrolling = {
    -- Half-width columns, so you see a sliver of neighboring windows
    -- (like niri) instead of one window filling the whole screen.
    column_width = 0.5,
  },
})

-- Horizontal 3-finger swipe scrolls the scrolling-layout "tape" live,
-- sliding all of this workspace's windows left/right under your fingers.
-- Only meaningful while this layout is active, so it lives here rather
-- than in input.lua.
hl.gesture({ fingers = 3, direction = "horizontal", action = "scroll_move" })

-- Omarchy's default SUPER+arrows use hl.dsp.focus({direction=...}), the
-- classic movefocus dispatcher. It no-ops when the active column is
-- fullscreened/maximized ("Full width", SUPER+ALT+F) -- it won't move to
-- neighboring columns at all, which is what made them "disappear" until
-- you un-maximized. hl.dsp.layout("focus l/r/u/d") is the scrolling
-- layout's own layout-aware focus command: it moves to the next column
-- (or window within a column, for u/d) and brings it into view even when
-- the current column is maximized, without clearing that column's
-- maximized state -- the same effect the 3-finger swipe already has.
hl.unbind("SUPER + LEFT")
hl.unbind("SUPER + RIGHT")
hl.unbind("SUPER + UP")
hl.unbind("SUPER + DOWN")
o.bind("SUPER + LEFT", "Focus on left window", hl.dsp.layout("focus l"))
o.bind("SUPER + RIGHT", "Focus on right window", hl.dsp.layout("focus r"))
o.bind("SUPER + UP", "Focus on above window", hl.dsp.layout("focus u"))
o.bind("SUPER + DOWN", "Focus on below window", hl.dsp.layout("focus d"))
