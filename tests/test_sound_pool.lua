-- test_sound_pool.lua -- the "play every sound once before repeating" bag.
--
--   luajit tests\test_sound_pool.lua        (from the repository root)
--
-- Pure Lua: sound_pool.lua has no DMF or game dependencies, so the rng can be replaced
-- and the no-repeat rule checked exactly instead of statistically.

package.path = package.path .. ";./?.lua"

local SoundPool = dofile("scripts/mods/ciallo/sound_pool.lua")

local failures = 0

local function check(what, ok, detail)
    print(string.format("[%s] %-46s %s", ok and "PASS" or "FAIL", what, detail or ""))
    if not ok then
        failures = failures + 1
    end
end

local function identity(i) return i end
local function always_first(i) return 1 end
local function always_last(i) return i end

-- a deterministic pseudo-random rng so a failure can be reproduced
local function lcg(seed)
    local state = seed or 1
    return function(i)
        state = (state * 1103515245 + 12345) % 2147483648
        return (state % i) + 1
    end
end

-- 1. every sound is used once per cycle, and never twice in a row
for _, rng in ipairs({ identity, always_first, always_last, lcg(7), lcg(99) }) do
    local files = { "a.wav", "b.wav", "c.wav", "d.wav" }
    local pool = SoundPool.new({ files = files, rng = rng })
    local counts = {}
    local previous = nil
    local repeats = 0
    local pick = {}
    for i = 1, 40 do
        local path = pool:pick()
        pick[#pick + 1] = path
        counts[path] = (counts[path] or 0) + 1
        if previous ~= nil and path == previous then
            repeats = repeats + 1
        end
        previous = path
    end
    local all_seen = true
    for _, name in ipairs(files) do
        if not counts[name] then all_seen = false end
    end
    check("40 picks never repeat back to back", repeats == 0, "repeats=" .. repeats)
    check("every sound appears within 40 picks", all_seen, "")
    -- each full cycle of 4 must contain each sound exactly once
    local balanced = true
    for offset = 1, 36, 4 do
        local window = {}
        for k = 0, 3 do
            local name = pick[offset + k]
            window[name] = (window[name] or 0) + 1
        end
        for _, name in ipairs(files) do
            if window[name] ~= 1 then balanced = false end
        end
    end
    check("each 4-pick window is a permutation", balanced, "")
end

-- 2. two sounds: the refill boundary must not repeat either
do
    local pool = SoundPool.new({ files = { "a.wav", "b.wav" }, rng = always_last })
    local first = pool:pick()
    local second = pool:pick()
    local third = pool:pick()
    check("2-sound pool alternates", first ~= second and second ~= third,
        table.concat({ first, second, third }, ","))
end

-- 3. single mode always returns that file
do
    local pool = SoundPool.new({ single = "only.wav" })
    check("single mode is stable", pool:pick() == "only.wav" and pool:pick() == "only.wav", "")
    check("single mode reports one sound", pool:count() == 1, tostring(pool:count()))
    check("single mode is flagged", pool:is_single(), "")
end

-- 4. nothing configured
do
    local pool = SoundPool.new()
    check("empty pool picks nil", pool:pick() == nil, "")
    check("empty pool counts zero", pool:count() == 0, tostring(pool:count()))
end

-- 5. switching modes resets the bag
do
    local pool = SoundPool.new({ files = { "a.wav", "b.wav", "c.wav" }, rng = identity })
    pool:pick()
    pool:set_single("solo.wav")
    check("set_single wins over the list", pool:pick() == "solo.wav", "")
    pool:set_files({ "x.wav", "y.wav" })
    local first = pool:pick()
    check("set_files leaves single mode", first == "x.wav" or first == "y.wav", tostring(first))
    check("set_files copies the list", pool:count() == 2, tostring(pool:count()))
end

-- 6. the caller's list is not mutated by the pool
do
    local files = { "a.wav", "b.wav" }
    local pool = SoundPool.new({ files = files, rng = identity })
    pool:pick()
    check("caller list untouched", #files == 2, "#files=" .. #files)
end

if failures > 0 then
    print(string.format("\n%d CHECK(S) FAILED", failures))
    os.exit(1)
end
print("\nALL CHECKS PASSED")
os.exit(0)
