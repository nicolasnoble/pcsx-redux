-- Extracts every room script of a Japanese Valkyrie Profile disc and pairs it
-- with the US room it translates. Each JP string must decode against the JP
-- font database and encode back to the bytes it was read from. With a US disc
-- as well, rooms are paired by index (JP = US + 117) and strings by pointer
-- index, and the match statistics are printed.
--
--   VP_DISC_JP=<jp.cue> [VP_DISC_US=<us.cue>] pcsx-redux -cli -dofile examples/vp/jp-test.lua
--
-- VP_JP_RED=1 looks the JP glyphs up in the US font database, which must make
-- the extraction fail. VP_JP_RED=2 keeps one JP glyph per character (the
-- characters the database lists several times lose their other bitmaps),
-- which must fail too.

local here = debug.getinfo(1, 'S').source:match('^@(.*/)') or './'
Support.extra.dofile(here .. 'browser.lua')

if os.getenv('VP_JP_RED') == '1' then
    VP.constants.fontJPByData = VP.constants.fontByData
    print('red arm: JP glyphs looked up in the US font database')
elseif os.getenv('VP_JP_RED') == '2' then
    -- One glyph per character, the last one listed: the variants are lost.
    VP.constants.fontJPByData = {}
    for k, v in pairs(VP.constants.fontJP) do VP.constants.fontJPByData[v.width .. '-' .. v.data] = v end
    print('red arm: one JP glyph per character')
end

local function rooms(path, region)
    local iso = PCSX.openIso(path)
    local disc = VP.vfs.identify(iso)
    if not disc or disc.region ~= region then
        print('FAIL: not a ' .. region .. ' Valkyrie Profile disc: ' .. tostring(path))
        PCSX.quit(1)
        return nil
    end
    print(string.format('disc: %s %s disc %d', disc.exe, disc.region, disc.disc))
    local index
    for _, c in ipairs(VP.vfs.expand(VP.vfs.root(iso))) do
        if c.name == 'Game index' then index = c end
    end
    local dir
    for _, c in ipairs(VP.vfs.expand(index)) do
        if c.name == 'GAME' then
            for _, d in ipairs(VP.vfs.expand(c)) do
                if d.name == 'ROOMS' then dir = d end
            end
        end
    end
    local out, errors = {}, 0
    local function walk(node, idx)
        local children = VP.vfs.expand(node)
        if node.err then
            errors = errors + 1
            print('FAIL expand ' .. node.name .. ': ' .. node.err)
        end
        for _, v in ipairs(node.viewers or {}) do
            if v.load then
                local ptrs, err = VP.vfs.ptrs(v)
                if not ptrs then
                    errors = errors + 1
                    print('FAIL load ' .. idx .. ': ' .. tostring(err))
                elseif v.extra.key then
                    out[idx] = out[idx] or {}
                    table.insert(out[idx], v.extra)
                end
            end
        end
        for _, c in ipairs(children) do walk(c, idx) end
    end
    for _, f in ipairs(VP.vfs.expand(dir)) do walk(f, f.index) end
    return out, errors
end

local function strings(extra)
    local lookup = resolveFont(extra.font)
    local r = {}
    local i = extra.first
    while extra.tokens[i] do
        r[i] = VP.text.toEditable(extra.tokens[i], lookup, extra.style)
        i = i + 1
    end
    return r, i - extra.first
end

local jp, jpErrors = rooms(os.getenv('VP_DISC_JP'), 'JP')
if not jp then return end
local stats = { rooms = 0, scripts = 0, strings = 0, failures = 0, unknown = 0, heights = {} }
for idx, list in pairs(jp) do
    stats.rooms = stats.rooms + 1
    for _, extra in ipairs(list) do
        stats.scripts = stats.scripts + 1
        local i = extra.first
        while extra.tokens[i] do
            stats.strings = stats.strings + 1
            local ok, enc = pcall(VP.text.encodeTokens, extra.tokens[i], extra.style)
            if not ok or enc ~= extra.raw[i] then
                stats.failures = stats.failures + 1
                if stats.failures <= 10 then print('FAIL round trip room ' .. idx .. ' ptr ' .. i) end
            end
            for _, t in ipairs(extra.tokens[i]) do
                if t.g and extra.font[t.g] and not extra.font[t.g].text and not extra.font[t.g].padding then
                    stats.unknown = stats.unknown + 1
                end
            end
            i = i + 1
        end
        local h = extra.font[1] and extra.font[1].height or 0
        stats.heights[h] = (stats.heights[h] or 0) + 1
    end
end
local hs = {}
for h, n in pairs(stats.heights) do hs[#hs + 1] = h .. ':' .. n end
print(string.format('JP rooms=%d scripts=%d strings=%d round-trip failures=%d unknown glyphs=%d load errors=%d heights %s',
    stats.rooms, stats.scripts, stats.strings, stats.failures, stats.unknown, jpErrors, table.concat(hs, ' ')))
local green = stats.failures == 0 and jpErrors == 0 and stats.strings > 0

local usPath = os.getenv('VP_DISC_US')
if usPath then
    VP.globals.index.entries = {}
    local us, usErrors = rooms(usPath, 'US')
    if not us then return end
    local m = { pairs = 0, noJP = 0, scriptCount = 0, samePtrs = 0, diffPtrs = 0, usStrings = 0, matched = 0, emptyEither = 0 }
    for idx, list in pairs(us) do
        local j = jp[idx + 117]
        if not j then
            m.noJP = m.noJP + 1
        elseif #j ~= #list then
            m.scriptCount = m.scriptCount + 1
        else
            m.pairs = m.pairs + 1
            for k, extra in ipairs(list) do
                local u, nu = strings(extra)
                local p, np = strings(j[k])
                m.usStrings = m.usStrings + nu
                if nu == np then m.samePtrs = m.samePtrs + 1 else
                    m.diffPtrs = m.diffPtrs + 1
                    if m.diffPtrs <= 20 then print(string.format('ptr count differs: US %d (%d) JP %d (%d)', idx, nu, idx + 117, np)) end
                end
                for i, s in pairs(u) do
                    if p[i] then
                        m.matched = m.matched + 1
                        if s == '' or p[i] == '' then m.emptyEither = m.emptyEither + 1 end
                    end
                end
            end
        end
    end
    print(string.format('US rooms=%d load errors=%d; paired rooms=%d, US rooms with no JP room=%d, script count differs=%d',
        (function() local n = 0 for _ in pairs(us) do n = n + 1 end return n end)(), usErrors, m.pairs, m.noJP, m.scriptCount))
    print(string.format('scripts with the same pointer count=%d, different=%d; US strings=%d, with a JP string at the same index=%d (empty on one side %d)',
        m.samePtrs, m.diffPtrs, m.usStrings, m.matched, m.emptyEither))
    green = green and usErrors == 0
end
print('JP ' .. (green and 'PASS' or 'FAIL'))
PCSX.quit(green and 0 or 1)
