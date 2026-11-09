-- Script rebuild used by the in-game preview (VP.preview.rebuild), over every
-- room script of a Valkyrie Profile disc:
--   1. no rows: the rebuilt script is byte-identical to the original;
--   2. every string given back as its own tokens, and every literal box value
--      given back as itself: still byte-identical;
--   0. an accented letter appended to a room font advances as far as its base
--      letter does in that same font;
--   3. one string made longer and one box widened: the rebuilt script parses,
--      the changed string reads back as the new tokens, every other string and
--      the rest of the logic are unchanged, and the box reads back widened.
--
--   VP_DISC1=<disc.cue> pcsx-redux -cli -dofile examples/vp/preview-test.lua
--
-- VP_PREVIEW_RED=1 makes the rebuild leave the header's strings length stale,
-- which must fail checks 3 on every script.

local here = debug.getinfo(1, 'S').source:match('^@(.*/)') or './'
Support.extra.dofile(here .. 'browser.lua')

local iso = PCSX.openIso(os.getenv('VP_DISC1'))
if not VP.vfs.identify(iso) then
    print('FAIL: not identified as Valkyrie Profile')
    return PCSX.quit(1)
end

local stats = { scripts = 0, identity = 0, selfRows = 0, changed = 0, boxes = 0, failures = 0, skipped = 0, accents = 0 }

-- Accented letters and the letter they are drawn on.
local bases = {
    ['à'] = 'a', ['â'] = 'a', ['ç'] = 'c', ['è'] = 'e', ['é'] = 'e', ['ê'] = 'e', ['ë'] = 'e',
    ['î'] = 'i', ['ï'] = 'i', ['ô'] = 'o', ['ù'] = 'u', ['û'] = 'u', ['ü'] = 'u',
}
local seen = {}

-- VP_EDITABLE_OUT=<file> also writes every string's editable text form, one
-- JSON string a line: the corpus of the web editor's chip round-trip test
-- (translate-web-test.mjs).
local editableOut = os.getenv('VP_EDITABLE_OUT') and assert(io.open(os.getenv('VP_EDITABLE_OUT'), 'w'))
stats.editable = 0
local function json(str)
    return '"' .. str:gsub('[%c"\\]', function(c)
        if c == '\n' then return '\\n' end
        if c == '"' or c == '\\' then return '\\' .. c end
        return string.format('\\u%04x', c:byte())
    end) .. '"'
end

local function fail(path, what)
    stats.failures = stats.failures + 1
    if stats.failures <= 20 then print('FAIL ' .. path .. ': ' .. what) end
end

local function strings(bytes)
    local p = VP.preview.parse(bytes)
    local buf = Support.File.buffer()
    buf:write(p.strings)
    local out = {}
    for i = 3, p.nPtrs do
        buf:rSeek(p.ptrs[i])
        local start = p.ptrs[i]
        VP.text.decodeTokens(buf, 'primary')
        out[i] = p.strings:sub(start + 1, tonumber(buf:rTell()))
    end
    buf:close()
    return out, p
end

local function boxesOf(logic)
    local buf = Support.File.buffer()
    buf:write(logic)
    local t = VP.room.textboxes(buf, 3)
    buf:close()
    return t
end

