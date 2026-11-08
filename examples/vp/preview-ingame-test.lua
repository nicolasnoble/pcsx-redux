-- In-game preview, end to end: translate one string of the Prologue's first
-- room (3613), arm VP.preview, play New Game -> Prologue and look for the
-- translation's accented glyphs in the real textbox.
--
--   pcsx-redux -cli -interpreter -debugger -iso <USA disc 1.cue> \
--       -dofile examples/vp/preview-ingame-test.lua -run
--
-- "I must hurry!" becomes "Je dois me dépêcher !". The room's font has no é
-- or ê, so they only reach the screen if the font was extended too. A glyph
-- counts as found where its set pixels are all dark and the rest of its cell
-- all light. PASS needs é and ê found once the script was patched.
-- VP_PREVIEW_INGAME_RED=1 runs without arming the preview, which must FAIL.
-- VP_SHOTS=dir writes the screenshots taken there as raw 15-bit 320x224.
--
-- Timing: the title menu takes input from about frame 2600 on this build with
-- OpenBIOS; the line is on screen around frames 4200-4600.

local here = debug.getinfo(1, 'S').source:match('^@(.*/)') or './'
Support.extra.dofile(here .. 'browser.lua')
local ffi = require('ffi')

local ROOM, FIND, REPL = '3613.arm', 'I must hurry!', 'Je dois me dépêcher !'
local red = os.getenv('VP_PREVIEW_INGAME_RED') == '1'
local shotDir = os.getenv('VP_SHOTS')

local function fail(msg)
    print('FAIL: ' .. msg)
    PCSX.quit(1)
end

local function findViewer()
    local iso = PCSX.getCurrentIso()
    if not VP.vfs.identify(iso) then return nil end
    local found
    local function walk(node, depth)
        if found or depth > 4 then return end
        for _, c in ipairs(VP.vfs.expand(node)) do
            if c.name == ROOM or node.name == ROOM then
                for _, v in ipairs(c.viewers) do
                    if v.name == 'Room script' then found = v end
                end
            end
            if found then return end
            if c.isDir or c.name == ROOM then walk(c, depth + 1) end
        end
    end
    walk(VP.vfs.root(iso), 0)
    return found
end

local v = findViewer()
if not v then return fail('no Room script viewer for ' .. ROOM .. ' (is USA disc 1 loaded?)') end
VP.vfs.ptrs(v)
local extra = v.extra
local lookup = resolveFont(extra.font)
local idx, edited
local i = extra.first
while extra.tokens[i] do
    local ed = VP.text.toEditable(extra.tokens[i], lookup, 'primary')
    if ed:find(FIND, 1, true) then
        idx, edited = i, ed:gsub(FIND:gsub('%p', '%%%0'), REPL)
        break
    end
    i = i + 1
end
if not idx then return fail('no string containing ' .. FIND) end
local toks = assert(VP.text.fromEditable(edited, 'primary'))
local dbPath = os.tmpname()
local db = VP.tdb.open(dbPath)
assert(db:put({ key = extra.key, idx = idx, tokens = toks, status = VP.tdb.status.draft, author = 'test',
                srcHash = VP.text.fnv1a64(extra.raw[idx]) }, 0))
if not red then VP.preview.arm(db) end
print(string.format('room %s key %s pointer %d, preview %s', ROOM, extra.key, idx, red and 'NOT armed (red arm)' or 'armed'))

-- Glyph templates from the font database, rows of 0/1.
local function template(ch)
    local g = VP.constants.font[ch]
    local bytes = base64.decode(g.data)
    local rows = {}
    for y = 0, g.height - 1 do
        local bits = bytes:byte(y * 2 + 2) * 256 + bytes:byte(y * 2 + 1)
        rows[y + 1] = {}
        for x = 0, g.width - 1 do rows[y + 1][x + 1] = bit.band(bits, bit.lshift(1, 15 - x)) ~= 0 end
    end
    return rows, g.width, g.height
end
local wanted = { 'é', 'ê' }
local templates = {}
for _, ch in ipairs(wanted) do templates[ch] = { template(ch) } end

local DARK = 30 -- sum of the three 5-bit channels
local function findGlyph(px, W, H, t)
    local rows, w, h = t[1], t[2], t[3]
    for y = 0, H - h do
        for x = 0, W - w do
            local ok = true
            for gy = 1, h do
                local row = rows[gy]
                for gx = 1, w do
                    if row[gx] ~= (px[(y + gy - 1) * W + x + gx - 1] < DARK) then
                        ok = false
                        break
                    end
                end
                if not ok then break end
            end
            if ok then return x, y end
        end
    end
end

local found = {}
local function look(frame)
    local sh = PCSX.GPU.takeScreenShot()
    local W, H = sh.width, sh.height
    local data = tostring(sh.data)
    if shotDir then
        local f = io.open(string.format('%s/shot-%05d.raw', shotDir, frame), 'wb')
        f:write(data)
        f:close()
    end
    if #data ~= W * H * 2 then return end
    local p = ffi.cast('const uint16_t*', data)
    local px = {}
    for k = 0, W * H - 1 do
        local c = p[k]
        px[k] = bit.band(c, 31) + bit.band(bit.rshift(c, 5), 31) + bit.band(bit.rshift(c, 10), 31)
    end
    for ch, t in pairs(templates) do
        local x, y = findGlyph(px, W, H, t)
        if x and not found[ch] then
            found[ch] = { frame = frame, x = x, y = y }
            print(string.format('found %s at %d,%d, frame %d', ch, x, y, frame))
        end
    end
end

local pad = PCSX.SIO0.slots[1].pads[1]
local B = PCSX.CONSTS.PAD.BUTTON
local T = 2600
local seq = { [T] = B.DOWN, [T + 25] = B.DOWN, [T + 50] = B.DOWN, [T + 75] = B.DOWN, [T + 110] = B.CROSS }
local LOOK_FROM, LOOK_TO, LOOK_EVERY = 4000, 4800, 100
local frames = 0
VP.previewIngameListener = PCSX.Events.createEventListener('GPU::Vsync', function()
    frames = frames + 1
    if seq[frames] then pad.setOverride(seq[frames]) end
    if seq[frames - 6] then pad.clearOverride(seq[frames - 6]) end
    if frames >= LOOK_FROM and frames % LOOK_EVERY == 0 then look(frames) end
    if frames == LOOK_TO then
        for _, l in ipairs(VP.preview.log) do print('preview: ' .. l) end
        db:close()
        os.remove(dbPath)
        local patched = VP.preview.lastPatch and VP.preview.lastPatch.key == extra.key
        local all = true
        for _, ch in ipairs(wanted) do if not found[ch] then all = false end end
        print(string.format('patched=%s glyphs=%s', tostring(patched), tostring(all)))
        if patched and all then
            print('PASS')
            PCSX.quit(0)
        else
            print('FAIL')
            PCSX.quit(1)
        end
    end
end)
