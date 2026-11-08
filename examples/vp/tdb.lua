-- Translation database.
--
-- One row per translated string, keyed by the room script it belongs to
-- (VP.text.scriptKey, so rooms sharing a script share rows) and the pointer
-- index in that script. A row holds the translation as a token list, optional
-- overrides of the textbox geometry, a status, and bookkeeping.
--
--   local db = VP.tdb.open('vp-fr.tdb')
--   local row = db:get(key, idx)            -- nil when nothing was ever saved
--   local ok, theirs = db:put(row, row and row.version or 0)
--   for row in db:query { status = VP.tdb.status.draft } do ... end
--   db:transaction(function(tx) ... end)    -- commits on return, rolls back on error
--   for _, h in ipairs(db:history(key, idx)) do ... end
--
-- Writes are versioned. put() names the version it read (0 for a row that does
-- not exist yet). If the stored row has moved on since, nothing is written and
-- put() returns false and the stored row, so the caller can show both. A local
-- database never conflicts with itself; the check is there so a shared backend
-- can slot in behind the same interface.
--
-- Rows are never removed: delete() sets deletedAt and bumps the version, and a
-- later put() on that version brings the row back. Every write also appends the
-- new state to the history, inside the same transaction.
--
-- Row fields: key, idx, srcHash (FNV-1a 64 of the original string's bytes, to
-- notice a changed source), tokens (the translation, see VP.text.fromEditable),
-- boxX, boxY, boxW, boxH (nil keeps the original geometry), status, author,
-- note, version, createdAt, updatedAt, deletedAt (seconds since the epoch).

VP.tdb = VP.tdb or {}

VP.tdb.status = { untranslated = 0, draft = 1, reviewed = 2 }
VP.tdb.statusNames = { [0] = 'untranslated', [1] = 'draft', [2] = 'reviewed' }

-- Token lists are stored as text. This pair is the only place that knows the
-- format, so changing it is a change to these two functions.
--
-- The text is a Lua table constructor, readable and greppable in the database
-- file: { {ch="B"}, {ch="o"}, {c=0}, {c=4,args={2}} }. It is parsed by hand
-- rather than loaded, since a shared database is not trusted code.
local tokenFields = { ch = 'string', g = 'number', c = 'number', z = 'boolean', wide = 'boolean' }

local function quote(s)
    return '"' .. s:gsub('[%c"\\]', function(ch)
        if ch == '"' or ch == '\\' then return '\\' .. ch end
        return string.format('\\%03d', ch:byte())
    end) .. '"'
end

