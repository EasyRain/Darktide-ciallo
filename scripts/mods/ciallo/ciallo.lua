-- ciallo.lua (v1.2)
-- Plays "Ciallo~" whenever YOUR push actually lands (the game executes the
-- push attack). Rapid pushes overlap: the WAV player keeps a pool of
-- concurrent MCI voices.
--
-- IMPORTANT (timing): we hook ActionPush._push, NOT ActionPush.start.
--   start  = the push ACTION begins (charges/wind-up; happens on button press,
--            even if the push will fail or be cancelled).
--   _push  = the game actually executes the push (reach damage_time on
--            fixed_update). It never runs for failed pushes (stamina broken /
--            staggered mid-block) or for charge-type pushes released early
--            (e.g. force swords: hold ~0.5s to charge, release early = cancel).
-- So hooking _push plays the sound only when a push really goes out.
local mod = get_mod("ciallo")
local AudioPlayer = Mods.file.dofile("ciallo/scripts/mods/ciallo/audio_player")

-- Default sound: a copy shipped inside the mod (assets/Ciallo~.wav).
-- Override it anytime with the "sound_path" option (absolute path allowed).
local DEFAULT_SOUND_PATH = "../mods/ciallo/assets/Ciallo~.wav"
local SOUND_ALIASES = { ".wav", ".mp3" }

local warned = false

local function dbg(fmt, ...)
    if mod:get("debug_logging") then
        mod:info("[dbg] " .. fmt, ...)
    end
end

-- Resolve the configured path; if the file is missing, try the same path with
-- .wav / .mp3 extensions swapped in (so converting the file just works).
local function resolve_sound_path()
    local configured = mod:get("sound_path")
    if configured == nil or configured == "" then
        configured = DEFAULT_SOUND_PATH
    end
    if AudioPlayer.file_exists(configured) then
        return configured
    end
    local base = configured:gsub("%.[Ww][Aa][Vv]$", ""):gsub("%.[Mm][Pp]3$", "")
    if base == configured then
        base = configured:gsub("%.[^.]*$", "")
    end
    for _, ext in ipairs(SOUND_ALIASES) do
        local candidate = base .. ext
        if AudioPlayer.file_exists(candidate) then
            return candidate
        end
    end
    return nil
end

local function play_push_sound()
    if not mod:is_enabled() then
        return
    end

    AudioPlayer.set_pool_size(mod:get("voices") or 4)
    AudioPlayer.set_volume(mod:get("volume") or 100)

    local path = resolve_sound_path()
    if not path then
        if not warned then
            warned = true
            mod:warning("Ciallo sound file not found. Check the 'sound_path' option. Looked for: " .. tostring(mod:get("sound_path") or DEFAULT_SOUND_PATH))
        end
        return
    end

    if not AudioPlayer.available then
        if not warned then
            warned = true
            mod:warning("Audio player unavailable: " .. tostring(AudioPlayer.last_error))
        end
        return
    end

    dbg("playing push sound: %s", path)
    local ok = AudioPlayer.play(path)
    if not ok and not warned then
        warned = true
        mod:warning("Could not play sound: " .. tostring(AudioPlayer.last_error))
    end
end

-- Is the given unit our own local player?
local function is_local_unit(unit)
    if not unit then
        return false
    end
    local local_player = Managers.player and Managers.player:local_player(1)
    local local_unit = local_player and local_player.player_unit
    return local_unit == unit
end

-- Is the unit that is performing the action our own local player?
local function is_local_player_unit(action_self)
    local player_unit = action_self and action_self._player_unit
    if player_unit and is_local_unit(player_unit) then
        return true
    end
    -- fallback: the action's player channel is the local one
    local local_player = Managers.player and Managers.player:local_player(1)
    local player = action_self and action_self._player
    return player ~= nil and local_player ~= nil and player == local_player
end

-- Called when the push attack is actually executed (ActionPush._push ran).
-- start fires on button press (charge/wind-up begins) even for pushes that
-- will fail or be cancelled, so we deliberately listen to _push instead.
local function on_push_executed(action_self)
    if not mod:is_enabled() then
        return
    end
    if not is_local_player_unit(action_self) then
        return
    end
    -- skip prediction re-simulation so the sound plays once per real push
    local unit_data_extension = action_self and action_self._unit_data_extension
    if unit_data_extension and unit_data_extension.is_resimulating then
        return
    end
    play_push_sound()
