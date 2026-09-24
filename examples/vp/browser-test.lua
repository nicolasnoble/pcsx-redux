-- Headless check of the browser's node model: opens a disc, walks the tree,
-- expands a sample of entries and renders every viewer it finds.
--   VP_DISC1=<disc.cue> pcsx-redux -cli -dofile examples/vp/browser-test.lua
-- VP_BROWSE_ALL=1 expands every index entry instead of the sample.

-- Absolute path, so browser.lua's own relative dofiles resolve against its
-- directory rather than the current one.
local here = debug.getinfo(1, 'S').source:match('^@(.*/)') or './'
Support.extra.dofile(here .. 'browser.lua')

local path = os.getenv('VP_DISC1')
local iso = PCSX.openIso(path)
local disc = VP.vfs.identify(iso)
if not disc then
    print('FAIL: not identified as Valkyrie Profile: ' .. tostring(path))
    PCSX.quit(1)
    return
end
print(string.format('disc: %s %s disc %d', disc.exe, disc.region, disc.disc))

local all = os.getenv('VP_BROWSE_ALL') == '1'
local stats = { nodes = 0, errors = 0, viewers = 0, viewerErrors = 0, entries = 0, tims = 0, sounds = 0, windows = 0, runtimeWindows = 0, kinds = {} }
local samples = {}

local function walk(node, depth, isEntry)
    stats.nodes = stats.nodes + 1
    local children = VP.vfs.expand(node)
    if node.err then
        stats.errors = stats.errors + 1
        print('EXPAND ERROR ' .. node.name .. ': ' .. node.err)
    end
    for _, v in ipairs(node.viewers) do
        stats.viewers = stats.viewers + 1
        local text = VP.vfs.render(v)
        if text:sub(1, 6) == 'Error:' then
            stats.viewerErrors = stats.viewerErrors + 1
            print('VIEWER ERROR ' .. node.name .. ': ' .. text)
        else
            local ptrs = VP.vfs.ptrs(v)
            for i = v.first or 1, ptrs and #ptrs or 0 do
                local window = VP.glyphs.parse(ptrs[i])
                if window then
                    stats.windows = stats.windows + 1
                    if #window.unknown > 0 then stats.runtimeWindows = stats.runtimeWindows + 1 end
                end
            end
        end
        if text:sub(1, 6) ~= 'Error:' and not samples[v.name] then
            samples[v.name] = node.name .. '\n' .. text:sub(1, 300)
        end
    end
    if #children == 0 and not node.isDir then
        local ok, file = pcall(node.open)
        if ok then
            if VP.images.parseTim(file) then stats.tims = stats.tims + 1 end
            if VP.sounds.parse(file) then stats.sounds = stats.sounds + 1 end
        end
    end
    if node.kind then stats.kinds[node.kind] = (stats.kinds[node.kind] or 0) + 1 end
    for _, c in ipairs(children) do walk(c, depth + 1) end
end

local root = VP.vfs.root(iso)
for _, top in ipairs(VP.vfs.expand(root)) do
    print('top: ' .. top.name .. ' -> ' .. #VP.vfs.expand(top) .. ' children')
end
local isoTop, indexTop = VP.vfs.expand(root)[1], VP.vfs.expand(root)[2]
for _, c in ipairs(VP.vfs.expand(isoTop)) do print('  iso9660: ' .. c.name .. ' ' .. tostring(c.size)) end

-- Walk the index. By default only a handful of entries per directory, which
-- still covers every container format.
local function walkDir(dir)
    local n = 0
    for _, c in ipairs(VP.vfs.expand(dir)) do
        if c.isDir then
            walkDir(c)
        else
            stats.entries = stats.entries + 1
            n = n + 1
            if all or n <= 3 or n % 150 == 0 then walk(c, 0) end
        end
    end
end
walkDir(indexTop)

print(string.format('entries=%d nodes=%d expandErrors=%d viewers=%d viewerErrors=%d',
    stats.entries, stats.nodes, stats.errors, stats.viewers, stats.viewerErrors))
print(string.format('tims=%d sounds=%d windows=%d runtimeWindows=%d', stats.tims, stats.sounds, stats.windows, stats.runtimeWindows))
local kinds = {}
for k, n in pairs(stats.kinds) do kinds[#kinds + 1] = k .. '=' .. n end
table.sort(kinds)
print('kinds: ' .. table.concat(kinds, ' '))
for name, s in pairs(samples) do print('--- sample ' .. name .. ': ' .. s) end
PCSX.quit(0)
