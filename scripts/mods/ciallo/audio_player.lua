-- audio_player.lua (v2)
-- Plays a local audio file from the game's Lua using LuaJIT FFI into winmm.dll.
-- WAV: MCI waveaudio alias POOL -> real polyphony (rapid pushes overlap).
-- MP3/other: single MCI instance (restarts on each push).
local M = { available = false, last_error = nil }

local ffi = Mods and Mods.lua and Mods.lua.ffi
if ffi and type(ffi.load) == "function" and type(ffi.cdef) == "function" and type(ffi.new) == "function" then
    local cdef_ok = pcall(ffi.cdef, [[
        unsigned int __stdcall PlaySoundW(const wchar_t* pszSound, void* hmod, unsigned int fdwSound);
        int __stdcall mciSendStringW(const wchar_t* lpstrCommand, wchar_t* lpstrReturnString, unsigned int uReturnLength, void* hwndCallback);
        int __stdcall mciGetErrorStringW(unsigned int mciError, wchar_t* lpstrBuffer, unsigned int uLength);
    ]])
    if cdef_ok then
        local load_ok, winmm = pcall(ffi.load, "winmm")
        if load_ok and winmm then
            M.winmm = winmm
            M.available = true
        else
            M.last_error = "winmm.dll could not be loaded: " .. tostring(winmm)
        end
    else
        M.last_error = "ffi.cdef failed"
    end
else
    M.last_error = "Mods.lua.ffi is not available"
end

-- Pool of concurrently-playing waveaudio instances for WAV files.
M.pool_size = 4
M._wav_path = nil
M._wav_aliases = {}
M._wav_cursor = 0
M._mp3_alias = nil
M._volume = 100

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

local function mci_error_string(err_code)
    if not err_code or err_code == 0 then
        return "ok"
    end
    local buf = ffi.new("wchar_t[256]")
    M.winmm.mciGetErrorStringW(err_code, buf, 256)
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
    return M.winmm.mciSendStringW(cmd_w, nil, 0, nil)
end

local function play_sound_fallback(path)
    -- Single-shot fallback via PlaySound (async). No overlap.
    local path_w = to_utf16(path)
    local SND_FILENAME = 0x0001
    local SND_NODEFAULT = 0x0002
    local SND_ASYNC = 0x0008
    return M.winmm.PlaySoundW(path_w, nil, SND_FILENAME + SND_NODEFAULT + SND_ASYNC) ~= 0
end

local function set_alias_volume(alias_name)
    local percent = math.max(0, math.min(100, M._volume or 100))
    mci("setaudio " .. alias_name .. " volume to " .. math.floor(percent * 10))
end

-- Open a pool of aliases for the given WAV path (one waveaudio instance each).
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

function M.play(path)
    if not M.available then
        M.last_error = "audio player unavailable"
        return false
    end
    if not path or path == "" then
        M.last_error = "no sound path configured"
        return false
    end

    if ends_with(path, ".wav") then
        if not ensure_wav_pool(path) then
            -- Last-resort single shot (no overlap, but plays at least).
            return play_sound_fallback(path)
        end
        M._wav_cursor = M._wav_cursor % #M._wav_aliases + 1
        local alias_name = M._wav_aliases[M._wav_cursor]
        local rc = mci("play " .. alias_name .. " from 0")
        if rc ~= 0 then
            M.last_error = "MCI play failed (" .. mci_error_string(rc) .. ")"
            return false
        end
        return true
    end

    -- MP3 / other formats: one instance, restart on each push.
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

function M.set_volume(percent)
    M._volume = tonumber(percent) or 100
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
    if size ~= M.pool_size then
        M.pool_size = size
        M.close_wav_pool()
    end
end

function M.close_wav_pool()
    for i = 1, #M._wav_aliases do
        mci("close " .. M._wav_aliases[i])
    end
    M._wav_aliases = {}
    M._wav_path = nil
    M._wav_cursor = 0
end

function M.close()
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

return M
