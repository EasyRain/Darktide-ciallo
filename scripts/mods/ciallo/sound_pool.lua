-- sound_pool.lua -- which sound plays next.
--
-- Two modes, decided by what "sound_path" points at (the caller picks the mode):
--   single : always the same file
--   list   : a folder's sounds, played in a shuffled "bag" so nothing repeats until
--            every sound has been used once (a plain random pick repeats too often)
--
-- Pure Lua on purpose: no DMF, no game API, so tests\test_sound_pool.lua can drive it
-- with a fake rng and check the no-repeat rule exactly.
local M = {}

local SoundPool = {}
SoundPool.__index = SoundPool

function M.new(options)
    options = options or {}
    local self = setmetatable({
        single = nil,
        files = {},
        bag = {},
        last = nil,
        rng = options.rng or math.random,
    }, SoundPool)
    if options.single then
        self:set_single(options.single)
    elseif options.files then
        self:set_files(options.files)
    end
    return self
end

-- Always this one sound.
function SoundPool:set_single(path)
    self.single = path
    self.files = {}
    self.bag = {}
    self.last = nil
end

-- Random pick from these sounds (a copy is kept: the caller may reuse its list).
function SoundPool:set_files(files)
    self.single = nil
    self.files = {}
    for i = 1, #files do
        self.files[i] = files[i]
    end
    self.bag = {}
    self.last = nil
end

function SoundPool:is_single()
    return self.single ~= nil
end

function SoundPool:count()
    if self.single then
        return 1
    end
    return #self.files
end

function SoundPool:shuffle()
    local bag = self.bag
    for i = #bag, 2, -1 do
        local j = self.rng(i)
        if j < 1 then j = 1 elseif j > i then j = i end
        bag[i], bag[j] = bag[j], bag[i]
    end
end

-- Refill and shuffle. The first sound of the new bag must not be the last one played,
-- otherwise a short pool can still repeat back to back across the refill boundary.
function SoundPool:refill()
    self.bag = {}
    for i = 1, #self.files do
        self.bag[i] = self.files[i]
    end
    if #self.bag == 0 then
        return false
    end
    self:shuffle()
    if #self.bag > 1 and self.last ~= nil and self.bag[#self.bag] == self.last then
        local swap_with = self.rng(#self.bag - 1)
        if swap_with < 1 then swap_with = 1 elseif swap_with > #self.bag - 1 then swap_with = #self.bag - 1 end
        self.bag[#self.bag], self.bag[swap_with] = self.bag[swap_with], self.bag[#self.bag]
    end
    return true
end

-- The next sound to play, or nil when there is nothing configured.
function SoundPool:pick()
    if self.single then
        return self.single
    end
    if #self.files == 0 then
        return nil
    end
    if #self.bag == 0 then
        self:refill()
    end
    local path = table.remove(self.bag)
    self.last = path
    return path
end

return M
