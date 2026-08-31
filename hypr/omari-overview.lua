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

-- The swipe does not *trigger* the opening zoom, it *is* the opening zoom.
--
-- hl.gesture takes a table of start/update/finish callbacks as its action
-- (Hyprland 0.56, src/config/lua/bindings/LuaBindingsConfigRules.cpp) and
-- calls them for every trackpad event of the gesture, not just once when it
-- completes. That is what makes a stageless overview possible at all: the
-- overlay can be handed the fingers' position frame by frame and pull back
-- under them, instead of playing a fixed animation once they lift.
--
-- Each callback gets the event as a table -- `delta` is the *per-event*
-- delta, not the running total (ITrackpadGesture::distance does the
-- accumulating for Hyprland's built-in gestures; a Lua one has to do its
-- own), and `time_ms` is the event's own timestamp. Upward finger motion is
-- negative y, so travel is accumulated by subtracting it.
--
-- What goes out is hl.dsp.event, which puts a single `custom>>...` line on
-- Hyprland's event socket -- the socket the overlay is already listening to.
-- Deliberately NOT exec_cmd: that spawns a process, and this runs at touchpad
-- rate.
--
-- Only the raw travel is sent. Turning pixels into a fraction of a zoom
-- wants the height of the screen and the state of the overview, and both of
-- those live at the other end.
local travel = 0

local function emit(msg)
  hl.dispatch(hl.dsp.event(msg))
end

local function report(e)
  travel = travel - e.delta.y
  emit(string.format("omari:overview-at %.1f %d", travel, e.time_ms))
end

-- Registered as "up", not "vertical", so a downward 4-finger swipe still
-- matches nothing and does nothing, exactly as before. It does not stop a
-- swipe being *reversed*: CTrackpadGestures::gestureUpdate picks the matching
-- gesture once, on the first 5px of travel, and keeps feeding this one every
-- event afterwards whichever way the fingers then go -- which is what lets a
-- half-opened overview be pushed back down and cancelled without lifting.
hl.gesture({
  fingers = 4,
  direction = "up",
  action = {
    start = function(e)
      travel = 0
      emit("omari:overview-begin")
      report(e)
    end,
    update = report,
    finish = function(e)
      -- Whether the swipe went far or fast enough to commit is decided at the
      -- other end, which is the end that knows how far the zoom actually got.
      -- All that is reported here is whether the gesture was abandoned rather
      -- than finished, and when the fingers actually lifted -- the second
      -- because a touchpad sends updates only while something is moving, so
      -- the gap between the last one and this is the only way to tell a swipe
      -- still travelling at the release from one that came to rest on the pad
      -- first and then let go.
      emit(string.format("omari:overview-end %d %d", e.cancelled and 1 or 0, e.time_ms))
      travel = 0
    end,
  },
})

-- Keyboard equivalent of the swipe, for when your hands are on the keys.
-- Not SUPER+CTRL+O: Omarchy already binds that to "Toggle menu". SUPER+O,
-- SUPER+SHIFT+O and SUPER+CTRL+O are all taken; SUPER+ALT+O is free and
-- keeps O for "overview". Lives here rather than in bindings.lua so it
-- appears and disappears with the overview toggle itself.
o.bind("SUPER + ALT + O", "Overview", "omarchy-shell shell toggle bergdahlchi.omari")
