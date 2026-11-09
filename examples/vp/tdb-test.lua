-- Tests of the translation database (tdb.lua) and the editable text codec, on
-- a temporary sqlite file. No disc is needed.
--
--   pcsx-redux -cli -dofile examples/vp/tdb-test.lua
--
-- Red arms: VP_TDB_RED=1 makes the sqlite backend skip its version check,
-- which the conflict tests must catch; VP_TDB_RED=2 runs transactions without
-- a transaction, which the rollback test must catch; VP_TDB_RED=3 gives every
-- language every letter, which the languages test must catch; VP_TDB_RED=4
-- makes the charset ignore the database glyphs, and VP_TDB_RED=5 draws pages from
-- the font database instead of the charset; the glyphs test must catch both.

local here = debug.getinfo(1, 'S').source:match('^@(.*/)') or './'
Support.extra.dofile(here .. 'browser.lua')

if os.getenv('VP_TDB_RED') == '1' then
    local cas = VP.tdb.backends.sqlite.compareAndSet
    VP.tdb.backends.sqlite.compareAndSet = function(self, rec, expected, now)
        local cur = self:get(rec.key, rec.idx)
        return cas(self, rec, cur and cur.version or 0, now)
    end
    local gcas = VP.tdb.backends.sqlite.compareAndSetGlyph
    VP.tdb.backends.sqlite.compareAndSetGlyph = function(self, rec, expected, now)
        local cur = self:getGlyph(rec.lang, rec.ch)
        return gcas(self, rec, cur and cur.version or 0, now)
    end
    print('red arm: the version check is skipped')
end
if os.getenv('VP_TDB_RED') == '5' then
    local png = VP.glyphs.pagePng
    VP.glyphs.pagePng = function(w, l, font) return png(w, l, type(font) == 'table' and 'US' or font) end
    print('red arm: pages are drawn from the font database, not the charset')
end
if os.getenv('VP_TDB_RED') == '4' then
    VP.tdb.backends.sqlite.glyphs = function() return {} end
    print('red arm: the charset ignores the database glyphs')
end
if os.getenv('VP_TDB_RED') == '3' then
    VP.languages.charset = function() return VP.constants.font end
    print('red arm: every language gets every letter')
end
if os.getenv('VP_TDB_RED') == '2' then
    VP.tdb.backends.sqlite.transaction = function(self, fn) return fn() end
    print('red arm: transactions do not roll back')
end

local results = { pass = 0, fail = 0 }
local paths = {}

local function tmpdb(options)
    local path = os.tmpname()
    os.remove(path)
    paths[#paths + 1] = path
    local now = 1000
    options = options or {}
    options.clock = function()
        now = now + 1
        return now
    end
    return VP.tdb.open(path, options), path
end

local function eq(a, b, what)
    if type(a) == 'table' and type(b) == 'table' then
        for k, v in pairs(a) do eq(v, b[k], (what or '') .. '.' .. tostring(k)) end
        for k, v in pairs(b) do
            if a[k] == nil then error((what or '') .. '.' .. tostring(k) .. ': missing, expected ' .. tostring(v), 0) end
        end
        return
    end
    if a ~= b then error(string.format('%s: got %s, expected %s', what or 'value', tostring(a), tostring(b)), 0) end
end

local function truthy(v, what) if not v then error(what .. ': expected true', 0) end end

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name, fn } end

