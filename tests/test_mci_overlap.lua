-- test_mci_overlap.lua -- the MCI fallback must keep a pool per file too.
--
--   luajit tests\test_mci_overlap.lua        (from the repository root)
--
-- The fallback used to hold a single alias pool and close it whenever the path changed, so
-- a random pick cut the previous sound off. Silent WAVs are written here, so this makes no
-- noise. Outside the game the native DLL is absent, so the module picks the MCI backend -
-- which is exactly the code under test; winmm is loaded for real by the module.

Mods = {
    lua = {
        ffi = require("ffi"),
        io = io,
        os = os,
        debug = debug,
        loadstring = loadstring,
    },
    file = {},
}

local AudioPlayer = dofile("scripts/mods/ciallo/audio_player.lua")

local failures = 0

local function check(what, ok, detail)
    print(string.format("[%s] %-50s %s", ok and "PASS" or "FAIL", what, detail or ""))
    if not ok then
        failures = failures + 1
    end
end

local function u32(n)
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function u16(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function write_silent_wav(path, channels, rate, bits, seconds)
    local samples = math.floor(rate * seconds)
    local block = channels * bits / 8
    local data = samples * block
    local header = "RIFF" .. u32(36 + data) .. "WAVE" .. "fmt " .. u32(16) ..
        u16(1) .. u16(channels) .. u32(rate) .. u32(rate * block) .. u16(block) .. u16(bits) ..
        "data" .. u32(data)
    local handle = assert(io.open(path, "wb"))
    handle:write(header)
    local chunk = string.rep(bits == 8 and "\128" or "\0", 4096)
    local left = data
    while left > 0 do
        local size = math.min(left, #chunk)
        handle:write(chunk:sub(1, size))
        left = left - size
    end
    handle:close()
end

local temp = os.getenv("TEMP") or "."
local path_a = temp .. "\\ciallo_mci_a.wav"
local path_b = temp .. "\\ciallo_mci_b.wav"
write_silent_wav(path_a, 2, 44100, 16, 1.0)
write_silent_wav(path_b, 2, 44100, 16, 1.0)

check("the fallback backend is in use", AudioPlayer.backend == "mci", tostring(AudioPlayer.backend))
check("A plays", AudioPlayer.play(path_a) == true, tostring(AudioPlayer.last_error))
check("A got its own pool",
    AudioPlayer._pools[path_a] ~= nil and #AudioPlayer._pools[path_a].aliases > 0,
    tostring(AudioPlayer._pools[path_a] and #AudioPlayer._pools[path_a].aliases))

check("B plays", AudioPlayer.play(path_b) == true, tostring(AudioPlayer.last_error))
check("A's pool survived B",
    AudioPlayer._pools[path_a] ~= nil and #AudioPlayer._pools[path_a].aliases > 0,
    tostring(AudioPlayer._pools[path_a] and #AudioPlayer._pools[path_a].aliases))
check("B has its own pool",
    AudioPlayer._pools[path_b] ~= nil and #AudioPlayer._pools[path_b].aliases > 0,
    tostring(AudioPlayer._pools[path_b] and #AudioPlayer._pools[path_b].aliases))

-- replaying A cycles its own voices and leaves B alone
local before = AudioPlayer._pools[path_a].cursor
AudioPlayer.play(path_a)
check("replaying A advances A's cursor", AudioPlayer._pools[path_a].cursor ~= before,
    before .. " -> " .. tostring(AudioPlayer._pools[path_a].cursor))
check("B still has its pool", AudioPlayer._pools[path_b] ~= nil, "")

-- the volume applies to every open pool
AudioPlayer.set_volume(35)
check("volume change keeps both pools", AudioPlayer._pools[path_a] ~= nil and AudioPlayer._pools[path_b] ~= nil, "")

-- over the cache limit the least recently used file is dropped, not the newest
for i = 1, AudioPlayer._pool_cache + 1 do
    local extra = temp .. "\\ciallo_mci_extra" .. i .. ".wav"
    write_silent_wav(extra, 2, 44100, 16, 0.2)
    AudioPlayer.play(extra)
end
local pools = 0
for _ in pairs(AudioPlayer._pools) do
    pools = pools + 1
end
check("the pool cache stays bounded", pools <= AudioPlayer._pool_cache, tostring(pools))

AudioPlayer.close()
check("close() drops every pool", next(AudioPlayer._pools) == nil, "")

os.remove(path_a)
os.remove(path_b)
for i = 1, AudioPlayer._pool_cache + 1 do
    os.remove(temp .. "\\ciallo_mci_extra" .. i .. ".wav")
end

if failures > 0 then
    print(string.format("\n%d CHECK(S) FAILED", failures))
    os.exit(1)
end
print("\nALL CHECKS PASSED")
os.exit(0)
