-- The ImGui glyph editor, drawn in the Translate tab under "Glyphs". It edits
-- the target language's glyphs in the translation database through the model
-- (translate-model.lua, M.loadGlyph / saveGlyph / revertGlyph), so edits are
-- versioned like strings, and the fit check, the page previews and the
-- in-game preview use them as soon as they are saved.
--
-- Left: every character of the target language with where its glyph comes
-- from, and a box to add a new one. Right: the 16x12 pixel grid (click or drag
-- to paint, the first cell clicked decides on or off), the advance (columns
-- past it are shaded), and a line of text drawn in the game font with the
-- glyph as edited, before it is saved.

VP.glyphEditor = VP.glyphEditor or {}
local G = VP.glyphEditor
local M = VP.tmodel
local F = VP.fontedit

local RED, GREEN, YELLOW = 0xff5050ff, 0xff60d060, 0xff40c8e8
local CELL = 18

G.sample = G.sample or 'Lenneth: Je dois me dépêcher !'

local function colored(color, text)
    imgui.PushStyleColor(imgui.constant.Col.Text, color)
    imgui.TextUnformatted(text)
    imgui.PopStyleColor()
end

-- The charset the preview line draws from: the database's, with the glyph
-- being edited swapped for a working copy that follows every stroke.
local function previewSet(s)
    local cs = M.charset()
    local ge = s.ge
    if not s.scratch then s.scratch = { height = F.HEIGHT } end
    if s.previewBase ~= cs or s.previewCh ~= ge.ch then
        local set = {}
        for k, v in pairs(cs) do set[k] = v end
        set[ge.ch] = s.scratch
        s.previewBase, s.previewCh, s.previewSet = cs, ge.ch, set
        s.dirty = true
    end
    if s.dirty then
        s.scratch.width, s.scratch.data = ge.width, F.encode(ge.rows)
        VP.glyphs.refreshGlyph(s.scratch)
        s.dirty = false
    end
    return s.previewSet
end

local function select(s, ch)
    s.ge = M.loadGlyph(ch)
    s.message, s.history = nil, nil
    s.dirty = true
end

local function drawList(s)
    imgui.BeginGroup()
    imgui.SetNextItemWidth(220)
    local _, f = imgui.extra.InputTextWithHint('##glyphfilter', 'filter: a character, or edited / added', s.filter)
    s.filter = f
    imgui.safe.BeginChild('glyphlist', 220, 300, 1, function()
        for _, e in ipairs(M.glyphEntries()) do
            local f2 = s.filter
            if f2 == '' or e.ch == f2 or e.origin == f2 then
                local label = string.format('%s  %s  %d##g%s', e.ch == ' ' and 'space' or e.ch, e.origin,
                    e.glyph.width, e.ch)
                if imgui.Selectable(label, s.ge and s.ge.ch == e.ch) then select(s, e.ch) end
            end
        end
    end)
    imgui.SetNextItemWidth(60)
    local _, n = imgui.extra.InputText('##newglyph', s.newCh)
    s.newCh = n
    imgui.SameLine()
    if imgui.Button('Add or edit character') then
        if s.newCh:match('^[\32-\126\194-\244][\128-\191]*$') and #s.newCh <= 4 then
            select(s, s.newCh)
        else
            s.message, s.messageColor = 'Type one character.', RED
        end
    end
    imgui.EndGroup()
end

local function drawGrid(s)
    local ge = s.ge
    local CF = imgui.constant.ColorEditFlags
    local flags = bit.bor(CF.NoTooltip, CF.NoDragDrop)
    local hoverFlags = imgui.constant.HoveredFlags.AllowWhenBlockedByActiveItem
    if not imgui.IsMouseDown(0) then s.paint = nil end
    -- Where the grid starts, in ImGui screen coordinates (for scripts driving the editor).
    G.gridOrigin = { imgui.GetCursorScreenPos() }
    G.cellStride = CELL + 1
    imgui.PushStyleVar_2(imgui.constant.StyleVar.ItemSpacing, 1, 1)
    for y = 0, F.HEIGHT - 1 do
        for x = 0, F.COLUMNS - 1 do
            if x > 0 then imgui.SameLine() end
            local on = F.get(ge.rows, x, y)
            local past = x >= ge.width
            local c = on and (past and 0.45 or 0.0) or (past and 0.55 or 1.0)
            imgui.ColorButton(string.format('##px%d_%d', x, y), c, c, c, 1, flags, CELL, CELL)
            if imgui.IsItemHovered(hoverFlags) then
                if imgui.IsMouseClicked(0) then s.paint = not on end
                if s.paint ~= nil and imgui.IsMouseDown(0) and on ~= s.paint then
                    F.set(ge.rows, x, y, s.paint)
                    s.dirty = true
                    s.message = nil
                end
            end
        end
    end
    imgui.PopStyleVar(1)
end

