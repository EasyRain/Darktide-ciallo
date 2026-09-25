-- test_audio_files.lua -- the folder scan in audio_player.lua, without the game.
--
--   luajit tests\test_audio_files.lua        (from the repository root)
--
-- The mod gets its FFI table from Mods.lua; here we hand the module the same table so the
-- real listing code runs against a real folder (assets\sfx). DML preserves io/os/ffi/
-- debug/loadstring in Mods.lua (see binaries\mod_loader), so the stub provides all of them.
-- The native DLL is not present outside the game, so the module falls back to MCI.

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
    print(string.format("[%s] %-46s %s", ok and "PASS" or "FAIL", what, detail or ""))
    if not ok then
        failures = failures + 1
    end
end

check("module loaded with a backend", AudioPlayer.available == true, tostring(AudioPlayer.backend))

-- the shipped collection
local files = AudioPlayer.list_sounds("assets/sfx")
if type(files) == "table" then
    print(string.format("       assets/sfx -> %d file(s), first=%s last=%s", #files, tostring(files[1]), tostring(files[#files])))
    check("the folder scan finds sounds", #files >= 1, tostring(#files))
    local all_audio, all_exist, sorted = true, true, true
    for i, path in ipairs(files) do
        local lower = path:lower()
        if lower:sub(-4) ~= ".wav" and lower:sub(-4) ~= ".mp3" then all_audio = false end
        if not AudioPlayer.file_exists(path) then all_exist = false end
        if i > 1 and files[i - 1] > path then sorted = false end
    end
    check("every entry is .wav/.mp3", all_audio, "")
    check("every entry is openable", all_exist, "")
    check("the list is sorted", sorted, "")
    check("paths are joined with /", files[1]:find("/", 1, true) ~= nil, tostring(files[1]))
else
    check("the folder scan finds sounds", false, tostring(files))
end

-- a folder without audio files, a missing folder, and a file where a folder is expected
local scripts = AudioPlayer.list_sounds("scripts")
check("a folder without audio returns nil", scripts == nil, tostring(scripts))
local missing = AudioPlayer.list_sounds("assets/does-not-exist")
check("a missing folder returns nil", missing == nil, tostring(missing))
local as_file = AudioPlayer.list_sounds("assets/Ciallo~.wav")
check("a file path is not treated as a folder", as_file == nil, tostring(as_file))

-- subfolders must NOT be scanned: only the files directly inside the given folder
do
    local temp = (os.getenv("TEMP") or ".") .. "\\ciallo_scan_test"
    os.execute('rmdir /s /q "' .. temp .. '" >nul 2>nul')
    os.execute('mkdir "' .. temp .. '" >nul 2>nul')
    os.execute('mkdir "' .. temp .. '\\sub" >nul 2>nul')
    os.execute('mkdir "' .. temp .. '\\sub\\deeper" >nul 2>nul')
    local function touch(path)
        local handle = io.open(path, "wb")
        if handle then
            handle:write("x")
            handle:close()
        end
    end
    touch(temp .. "\\top_1.wav")
    touch(temp .. "\\top_2.mp3")
    touch(temp .. "\\notes.txt")
    touch(temp .. "\\sub\\nested.wav")
    touch(temp .. "\\sub\\deeper\\nested2.wav")

    local listed = AudioPlayer.list_sounds(temp)
    local names = {}
    if type(listed) == "table" then
        for _, path in ipairs(listed) do
            names[#names + 1] = path:match("[^/]+$")
        end
    end
    check("only the folder's own files are listed", type(listed) == "table" and #listed == 2, table.concat(names, ","))
    local leaked = false
    for _, name in ipairs(names) do
        if name == "nested.wav" or name == "nested2.wav" then
            leaked = true
        end
    end
    check("no file from a subfolder leaks in", not leaked, "")
    os.execute('rmdir /s /q "' .. temp .. '" >nul 2>nul')
end

-- the single-file check the mod uses for "is this a file?"
check("file_exists finds the bundled sound", AudioPlayer.file_exists("assets/Ciallo~.wav") == true, "")
check("file_exists rejects a folder", AudioPlayer.file_exists("assets/sfx") == false, "")
check("file_exists rejects a missing file", AudioPlayer.file_exists("assets/nope.wav") == false, "")

if failures > 0 then
    print(string.format("\n%d CHECK(S) FAILED", failures))
    os.exit(1)
end
print("\nALL CHECKS PASSED")
os.exit(0)
