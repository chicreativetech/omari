-- Omari Alt-Tab: niri's window switcher, on ALT+TAB.
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
-- ALT by default, and for a reason worth knowing before changing it: with
-- SUPER held instead, A, W and O -- the scope filter, the thing that makes
-- this niri's switcher and not just a nicer ALT+TAB -- are SUPER+A/W/O, keys
-- Omarchy binds to its own commands, so the filter is unreachable for exactly
-- the modifier the row was opened on. The binding is the user's either way
-- (the bar popup's Keys tab); ALT is what the switcher is built around.
--
-- What goes out is hl.dsp.event, which puts a single `custom>>...` line on
-- Hyprland's event socket, the socket the overlay is already listening to.
-- Deliberately NOT exec_cmd: that spawns a process, and a switcher that lags
-- the key that opened it by the length of a process spawn is a switcher you
-- stop using. Same channel the overview's gesture uses, for the same reason.
local function emit(msg)
  hl.dispatch(hl.dsp.event(msg))
end

-- ------------------------------------------------------------ the binding
--
-- Which keys open the switcher is the user's: the bar popup's Keys tab writes
-- ~/.config/omari/keybinds.conf and this reads it on every load. Read rather
-- than substituted in when the config is installed, so the copy in the toggles
-- directory is byte for byte the file that shipped whatever the binding is:
-- changing the shortcut is a `hyprctl reload`, never a re-run of omari-toggle,
-- and the binding outlives Alt-Tab being switched off and back on.
-- See bin/omari-keybind, which owns the file's format and the same default.
local DEFAULT_BIND = "ALT + TAB"

local function configured_bind(name, fallback)
  local home = os.getenv("HOME") or ""
  local config_home = os.getenv("XDG_CONFIG_HOME")
  if config_home == nil or config_home == "" then
    config_home = home .. "/.config"
  end

  local file = io.open(config_home .. "/omari/keybinds.conf", "r")
  if not file then
    return fallback
  end

  -- Last assignment wins, which is what the script writes and what its own
  -- reader does -- a file that somehow grew a duplicate reads the same on
  -- both sides.
  local value
  for line in file:lines() do
    local body = line:gsub("#.*", "")
    local key, raw = body:match("^%s*([%a_]+)%s*=%s*(.-)%s*$")
    if key == name and raw ~= "" then
      value = raw
    end
  end
  file:close()

  return value or fallback
end

-- The switcher is held up by its modifiers, so this file needs the binding
-- broken into the modifiers to watch and the key that steps the row -- not
-- just the string Hyprland binds. Both sides of each modifier, so the switcher
-- rides the right SUPER or ALT as readily as the left.
local MOD_HOLD_KEYS = {
  SUPER = { "Super_L", "Super_R" },
  META = { "Super_L", "Super_R" },
  WIN = { "Super_L", "Super_R" },
  CTRL = { "Control_L", "Control_R" },
  CONTROL = { "Control_L", "Control_R" },
  ALT = { "Alt_L", "Alt_R" },
  SHIFT = { "Shift_L", "Shift_R" },
}

local function parse_bind(spec)
  local mods, key = {}, nil
  for raw in spec:gmatch("[^+]+") do
    -- A fresh local rather than reassigning `raw`: Lua 5.4 makes a for-loop's
    -- control variable const, and trimming in place does not compile.
    local token = raw:match("^%s*(.-)%s*$"):upper()
    if token ~= "" then
      if MOD_HOLD_KEYS[token] then
        mods[#mods + 1] = token
      else
        key = token
      end
    end
  end
  return mods, key
end

local MODS, STEP_KEY = parse_bind(configured_bind("alttab", DEFAULT_BIND))
-- A binding with no key, or no modifier to hold the row up with, is not a
-- switcher. bin/omari-keybind refuses to write one, so this only catches a
-- hand-edited config -- and falling back beats binding nothing at all.
if not STEP_KEY or #MODS == 0 then
  MODS, STEP_KEY = parse_bind(DEFAULT_BIND)
end

-- The modifier the overlay is told about, so its own release handling watches
-- the same key this does. First one wins: in SUPER+ALT+TAB either would do,
-- and letting go of either ends the hold.
local HOLD_MOD = MODS[1]

local HOLD_KEYS = {}
do
  local seen = {}
  for _, mod in ipairs(MODS) do
    for _, keysym in ipairs(MOD_HOLD_KEYS[mod]) do
      if not seen[keysym] then
        seen[keysym] = true
        HOLD_KEYS[#HOLD_KEYS + 1] = keysym
      end
    end
  end
end

local function mods_held()
  for _, key in ipairs(HOLD_KEYS) do
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
-- The switcher is up "as long as the modifier is held", and something has to
-- notice the moment it is not. The overlay itself is the obvious candidate -- it takes an
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
  watching = false, -- whether a switcher is up and waiting on the release
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
  session.watching = false
  session.armed = false
  session.ticks = 0
  if session.timer then
    session.timer:set_enabled(false)
  end
end

local function tick()
  if not session.watching then
    return
  end
  if mods_held() then
    -- Arm on the first frame the modifier is genuinely seen down. Until then a
    -- "not held" reading means "cannot tell yet", not "let go" -- the bind
    -- fires on the step key's press, which can land a frame before the key
    -- state this reads has caught up, and committing on that would close the
    -- switcher in the same breath that opened it.
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

local function watch()
  session.watching = true
  session.armed = false
  session.ticks = 0
  -- One timer for the life of the config, enabled and disabled rather than
  -- created per switcher. HL.Timer can be turned off but not taken back, so a
  -- timer per switcher would be a slow leak of disabled timers.
  if not session.timer then
    session.timer = hl.timer(tick, { timeout = 30, type = "repeat" })
  end
  session.timer:set_enabled(true)
end

-- ------------------------------------------------------------------- binds
--
-- `dir` is the way the selection moves, passed through to the overlay: it is
-- the end that knows what is in the list, and this end does not need to. The
-- modifier rides along because the overlay watches for its release too -- it
-- has the keyboard grab, so it usually sees the release first -- and a
-- rebound switcher whose overlay was still waiting on ALT would be held up by
-- nothing but this watchdog. Appended, so an overlay from an older release
-- reading parts[2] is unaffected.
local function step(dir)
  return function()
    emit("omari:alttab step " .. dir .. " " .. HOLD_MOD)
    watch()
  end
end

local MOD_PREFIX = table.concat(MODS, " + ")
local FORWARD = MOD_PREFIX .. " + " .. STEP_KEY
-- SHIFT is how the row is walked backwards, so a binding that already holds
-- SHIFT has no backwards half -- there is no second SHIFT to add. The row
-- still reverses on the arrow keys, which the overlay handles itself.
local BACKWARD = nil
for _, mod in ipairs(MODS) do
  if mod == "SHIFT" then
    BACKWARD = false
  end
end
if BACKWARD == nil then
  BACKWARD = MOD_PREFIX .. " + SHIFT + " .. STEP_KEY
end

-- Omarchy binds ALT+TAB already -- twice over, cycle_next and bring_to_top --
-- and the point of this toggle is to replace it, so the binds this file is
-- about to take go first. Unbinding by key rather than by handle is
-- deliberate: these are somebody else's binds, and the key is the only thing
-- this file can know about them. Rebinding the switcher elsewhere therefore
-- gives ALT+TAB back to whoever had it, which is the right thing to happen.
hl.unbind(FORWARD)
if BACKWARD then
  hl.unbind(BACKWARD)
end

-- `repeating`, so holding the step key down runs along the row at the
-- keyboard's own repeat rate instead of stopping on the second window. That is
-- what the key does in every other switcher, and the row is exactly the thing
-- you want to travel along.
o.bind(FORWARD, "Switch windows", step("next"), { repeating = true })
if BACKWARD then
  o.bind(BACKWARD, "Switch windows (backwards)", step("prev"), { repeating = true })
end

-- The overlay closing for a reason of its own -- Escape, a click, a commit it
-- made itself -- says so, so the watchdog stops polling for a release nobody
-- is waiting on any more. Sent from QML as a plain dispatch of this function;
-- it returns a no-op dispatcher because `hyprctl dispatch <lua>` evaluates its
-- argument as `hl.dispatch(...)` and wants a dispatcher back.
function omari_alttab_closed()
  stop_watch()
  return hl.dsp.no_op()
end
