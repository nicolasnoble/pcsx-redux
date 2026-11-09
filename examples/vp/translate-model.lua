-- The model behind the Translate views (translate.lua for ImGui, the web view
-- for a browser): the open translation database, one pointer's edit state, the
-- versioned save, the fit check and the page previews. Nothing here draws.
--
-- An edit state is a plain table: base (the version it was loaded from), text
-- (the editable form of VP.text.toEditable), status, note, override and
-- boxX/boxY/boxW/boxH, sourceChanged, and optionally author (the translator
-- saving it, M.author when absent). Views keep their own per-pointer table
-- of them and add whatever display fields they need.
--
-- The database file is VP_TDB from the environment, or vp-fr.tdb in the current
-- directory.

VP.tmodel = VP.tmodel or {}
local M = VP.tmodel
M.path = M.path or os.getenv('VP_TDB') or 'vp-fr.tdb'
M.author = M.author or os.getenv('VP_AUTHOR') or os.getenv('USER') or ''

function M.open(path)
    if M.db then M.db:close() end
    M.db, M.dbError = nil, nil
    local ok, db = pcall(VP.tdb.open, path)
    if ok then
        M.db, M.openPath = db, path
        -- An armed in-game preview follows the database the editor uses.
        if VP.preview and VP.preview.armed() then VP.preview.db = db end
    else
        M.dbError = tostring(db)
    end
    return M.db
end

-- The <window .../> line glyphs.windowGeometry reads, for a textbox as
-- extractTextboxes found it, with the row's overrides applied.
function M.windowHead(tb, row)
    if not tb then return nil end
    local over = row and (row.boxX or row.boxY or row.boxW or row.boxH)
    if not over then
        if tb.typ == 'fixed' then return '<window type="fixed"/>' end
        if tb.typ == 'auto' then return '<window type="auto"/>' end
    end
    local x, y = row and row.boxX or tb.x, row and row.boxY or tb.y
    local w, h = row and row.boxW or tb.width, row and row.boxH or tb.height
    if tb.typ == 'fixed' then x, y, w, h = row.boxX or 64, row.boxY or 32, row.boxW or 192, row.boxH or 14 end
    return string.format('<window x="%s" y="%s" width="%s" height="%s"%s/>', tostring(x), tostring(y), tostring(w),
        tostring(h), tb.placement and ' placement="helper"' or '')
end

-- The original box, as the fit check sees it: numbers where they are known.
-- A 16x16 box at 16,16 is the placeholder rooms pass for messages the field
-- executable opens with its own geometry (room.lua, nativeWindows); the real
-- size is unknown unless extraction already replaced it. On USA disc 1 it is
-- 1120 of the 1164 retail strings wider than their recorded box.
function M.originalBox(tb)
    if not tb then return {} end
    if tb.typ == 'fixed' then return { x = 64, y = 32, width = 192, height = 14 } end
    if tb.x == 16 and tb.y == 16 and tb.width == 16 and tb.height == 16 then return {} end
    return { x = tonumber(tb.x), y = tonumber(tb.y), width = tonumber(tb.width), height = tonumber(tb.height) }
end

local function srcHash(extra, i) return VP.text.fnv1a64(extra.raw[i]) end

-- The edit state of pointer i as the database holds it now.
function M.loadEdit(extra, i, lookup)
    local row = M.db:get(extra.key, i)
    local live = row and not row.deletedAt
    local e = {
        base = row and row.version or 0,
        text = live and VP.text.toEditable(row.tokens, lookup) or VP.text.toEditable(extra.tokens[i], lookup),
        status = live and row.status or VP.tdb.status.untranslated,
        note = live and row.note or '',
        override = live and (row.boxX or row.boxY or row.boxW or row.boxH) and true or false,
        sourceChanged = row and row.srcHash and row.srcHash ~= srcHash(extra, i),
    }
    local box = M.originalBox(extra.textboxes[i])
    e.boxX = live and row.boxX or box.x or 0
    e.boxY = live and row.boxY or box.y or 0
    e.boxW = live and row.boxW or box.width or 0
    e.boxH = live and row.boxH or box.height or 0
    return e
end

-- The edit's text as tokens, or nil, message, byte position.
-- Only characters of the database's target language parse.
function M.parse(extra, e) return VP.text.fromEditable(e.text, extra.style, M.charset()) end

-- Characters the open database's target language may use.
function M.charset() return M.db and M.db:charset() or VP.constants.font end