local function check(path, v)
    local extra = v.extra
    local bytes = tostring(v.script:readAt(v.script:size(), 0))
    if seen[extra.key] then return end
    seen[extra.key] = true
    stats.scripts = stats.scripts + 1
    if editableOut then
        local lookup = resolveFont(extra.font)
        local i = extra.first
        while extra.tokens[i] do
            editableOut:write(json(VP.text.toEditable(extra.tokens[i], lookup, extra.style)), '\n')
            stats.editable = stats.editable + 1
            i = i + 1
        end
    end

    if v.fontFile then
        local fontBytes = tostring(v.fontFile:readAt(v.fontFile:size(), 0))
        local font = VP.preview.parseFont(fontBytes)
        for acc, base in pairs(bases) do
            local b = VP.constants.font[base]
            local bi = font.index[b.width .. '-' .. base64.decode(b.data)]
            local present = font.index[VP.constants.font[acc].width .. '-' .. base64.decode(VP.constants.font[acc].data)]
            if bi and not present then
                local _, newFont = VP.preview.resolveChars({ [3] = { tokens = { { ch = acc } } } }, fontBytes)
                local nf = VP.preview.parseFont(newFont)
                local added = #font.widths + 1
                stats.accents = stats.accents + 1
                if nf.widths[added] ~= font.widths[bi] then
                    fail(path, string.format('appended %s advances %d, %s in this font advances %d', acc, nf.widths[added],
                                             base, font.widths[bi]))
                    break
                end
            end
        end
    end

    local ok, out = pcall(VP.preview.rebuild, bytes, {})
    if not ok then return fail(path, 'identity rebuild raised ' .. tostring(out)) end
    if out ~= bytes then return fail(path, 'identity rebuild differs') end
    stats.identity = stats.identity + 1

    local rows = {}
    local i = extra.first
    while extra.tokens[i] do
        rows[i] = { tokens = extra.tokens[i] }
        i = i + 1
    end
    for idx, tb in pairs(extra.textboxes or {}) do
        if rows[idx] and tb.sites and #tb.sites > 0 and not tb.native then
            local ok2 = true
            for _, f in ipairs({ 'x', 'y', 'width', 'height' }) do
                for _, s in ipairs(tb.sites) do if not s[f] then ok2 = false end end
            end
            if ok2 and type(tb.x) == 'number' and type(tb.y) == 'number' and type(tb.width) == 'number'
                and type(tb.height) == 'number' and #tb.sites == 1 then
                rows[idx].boxX, rows[idx].boxY, rows[idx].boxW, rows[idx].boxH = tb.x, tb.y, tb.width, tb.height
            end
        end
    end
    local ok3, out3 = pcall(VP.preview.rebuild, bytes, rows)
    if not ok3 then return fail(path, 'self rebuild raised ' .. tostring(out3)) end
    if out3 ~= bytes then return fail(path, 'self rebuild differs') end
    stats.selfRows = stats.selfRows + 1

    -- Change the first string and widen the first single-site literal box.
    local first = extra.first
    if not extra.tokens[first] then stats.skipped = stats.skipped + 1 return end
    local longer = { terminated = extra.tokens[first].terminated }
    for k, t in ipairs(extra.tokens[first]) do longer[k] = t end
    for _ = 1, 7 do longer[#longer + 1] = { g = 0x41 } end
    local change = { [first] = { tokens = longer } }
    local boxIdx
    for idx, tb in pairs(extra.textboxes or {}) do
        if tb.sites and #tb.sites == 1 and tb.sites[1].width and type(tb.width) == 'number' and not tb.native
            and (not boxIdx or idx < boxIdx) then
            boxIdx = idx
        end
    end
    if boxIdx then
        change[boxIdx] = change[boxIdx] or { tokens = extra.tokens[boxIdx] }
        change[boxIdx].boxW = extra.textboxes[boxIdx].width + 8
    end
    local ok4, out4 = pcall(VP.preview.rebuild, bytes, change)
    if not ok4 then return fail(path, 'changed rebuild raised ' .. tostring(out4)) end
    local ok5, after, p = pcall(strings, out4)
    if not ok5 then return fail(path, 'changed script does not parse: ' .. tostring(after)) end
    local before = strings(bytes)
    for j, s in pairs(before) do
        local want = j == first and (VP.text.encodeTokens(longer, 'primary') .. (longer.terminated and '' or '\0')) or s
        if after[j] ~= want then return fail(path, 'string ' .. j .. ' reads back wrong') end
    end
    local origP = VP.preview.parse(bytes)
    if boxIdx then
        local tb = boxesOf(p.logic)[boxIdx]
        if not tb or tb.width ~= extra.textboxes[boxIdx].width + 8 then return fail(path, 'box ' .. boxIdx .. ' not widened') end
        local diffWords = 0
        for o = 1, #p.logic, 4 do if p.logic:sub(o, o + 3) ~= origP.logic:sub(o, o + 3) then diffWords = diffWords + 1 end end
        if diffWords ~= 1 then return fail(path, diffWords .. ' logic words changed, expected 1') end
        stats.boxes = stats.boxes + 1
    elseif p.logic ~= origP.logic then
        return fail(path, 'logic changed with no box override')
    end
    stats.changed = stats.changed + 1
end

local function walk(node, path)
    local children = VP.vfs.expand(node)
    for _, v in ipairs(node.viewers) do
        if v.load then
            local ptrs = VP.vfs.ptrs(v)
            if ptrs and v.extra and v.extra.key then check(path, v) end
        end
    end
    for _, c in ipairs(children) do walk(c, path .. '/' .. c.name) end
end
local function walkDir(dir, path)
    for _, c in ipairs(VP.vfs.expand(dir)) do
        if c.isDir then walkDir(c, path .. '/' .. c.name) else walk(c, path .. '/' .. c.name) end
    end
end
walkDir(VP.vfs.expand(VP.vfs.root(iso))[2], '')

print(string.format('scripts=%d identity=%d self=%d changed=%d boxes=%d accents=%d skipped=%d failures=%d',
    stats.scripts, stats.identity, stats.selfRows, stats.changed, stats.boxes, stats.accents, stats.skipped, stats.failures))
if editableOut then
    editableOut:close()
    print(string.format('editable strings written: %d', stats.editable))
end
local pass = stats.failures == 0 and stats.scripts > 1000 and stats.identity == stats.scripts and stats.boxes > 0
    and stats.accents > 0
print(pass and 'PASS' or 'FAIL')
PCSX.quit(pass and 0 or 1)
