-- The Translate viewer: edits one room script's strings into the translation
-- database (tdb.lua), one pointer at a time.
--
-- The translation is typed in the editable text form of VP.text.toEditable:
-- characters as themselves, control codes as {tags}. Characters must exist in
-- the font database; the text is parsed on every edit and a problem is shown
-- under the box. Saving goes through the database's version check, so a row
-- somebody else saved meanwhile opens a dialog with both versions. The page
-- preview draws the translation in the game font beside the original.
--
-- The database file is VP_TDB from the environment, or vp-fr.tdb in the current
-- directory, and can be changed at the top of the viewer.

VP.translate = VP.translate or {}
local T = VP.translate
T.path = T.path or os.getenv('VP_TDB') or 'vp-fr.tdb'
T.author = T.author or os.getenv('VP_AUTHOR') or os.getenv('USER') or ''

-- Pixels per game pixel in the page previews.
T.previewScale = T.previewScale or 2
local PAGE_W, PAGE_H = 320, 240
local RED, GREEN, YELLOW = 0xff5050ff, 0xff60d060, 0xff40c8e8

function T.open(path)
    if T.db then T.db:close() end
    T.db, T.dbError = nil, nil
    local ok, db = pcall(VP.tdb.open, path)
    if ok then
        T.db, T.openPath = db, path
        -- An armed in-game preview follows the database the editor uses.
        if VP.preview and VP.preview.armed() then VP.preview.db = db end
    else
        T.dbError = tostring(db)
    end
    return T.db
end

local function colored(color, text)
    imgui.PushStyleColor(imgui.constant.Col.Text, color)
    imgui.TextUnformatted(text)
    imgui.PopStyleColor()
end

-- The <window .../> line glyphs.windowGeometry reads, for a textbox as
-- extractTextboxes found it, with the row's overrides applied.
local function windowHead(tb, row)
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
local function originalBox(tb)
    if not tb then return {} end
    if tb.typ == 'fixed' then return { x = 64, y = 32, width = 192, height = 14 } end
    if tb.x == 16 and tb.y == 16 and tb.width == 16 and tb.height == 16 then return {} end
    return { x = tonumber(tb.x), y = tonumber(tb.y), width = tonumber(tb.width), height = tonumber(tb.height) }
end

local function srcHash(extra, i) return VP.text.fnv1a64(extra.raw[i]) end

-- Editor state of pointer i, loaded from the database on first use.
local function editState(v, extra, i)
    local e = v.edits[i]
    if e then return e end
    local row = T.db:get(extra.key, i)
    local live = row and not row.deletedAt
    e = {
        base = row and row.version or 0,
        text = live and VP.text.toEditable(row.tokens, v.lookup) or VP.text.toEditable(extra.tokens[i], v.lookup),
        status = live and row.status or VP.tdb.status.untranslated,
        note = live and row.note or '',
        override = live and (row.boxX or row.boxY or row.boxW or row.boxH) and true or false,
        sourceChanged = row and row.srcHash and row.srcHash ~= srcHash(extra, i),
    }
    local tb = extra.textboxes[i]
    local box = originalBox(tb)
    e.boxX = live and row.boxX or box.x or 0
    e.boxY = live and row.boxY or box.y or 0
    e.boxW = live and row.boxW or box.width or 0
    e.boxH = live and row.boxH or box.height or 0
    v.edits[i] = e
    return e
end

local function rowFromEdit(extra, i, e, tokens)
    local row = {
        key = extra.key, idx = i, srcHash = srcHash(extra, i), tokens = tokens, status = e.status,
        author = T.author ~= '' and T.author or nil, note = e.note ~= '' and e.note or nil,
    }
    if e.override then row.boxX, row.boxY, row.boxW, row.boxH = e.boxX, e.boxY, e.boxW, e.boxH end
    return row
end

local function save(v, extra, i, e, tokens, expected)
    local ctx = { box = originalBox(extra.textboxes[i]), lookup = v.lookup }
    local ok, r = T.db:put(rowFromEdit(extra, i, e, tokens), expected, ctx)
    if ok then
        e.base, e.message, e.messageColor, e.sourceChanged = r.version, 'Saved as version ' .. r.version, GREEN, false
        e.conflict = nil
    elseif ok == false then
        e.conflict = r
        e.openConflict = true
    else
        e.message, e.messageColor = r, RED
    end
end

-- First pointer after `from` (wrapping) with no live translation.
local function nextUntranslated(v, extra, ptrs, from)
    local n = #ptrs - extra.first + 1
    for k = 1, n do
        local i = (from - extra.first + k) % n + extra.first
        local row = T.db:get(extra.key, i)
        if not row or row.deletedAt or row.status == VP.tdb.status.untranslated then return i end
    end
    return nil
end

