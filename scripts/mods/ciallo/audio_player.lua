-- audio_player.lua (v3)
-- Plays a local audio file from the game's Lua.
-- Backend 1 (preferred): ciallo_sfx.dll - native waveOut polyphony (low latency).
-- Backend 2 (fallback):  MCI voice pool via LuaJIT FFI (winmm), real overlap.
local M = { available = false, last_error = nil, backend = nil }

local ffi = Mods and Mods.lua and Mods.lua.ffi
local winmm = nil

-- #############################################################
-- # Native backend (ciallo_sfx.dll)
-- #############################################################
local native = nil

local function try_load_native()
    if not (ffi and type(ffi.load) == "function" and type(ffi.cdef) == "function") then
        return false
    end
    local cdef_ok = pcall(ffi.cdef, [[
        int ciallo_available(void);
        const char* ciallo_error(void);
        int ciallo_init(int max_voices, int volume_percent);
        int ciallo_play(const char* utf8_path);
        void ciallo_set_volume(int percent);
        void ciallo_shutdown(void);
    ]])
    if not cdef_ok then
        return false
    end
    local ok, lib = pcall(ffi.load, "../mods/ciallo/bin/ciallo_sfx.dll")
    if not ok or not lib then
        return false
    end
    local ok_avail, avail = pcall(lib.ciallo_available)
    if not ok_avail or avail ~= 1 then
        return false
    end
    native = lib
    return true
end

-- #############################################################
-- # Fallback backend: MCI pool via FFI
-- #############################################################
local function init_ffi()
    if not (ffi and type(ffi.load) == "function" and type(ffi.cdef) == "function" and type(ffi.new) == "function") then
        M.last_error = "Mods.lua.ffi is not available"
        return false
    end
    local cdef_ok = pcall(ffi.cdef, [[
        unsigned int __stdcall PlaySoundW(const wchar_t* pszSound, void* hmod, unsigned int fdwSound);
        int __stdcall mciSendStringW(const wchar_t* lpstrCommand, wchar_t* lpstrReturnString, unsigned int uReturnLength, void* hwndCallback);
        int __stdcall mciGetErrorStringW(unsigned int mciError, wchar_t* lpstrBuffer, unsigned int uLength);
    ]])
    if not cdef_ok then
        M.last_error = "ffi.cdef failed"
        return false
    end
    local load_ok, w = pcall(ffi.load, "winmm")
    if not (load_ok and w) then
        M.last_error = "winmm.dll could not be loaded"
        return false
    end
    winmm = w
    return true
end