function VP.tdb.serialize(tokens)
    local out = {}
    for i, t in ipairs(tokens) do
        local f = {}
        if t.ch then f[#f + 1] = 'ch=' .. quote(t.ch) end
        if t.g then f[#f + 1] = 'g=' .. string.format('%d', t.g) end
        if t.c then
            f[#f + 1] = 'c=' .. string.format('%d', t.c)
            if t.args and #t.args > 0 then
                local a = {}
                for j, v in ipairs(t.args) do a[j] = string.format('%d', v) end
                f[#f + 1] = 'args={' .. table.concat(a, ',') .. '}'
            end
        end
        if t.z then f[#f + 1] = 'z=true' end
        if t.wide then f[#f + 1] = 'wide=true' end
        if #f == 0 then error('Cannot serialize token ' .. i) end
        out[i] = '{' .. table.concat(f, ',') .. '}'
    end
    return '{' .. table.concat(out, ',') .. '}'
end

function VP.tdb.deserialize(s)
    local pos = 1
    local function fail(what) error(string.format('Bad token text at %d: %s', pos, what), 0) end
    local function skip() pos = s:find('[^ \t\r\n]', pos) or #s + 1 end
    local function eat(ch)
        skip()
        if s:sub(pos, pos) ~= ch then return false end
        pos = pos + 1
        return true
    end
    local function expect(ch) if not eat(ch) then fail('expected ' .. ch) end end
    local function number()
        skip()
        local n = s:match('^%-?%d+', pos)
        if not n then fail('expected a number') end
        pos = pos + #n
        return tonumber(n)
    end
    local function str()
        skip()
        if s:sub(pos, pos) ~= '"' then fail('expected a string') end
        pos = pos + 1
        local out = {}
        while true do
            local ch = s:sub(pos, pos)
            if ch == '' then fail('unterminated string') end
            pos = pos + 1
            if ch == '"' then break end
            if ch == '\\' then
                local d = s:match('^%d%d%d', pos)
                if d then
                    ch = string.char(tonumber(d))
                    pos = pos + 3
                else
                    ch = s:sub(pos, pos)
                    if ch ~= '"' and ch ~= '\\' then fail('bad escape') end
                    pos = pos + 1
                end
            end
            out[#out + 1] = ch
        end
        return table.concat(out)
    end
    local tokens = {}
    expect('{')
    while not eat('}') do
        if #tokens > 0 then expect(',') end
        expect('{')
        local t = {}
        while not eat('}') do
            if next(t) then expect(',') end
            skip()
            local name = s:match('^%a+', pos)
            if not name then fail('expected a field name') end
            pos = pos + #name
            expect('=')
            if name == 'args' then
                expect('{')
                t.args = {}
                while not eat('}') do
                    if #t.args > 0 then expect(',') end
                    t.args[#t.args + 1] = number()
                end
            elseif tokenFields[name] == 'string' then
                t[name] = str()
            elseif tokenFields[name] == 'number' then
                t[name] = number()
            elseif tokenFields[name] == 'boolean' then
                skip()
                if s:sub(pos, pos + 3) ~= 'true' then fail('expected true') end
                pos = pos + 4
                t[name] = true
            else
                fail('unknown field ' .. name)
            end
        end
        tokens[#tokens + 1] = t
    end
    skip()
    if pos <= #s then fail('trailing text') end
    return tokens
end

-- Numbered, add-only schema migrations. A database records the last one it
-- ran in meta.migration; opening runs the ones after it, each in its own
-- transaction. Never edit a migration once it has shipped: add the next one.
VP.tdb.migrations = {
    [1] = function(db)
        db:exec [[
CREATE TABLE strings (
    script_key TEXT NOT NULL,
    ptr_idx INTEGER NOT NULL,
    src_hash TEXT,
    tokens TEXT,
    box_x INTEGER, box_y INTEGER, box_w INTEGER, box_h INTEGER,
    status INTEGER NOT NULL DEFAULT 0,
    author TEXT,
    note TEXT,
    version INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER,
    PRIMARY KEY (script_key, ptr_idx)
);
CREATE INDEX strings_status ON strings (status);
CREATE INDEX strings_author ON strings (author);
CREATE TABLE history (
    id INTEGER PRIMARY KEY,
    script_key TEXT NOT NULL,
    ptr_idx INTEGER NOT NULL,
    version INTEGER NOT NULL,
    src_hash TEXT,
    tokens TEXT,
    box_x INTEGER, box_y INTEGER, box_w INTEGER, box_h INTEGER,
    status INTEGER NOT NULL,
    author TEXT,
    note TEXT,
    at INTEGER NOT NULL,
    deleted_at INTEGER
);
CREATE INDEX history_row ON history (script_key, ptr_idx, version);
]]
    end,
}

-- Columns of a stored record, in table order, and the row field each maps to.
local columns = {
    { 'script_key', 'key' }, { 'ptr_idx', 'idx' }, { 'src_hash', 'srcHash' }, { 'tokens', 'tokens' },
    { 'box_x', 'boxX' }, { 'box_y', 'boxY' }, { 'box_w', 'boxW' }, { 'box_h', 'boxH' },
    { 'status', 'status' }, { 'author', 'author' }, { 'note', 'note' }, { 'version', 'version' },
    { 'created_at', 'createdAt' }, { 'updated_at', 'updatedAt' }, { 'deleted_at', 'deletedAt' },
}
local historyColumns = {
    { 'script_key', 'key' }, { 'ptr_idx', 'idx' }, { 'version', 'version' }, { 'src_hash', 'srcHash' },
    { 'tokens', 'tokens' }, { 'box_x', 'boxX' }, { 'box_y', 'boxY' }, { 'box_w', 'boxW' }, { 'box_h', 'boxH' },
    { 'status', 'status' }, { 'author', 'author' }, { 'note', 'note' }, { 'at', 'updatedAt' },
    { 'deleted_at', 'deletedAt' },
}

local function fromColumns(r, cols)
    if not r then return nil end
    local rec = {}
    for _, c in ipairs(cols) do rec[c[2]] = r[c[1]] end
    return rec
end

local function columnList(cols)
    local names = {}
    for i, c in ipairs(cols) do names[i] = c[1] end
    return table.concat(names, ', ')
end

-- Backends store records: rows whose tokens are already serialized text. A
-- backend provides get, compareAndSet, query, history, transaction and close.
-- compareAndSet(record, expectedVersion, now) stores the record as version
-- expectedVersion + 1 when the stored version is expectedVersion (0 meaning no
-- stored row), and returns true and the stored record, or false and the
-- current record.
VP.tdb.backends = VP.tdb.backends or {}

local sqlite = {}
sqlite.__index = sqlite
VP.tdb.backends.sqlite = sqlite

function sqlite.open(path, options)
    local self = setmetatable({ db = PCSX.SQLite.open(path) }, sqlite)
    self.db:busyTimeout(5000)
    self.db:exec 'CREATE TABLE IF NOT EXISTS meta (migration INTEGER NOT NULL)'
    if not self.db:first 'SELECT migration FROM meta' then self.db:run 'INSERT INTO meta (migration) VALUES (0)' end
    local migrations = options and options.migrations or VP.tdb.migrations
    local current = self.db:first('SELECT migration FROM meta').migration
    if not migrations[current] and current ~= 0 then
        self.db:close()
        error('Translation database ' .. path .. ' is at migration ' .. current ..
            ', newer than this code knows; update the example', 2)
    end
    local n = current + 1
    while migrations[n] do
        self.db:transaction(function()
            migrations[n](self.db)
            self.db:run('UPDATE meta SET migration = ?', n)
        end)
        n = n + 1
    end
    self.migration = n - 1
    return self
end

local selectRow = 'SELECT ' .. columnList(columns) .. ' FROM strings WHERE script_key = ? AND ptr_idx = ?'

function sqlite:get(key, idx)
    return fromColumns(self.db:first(selectRow, key, idx), columns)
end

function sqlite:compareAndSet(rec, expectedVersion, now)
    return self.db:transaction(function()
        local cur = self:get(rec.key, rec.idx)
        local curVersion = cur and cur.version or 0
        if curVersion ~= expectedVersion then return false, cur end
        local stored = {}
        for k, v in pairs(rec) do stored[k] = v end
        stored.version = curVersion + 1
        stored.createdAt = cur and cur.createdAt or now
        stored.updatedAt = now
        local values = {}
        for i, c in ipairs(columns) do values[i] = stored[c[2]] end
        local slots = string.rep('?', #columns, ', ')
        self.db:run('INSERT OR REPLACE INTO strings (' .. columnList(columns) .. ') VALUES (' .. slots .. ')',
            unpack(values, 1, #columns))
        local hvalues = {}
        for i, c in ipairs(historyColumns) do hvalues[i] = stored[c[2]] end
        self.db:run('INSERT INTO history (' .. columnList(historyColumns) .. ') VALUES (' ..
            string.rep('?', #historyColumns, ', ') .. ')', unpack(hvalues, 1, #historyColumns))
        return true, stored
    end)
end

-- filter: status, script, author (each optional, matched exactly), deleted
-- (true to include soft-deleted rows). Rows come back ordered by key and index.
function sqlite:query(filter)
    filter = filter or {}
    local where, args = {}, {}
    if filter.status ~= nil then
        where[#where + 1] = 'status = ?'
        args[#args + 1] = filter.status
    end
    if filter.script ~= nil then
        where[#where + 1] = 'script_key = ?'
        args[#args + 1] = filter.script
    end
    if filter.author ~= nil then
        where[#where + 1] = 'author = ?'
        args[#args + 1] = filter.author
    end
    if not filter.deleted then where[#where + 1] = 'deleted_at IS NULL' end
    local sql = 'SELECT ' .. columnList(columns) .. ' FROM strings'
    if #where > 0 then sql = sql .. ' WHERE ' .. table.concat(where, ' AND ') end
    sql = sql .. ' ORDER BY script_key, ptr_idx'
    -- Read everything before handing out rows, so a caller writing inside its
    -- loop does not run into the read statement.
    local list = {}
    for r in self.db:rows(sql, unpack(args, 1, #args)) do list[#list + 1] = fromColumns(r, columns) end
    return list
end

function sqlite:history(key, idx)
    local list = {}
    for r in self.db:rows('SELECT ' .. columnList(historyColumns) ..
        ' FROM history WHERE script_key = ? AND ptr_idx = ? ORDER BY version', key, idx) do
        list[#list + 1] = fromColumns(r, historyColumns)
    end
    return list
end

function sqlite:transaction(fn) return self.db:transaction(fn) end

function sqlite:close() self.db:close() end

-- The database object the editor uses, over any backend.
local tdb = {}
tdb.__index = tdb

local function toRow(rec)
    if not rec then return nil end
    local row = {}
    for k, v in pairs(rec) do row[k] = v end
    if rec.tokens then row.tokens = VP.tdb.deserialize(rec.tokens) end
    return row
end

-- target: a path to a local sqlite file, or a table naming a backend
-- ({ backend = 'sqlite', path = ... }, later a remote one). options.clock
-- replaces os.time for timestamps, options.migrations the migration list.
function VP.tdb.open(target, options)
    options = options or {}
    local backend
    if type(target) == 'string' then
        backend = sqlite.open(target, options)
    elseif type(target) == 'table' then
        local impl = VP.tdb.backends[target.backend or 'sqlite']
        if not impl then error('No translation database backend named ' .. tostring(target.backend), 2) end
        backend = impl.open(target.path, options)
    else
        error('VP.tdb.open: needs a path or a backend description', 2)
    end
    return setmetatable({
        backend = backend,
        clock = options.clock or os.time,
        hooks = { beforeSave = { VP.tdb.fitHook } },
    }, tdb)
end

-- The stored row for (key, idx), soft-deleted or not, or nil.
function tdb:get(key, idx) return toRow(self.backend:get(key, idx)) end

-- Stores row as the new version of (row.key, row.idx). expectedVersion is the
-- version the caller read, 0 when it read no row. Returns true and the stored
-- row; false and the current row on a version conflict; nil and a message when
-- a beforeSave hook refused the row. context is passed to the hooks (the
-- editor gives the original textbox there).
function tdb:put(row, expectedVersion, context)
    if type(row.key) ~= 'string' or type(row.idx) ~= 'number' then error('tdb:put: row needs key and idx', 2) end
    if type(expectedVersion) ~= 'number' then error('tdb:put: needs the version the row was read at', 2) end
    for _, hook in ipairs(self.hooks.beforeSave) do
        local err = hook(row, context or {}, self)
        if err then return nil, err end
    end
    local rec = {}
    for k, v in pairs(row) do rec[k] = v end
    -- Writing a row is what brings a soft-deleted one back.
    rec.version, rec.createdAt, rec.updatedAt, rec.deletedAt = nil, nil, nil, nil
    rec.status = rec.status or VP.tdb.status.untranslated
    if row.tokens then rec.tokens = VP.tdb.serialize(row.tokens) end
    local ok, stored = self.backend:compareAndSet(rec, expectedVersion, self.clock())
    return ok, toRow(stored)
end

-- Soft delete: same versioning as put.
function tdb:delete(key, idx, expectedVersion, author)
    local cur = self:get(key, idx)
    if not cur then return false, nil end
    cur.deletedAt = self.clock()
    cur.author = author or cur.author
    local rec = {}
    for k, v in pairs(cur) do rec[k] = v end
    rec.version, rec.createdAt, rec.updatedAt = nil, nil, nil
    if cur.tokens then rec.tokens = VP.tdb.serialize(cur.tokens) end
    local ok, stored = self.backend:compareAndSet(rec, expectedVersion, cur.deletedAt)
    return ok, toRow(stored)
end

-- Iterates the rows matching filter ({ status =, script =, author =, deleted = }).
function tdb:query(filter)
    local list, i = self.backend:query(filter), 0
    return function()
        i = i + 1
        return toRow(list[i])
    end
end

-- Every stored state of (key, idx), oldest first. updatedAt is when it was written.
function tdb:history(key, idx)
    local list = self.backend:history(key, idx)
    for i, rec in ipairs(list) do list[i] = toRow(rec) end
    return list
end

-- Runs fn(db) in a transaction: committed when it returns, rolled back when it
-- raises (and the error raised again).
function tdb:transaction(fn)
    return self.backend:transaction(function() return fn(self) end)
end

function tdb:close() self.backend:close() end

-- The geometry a row will be shown in: its overrides over the original box.
-- original is { x, y, width, height } or nil.
function VP.tdb.effectiveBox(row, original)
    original = original or {}
    return {
        x = row.boxX or original.x,
        y = row.boxY or original.y,
        width = row.boxW or original.width,
        height = row.boxH or original.height,
    }
end

-- beforeSave hook: a reviewed row must fit its box. Each line has to fit the
-- box width, and each page fit the box height at 14 pixels a line (a 12 pixel
-- box holds one line, 42 three, 70 five). When the width or height is only known
-- at run time, that dimension is not checked. context.box is the original
-- textbox, context.lookup the script font's glyph-to-character map for any {g}
-- token.
function VP.tdb.fitHook(row, context)
    if row.status ~= VP.tdb.status.reviewed or not row.tokens then return nil end
    local box = VP.tdb.effectiveBox(row, context.box)
    local problems = VP.tdb.fitProblems(row.tokens, box, context.lookup)
    if #problems > 0 then return 'Does not fit its box, so it cannot be marked reviewed: ' .. problems[1] end
    return nil
end

function VP.tdb.fitProblems(tokens, box, lookup)
    local problems = {}
    local widths, missing = VP.glyphs.measureTokens(tokens, lookup)
    if missing > 0 then problems[#problems + 1] = missing .. ' characters have no glyph' end
    local maxLines = type(box.height) == 'number' and math.floor((box.height + 2) / 14) or nil
    for p, page in ipairs(widths) do
        if type(box.width) == 'number' then
            for l, w in ipairs(page) do
                if w > box.width then
                    problems[#problems + 1] = string.format('page %d line %d is %d px, the box is %d px', p, l, w, box.width)
                end
            end
        end
        if maxLines and #page > maxLines then
            problems[#problems + 1] = string.format('page %d has %d lines, the box holds %d', p, #page, maxLines)
        end
    end
    return problems
end
