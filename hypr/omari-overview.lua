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

-- The swipe does not *trigger* the zoom, it *is* the zoom, in both directions.
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
-- own), and `time_ms` is the event's own timestamp.
--
-- What goes out is hl.dsp.event, which puts a single `custom>>...` line on
-- Hyprland's event socket -- the socket the overlay is already listening to.
-- Deliberately NOT exec_cmd: that spawns a process, and this runs at touchpad
-- rate.
--
-- Only the raw travel is sent. Turning pixels into a fraction of a zoom
-- wants the height of the screen and the state of the overview, and both of
-- those live at the other end.
local function emit(msg)
  hl.dispatch(hl.dsp.event(msg))
end

-- Both directions report the same three things about themselves and differ
-- only in which way counts as forward, so they are the same tracker twice.
-- `sign` turns the axis into travel that grows as the gesture proceeds: up is
-- negative y, down is positive.
local function tracker(prefix, sign)
  local travel = 0

  local function report(e)
    travel = travel + sign * e.delta.y
    emit(string.format("%s-at %.1f %d", prefix, travel, e.time_ms))
  end

  return {
    start = function(e)
      travel = 0
      emit(prefix .. "-begin")
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
      emit(string.format("%s-end %d %d", prefix, e.cancelled and 1 or 0, e.time_ms))
      travel = 0
    end,
  }
end

-- Two gestures rather than one "vertical", so each direction keeps its own
-- travel and its own meaning. Hyprland allows the pair: addGesture only
-- refuses a registration whose axis collides with an existing one for the same
-- finger count, and UP and DOWN collide with neither each other nor VERTICAL.
--
-- Registering them separately does not stop either being *reversed* mid-swipe:
-- CTrackpadGestures::gestureUpdate picks the matching gesture once, on the
-- first 5px of travel, and keeps feeding that one every event afterwards
-- whichever way the fingers then go. So a half-opened overview can be pushed
-- back down and cancelled, and a half-completed dive pushed back up, without
-- ever lifting.
--
-- Up opens the overview and nothing else: swiping further up on one already
-- open is ignored, so the same stroke never means both "in" and "out". Down
-- dives into whatever the overview is centred on -- which is a workspace
-- switch as well as a zoom, and the far end has rather more to arrange for
-- it; see gestureDiveBegin.
hl.gesture({ fingers = 4, direction = "up", action = tracker("omari:overview", -1) })
hl.gesture({ fingers = 4, direction = "down", action = tracker("omari:overview-down", 1) })

-- Keyboard equivalent of the swipe, for when your hands are on the keys.
-- Not SUPER+CTRL+O: Omarchy already binds that to "Toggle menu". SUPER+O,
-- SUPER+SHIFT+O and SUPER+CTRL+O are all taken; SUPER+ALT+O is free and
-- keeps O for "overview". Lives here rather than in bindings.lua so it
-- appears and disappears with the overview toggle itself.
o.bind("SUPER + ALT + O", "Overview", "omarchy-shell shell toggle bergdahlchi.omari")
