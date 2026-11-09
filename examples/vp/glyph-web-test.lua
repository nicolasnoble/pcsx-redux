-- Tests of the web glyph editor (translate-web-glyphs.lua), calling its routes
-- with requests built here, on a temporary database. No disc is needed.
--
--   pcsx-redux -cli -dofile examples/vp/glyph-web-test.lua
--
-- Red arm: VP_GLYPHWEB_RED=1 makes the save read the grid with x and y
-- swapped, which the saved-bitmap check must catch.

local here = debug.getinfo(1, 'S').source:match('^@(.*/)') or './'
Support.extra.dofile(here .. 'browser.lua')
local W, M, F = VP.tweb, VP.tmodel, VP.fontedit

local path = os.tmpname()
os.remove(path)
M.path, M.author = path, 'ana'
M.open(path)

local results = { pass = 0, fail = 0 }
local function check(cond, what)
    if cond then
        results.pass = results.pass + 1
        print('PASS ' .. what)
    else
        results.fail = results.fail + 1
        print('FAIL ' .. what)
    end
end

local function enc(s)
    return (tostring(s):gsub('[^%w%-%._~]', function(c) return string.format('%%%02X', c:byte()) end))
end
local function body(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = enc(k) .. '=' .. enc(v) end
    return table.concat(parts, '&')
end
local function get(query) return W.handle({ method = 'GET', urlData = { query = query }, headers = {} }) end
local function post(query, form)
    return W.handle({ method = 'POST', urlData = { query = query }, headers = {}, body = body(form) })
end

-- The form a browser would post for rows, with the given fields.
local function form(ch, rows, extra)
    local f = { ch = ch }
    for x = 0, F.COLUMNS - 1 do
        for y = 0, F.HEIGHT - 1 do
            if F.get(rows, x, y) then
                if os.getenv('VP_GLYPHWEB_RED') == '1' and x < F.HEIGHT and y < F.COLUMNS then
                    f[string.format('c%d_%d', y, x)] = '1'
                else
                    f[string.format('c%d_%d', x, y)] = '1'
                end
            end
        end
    end
    for k, v in pairs(extra) do f[k] = v end
    return f
end

local page = get('p=glyphs&ch=' .. enc('é'))
check(page:match('^HTTP/1.1 200'), 'glyph page answers')
local _, cells = page:gsub('type="checkbox"', '')
check(cells == F.COLUMNS * F.HEIGHT, 'grid has 192 cells (' .. cells .. ')')
local base = VP.languages.charset('fr')['é']
local rows = F.rows(base.data)
local _, lit = page:gsub('checked="checked"', '')
local want = 0
for x = 0, 15 do for y = 0, 11 do if F.get(rows, x, y) then want = want + 1 end end end
check(lit == want, string.format('lit cells match the French é (%d of %d)', lit, want))
check(page:find('data:image/png;base64,', 1, true) ~= nil, 'preview image present')
check(page:find('Glyphs</a>', 1, true) ~= nil, 'header links the glyph editor')

-- Add a column and save.
local edited = F.rows(base.data)
for y = 0, 11 do if F.get(edited, 4, y) then F.set(edited, 5, y, true) end end
local r = post('p=glyphsave', form('é', edited, { base = '0', width = '7', action = 'save', note = 'bold' }))
check(r:match('^HTTP/1.1 303'), 'save redirects')
local stored = M.db:glyph('é')
check(stored and stored.version == 1, 'stored as version 1')
check(stored and stored.data == F.encode(edited), 'stored bitmap is the posted grid')
check(stored and stored.width == 7 and stored.note == 'bold' and stored.author == 'ana', 'advance, note, author')
check(M.charset()['é'].data == F.encode(edited), 'charset uses the web edit')

-- A stale save conflicts and shows theirs.
local stale = post('p=glyphsave', form('é', F.blank(), { base = '0', width = '3', action = 'save' }))
check(stale:find('saved version 1', 1, true) ~= nil, 'stale save shows the conflict')
check(M.db:glyph('é').version == 1, 'stale save changed nothing')

-- Preview and fit do not store.
local pv = post('p=glyphsave', form('é', F.blank(), { base = '1', width = '6', action = 'fit' }))
local widthTag = pv:match('<input[^>]-name="width"[^>]*>') or ''
check(widthTag:match('value="(%d+)"') == '1' and M.db:glyph('é').version == 1,
    'fit sets the advance of a blank grid to 1, stores nothing (' .. widthTag .. ')')

-- Refused glyph: advance 0.
local bad = post('p=glyphsave', form('é', edited, { base = '1', width = '0', action = 'save' }))
check(bad:find('the advance is 1 to 16', 1, true) ~= nil and M.db:glyph('é').version == 1, 'advance 0 refused')

-- Add a new character, then revert it.
local n = F.blank()
for x = 0, 4 do F.set(n, x, 5, true) end
local add = post('p=glyphsave', form('ñ', n, { base = '0', width = '6', action = 'save' }))
check(add:match('^HTTP/1.1 303') and M.charset()['ñ'] ~= nil, 'ñ added')
local listed = get('p=glyphs&ch=' .. enc('ñ'))
check(listed:find('class="added"', 1, true) ~= nil, 'list marks the added character')
local rv = post('p=glyphsave', form('ñ', n, { base = '1', width = '6', action = 'revert' }))
check(rv:match('^HTTP/1.1 303') and M.charset()['ñ'] == nil, 'ñ removed')
check(#M.glyphHistory('ñ') == 2, 'ñ history has the add and the removal')

-- Not a character.
check(get('p=glyphs&ch=ab'):match('^HTTP/1.1 400'), 'two characters refused')

M.db:close()
os.remove(path)
print(string.format('GLYPHWEB %s: %d/%d', results.fail == 0 and 'PASS' or 'FAIL', results.pass,
    results.pass + results.fail))
PCSX.quit(results.fail == 0 and 0 or 1)
