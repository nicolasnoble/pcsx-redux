-- Round trip of the text token codec over every script on a Valkyrie Profile
-- disc: each room-script and simple-script string is decoded to tokens and
-- encoded back, and must give back exactly the bytes it was read from. Also
-- checks that the editable text form (VP.text.toEditable / fromEditable) gives
-- back the same characters and codes, checks the room-script key (rooms with
-- identical scripts get identical keys, and different scripts different ones)
-- and measures every string.
--
--   VP_DISC1=<disc.cue> pcsx-redux -cli -dofile examples/vp/tokens-test.lua
--
-- VP_TOKENS_RED=1 makes the encoder write the two arguments of special codes in
-- reverse order, which must make the round trip fail on those strings.

local here = debug.getinfo(1, 'S').source:match('^@(.*/)') or './'
Support.extra.dofile(here .. 'browser.lua')

local function quit(code)
    PCSX.quit(code)
end

-- FNV-1a 64 reference vectors.
for s, h in pairs({ [''] = 'cbf29ce484222325', a = 'af63dc4c8601ec8c', foobar = '85944171f73967e8' }) do
    if VP.text.fnv1a64(s) ~= h then
        print('FAIL: fnv1a64("' .. s .. '") = ' .. VP.text.fnv1a64(s) .. ', expected ' .. h)
        return quit(1)
    end
end

if os.getenv('VP_TOKENS_RED') == '1' then
    local encode = VP.text.encodeTokens
    VP.text.encodeTokens = function(tokens, style)
        local swapped = { terminated = tokens.terminated }
        for i, t in ipairs(tokens) do
            if t.c and t.args and #t.args == 2 then t = { c = t.c, args = { t.args[2], t.args[1] } } end
            swapped[i] = t
        end
        return encode(swapped, style)
    end
    print('red arm: two-argument codes encoded with their arguments swapped')
end

local path = os.getenv('VP_DISC1')
local iso = PCSX.openIso(path)
local disc = VP.vfs.identify(iso)
if not disc then
    print('FAIL: not identified as Valkyrie Profile: ' .. tostring(path))
    return quit(1)
end
print(string.format('disc: %s %s disc %d', disc.exe, disc.region, disc.disc))

