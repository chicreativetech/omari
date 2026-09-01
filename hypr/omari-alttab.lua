-- Omari Alt-Tab: niri's window switcher, on ALT+TAB and SUPER+TAB.
--
-- This file is NOT loaded directly, and does not need to be copied anywhere.
-- It ships inside the Omari plugin directory; turning Alt-Tab on (the bar
-- popup's switch, or bin/omari-toggle alttab on) copies it into
-- ~/.local/state/omarchy/toggles/hypr/omari-alttab.lua, a directory Omarchy's
-- default toggle loader (default.hypr.toggles, required from hyprland.lua)
-- already sources on every reload -- see
-- /usr/share/omarchy/default/hypr/toggles.lua.
--
-- What is here is only the half that has to live in the compositor: which keys
-- open the switcher, and when the modifier holding it up is let go. The list,
-- the thumbnails, the scope filter and the focus dispatch are all at the other
-- end, in OmariAltTab.qml -- see the comments there.
--
-- What goes out is hl.dsp.event, which puts a single `custom>>...` line on
-- Hyprland's event socket, the socket the overlay is already listening to.
-- Deliberately NOT exec_cmd: that spawns a process, and a switcher that lags
-- the key that opened it by the length of a process spawn is a switcher you
-- stop using. Same channel the overview's gesture uses, for the same reason.
local function emit(msg)
  hl.dispatch(hl.dsp.event(msg))
end

-- The two keys each modifier can be held down with. Both are checked, so the
-- switcher rides the right Alt as readily as the left one.
local mod_keys = {
  alt = { "Alt_L", "Alt_R" },
  super = { "Super_L", "Super_R" },
}

local function mod_held(which)
  for _, key in ipairs(mod_keys[which] or {}) do
    -- pcall because is_key_down is asked about a keysym name: a layout that
    -- does not have one would otherwise take the watchdog down with it, and
    -- the watchdog is the safety net rather than the mechanism.
    local ok, down = pcall(hl.is_key_down, key)
    if ok and down then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------- the hold
--
-- The switcher is up "as long as ALT is held", and something has to notice the
-- moment it is not. The overlay itself is the obvious candidate -- it takes an
-- exclusive keyboard grab while it is up, so the release is delivered to it --
-- and it does listen for exactly that. This is the second, independent answer
-- to the same question, and it is here because the first one depends on a
-- grab: if the grab is late, or the release is swallowed on its way to Qt, the
-- overlay would sit there holding the whole keyboard with no way to know the
-- key it is waiting for has already come back up.
--
-- Polling rather than a release keybind. `bindr` on a bare modifier is exactly
-- the case Hyprland's bind matching is worst at -- the modmask a release is
-- tested against no longer contains the modifier being released -- while
-- hl.is_key_down reads the keyboard's own state and has no opinion about
-- masks. 30ms is a third of a frame at 100Hz: the commit is not perceptibly
-- behind the finger, and it only runs while the switcher is actually up.
local session = {
  mod = nil, -- "alt"/"super" while the switcher is up, nil otherwise
  armed = false, -- whether the modifier has been *seen* held at least once
  ticks = 0,
  timer = nil,
}

-- How long the watchdog waits to see the modifier held before giving up on
-- ever seeing it. Reached only if is_key_down cannot answer for this keyboard
-- at all, in which case the overlay's own key handling is the whole story and
-- a timer polling forever is nothing but load. Two seconds at 30ms.
local ARM_DEADLINE = 66

local function stop_watch()
  session.mod = nil
  session.armed = false
  session.ticks = 0
  if session.timer then
    session.timer:set_enabled(false)
  end
end

local function tick()
  if not session.mod then
    return
  end
  if mod_held(session.mod) then
    -- Arm on the first frame the modifier is genuinely seen down. Until then a
    -- "not held" reading means "cannot tell yet", not "let go" -- the bind
    -- fires on the Tab press, which can land a frame before the key state this
    -- reads has caught up, and committing on that would close the switcher in
    -- the same breath that opened it.
    session.armed = true
    return
  end
  session.ticks = session.ticks + 1
  if session.armed then
    stop_watch()
    emit("omari:alttab commit")
  elseif session.ticks >= ARM_DEADLINE then
    stop_watch()
  end
end

local function watch(which)
  session.mod = which
  session.armed = false
  session.ticks = 0
  -- One timer for the life of the config, enabled and disabled rather than
  -- created per switcher. HL.Timer can be turned off but not taken back, so a
  -- timer per ALT+TAB would be a slow leak of disabled timers.
  if not session.timer then
    session.timer = hl.timer(tick, { timeout = 30, type = "repeat" })
  end
  session.timer:set_enabled(true)
end

-- ------------------------------------------------------------------- binds
--
-- `which` is the modifier the switcher is riding on and `dir` the way the
-- selection moves, both passed through to the overlay: it is the end that
-- knows what is in the list, and this end does not need to.
local function step(which, dir)
  return function()
    emit("omari:alttab step " .. which .. " " .. dir)
    watch(which)
  end
end

-- Omarchy binds all four of these already -- ALT+TAB twice over (cycle_next
-- and bring_to_top), SUPER+TAB to the next workspace -- and the point of this
-- toggle is to replace them, so they go first. Unbinding by key rather than by
-- handle is deliberate: these are somebody else's binds, and the key is the
-- only thing this file can know about them.
--
-- SUPER+TAB's old meaning is not lost while this is on: omari-mode.lua binds
-- SUPER+PageDown/PageUp to the same next/previous workspace dispatch, and
-- Omarchy's own SUPER+CTRL+TAB ("Former workspace") is untouched.
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")

-- `repeating`, so holding TAB down runs along the row at the keyboard's own
-- repeat rate instead of stopping on the second window. That is what the key
-- does in every other switcher, and the row is exactly the thing you want to
-- travel along.
o.bind("ALT + TAB", "Switch windows", step("alt", "next"), { repeating = true })
o.bind("ALT + SHIFT + TAB", "Switch windows (backwards)", step("alt", "prev"), { repeating = true })
o.bind("SUPER + TAB", "Switch windows", step("super", "next"), { repeating = true })
o.bind("SUPER + SHIFT + TAB", "Switch windows (backwards)", step("super", "prev"), { repeating = true })

-- The overlay closing for a reason of its own -- Escape, a click, a commit it
-- made itself -- says so, so the watchdog stops polling for a release nobody
-- is waiting on any more. Sent from QML as a plain dispatch of this function;
-- it returns a no-op dispatcher because `hyprctl dispatch <lua>` evaluates its
-- argument as `hl.dispatch(...)` and wants a dispatcher back.
function omari_alttab_closed()
  stop_watch()
  return hl.dsp.no_op()
end