local function chars(s)
    local t = {}
    for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do t[#t + 1] = { ch = ch } end
    return t
end

local KEY = 'cbf29ce484222325'

test('serialize round trip', function()
    local toks = {
        { ch = 'a' }, { ch = '"' }, { ch = '\\' }, { ch = '\n' }, { ch = 'é' }, { c = 0 }, { c = 4, args = { 2 } },
        { c = 19, args = { 255, 255 } }, { g = 17, wide = true }, { z = true },
    }
    local s = VP.tdb.serialize(toks)
    local back = VP.tdb.deserialize(s)
    toks[6].args = {}
    eq(back, toks, 'tokens')
    -- What the editor stores must come back as the same editable text.
    local text = '{port 1 0}Mère\n{ssync}{spd 20}Petite {{x}} !{new}\nSuite{pause}{delay 120 0}'
    local stored = VP.tdb.deserialize(VP.tdb.serialize(assert(VP.text.fromEditable(text))))
    eq(VP.text.toEditable(stored), text, 'editable text through the database')
    truthy(s:find('ch="é"', 1, true), 'readable text')
    for _, bad in ipairs({ '', '{', '{{ch="a"}', '{{x=1}}', '{os.exit()}', '{{ch="a"}} x', '{{c=1,args={1,}}}' }) do
        local ok = pcall(VP.tdb.deserialize, bad)
        if ok then error('accepted bad token text: ' .. bad, 0) end
    end
end)

test('put and get', function()
    local db = tmpdb()
    eq(db:get(KEY, 3), nil, 'empty get')
    local ok, row = db:put({ key = KEY, idx = 3, tokens = chars('Bonjour'), status = 1, author = 'ana', srcHash = 'abc' }, 0)
    truthy(ok, 'put')
    eq(row.version, 1, 'version')
    eq(row.createdAt, row.updatedAt, 'timestamps')
    local got = db:get(KEY, 3)
    eq(got.tokens, chars('Bonjour'), 'tokens')
    eq(got.author, 'ana', 'author')
    eq(got.srcHash, 'abc', 'srcHash')
    eq(got.boxW, nil, 'no box override')
    db:close()
end)

test('conflict', function()
    local db = tmpdb()
    db:put({ key = KEY, idx = 3, tokens = chars('Salut'), status = 1, author = 'ana' }, 0)
    local readA, readB = db:get(KEY, 3), db:get(KEY, 3)
    readA.tokens = chars('Bonjour')
    readA.author = 'ana'
    local okA, rowA = db:put(readA, readA.version)
    truthy(okA, 'first writer')
    readB.tokens = chars('Coucou')
    readB.author = 'bob'
    local okB, theirs = db:put(readB, readB.version)
    eq(okB, false, 'second writer conflicts')
    eq(theirs.version, rowA.version, 'conflict returns the stored version')
    eq(theirs.tokens, chars('Bonjour'), 'conflict returns the stored tokens')
    eq(db:get(KEY, 3).tokens, chars('Bonjour'), 'stored row unchanged')
    local okNew = db:put({ key = KEY, idx = 3, tokens = chars('x') }, 0)
    eq(okNew, false, 'creating a row that exists conflicts')
    local okRetry = db:put(readB, theirs.version)
    truthy(okRetry, 'retry on the current version')
    eq(db:get(KEY, 3).tokens, chars('Coucou'), 'retry stored')
    db:close()
end)

test('transaction rollback and commit', function()
    local db = tmpdb()
    local ok = pcall(db.transaction, db, function(tx)
        tx:put({ key = KEY, idx = 3, tokens = chars('a') }, 0)
        tx:put({ key = KEY, idx = 4, tokens = chars('b') }, 0)
        error('abort')
    end)
    eq(ok, false, 'transaction raised')
    eq(db:get(KEY, 3), nil, 'first write rolled back')
    eq(db:get(KEY, 4), nil, 'second write rolled back')
    eq(#db:history(KEY, 3), 0, 'history rolled back')
    db:transaction(function(tx)
        tx:put({ key = KEY, idx = 3, tokens = chars('a') }, 0)
        tx:put({ key = KEY, idx = 4, tokens = chars('b') }, 0)
    end)
    truthy(db:get(KEY, 3) and db:get(KEY, 4), 'both committed')
    db:close()
end)

test('migrations', function()
    local db, path = tmpdb()
    db:put({ key = KEY, idx = 3, tokens = chars('a') }, 0)
    local n = 0
    for k in pairs(VP.tdb.migrations) do n = math.max(n, k) end
    eq(db.backend.migration, n, 'fresh database is at the last migration')
    db:close()
    local more = {}
    for k, v in pairs(VP.tdb.migrations) do more[k] = v end
    local ran = 0
    more[n + 1] = function(sdb)
        ran = ran + 1
        sdb:exec 'ALTER TABLE strings ADD COLUMN glossary TEXT'
    end
    local db2 = VP.tdb.open(path, { migrations = more })
    eq(ran, 1, 'new migration ran')
    eq(db2.backend.migration, n + 1, 'meta updated')
    eq(db2:get(KEY, 3).tokens, chars('a'), 'rows kept')
    truthy(db2.backend.db:first("SELECT 1 AS one FROM pragma_table_info('strings') WHERE name = 'glossary'"),
        'column added')
    db2:close()
    local db3 = VP.tdb.open(path, { migrations = more })
    eq(ran, 1, 'migration not run twice')
    db3:close()
    local ok, err = pcall(VP.tdb.open, path)
    eq(ok, false, 'older code refuses a newer database')
    truthy(tostring(err):find('newer than this code knows', 1, true), 'message: ' .. tostring(err))
    local broken = {}
    for k, v in pairs(more) do broken[k] = v end
    broken[n + 2] = function(sdb)
        sdb:exec 'CREATE TABLE half (x INTEGER)'
        error('migration fails')
    end
    eq(pcall(VP.tdb.open, path, { migrations = broken }), false, 'failing migration raises')
    local db4 = VP.tdb.open(path, { migrations = more })
    eq(db4.backend.migration, n + 1, 'failed migration not recorded')
    eq(db4.backend.db:first("SELECT name FROM sqlite_master WHERE name = 'half'"), nil, 'failed migration rolled back')
    db4:close()
end)

test('soft delete', function()
    local db = tmpdb()
    local _, row = db:put({ key = KEY, idx = 3, tokens = chars('a'), status = 1 }, 0)
    db:put({ key = KEY, idx = 4, tokens = chars('b'), status = 1 }, 0)
    eq((db:delete(KEY, 3, 0)), false, 'stale delete conflicts')
    local ok, del = db:delete(KEY, 3, row.version, 'bob')
    truthy(ok, 'delete')
    truthy(del.deletedAt, 'deletedAt set')
    eq(del.version, row.version + 1, 'delete bumps the version')
    eq(del.tokens, chars('a'), 'tokens kept')
    local seen = {}
    for r in db:query {} do seen[#seen + 1] = r.idx end
    eq(seen, { 4 }, 'query hides deleted rows')
    seen = {}
    for r in db:query { deleted = true } do seen[#seen + 1] = r.idx end
    eq(seen, { 3, 4 }, 'query with deleted=true shows them')
    truthy(db:get(KEY, 3).deletedAt, 'get returns the deleted row')
    local okBack, back = db:put(db:get(KEY, 3), del.version)
    truthy(okBack, 'put brings it back')
    eq(back.deletedAt, nil, 'deletedAt cleared')
    db:close()
end)

test('history', function()
    local db = tmpdb()
    local _, r1 = db:put({ key = KEY, idx = 3, tokens = chars('a'), author = 'ana' }, 0)
    r1.tokens = chars('ab')
    local _, r2 = db:put(r1, r1.version)
    r2.tokens, r2.author = chars('abc'), 'bob'
    local _, r3 = db:put(r2, r2.version)
    db:delete(KEY, 3, r3.version, 'cy')
    db:put({ key = KEY, idx = 4, tokens = chars('other') }, 0)
    local h = db:history(KEY, 3)
    eq(#h, 4, 'one entry per write')
    for i, e in ipairs(h) do eq(e.version, i, 'version ' .. i) end
    eq(h[1].tokens, chars('a'), 'first tokens')
    eq(h[3].tokens, chars('abc'), 'third tokens')
    eq(h[3].author, 'bob', 'third author')
    eq(h[4].author, 'cy', 'deleter')
    truthy(h[4].deletedAt, 'delete recorded')
    eq(h[1].deletedAt, nil, 'first not deleted')
    db:close()
end)

test('query filters', function()
    local db = tmpdb()
    db:put({ key = 'k1', idx = 3, tokens = chars('a'), status = 1, author = 'ana' }, 0)
    db:put({ key = 'k1', idx = 4, tokens = chars('b'), status = 2, author = 'bob' }, 0)
    db:put({ key = 'k2', idx = 3, tokens = chars('c'), status = 1, author = 'bob' }, 0)
    local function ids(filter)
        local t = {}
        for r in db:query(filter) do t[#t + 1] = r.key .. ':' .. r.idx end
        return table.concat(t, ' ')
    end
    eq(ids {}, 'k1:3 k1:4 k2:3', 'all')
    eq(ids { status = 1 }, 'k1:3 k2:3', 'status')
    eq(ids { author = 'bob' }, 'k1:4 k2:3', 'author')
    eq(ids { script = 'k1' }, 'k1:3 k1:4', 'script')
    eq(ids { status = 1, author = 'bob' }, 'k2:3', 'status and author')
    eq(ids { script = "k1' OR 1=1 --" }, '', 'values are bound, not spliced')
    db:close()
end)

test('beforeSave refuses a reviewed row the game cannot wrap', function()
    local db = tmpdb()
    local long = chars(string.rep('W', 40))
    local box = { x = 24, y = 16, width = 100, height = 42 }
    local ok, err = db:put({ key = KEY, idx = 3, tokens = long, status = 2 }, 0, { box = box })
    eq(ok, nil, 'refused')
    truthy(err and err:find('wider than the box', 1, true), 'message names the cause: ' .. tostring(err))
    eq(db:get(KEY, 3), nil, 'nothing written')
    truthy(db:put({ key = KEY, idx = 3, tokens = long, status = 1 }, 0, { box = box }), 'a draft may overflow')
    local w = VP.glyphs.measureTokens(long)[1][1]
    local row = db:get(KEY, 3)
    row.status, row.boxW = 2, w
    truthy(db:put(row, row.version, { box = box }), 'reviewed once the box override is wide enough')
    -- The game wraps a long line at its spaces and scrolls a page with more
    -- lines than the box holds: neither stops a review.
    local words = chars(string.rep('WWW ', 30))
    local okW, errW = db:put({ key = KEY, idx = 4, tokens = words, status = 2 }, 0, { box = box })
    truthy(okW, 'a line that wraps into a scrolling page is reviewed: ' .. tostring(errW))
    local problems, notes, pages = VP.tdb.fitProblems(words, box)
    eq(#problems, 0, 'no problems')
    truthy(#pages[1] > 3 and #notes == 1, 'wrapped to ' .. #pages[1] .. ' lines, one scroll note')
    local tall = chars('a')
    for _ = 1, 3 do
        tall[#tall + 1] = { c = 0, args = {} }
        tall[#tall + 1] = { ch = 'a' }
    end
    local okT, errT = db:put({ key = KEY, idx = 6, tokens = tall, status = 2 }, 0, { box = box })
    truthy(okT, 'four lines in a three-line box scroll, and are reviewed: ' .. tostring(errT))
    local _, tallNotes = VP.tdb.fitProblems(tall, box)
    truthy(tallNotes[1] and tallNotes[1]:find('4 lines in a 3-line box', 1, true), 'note: ' .. tostring(tallNotes[1]))
    truthy(db:put({ key = KEY, idx = 5, tokens = long, status = 2 }, 0, { box = { width = 'var', height = 'var' } }),
        'unknown box dimensions are not checked')
    db:close()
end)

test('editable codec', function()
    local toks = {
        { ch = 'O' }, { ch = 'k' }, { ch = '{' }, { ch = '}' }, { c = 2, args = {} }, { c = 0, args = {} },
        { c = 3, args = { 255 } }, { c = 3, args = { 2 } }, { c = 4, args = { 5 } }, { c = 1, args = {} },
        { c = 7, args = { 3 } }, { ch = '.' }, { c = 7, args = { 1 } }, { c = 17, args = { 30, 1 } },
        { c = 19, args = { 255, 255 } }, { c = 6, args = { 1, 2 } }, { c = 9, args = {} }, { g = 200 },
        { ch = 'é' },
    }
    local text = VP.text.toEditable(toks)
    eq(text, 'Ok{{}}{pause}\n{rspd}{spd 2}{clr 5}{new}\n{rep 3}.{rrep}{delay 30 1}{dport}{c6 1 2}{c9}{g 200}é',
        'editable text')
    eq(VP.text.fromEditable(text), toks, 'parsed back')
    local function refuses(s, what)
        local t, err = VP.text.fromEditable(s)
        if t then error('accepted ' .. what, 0) end
        return err
    end
    truthy(refuses('abc\1', 'a character with no glyph'):find('No glyph', 1, true), 'unknown glyph message')
    refuses('{bogus}', 'an unknown tag')
    refuses('{clr}', 'a missing argument')
    refuses('{clr 256}', 'an argument above 255')
    refuses('{pause 1}', 'an extra argument')
    refuses('{rspd 1}', 'an argument on an alias')
    refuses('a}b', 'a lone }')
    refuses('{new', 'an unclosed tag')
end)

test('languages', function()
    -- A database made before the settings migration upgrades to fr from en.
    local path = os.tmpname()
    os.remove(path)
    paths[#paths + 1] = path
    local old = VP.tdb.open(path, { migrations = { VP.tdb.migrations[1] } })
    old:close()
    local db = VP.tdb.open(path)
    eq(db:targetLanguage(), 'fr', 'upgraded target')
    eq(db:sourceLanguage(), 'en', 'upgraded source')
    db:close()
    db = tmpdb()
    eq(db:targetLanguage(), 'fr', 'new target')
    truthy(db:setLanguage('target', 'fr-CA'), 'fr-CA accepted')
    eq(db:targetLanguage(), 'fr-CA', 'target set')
    for _, bad in ipairs({ 'french!', '', 'f', 'fr-', 'fr--CA', 'toolongsubtag-x', 'fr-abcdefghi' }) do
        local ok = db:setLanguage('target', bad)
        if ok then error('accepted the tag ' .. bad, 0) end
    end
    eq(db:targetLanguage(), 'fr-CA', 'a refused tag changes nothing')
    -- fr-CA uses the fr letters; en has none, so the same text no longer parses
    -- or fits, exactly as a character with no glyph at all.
    truthy(db:charset()['é'], 'fr-CA has é')
    truthy(VP.text.fromEditable('été', 'primary', db:charset()), 'été parses in fr-CA')
    db:setLanguage('target', 'en')
    eq(db:charset()['é'], nil, 'en has no é')
    truthy(db:charset()['e'], 'en has e')
    local t, err = VP.text.fromEditable('été', 'primary', db:charset())
    eq(t, nil, 'été parses in en')
    truthy(err:find('No glyph for é', 1, true), 'refused as a missing glyph: ' .. tostring(err))
    local problems = VP.tdb.fitProblems(chars('été'), { width = 100, height = 14 }, nil, db:charset())
    eq(problems[1], '2 characters have no glyph', 'fit check in en')
    local ok, msg = db:put({ key = 'k', idx = 3, tokens = chars('été'), status = VP.tdb.status.reviewed }, 0,
        { box = { width = 100, height = 14 } })
    eq(ok, nil, 'reviewed save in en')
    truthy(msg:find('no glyph', 1, true), 'reviewed save refused on the glyph: ' .. tostring(msg))
    db:setLanguage('target', 'fr')
    truthy(db:put({ key = 'k', idx = 3, tokens = chars('été'), status = VP.tdb.status.reviewed }, 0,
        { box = { width = 100, height = 14 } }), 'reviewed save in fr')
    -- The retail font has no French letters; the font database has them all.
    eq(VP.constants.retailFont['é'], nil, 'retail font has no é')
    truthy(VP.constants.font['é'], 'font database has é')
end)

test('glyphs', function()
    local F = VP.fontedit
    -- A database made before the glyphs migration upgrades with none.
    local path = os.tmpname()
    os.remove(path)
    paths[#paths + 1] = path
    local old = VP.tdb.open(path, { migrations = { VP.tdb.migrations[1], VP.tdb.migrations[2] } })
    old:close()
    local up = VP.tdb.open(path)
    eq(next(up:glyphEdits()), nil, 'upgraded database has no glyphs')
    up:close()

    local db = tmpdb()
    local base = db:charset()['é']
    eq(base.width, 6, 'retail-set é advance')
    -- Edit é: one more column, advance 7.
    local rows = F.rows(base.data)
    for y = 0, F.HEIGHT - 1 do
        if F.get(rows, 4, y) then F.set(rows, 5, y, true) end
    end
    eq(F.extent(rows), 6, 'edited extent')
    eq(F.suggestedWidth(rows), 7, 'suggested advance')
    local ok, g = db:putGlyph({ ch = 'é', width = 7, data = F.encode(rows), author = 'ana' }, 0)
    truthy(ok, 'é stored')
    eq(g.version, 1, 'é version')
    eq(db:charset()['é'].width, 7, 'charset uses the edit')
    eq(db:charset()['é'].data, F.encode(rows), 'charset uses the edited bitmap')
    eq(VP.languages.charset('fr')['é'].width, 6, 'the language set is untouched')
    eq(VP.constants.font['é'].width, 6, 'the font database is untouched')
    local widths = VP.glyphs.measureTokens(chars('éé'), nil, nil, db:charset())
    eq(widths[1][1], 14, 'measured with the edited advance')
    -- A stale write is a conflict, not last-writer-wins.
    local ok2, cur = db:putGlyph({ ch = 'é', width = 8, data = F.encode(rows), author = 'bo' }, 0)
    eq(ok2, false, 'stale glyph write')
    eq(cur.author, 'ana', 'conflict returns the stored glyph')
    eq(db:charset()['é'].width, 7, 'conflict changed nothing')
    -- Add a character the language set does not have.
    eq(db:charset()['ñ'], nil, 'fr has no ñ')
    local t0 = VP.text.fromEditable('año', 'primary', db:charset())
    eq(t0, nil, 'año refused before ñ exists')
    local n = F.blank()
    for x = 0, 4 do F.set(n, x, 1, true) end
    for y = 4, 8 do
        F.set(n, 0, y, true)
        F.set(n, 4, y, true)
    end
    for x = 1, 3 do F.set(n, x, 3, true) end
    truthy(db:putGlyph({ ch = 'ñ', width = F.suggestedWidth(n), data = F.encode(n), author = 'ana' }, 0), 'ñ added')
    truthy(VP.text.fromEditable('año', 'primary', db:charset()), 'año parses once ñ exists')
    eq(#VP.tdb.fitProblems(chars('año'), { width = 100, height = 14 }, nil, db:charset()), 0, 'año fits')
    eq(F.origin('ñ', 'fr', true), 'added', 'ñ is added')
    eq(F.origin('é', 'fr', true), 'edited', 'é is edited')
    eq(F.origin('e', 'fr', false), 'retail', 'e is retail')
    eq(F.origin('ê', 'fr', false), 'letter', 'ê is a French letter')
    -- Glyphs belong to the target language's primary subtag.
    db:setLanguage('target', 'en')
    eq(db:charset()['ñ'], nil, 'en does not see the French ñ')
    db:setLanguage('target', 'fr-CA')
    truthy(db:charset()['ñ'], 'fr-CA sees the French ñ')
    -- Refusals.
    for _, bad in ipairs({
        { ch = 'ab', width = 6, data = F.encode(n) },
        { ch = '', width = 6, data = F.encode(n) },
        { ch = '\n', width = 6, data = F.encode(n) },
        { ch = 'x', width = 0, data = F.encode(n) },
        { ch = 'x', width = 17, data = F.encode(n) },
        { ch = 'x', width = 6, data = 'AAAA' },
        { ch = 'x', width = 6, height = 11, data = F.encode(n) },
    }) do
        local okb, msg = db:putGlyph(bad, 0)
        if okb ~= nil then error('accepted a bad glyph ' .. tostring(bad.ch) .. '/' .. tostring(bad.width), 0) end
        truthy(msg:find('Glyph not saved', 1, true), 'refusal message: ' .. tostring(msg))
    end
    local _, notes = F.check({ ch = 'x', width = 3, data = F.encode(n) })
    truthy(notes[1] and notes[1]:find('overlaps', 1, true), 'advance under the extent is noted')
    local _, notes2 = F.check({ ch = 'q', width = 6, data = db:charset()['e'].data }, db:charset())
    truthy(table.concat(notes2, ' '):find('same glyph as e', 1, true), 'a shared bitmap is noted')
    -- In-game preview: a room font holding the retail e and é gets the edited é
    -- appended (its bitmap is new), and nothing for an unedited e.
    local function roomFont(list)
        local f = { height = 12, widths = {}, bitmaps = {} }
        for i, ch in ipairs(list) do
            local gl = VP.languages.charset('fr')[ch]
            f.widths[i], f.bitmaps[i] = gl.width, base64.decode(gl.data)
        end
        return VP.preview.buildFont(f)
    end
    local fontBytes = roomFont({ 'e', 'é' })
    local out, newFont, added = VP.preview.resolveChars({ [1] = { tokens = chars('eé') } }, fontBytes, db:charset())
    eq(added, 1, 'edited é appended to the room font')
    eq(out[1].tokens[1].g, 1, 'e keeps the room glyph')
    eq(out[1].tokens[2].g, 3, 'é uses the appended glyph')
    -- The web preview draws the edited glyph; the language set's draws the old one.
    local edPng = VP.glyphs.pagePng(nil, { 'é' }, db:charset())
    local basePng = VP.glyphs.pagePng(nil, { 'é' }, VP.languages.charset('fr'))
    truthy(edPng ~= basePng, 'translated page drawn with the edited é')
    local nf = VP.preview.parseFont(newFont)
    eq(nf.widths[3], 7, 'appended glyph has the edited advance')
    eq(nf.bitmaps[3], base64.decode(F.encode(rows)), 'appended glyph has the edited bitmap')
    -- Delete restores the language glyph; history keeps every version.
    local okd, del = db:deleteGlyph('é', 1, 'bo')
    truthy(okd, 'é deleted')
    eq(del.deletedAt ~= nil, true, 'soft deleted')
    eq(db:charset()['é'].width, 6, 'é back to the French letter')
    local _, _, addedAfter = VP.preview.resolveChars({ [1] = { tokens = chars('é') } }, fontBytes, db:charset())
    eq(addedAfter, 0, 'restored é is the room font glyph again')
    eq(VP.glyphs.pagePng(nil, { 'é' }, db:charset()), basePng, 'restored é drawn as the French letter')
    truthy(db:putGlyph({ ch = 'é', width = 6, data = base.data, author = 'ana' }, 2), 'é written again')
    local h = db:glyphHistory('é')
    eq(#h, 3, 'é history')
    eq(h[1].width, 7, 'history v1')
    eq(h[2].deletedAt ~= nil, true, 'history v2 is the delete')
    eq(h[3].deletedAt, nil, 'history v3 brings it back')
    db:close()
end)

test('glyph entries and JP duplicates', function()
    local F = VP.fontedit
    local list = F.entries('fr', { ['ñ'] = { width = 6, height = 12, data = VP.constants.font['n'].data } })
    local byCh = {}
    for _, e in ipairs(list) do byCh[e.ch] = e end
    eq(byCh['ñ'].origin, 'added', 'added entry listed')
    eq(byCh['é'].origin, 'letter', 'French letter listed')
    eq(byCh['A'].origin, 'retail', 'retail letter listed')
    truthy(list[1].ch == ' ', 'sorted by codepoint, space first: ' .. list[1].ch)
    local dups = F.jpDuplicates()
    truthy(#dups > 0, 'the JP database has duplicated characters')
    local total = 0
    for _, d in ipairs(dups) do
        total = total + d.count
        eq(#F.jpVariants(d.ch), d.count, 'variants of ' .. d.ch)
    end
    truthy(#VP.constants.fontJPVariants > 0, 'JP variants loaded')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t[2])
    if ok then
        results.pass = results.pass + 1
        print('PASS ' .. t[1])
    else
        results.fail = results.fail + 1
        print('FAIL ' .. t[1] .. ': ' .. tostring(err))
    end
end
for _, p in ipairs(paths) do
    os.remove(p)
    os.remove(p .. '-journal')
end
print(string.format('TDB %s: %d/%d tests pass', results.fail == 0 and 'PASS' or 'FAIL', results.pass,
    results.pass + results.fail))
PCSX.quit(results.fail == 0 and 0 or 1)
