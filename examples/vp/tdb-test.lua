-- Tests of the translation database (tdb.lua) and the editable text codec, on
-- a temporary sqlite file. No disc is needed.
--
--   pcsx-redux -cli -dofile examples/vp/tdb-test.lua
--
-- Red arms: VP_TDB_RED=1 makes the sqlite backend skip its version check,
-- which the conflict tests must catch; VP_TDB_RED=2 runs transactions without
-- a transaction, which the rollback test must catch.

local here = debug.getinfo(1, 'S').source:match('^@(.*/)') or './'
Support.extra.dofile(here .. 'browser.lua')

if os.getenv('VP_TDB_RED') == '1' then
    local cas = VP.tdb.backends.sqlite.compareAndSet
    VP.tdb.backends.sqlite.compareAndSet = function(self, rec, expected, now)
        local cur = self:get(rec.key, rec.idx)
        return cas(self, rec, cur and cur.version or 0, now)
    end
    print('red arm: the version check is skipped')
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