-- Sets the open database's languages (BCP 47 tags). Returns true, or nil and
-- a message, in which case neither changed.
function M.setLanguages(target, source)
    if not M.db then return nil, 'No database open' end
    for _, t in ipairs({ target, source }) do
        if not VP.languages.valid(t) then return nil, 'Not a language tag: ' .. tostring(t) end
    end
    M.db:setLanguage('target', target)
    M.db:setLanguage('source', source)
    return true
end

-- The open database's target and source languages, or the defaults.
function M.languages()
    if not M.db then return 'fr', 'en' end
    return M.db:targetLanguage(), M.db:sourceLanguage()
end

local function rowFromEdit(extra, i, e, tokens)
    local row = {
        key = extra.key, idx = i, srcHash = srcHash(extra, i), tokens = tokens, status = e.status,
        author = (e.author or M.author) ~= '' and (e.author or M.author) or nil, note = e.note ~= '' and e.note or nil,
    }
    if e.override then row.boxX, row.boxY, row.boxW, row.boxH = e.boxX, e.boxY, e.boxW, e.boxH end
    return row
end

-- Saves e as the version after `expected`. Returns 'saved', row; 'conflict',
-- their row; or 'error', message. On success e.base and e.sourceChanged follow.
function M.save(extra, i, e, tokens, expected, lookup)
    local ctx = { box = M.originalBox(extra.textboxes[i]), lookup = lookup }
    local ok, r = M.db:put(rowFromEdit(extra, i, e, tokens), expected, ctx)
    if ok then
        e.base, e.sourceChanged = r.version, false
        return 'saved', r
    elseif ok == false then
        return 'conflict', r
    end
    return 'error', r
end

-- First pointer after `from` (wrapping) with no live translation.
function M.nextUntranslated(extra, nptrs, from)
    local n = nptrs - extra.first + 1
    for k = 1, n do
        local i = (from - extra.first + k) % n + extra.first
        local row = M.db:get(extra.key, i)
        if not row or row.deletedAt or row.status == VP.tdb.status.untranslated then return i end
    end
    return nil
end

-- Counts by status over pointers first..nptrs, indexed 0..2.
function M.counts(extra, nptrs)
    local c = { [0] = 0, 0, 0 }
    local seen = 0
    for row in M.db:query { script = extra.key } do
        if row.idx >= extra.first and row.idx <= nptrs then
            c[row.status] = (c[row.status] or 0) + 1
            seen = seen + 1
        end
    end
    c[0] = c[0] + (nptrs - extra.first + 1 - seen)
    return c
end

-- The original page as the game leaves it: window, pages.
function M.originalPreview(ptrText, extra, i, lookup)
    local tb = extra.textboxes[i]
    local ob = M.originalBox(tb)
    local pages = VP.glyphs.pagesFromTokens(extra.tokens[i], lookup, extra.style)
    return VP.glyphs.parse(ptrText), VP.glyphs.scrollPages((VP.glyphs.wrapPages(pages, ob.width)), ob.height)
end

-- The translation in its (possibly overridden) box: window, pages (wrapped,
-- and a page taller than the box scrolled to its last lines), problems, notes.
function M.translationPreview(extra, i, e, tokens, lookup)
    local tb = extra.textboxes[i]
    local row = e.override and { boxX = e.boxX, boxY = e.boxY, boxW = e.boxW, boxH = e.boxH } or nil
    local head = M.windowHead(tb, row)
    local window = head and VP.glyphs.windowGeometry(head) or nil
    local box = VP.tdb.effectiveBox(row or {}, M.originalBox(tb))
    local problems, notes, wrapped = VP.tdb.fitProblems(tokens, box, lookup, M.charset())
    return window, VP.glyphs.scrollPages(wrapped, box.height), problems, notes
end

-- One line per saved version, in the order VP.tdb's history returns them.
function M.history(extra, i, lookup)
    local out = {}
    for _, h in ipairs(M.db:history(extra.key, i)) do
        local t = h.tokens and VP.text.toEditable(h.tokens, lookup):gsub('\n', ' / ') or ''
        if #t > 80 then t = t:sub(1, 80) .. '...' end
        out[#out + 1] = string.format('v%d %s %s %s%s: %s', h.version, os.date('!%Y-%m-%d %H:%M', h.updatedAt),
            h.author or '?', VP.tdb.statusNames[h.status] or '?', h.deletedAt and ' (deleted)' or '', t)
    end
    return out
end