local function save(s, expected)
    local result, r = M.saveGlyph(s.ge, expected)
    if result == 'saved' then
        local ch = s.ge.ch
        select(s, ch)
        s.message, s.messageColor = string.format('Saved %s as version %d.', ch, r.version), GREEN
    elseif result == 'conflict' then
        s.ge.conflict = r
        s.message, s.messageColor = string.format('%s saved version %d of %s while you were editing version %d.',
            r.author or 'Someone', r.version, s.ge.ch, s.ge.base), RED
    else
        s.message, s.messageColor = r, RED
    end
end

local function drawEditor(s)
    local ge = s.ge
    imgui.BeginGroup()
    imgui.TextUnformatted(string.format('Glyph %s (%s), stored version %d', ge.ch == ' ' and 'space' or ge.ch,
        ge.origin, ge.base))
    drawGrid(s)
    local extent = F.extent(ge.rows)
    imgui.SetNextItemWidth(200)
    local changed, w = imgui.SliderInt('advance', ge.width, 1, F.COLUMNS)
    if changed then
        ge.width = w
        s.dirty = true
    end
    imgui.SameLine()
    imgui.TextUnformatted(string.format('bitmap %d px wide', extent))
    imgui.SameLine()
    if imgui.Button('Advance = width + 1') then
        ge.width = F.suggestedWidth(ge.rows)
        s.dirty = true
    end
    if imgui.Button('Clear') then
        ge.rows = F.blank()
        s.dirty = true
    end
    imgui.SameLine()
    if imgui.Button('Reload') then select(s, ge.ch) end
    imgui.SameLine()
    imgui.TextUnformatted('Note')
    imgui.SameLine()
    imgui.SetNextItemWidth(220)
    local _, note = imgui.extra.InputText('##glyphnote', ge.note)
    ge.note = note

    local problems, notes = M.checkGlyph(ge)
    for _, p in ipairs(problems) do colored(RED, p) end
    for _, n in ipairs(notes) do colored(YELLOW, n) end
    if #problems == 0 and imgui.Button('Save glyph') then save(s) end
    if ge.conflict then
        imgui.SameLine()
        if imgui.Button('Keep mine') then save(s, ge.conflict.version) end
        imgui.SameLine()
        if imgui.Button('Take theirs') then select(s, ge.ch) end
    end
    if ge.origin == 'edited' or ge.origin == 'added' then
        imgui.SameLine()
        if imgui.Button(ge.origin == 'added' and 'Remove character' or 'Revert to the original glyph') then
            local result, r = M.revertGlyph(ge)
            if result == 'saved' then
                local ch = ge.ch
                select(s, ch)
                s.message, s.messageColor = 'Reverted ' .. ch .. '.', GREEN
            else
                s.message, s.messageColor = type(r) == 'table' and 'Changed meanwhile, reload it.' or tostring(r), RED
            end
        end
    end
    if s.message then colored(s.messageColor or GREEN, s.message) end

    imgui.TextUnformatted('Preview in the game font, as edited:')
    imgui.SetNextItemWidth(420)
    local _, sample = imgui.extra.InputText('##glyphsample', G.sample)
    G.sample = sample
    local line = G.sample:find(ge.ch, 1, true) and G.sample or (G.sample .. ' ' .. ge.ch)
    VP.glyphs.drawLine(line, previewSet(s), VP.translate.previewScale or 2)
    if imgui.CollapsingHeader('Glyph history##' .. ge.ch) then
        for _, h in ipairs(M.glyphHistory(ge.ch)) do imgui.TextUnformatted(h) end
    end
    imgui.EndGroup()
end

-- The JP font is read only here: it is what the JP pane draws the disc with.
-- Characters it lists more than once are kept as variants (a room font can
-- use any of them); this lists them so nobody mistakes one for the glyph.
local function drawJapanese(s)
    if not imgui.CollapsingHeader('Japanese font duplicates (read only)') then return end
    local dups = F.jpDuplicates()
    imgui.TextUnformatted(string.format('%d characters have more than one bitmap in the JP font database; ' ..
        'the JP pane recognizes every variant and draws the last one listed.', #dups))
    local shown = {}
    for i = 1, math.min(#dups, 40) do shown[#shown + 1] = dups[i].ch .. 'x' .. dups[i].count end
    imgui.TextUnformatted(table.concat(shown, ' ') .. (#dups > 40 and ' ...' or ''))
end

-- Called from the Translate tab with its viewer table.
function G.draw(v)
    local s = v.glyphs
    if not s or s.db ~= M.db then
        s = { db = M.db, filter = '', newCh = '' }
        v.glyphs = s
    end
    if G.openAtStart then imgui.SetNextItemOpen(true, imgui.constant.Cond.Once) end
    if imgui.CollapsingHeader('Glyphs of ' .. VP.languages.describe(M.db:targetLanguage())) then
        if not s.ge then select(s, 'é') end
        drawList(s)
        imgui.SameLine()
        drawEditor(s)
    end
    drawJapanese(s)
end