local function counts(extra, ptrs)
    local c = { [0] = 0, 0, 0 }
    local seen = 0
    for row in T.db:query { script = extra.key } do
        if row.idx >= extra.first and row.idx <= #ptrs then
            c[row.status] = (c[row.status] or 0) + 1
            seen = seen + 1
        end
    end
    c[0] = c[0] + (#ptrs - extra.first + 1 - seen)
    return c
end

local function drawPages(window, pages, set, id)
    local SCALE = T.previewScale
    local h = 0
    for _ in ipairs(pages) do h = h + PAGE_H * SCALE + 24 end
    imgui.safe.BeginChild(id, PAGE_W * SCALE + 16, h + 8, 0, function()
        for p, lines in ipairs(pages) do
            if #pages > 1 then imgui.TextUnformatted(string.format('page %d/%d', p, #pages)) end
            VP.glyphs.drawPage(window, lines, set, SCALE)
        end
    end)
end

local function drawConflict(v, extra, i, e, tokens)
    local id = 'Save conflict##' .. i
    if e.openConflict then
        imgui.OpenPopup(id)
        e.openConflict = nil
    end
    -- The binding turns a nil p_open into a pointer to false, which closes the
    -- modal at once; true gives it a working close button.
    imgui.safe.BeginPopupModal(id, true, imgui.constant.WindowFlags.AlwaysAutoResize, function()
        local theirs = e.conflict
        if not theirs then
            imgui.CloseCurrentPopup()
            return
        end
        imgui.TextUnformatted(string.format('%s saved version %d of this string while you were editing version %d.',
            theirs.author or 'Someone', theirs.version, e.base))
        if theirs.deletedAt then imgui.TextUnformatted('Their version deletes the translation.') end
        imgui.Separator()
        imgui.TextUnformatted('Theirs (' .. (VP.tdb.statusNames[theirs.status] or '?') .. '):')
        imgui.extra.InputTextMultiline('##theirs', theirs.tokens and VP.text.toEditable(theirs.tokens, v.lookup) or '',
            600, 100, imgui.constant.InputTextFlags.ReadOnly)
        imgui.TextUnformatted('Yours (' .. (VP.tdb.statusNames[e.status] or '?') .. '):')
        imgui.extra.InputTextMultiline('##yours', e.text, 600, 100, imgui.constant.InputTextFlags.ReadOnly)
        if imgui.Button('Keep mine') then
            save(v, extra, i, e, tokens, theirs.version)
            imgui.CloseCurrentPopup()
        end
        imgui.SameLine()
        if imgui.Button('Take theirs') then
            v.edits[i] = nil
            imgui.CloseCurrentPopup()
        end
        imgui.SameLine()
        if imgui.Button('Cancel') then
            e.conflict = nil
            imgui.CloseCurrentPopup()
        end
    end)
end

-- The in-game preview: while armed, every room the game loads gets its saved
-- translations (drafts and reviewed) patched in, from this database.
local function drawPreviewControl()
    local armed = VP.preview.armed()
    local changed, on = imgui.Checkbox('Show translations in game', armed)
    if changed then
        if on then VP.preview.arm(T.db) else VP.preview.disarm() end
    end
    imgui.SameLine()
    if VP.preview.armed() then
        imgui.TextUnformatted('Applies when the game next loads a room. Needs the debugger enabled.')
    else
        imgui.TextUnformatted('Off.')
    end
    local log = VP.preview.log
    if #log > 0 then imgui.TextUnformatted('Last: ' .. log[#log]) end
end

local function drawTranslate(v, room)
    imgui.TextUnformatted('Database')
    imgui.SameLine()
    imgui.SetNextItemWidth(400)
    local _, path = imgui.extra.InputText('##tdbpath', T.path)
    T.path = path
    imgui.SameLine()
    if imgui.Button(T.db and T.openPath == T.path and 'Reopen' or 'Open') then
        T.open(T.path)
        v.edits = {}
    end
    imgui.SameLine()
    imgui.TextUnformatted('Translator')
    imgui.SameLine()
    imgui.SetNextItemWidth(150)
    local _, author = imgui.extra.InputText('##tdbauthor', T.author)
    T.author = author
    if T.dbError then colored(RED, T.dbError) end
    if not T.db and not T.dbError then T.open(T.path) end
    if not T.db then return end
    drawPreviewControl()

    local ptrs, err = VP.vfs.ptrs(room)
    if not ptrs then
        colored(RED, 'Error: ' .. tostring(err))
        return
    end
    local extra = room.extra
    v.lookup = v.lookup or resolveFont(extra.font)
    v.cur = v.cur or extra.first

    local c = counts(extra, ptrs)
    imgui.TextUnformatted(string.format('Script %s: %d strings, %d untranslated, %d draft, %d reviewed', extra.key,
        #ptrs - extra.first + 1, c[0], c[1], c[2]))
    if imgui.Button('<') and v.cur > extra.first then v.cur = v.cur - 1 end
    imgui.SameLine()
    if imgui.Button('>') and v.cur < #ptrs then v.cur = v.cur + 1 end
    imgui.SameLine()
    imgui.SetNextItemWidth(300)
    local changed, n = imgui.SliderInt('pointer', v.cur, extra.first, #ptrs)
    if changed then v.cur = n end
    imgui.SameLine()
    if imgui.Button('Next untranslated') then
        local nx = nextUntranslated(v, extra, ptrs, v.cur)
        if nx then v.cur = nx else v.message = 'Every string of this script is translated.' end
    end
    if v.message then
        imgui.SameLine()
        imgui.TextUnformatted(v.message)
    end

    local i = v.cur
    local e = editState(v, extra, i)
    local tb = extra.textboxes[i]

    imgui.Separator()
    imgui.TextUnformatted('Original')
    imgui.extra.InputTextMultiline('##original' .. i, VP.text.toEditable(extra.tokens[i], v.lookup), -1, 90,
        imgui.constant.InputTextFlags.ReadOnly)
    imgui.TextUnformatted('Translation (control codes as {tags}, write {{ and }} for braces)')
    local edited, text = imgui.extra.InputTextMultiline('##translation' .. i, e.text, -1, 120)
    if edited then
        e.text = text
        e.message = nil
    end
    local tokens, perr, ppos = VP.text.fromEditable(e.text, extra.style)
    if not tokens then colored(RED, string.format('At byte %d: %s', ppos, perr)) end
    if e.sourceChanged then colored(RED, 'The original text changed since this translation was saved.') end

    local cb, ov = imgui.Checkbox('Override box', e.override)
    if cb then e.override = ov end
    if e.override then
        for _, f in ipairs({ { 'x', 'boxX' }, { 'y', 'boxY' }, { 'width', 'boxW' }, { 'height', 'boxH' } }) do
            imgui.SameLine()
            imgui.SetNextItemWidth(90)
            local ch, val = imgui.InputInt(f[1] .. '##box' .. i, e[f[2]], 1, 8)
            if ch then e[f[2]] = math.max(0, val) end
        end
    end
    for s = 0, 2 do
        if imgui.RadioButton(VP.tdb.statusNames[s] .. '##st' .. i, e.status == s) then e.status = s end
        imgui.SameLine()
    end
    imgui.SetNextItemWidth(300)
    local _, note = imgui.extra.InputTextWithHint('##note' .. i, 'note', e.note)
    e.note = note
    imgui.SameLine()
    if imgui.Button('Save') then
        if tokens then
            save(v, extra, i, e, tokens, e.base)
        else
            e.message, e.messageColor = 'Not saved: ' .. perr, RED
        end
    end
    imgui.SameLine()
    imgui.TextUnformatted(string.format('(editing version %d)', e.base))
    if e.message then colored(e.messageColor or GREEN, e.message) end
    if tokens then drawConflict(v, extra, i, e, tokens) end

    -- Previews: the original as the Preview tab draws it, the translation from
    -- its tokens in the (possibly overridden) box.
    local row = e.override and { boxX = e.boxX, boxY = e.boxY, boxW = e.boxW, boxH = e.boxH } or nil
    local origWindow = VP.glyphs.parse(ptrs[i])
    local origPages = VP.glyphs.pagesFromTokens(extra.tokens[i], v.lookup, extra.style)
    local head = windowHead(tb, row)
    local trWindow = head and VP.glyphs.windowGeometry(head) or nil
    imgui.Separator()
    imgui.BeginGroup()
    imgui.TextUnformatted('Original')
    local ob = originalBox(tb)
    drawPages(origWindow, VP.glyphs.scrollPages((VP.glyphs.wrapPages(origPages, ob.width)), ob.height), 'US', 'origpages')
    imgui.EndGroup()
    imgui.SameLine()
    imgui.BeginGroup()
    imgui.TextUnformatted('Translation')
    if tokens then
        local box = VP.tdb.effectiveBox(row or {}, originalBox(tb))
        local problems, notes, wrapped = VP.tdb.fitProblems(tokens, box, v.lookup)
        if #problems == 0 and #notes == 0 then
            colored(GREEN, 'Fits the box.')
        else
            for _, p in ipairs(problems) do colored(RED, p) end
            for _, n in ipairs(notes) do colored(YELLOW, n) end
        end
        -- Drawn as the game leaves it: wrapped, and a page taller than the box
        -- scrolled to its last lines.
        drawPages(trWindow, VP.glyphs.scrollPages(wrapped, box.height), 'US', 'trpages')
    end
    imgui.EndGroup()

    if imgui.CollapsingHeader('History##' .. i) then
        for _, h in ipairs(T.db:history(extra.key, i)) do
            local t = h.tokens and VP.text.toEditable(h.tokens, v.lookup):gsub('\n', ' / ') or ''
            if #t > 80 then t = t:sub(1, 80) .. '...' end
            imgui.TextUnformatted(string.format('v%d %s %s %s%s: %s', h.version, os.date('!%Y-%m-%d %H:%M', h.updatedAt),
                h.author or '?', VP.tdb.statusNames[h.status] or '?', h.deletedAt and ' (deleted)' or '', t))
        end
    end
end

-- The viewer for a room script viewer (vfs.lua roomScriptViewer).
function T.viewer(room)
    local v = { name = 'Translate', edits = {} }
    v.draw = function() drawTranslate(v, room) end
    return v
end
