-- ciallo.lua (v1.1)
-- Plays "Ciallo～(∠・ω- )⌒☆" whenever YOU push (hold block, press light attack).
-- Rapid pushes overlap: the WAV player keeps a pool of concurrent MCI voices.
local mod = get_mod("ciallo")
local AudioPlayer = Mods.file.dofile("ciallo/scripts/mods/ciallo/audio_player")

-- Where the sound lives. The option "sound_path" (Mod Options) overrides this.
local DEFAULT_SOUND_PATH = "D:/DshWorkSpace/Ciallo～(∠・ω- )⌒☆.wav"
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

-- Is the unit that is performing the action our own local player?
local function is_local_player_unit(action_self)
    local player_unit = action_self and action_self._player_unit
    if not player_unit then
        return false
    end
    local local_player = Managers.player and Managers.player:local_player(1)
    local local_unit = local_player and local_player.player_unit
    if local_unit == player_unit then
        return true
    end
    -- fallback: the action's player channel is the local one
    local player = action_self._player
    return player ~= nil and local_player ~= nil and player == local_player
end

local function on_push_start(action_self)
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

local function patch()
    local ok, ActionPush = pcall(require, "scripts/extension_systems/weapon/actions/action_push")
    if not ok or type(ActionPush) ~= "table" then
        mod:warning("Could not load ActionPush (game update changed it?). Push sound disabled. Error: " .. tostring(ActionPush))
        return false
    end
    if type(ActionPush.start) ~= "function" then
        mod:warning("ActionPush has no 'start' method. Push sound disabled.")
        return false
    end
    local hooked = pcall(mod.hook_safe, mod, ActionPush, "start", on_push_start)
    if not hooked then
        mod:warning("Could not hook ActionPush.start. Push sound disabled.")
        return false
    end
    mod:info("Ciallo push sound armed. Sound: " .. tostring(resolve_sound_path() or "FILE MISSING"))
    return true
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
