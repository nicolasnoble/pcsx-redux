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
-- The database, the edit state, the save and the fit check live in
-- translate-model.lua (VP.tmodel), which the web view shares. The database
-- path can be changed at the top of the viewer.

VP.translate = VP.translate or {}
local T = VP.translate
local M = VP.tmodel

-- Pixels per game pixel in the page previews.
T.previewScale = T.previewScale or 2
local PAGE_W, PAGE_H = 320, 240
local RED, GREEN, YELLOW = 0xff5050ff, 0xff60d060, 0xff40c8e8

local function colored(color, text)
    imgui.PushStyleColor(imgui.constant.Col.Text, color)
    imgui.TextUnformatted(text)
    imgui.PopStyleColor()
end

-- Editor state of pointer i, loaded from the database on first use.
local function editState(v, extra, i)
    local e = v.edits[i]
    if e then return e end
    e = M.loadEdit(extra, i, v.lookup)
    v.edits[i] = e
    return e
end

local function save(v, extra, i, e, tokens, expected)
    local result, r = M.save(extra, i, e, tokens, expected, v.lookup)
    if result == 'saved' then
        e.message, e.messageColor = 'Saved as version ' .. r.version, GREEN
        e.conflict = nil
    elseif result == 'conflict' then
        e.conflict = r
        e.openConflict = true
    else
        e.message, e.messageColor = r, RED
    end
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
        if on then VP.preview.arm(M.db) else VP.preview.disarm() end
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

-- The database's languages: the target picks the letters a translation may
-- use, and both are what the web view tells the browser's spellchecker.
local function drawLanguages(v)
    local target, source = M.languages()
    if v.langDb ~= M.db then v.langDb, v.target, v.source = M.db, target, source end
    imgui.TextUnformatted('Translating from')
    imgui.SameLine()
    imgui.SetNextItemWidth(80)
    local _, src = imgui.extra.InputText('##srclang', v.source)
    v.source = src
    imgui.SameLine()
    imgui.TextUnformatted('to')
    imgui.SameLine()
    imgui.SetNextItemWidth(80)
    local _, tgt = imgui.extra.InputText('##tgtlang', v.target)
    v.target = tgt
    imgui.SameLine()
    if (v.target ~= target or v.source ~= source) and imgui.Button('Set languages') then
        local ok, err = M.setLanguages(v.target, v.source)
        v.langMessage = ok and nil or err
        v.edits = {}
    end
    imgui.SameLine()
    imgui.TextUnformatted(VP.languages.describe(target))
    if v.langMessage then colored(RED, v.langMessage) end
end

-- The Japanese disc whose script shows beside the English one.
local function drawJapaneseDisc(v)
    VP.jp.status() -- opens VP_DISC_JP on first use
    if v.jpPath == nil then v.jpPath = VP.jp.path or '' end
    imgui.TextUnformatted('Japanese disc')
    imgui.SameLine()
    imgui.SetNextItemWidth(420)
    local _, p = imgui.extra.InputTextWithHint('##jpdisc', 'path to a JP disc 1 .cue', v.jpPath)
    v.jpPath = p
    imgui.SameLine()
    if imgui.Button('Open##jpdisc') then VP.jp.setDisc(v.jpPath) end
    imgui.SameLine()
    local st = VP.jp.status()
    if st == 'ok' then colored(GREEN, VP.jp.disc.exe) elseif st ~= 'unset' then colored(RED, st) end
end

local function drawTranslate(v, room)
    imgui.TextUnformatted('Database')
    imgui.SameLine()
    imgui.SetNextItemWidth(400)
    local _, path = imgui.extra.InputText('##tdbpath', M.path)
    M.path = path
    imgui.SameLine()
    if imgui.Button(M.db and M.openPath == M.path and 'Reopen' or 'Open') then
        M.open(M.path)
        v.edits = {}
    end
    imgui.SameLine()
    imgui.TextUnformatted('Translator')
    imgui.SameLine()
    imgui.SetNextItemWidth(150)
    local _, author = imgui.extra.InputText('##tdbauthor', M.author)
    M.author = author
    if M.dbError then colored(RED, M.dbError) end
    if not M.db and not M.dbError then M.open(M.path) end
    if not M.db then return end
    drawLanguages(v)
    drawJapaneseDisc(v)
    drawPreviewControl()

    local ptrs, err = VP.vfs.ptrs(room)
    if not ptrs then
        colored(RED, 'Error: ' .. tostring(err))
        return
    end
    local extra = room.extra
    v.lookup = v.lookup or resolveFont(extra.font)
    v.cur = v.cur or extra.first

    local c = M.counts(extra, #ptrs)
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
        local nx = M.nextUntranslated(extra, #ptrs, v.cur)
        if nx then v.cur = nx else v.message = 'Every string of this script is translated.' end
    end
    if v.message then
        imgui.SameLine()
        imgui.TextUnformatted(v.message)
    end

    local i = v.cur
    local e = editState(v, extra, i)
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
    local tokens, perr, ppos = M.parse(extra, e)
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
    -- its tokens in the (possibly overridden) box, both as the game leaves them.
    imgui.Separator()
    imgui.BeginGroup()
    imgui.TextUnformatted('Original')
    local origWindow, origPages = M.originalPreview(ptrs[i], extra, i, v.lookup)
    drawPages(origWindow, origPages, 'US', 'origpages')
    imgui.EndGroup()
    imgui.SameLine()
    imgui.BeginGroup()
    imgui.TextUnformatted('Japanese original')
    local jps, jerr = VP.jp.string(extra, i)
    if jps then
        imgui.TextDisabled(string.format('JP pointer %d (%s)', jps.ptr, jps.how == 'same' and 'same index' or
            'paired by the room logic'))
        drawPages(jps.window, jps.pages, 'JP', 'jppages')
    else
        imgui.TextDisabled(jerr)
    end
    imgui.EndGroup()
    imgui.SameLine()
    imgui.BeginGroup()
    imgui.TextUnformatted('Translation')
    if tokens then
        local trWindow, trPages, problems, notes = M.translationPreview(extra, i, e, tokens, v.lookup)
        if #problems == 0 and #notes == 0 then
            colored(GREEN, 'Fits the box.')
        else
            for _, p in ipairs(problems) do colored(RED, p) end
            for _, n in ipairs(notes) do colored(YELLOW, n) end
        end
        drawPages(trWindow, trPages, 'US', 'trpages')
    end
    imgui.EndGroup()

    if imgui.CollapsingHeader('History##' .. i) then
        for _, line in ipairs(M.history(extra, i, v.lookup)) do imgui.TextUnformatted(line) end
    end
end

-- The viewer for a room script viewer (vfs.lua roomScriptViewer).
function T.viewer(room)
    local v = { name = 'Translate', edits = {} }
    v.draw = function() drawTranslate(v, room) end
    return v
end