end

-- Fallback hook: PushAttack.push is the lowest level "the push really went
-- out" call (physics + damage). It only runs on non-resimulating executions,
-- so no extra resimulating check is needed here.
local function on_push_attack_executed(...)
    if not mod:is_enabled() then
        return
    end
    -- PushAttack.push(physics_world, push_position, push_direction, rewind_ms,
    --                 power_level, push_settings, attacking_unit, is_predicted,
    --                 weapon_item, weak_push)
    local attacking_unit = select(7, ...)
    if not is_local_unit(attacking_unit) then
        return
    end
    play_push_sound()
end

-- Hook the point where the game actually executes the push.
-- Strategy (primary -> fallback):
--   1. ActionPush._push      - runs only when a push action reaches its
--                              damage_time (charged pushes: only when fully
--                              charged; failed/cancelled pushes never get here)
--   2. PushAttack.push       - lowest-level "push really went out" utility.
--                              Used as fallback in case a game update renames
--                              ActionPush internals.
local function patch()
    -- Primary: ActionPush._push
    local ok, ActionPush = pcall(require, "scripts/extension_systems/weapon/actions/action_push")
    if ok and type(ActionPush) == "table" and type(ActionPush._push) == "function" then
        local hooked = pcall(mod.hook_safe, mod, ActionPush, "_push", on_push_executed)
        if hooked then
            mod:info("Ciallo push sound armed (ActionPush._push). Backend: %s. Sound: %s", tostring(AudioPlayer.backend or "?"), tostring(resolve_sound_path() or "FILE MISSING"))
            return true
        end
        mod:warning("Could not hook ActionPush._push. Trying lower-level fallback.")
    elseif ok and type(ActionPush) == "table" then
        mod:warning("ActionPush has no '_push' method in this game version. Trying lower-level fallback.")
    else
        mod:warning("Could not load ActionPush (game update changed it?). Trying lower-level fallback. Error: " .. tostring(ActionPush))
    end

    -- Fallback: PushAttack.push
    local ok2, PushAttack = pcall(require, "scripts/utilities/attack/push_attack")
    if ok2 and type(PushAttack) == "table" and type(PushAttack.push) == "function" then
        local hooked2 = pcall(mod.hook_safe, mod, PushAttack, "push", on_push_attack_executed)
        if hooked2 then
            mod:info("Ciallo push sound armed (PushAttack.push fallback). Backend: %s. Sound: %s", tostring(AudioPlayer.backend or "?"), tostring(resolve_sound_path() or "FILE MISSING"))
            return true
        end
        mod:warning("Could not hook PushAttack.push. Push sound disabled.")
        return false
    end

    mod:warning("Could not find any push hook target (ActionPush / PushAttack). Push sound disabled.")
    return false
end

-- Called by the "Test sound" button in Mod Options.
function mod.play_test_sound()
    play_push_sound()
end

-- Called when the sound_path option is edited.
function mod.on_sound_path_changed()
    warned = false
    AudioPlayer.close() -- reopen with the new file on next push
    dbg("sound path changed to: %s", tostring(mod:get("sound_path")))
end

function mod.on_all_mods_loaded()
    if mod:is_enabled() then
        patch()
    end
end

function mod.on_enabled(initial_call)
    if not initial_call then
        patch()
    end
end

function mod.on_disabled()
    AudioPlayer.close()
end

function mod.on_unload()
    AudioPlayer.close()
end

mod.on_setting_changed = function(setting_id)
    if setting_id == "sound_path" then
        mod.on_sound_path_changed()
    elseif setting_id == "volume" then
        AudioPlayer.set_volume(mod:get("volume") or 100)
    elseif setting_id == "voices" then
        AudioPlayer.set_pool_size(mod:get("voices") or 4)
    end
end

if mod:is_enabled() then
    AudioPlayer.close() -- ensure a clean MCI state on reload
end