local function hex(s, from, n)
    local t = {}
    for i = from, math.min(#s, from + n - 1) do t[#t + 1] = string.format('%02x', s:byte(i)) end
    return table.concat(t, ' ')
end

local stats = {
    rooms = 0, simple = 0, strings = 0, tokens = 0, glyphs = 0, zeros = 0, wide = 0, unterminated = 0,
    failures = 0, loadErrors = 0, editDiffs = 0, padding = 0, outOfFont = 0, trailing = 0, missing = 0, widest = 0, codes = {},
}
local byKey, keyOf = {}, {}

local function check(where, extra)
    local first = extra.first
    local i = first
    while extra.tokens[i] do
        local toks = extra.tokens[i]
        stats.strings = stats.strings + 1
        stats.tokens = stats.tokens + #toks
        if not toks.terminated then stats.unterminated = stats.unterminated + 1 end
        if toks.terminated == 'wide' then stats.wide = stats.wide + 1 end
        for _, t in ipairs(toks) do
            if t.g then
                stats.glyphs = stats.glyphs + 1
                local f = extra.font[t.g]
                if not f then
                    stats.outOfFont = stats.outOfFont + 1
                elseif f.padding then
                    stats.padding = stats.padding + 1
                end
            end
            if t.z then stats.zeros = stats.zeros + 1 end
            if t.wide then stats.wide = stats.wide + 1 end
            if t.c then
                local k = extra.style .. ':' .. t.c
                stats.codes[k] = (stats.codes[k] or 0) + 1
            end
        end
        local ok, enc = pcall(VP.text.encodeTokens, toks, extra.style)
        local want = extra.raw[i]
        if not ok or enc ~= want then
            stats.failures = stats.failures + 1
            if not ok then
                print(string.format('FAIL %s ptr %d: encode error: %s', where, i, enc))
            else
                local d = 1
                while d <= #enc and enc:byte(d) == want:byte(d) do d = d + 1 end
                print(string.format('FAIL %s ptr %d: %d bytes encoded, %d read, first difference at %d: got [%s] want [%s]',
                    where, i, #enc, #want, d, hex(enc, d, 8), hex(want, d, 8)))
            end
        end
        local widths, missing = VP.glyphs.measure(toks, extra.font, 'US', extra.style)
        local lookup = extra.lookup or resolveFont(extra.font)
        extra.lookup = lookup
        -- Editable text round trip: back to the same characters and codes.
        local ed = VP.text.toEditable(toks, lookup, extra.style)
        local back, perr = VP.text.fromEditable(ed, extra.style)
        local okEd = back and #back == #toks
        if okEd then
            for k, t in ipairs(toks) do
                local b = back[k]
                local want = t.g and lookup[t.g] ~= '<??>' and lookup[t.g] or nil
                if t.g and want then
                    okEd = okEd and b.ch == want
                elseif t.g then
                    okEd = okEd and b.g == t.g
                elseif t.z then
                    okEd = okEd and b.z
                else
                    okEd = okEd and b.c == t.c and #b.args == #t.args
                    for a = 1, #t.args do okEd = okEd and b.args[a] == t.args[a] end
                end
            end
        end
        if not okEd then
            stats.editDiffs = stats.editDiffs + 1
            if stats.editDiffs <= 10 then
                print(string.format('FAIL %s ptr %d: editable round trip: %s', where, i, tostring(perr)))
            end
        end
        stats.missing = stats.missing + missing
        for _, page in ipairs(widths) do
            for _, w in ipairs(page) do
                if w > stats.widest then stats.widest = w end
            end
        end
        i = i + 1
    end
end

local function walk(node, path)
    local children = VP.vfs.expand(node)
    for _, v in ipairs(node.viewers) do
        if v.load then
            local ptrs, err = VP.vfs.ptrs(v)
            if not ptrs then
                stats.loadErrors = stats.loadErrors + 1
                print('FAIL ' .. path .. ': ' .. tostring(err))
            else
                local extra = v.extra
                if extra.key then
                    stats.rooms = stats.rooms + 1
                    if extra.trailing ~= 0 then stats.trailing = stats.trailing + 1 end
                    local bytes = tostring(v.script:readAt(v.script:size(), 0))
                    if keyOf[bytes] and keyOf[bytes] ~= extra.key then
                        stats.failures = stats.failures + 1
                        print('FAIL ' .. path .. ': same script, key ' .. extra.key .. ' vs ' .. keyOf[bytes])
                    end
                    keyOf[bytes] = extra.key
                    byKey[extra.key] = byKey[extra.key] or {}
                    byKey[extra.key][bytes] = (byKey[extra.key][bytes] or 0) + 1
                else
                    stats.simple = stats.simple + 1
                end
                check(path, extra)
            end
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

local keys, shared, collisions, distinct = 0, 0, 0, 0
for key, contents in pairs(byKey) do
    keys = keys + 1
    local n, rooms = 0, 0
    for _, count in pairs(contents) do
        n = n + 1
        rooms = rooms + count
    end
    distinct = distinct + n
    if n > 1 then
        collisions = collisions + 1
        stats.failures = stats.failures + 1
        print('FAIL: key ' .. key .. ' covers ' .. n .. ' different scripts')
    end
    if rooms > 1 then shared = shared + 1 end
end

local codes = {}
for k, n in pairs(stats.codes) do codes[#codes + 1] = k .. '=' .. n end
table.sort(codes)
print(string.format('rooms=%d simple=%d strings=%d tokens=%d glyphs=%d zeros=%d wide=%d unterminated=%d',
    stats.rooms, stats.simple, stats.strings, stats.tokens, stats.glyphs, stats.zeros, stats.wide, stats.unterminated))
print('codes: ' .. table.concat(codes, ' '))
print(string.format('keys=%d distinct scripts=%d keys shared by several rooms=%d collisions=%d', keys, distinct, shared,
    collisions))
print(string.format('rooms with bytes after the last string=%d, characters with no glyph=%d, widest line=%d px',
    stats.trailing, stats.missing, stats.widest))
print(string.format('glyph tokens naming a padding glyph=%d, past the end of the font=%d', stats.padding, stats.outOfFont))
local green = stats.failures == 0 and stats.loadErrors == 0 and stats.editDiffs == 0
    and stats.strings > 0
print(string.format('TOKENS %s: %d strings, %d round-trip failures, %d load errors, %d editable round-trip failures',
    green and 'PASS' or 'FAIL', stats.strings, stats.failures, stats.loadErrors, stats.editDiffs))
quit(green and 0 or 1)
