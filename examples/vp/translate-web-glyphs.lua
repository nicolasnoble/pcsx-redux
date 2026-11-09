-- The glyph editor as web pages, over the same model as the ImGui one
-- (translate-model.lua, M.loadGlyph / saveGlyph / revertGlyph):
--
--   ?p=glyphs[&ch=X]        every character of the target language, and the
--                           editor for X
--   POST ?p=glyphsave       action=save, preview or revert
--
-- The pixel grid is a form of 16x12 checkboxes, so it works with no script;
-- a few lines of script add click-and-drag painting. A save goes through the
-- database's version check: a stale one shows the stored glyph beside yours
-- and offers to save over it.

local W = VP.tweb
local M = VP.tmodel
local F = VP.fontedit
local H = PCSX.Html
local U = W.util

local style = [[
.glyphs { display: flex; gap: 2em; align-items: flex-start; }
.glyphlist { columns: 6; font-family: monospace; font-size: 13px; max-width: 60em; }
.glyphlist a { text-decoration: none; } .glyphlist .edited { color: #ec4; } .glyphlist .added { color: #6d6; }
table.grid { border-collapse: collapse; } table.grid td { padding: 0; }
.grid input { appearance: none; -webkit-appearance: none; width: 20px; height: 20px; margin: 0;
    background: #fff; border: 1px solid #888; display: block; cursor: crosshair; }
.grid input:checked { background: #000; }
.grid td.past input { background: #999; } .grid td.past input:checked { background: #444; }
.bigglyph { image-rendering: pixelated; }
]]

-- Click toggles a cell; dragging paints every cell crossed with the value
-- the first one got.
local script = [[
(function () {
  let paint = null;
  document.querySelectorAll('.grid input').forEach(function (b) {
    b.addEventListener('mousedown', function (ev) { paint = !b.checked; b.checked = paint; ev.preventDefault(); });
    b.addEventListener('mouseenter', function () { if (paint !== null) b.checked = paint; });
    b.addEventListener('click', function (ev) { ev.preventDefault(); });
  });
  document.addEventListener('mouseup', function () { paint = null; });
})();
]]

local function label(ch) return ch == ' ' and 'space' or ch end

local function listBlock(current)
    local items = {}
    for _, e in ipairs(M.glyphEntries()) do
        local text = label(e.ch) .. ' ' .. e.glyph.width
        local a = H.a { href = U.link { { 'p', 'glyphs' }, { 'ch', e.ch } }, class = e.origin, title = e.origin, text }
        items[#items + 1] = H.div { e.ch == current and H.b(a) or a }
    end
    return H.div { class = 'glyphlist', items }
end

local function gridBlock(ge, readonly)
    local rows = {}
    for y = 0, F.HEIGHT - 1 do
        local cells = {}
        for x = 0, F.COLUMNS - 1 do
            cells[#cells + 1] = H.td { class = x >= ge.width and 'past' or false,
                H.input { type = 'checkbox', name = readonly and false or string.format('c%d_%d', x, y), value = '1',
                    checked = F.get(ge.rows, x, y) and 'checked' or false, disabled = readonly and 'disabled' or false,
                    title = string.format('%d,%d', x, y) },
            }
        end
        rows[#rows + 1] = H.tr(cells)
    end
    return H.table { class = 'grid', rows }
end

-- A line of text drawn in the game font with ge as edited, as a PNG data URI.
local function previewImg(ge, sample)
    local set = {}
    for k, v in pairs(M.charset()) do set[k] = v end
    set[ge.ch] = { width = ge.width, height = F.HEIGHT, data = F.encode(ge.rows) }
    local line = sample:find(ge.ch, 1, true) and sample or (sample .. ' ' .. ge.ch)
    local png = VP.glyphs.pagePng(nil, { line }, set)
    return H.img { class = 'gamepage', width = 640, height = 480, alt = line, title = line,
        src = 'data:image/png;base64,' .. base64.encode(png) }
end

local function editorPage(ge, message, conflict, sample)
    sample = sample or 'Lenneth: Je dois me dépêcher !'
    local problems, notes = M.checkGlyph(ge)
    local msgs = {}
    if message then msgs[#msgs + 1] = H.p { class = message.class, message.text } end
    for _, p in ipairs(problems) do msgs[#msgs + 1] = H.p { class = 'red', p } end
    for _, n in ipairs(notes) do msgs[#msgs + 1] = H.p { class = 'yellow', n } end
    local theirs = false
    if conflict then
        local tg = { ch = ge.ch, width = conflict.width, rows = F.rows(conflict.data, conflict.height) }
        theirs = H.div {
            H.p { class = 'red', string.format('%s saved version %d of %s while you were editing version %d. ' ..
                'Theirs is below; save again to replace it with yours.', conflict.author or 'Someone',
                conflict.version, label(ge.ch), ge.base) },
            H.p(string.format('Theirs: advance %d%s', conflict.width, conflict.deletedAt and ', reverted' or '')),
            gridBlock(tg, true),
        }
    end
    local base = conflict and conflict.version or ge.base
    local hist = {}
    for _, h in ipairs(M.glyphHistory(ge.ch)) do hist[#hist + 1] = H.div { class = 'hist', h } end
    return U.html('200 OK', 'Glyph ' .. label(ge.ch), {
        H.style(H.raw(style)),
        U.header(U.link { { 'p', 'glyphs' }, { 'ch', ge.ch } }),
        H.h2(string.format('Glyphs of %s', VP.languages.describe(M.db:targetLanguage()))),
        H.div { class = 'glyphs',
            H.div {
                H.h3(string.format('%s (%s), stored version %d', label(ge.ch), ge.origin, ge.base)),
                H.form { method = 'post', action = U.link { { 'p', 'glyphsave' } },
                    H.input { type = 'hidden', name = 'ch', value = ge.ch },
                    H.input { type = 'hidden', name = 'base', value = tostring(base) },
                    gridBlock(ge),
                    H.p { 'Advance ', H.input { type = 'number', name = 'width', min = 1, max = F.COLUMNS,
                        value = tostring(ge.width) },
                        string.format(' (bitmap %d px wide; retail glyphs advance by width + 1)', F.extent(ge.rows)) },
                    H.p { 'Note ', H.input { type = 'text', name = 'note', value = ge.note or '', size = 30 },
                        ' Translator ', H.input { type = 'text', name = 'author', value = M.author, size = 12 } },
                    H.p { 'Preview text ', H.input { type = 'text', name = 'sample', value = sample, size = 40 } },
                    H.p {
                        H.button { type = 'submit', name = 'action', value = 'preview', 'Preview' }, ' ',
                        H.button { type = 'submit', name = 'action', value = 'fit', 'Advance = width + 1' }, ' ',
                        #problems == 0 and H.button { type = 'submit', name = 'action', value = 'save', 'Save glyph' }
                            or false, ' ',
                        (ge.origin == 'edited' or ge.origin == 'added') and H.button { type = 'submit', name = 'action',
                            value = 'revert', ge.origin == 'added' and 'Remove character' or 'Revert to the original' }
                            or false,
                    },
                    msgs,
                },
                theirs,
                H.h3 'In the game font, as edited',
                previewImg(ge, sample),
                H.h3 'History',
                hist,
            },
            H.div {
                H.form { method = 'get', action = U.BASE,
                    H.input { type = 'hidden', name = 'p', value = 'glyphs' },
                    'Add or edit a character ', H.input { type = 'text', name = 'ch', size = 3 }, ' ',
                    H.input { type = 'submit', value = 'Open' },
                },
                H.p { class = 'dim', 'white: retail or language letter; ',
                    H.span { class = 'yellow', 'edited' }, '; ', H.span { class = 'green', 'added' } },
                listBlock(ge.ch),
            },
        },
        H.script(H.raw(script)),
    })
end

local function oneChar(ch)
    return type(ch) == 'string' and ch:match('^[\32-\126\194-\244][\128-\191]*$') and #ch <= 4
end

W.routes.glyphs = function(request, q)
    local db, err = U.ensureDb()
    if not db then return U.html('200 OK', 'Error', { H.p { class = 'red', err } }) end
    local ch = q.ch and q.ch ~= '' and q.ch or 'é'
    if not oneChar(ch) then return U.html('400 Bad Request', 'Bad character', { H.p 'One character, please.' }) end
    local msg = q.saved and { class = 'green', text = 'Saved as version ' .. q.saved } or
        q.reverted and { class = 'green', text = 'Reverted.' } or nil
    return editorPage(M.loadGlyph(ch), msg)
end

W.routes.glyphsave = function(request, q, form)
    if request.method ~= 'POST' then return U.html('405 Method Not Allowed', 'POST only', { H.p 'POST only.' }) end
    local db, err = U.ensureDb()
    if not db then return U.html('200 OK', 'Error', { H.p { class = 'red', err } }) end
    if not oneChar(form.ch) then return U.html('400 Bad Request', 'Bad character', { H.p 'One character, please.' }) end
    local ge = M.loadGlyph(form.ch)
    ge.base = tonumber(form.base) or 0
    ge.rows = F.blank()
    for x = 0, F.COLUMNS - 1 do
        for y = 0, F.HEIGHT - 1 do
            if form[string.format('c%d_%d', x, y)] then F.set(ge.rows, x, y, true) end
        end
    end
    ge.width = tonumber(form.width) or ge.width
    ge.note = form.note or ''
    if form.author and form.author ~= '' then ge.author = form.author end
    local sample = form.sample ~= '' and form.sample or nil
    local action = form.action
    if action == 'fit' then
        ge.width = F.suggestedWidth(ge.rows)
        return editorPage(ge, nil, nil, sample)
    elseif action == 'save' then
        local result, r = M.saveGlyph(ge)
        if result == 'saved' then
            return U.redirect(U.link { { 'p', 'glyphs' }, { 'ch', ge.ch }, { 'saved', r.version } })
        elseif result == 'conflict' then
            return editorPage(ge, nil, r, sample)
        end
        return editorPage(ge, { class = 'red', text = tostring(r) }, nil, sample)
    elseif action == 'revert' then
        local result, r = M.revertGlyph(ge)
        if result == 'saved' then
            return U.redirect(U.link { { 'p', 'glyphs' }, { 'ch', ge.ch }, { 'reverted', '1' } })
        end
        return editorPage(ge, { class = 'red', text = type(r) == 'table' and
            'Changed meanwhile: reload the glyph.' or tostring(r) }, nil, sample)
    end
    return editorPage(ge, nil, nil, sample)
end