-- UTF-8 -> UTF-16 code units (pure Lua)
local function utf8_to_utf16_units(str)
    local units = {}
    local i = 1
    local len = #str
    while i <= len do
        local b = string.byte(str, i)
        local cp
        if b < 0x80 then
            cp = b
            i = i + 1
        elseif b < 0xE0 then
            cp = (b - 0xC0) * 0x40 + (string.byte(str, i + 1) - 0x80)
            i = i + 2
        elseif b < 0xF0 then
            cp = (b - 0xE0) * 0x1000 + (string.byte(str, i + 1) - 0x80) * 0x40 + (string.byte(str, i + 2) - 0x80)
            i = i + 3
        else
            cp = (b - 0xF0) * 0x40000 + (string.byte(str, i + 1) - 0x80) * 0x1000 + (string.byte(str, i + 2) - 0x80) * 0x40 + (string.byte(str, i + 3) - 0x80)
            i = i + 4
        end
        if cp >= 0x10000 then
            cp = cp - 0x10000
            units[#units + 1] = 0xD800 + bit.band(bit.rshift(cp, 10), 0x3FF)
            units[#units + 1] = 0xDC00 + bit.band(cp, 0x3FF)
        else
            units[#units + 1] = cp
        end
    end
    return units
end

local function to_utf16(str)
    local units = utf8_to_utf16_units(str)
    local buf = ffi.new("wchar_t[?]", #units + 1)
    for j = 1, #units do
        buf[j - 1] = units[j]
    end
    buf[#units] = 0
    return buf
end

local function ends_with(str, suffix)
    return str:sub(-#suffix):lower() == suffix:lower()
end

M.pool_size = 4
M._wav_path = nil
M._wav_aliases = {}
M._wav_cursor = 0
M._mp3_alias = nil
M._volume = 100

local function mci_error_string(err_code)
    if not err_code or err_code == 0 then
        return "ok"
    end
    local buf = ffi.new("wchar_t[256]")
    winmm.mciGetErrorStringW(err_code, buf, 256)
    local out = {}
    for k = 0, 255 do
        local c = buf[k]
        if c == 0 then
            break
        end
        if c < 0x80 then
            out[#out + 1] = string.char(c)
        elseif c < 0x800 then
            out[#out + 1] = string.char(0xC0 + bit.rshift(c, 6), 0x80 + bit.band(c, 0x3F))
        else
            out[#out + 1] = string.char(0xE0 + bit.rshift(c, 12), 0x80 + bit.band(bit.rshift(c, 6), 0x3F), 0x80 + bit.band(c, 0x3F))
        end
    end
    return table.concat(out)
end

local function mci(cmd)
    local cmd_w = to_utf16(cmd)
    return winmm.mciSendStringW(cmd_w, nil, 0, nil)
end

local function play_sound_fallback(path)
    local path_w = to_utf16(path)
    local SND_FILENAME = 0x0001
    local SND_NODEFAULT = 0x0002
    local SND_ASYNC = 0x0008
    return winmm.PlaySoundW(path_w, nil, SND_FILENAME + SND_NODEFAULT + SND_ASYNC) ~= 0
end

local function set_alias_volume(alias_name)
    local percent = math.max(0, math.min(100, M._volume or 100))
    mci("setaudio " .. alias_name .. " volume to " .. math.floor(percent * 10))
end

local function ensure_wav_pool(path)
    if M._wav_path == path and #M._wav_aliases > 0 then
        return true
    end
    M.close_wav_pool()
    M._wav_path = path
    for i = 1, math.max(1, M.pool_size) do
        local alias_name = "ciallo_wav_" .. i
        local rc = mci('open "' .. path .. '" type waveaudio alias ' .. alias_name)
        if rc == 0 then
            M._wav_aliases[#M._wav_aliases + 1] = alias_name
            set_alias_volume(alias_name)
        else
            M.last_error = "MCI open #" .. i .. " failed (" .. mci_error_string(rc) .. ")"
            break
        end
    end
    M._wav_cursor = 0
    return #M._wav_aliases > 0
end

local function ensure_mp3_alias(path)
    if M._mp3_alias then
        return true
    end
    local alias_name = "ciallo_mp3"
    local rc = mci('open "' .. path .. '" type mpegvideo alias ' .. alias_name)
    if rc ~= 0 then
        rc = mci('open "' .. path .. '" alias ' .. alias_name)
    end
    if rc == 0 then
        M._mp3_alias = alias_name
        set_alias_volume(alias_name)
        return true
    end
    M.last_error = "MCI open failed (" .. mci_error_string(rc) .. ")"
    return false
end

local function mci_play(path)
    if ends_with(path, ".wav") then
        if not ensure_wav_pool(path) then
            return play_sound_fallback(path)
        end
        M._wav_cursor = M._wav_cursor % #M._wav_aliases + 1
        local rc = mci("play " .. M._wav_aliases[M._wav_cursor] .. " from 0")
        if rc ~= 0 then
            M.last_error = "MCI play failed (" .. mci_error_string(rc) .. ")"
            return false
        end
        return true
    end
    if not ensure_mp3_alias(path) then
        return play_sound_fallback(path)
    end
    local rc = mci("play " .. M._mp3_alias .. " from 0")
    if rc ~= 0 then
        M.last_error = "MCI play failed (" .. mci_error_string(rc) .. ")"
        return false
    end
    return true
end

function M.close_wav_pool()
    for i = 1, #M._wav_aliases do
        mci("close " .. M._wav_aliases[i])
    end
    M._wav_aliases = {}
    M._wav_path = nil
    M._wav_cursor = 0
end

-- #############################################################
-- # Public API
-- #############################################################
if try_load_native() then
    M.backend = "native"
    M.available = true
elseif init_ffi() then
    M.backend = "mci"
    M.available = true
end

function M.play(path)
    if not M.available then
        return false
    end
    if not path or path == "" then
        M.last_error = "no sound path configured"
        return false
    end
    if M.backend == "native" then
        local rc = native.ciallo_play(path)
        if rc ~= 1 then
            local ok, err = pcall(native.ciallo_error)
            M.last_error = (ok and err) or "native play failed"
        end
        return rc == 1
    end
    return mci_play(path)
end

function M.set_volume(percent)
    M._volume = tonumber(percent) or 100
    if M.backend == "native" and native then
        pcall(native.ciallo_set_volume, M._volume)
        return
    end
    for i = 1, #M._wav_aliases do
        set_alias_volume(M._wav_aliases[i])
    end
    if M._mp3_alias then
        set_alias_volume(M._mp3_alias)
    end
end

function M.set_pool_size(size)
    size = tonumber(size) or 4
    if size < 1 then
        size = 1
    end
    if size == M.pool_size then
        return
    end
    M.pool_size = size
    if M.backend == "native" and native then
        -- re-init the voice pool with the new size
        pcall(native.ciallo_shutdown)
        pcall(native.ciallo_init, size, M._volume)
        return
    end
    M.close_wav_pool()
end

function M.close()
    if M.backend == "native" and native then
        pcall(native.ciallo_shutdown)
        return
    end
    M.close_wav_pool()
    if M._mp3_alias then
        mci("close " .. M._mp3_alias)
        M._mp3_alias = nil
    end
end

function M.file_exists(path)
    local io = Mods and Mods.lua and Mods.lua.io
    if not io or not io.open then
        return nil
    end
    local ok, f = pcall(io.open, path, "rb")
    if ok and f then
        f:close()
        return true
    end
    return false
end

-- Keep the native pool in sync at first use.
if M.backend == "native" and native then
    pcall(native.ciallo_init, M.pool_size, M._volume)
end

return M
