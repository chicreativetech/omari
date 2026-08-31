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

-- Vertical 3-finger swipes are NOT registered here. input.lua already owns
-- that gesture, and it loads before this file (hyprland.lua requires
-- hypr.input at line 20, default.hypr.toggles at line 26), so a second
-- registration is shadowed by the first and Hyprland warns about it:
--   "gesture will be overshadowed by a previous gesture.
--    previous VERTICAL shadows new VERTICAL"
-- The split is deliberate and input.lua says so from its side: vertical
-- switches workspaces whatever the layout, so it belongs in the always-on
-- config, while the horizontal swipe above only means anything while the
-- scrolling layout is active, so it belongs here.

-- Omarchy ships the "workspaces" animation leaf disabled (instant switch,
-- no slide) since its default SUPER+number switching has no swipe direction
-- to match. Workspace switching here is a vertical swipe (input.lua's
-- gesture), so the switch should animate along that same axis -- same
-- style/speed/bezier Omarchy already uses for the (also
-- vertical-swipe-driven) specialWorkspace animation.
hl.animation({ leaf = "workspaces", enabled = true, speed = 3, bezier = "easeOutQuint", style = "slidevert" })

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

-- Workspaces are the vertical axis of this mode: the 3-finger vertical swipe
-- (input.lua) switches them, the overview stacks them as rows scrolling down,
-- and the animation above slides them vertically. Page Down/Up is the keyboard
-- version of that same axis -- Down goes to the next workspace, Up to the
-- previous, matching where the swipe and the overview put them.
--
-- Omarchy already has SUPER+TAB / SUPER+SHIFT+TAB for the same dispatch; these
-- are an addition, not a replacement, so both keep working. SUPER is required:
-- a bare Page_Down would be grabbed compositor-wide and stop paging in every
-- editor, browser and terminal. SUPER+PAGE_DOWN/PAGE_UP are unbound in
-- Omarchy's defaults, so there is nothing to unbind first.
--
-- "e+1"/"e-1" (not "+1"/"-1") is the same dispatch Omarchy's own next/previous
-- workspace bindings use: it walks only workspaces that exist, plus one empty
-- one at the end, instead of running off into empty workspace 11, 12, 13.
o.bind("SUPER + Page_Down", "Next workspace", hl.dsp.focus({ workspace = "e+1" }))
o.bind("SUPER + Page_Up", "Previous workspace", hl.dsp.focus({ workspace = "e-1" }))
