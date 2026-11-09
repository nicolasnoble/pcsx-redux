-- The Translate tool as a web page, over the same model as the ImGui tab
-- (translate-model.lua): with the web server enabled, open
--
--   http://localhost:8080/api/v1/lua/vp
--
-- It lists the room scripts of the loaded disc, edits one string at a time
-- with the database's versioned save (a stale version shows both versions),
-- runs the fit check, and shows the game screen from /api/v1/screen/still.
--
-- The web server has no authentication: anyone who can reach the port can
-- edit the database. Run it on localhost only.
--
-- Routes are in the query string, since a Lua handler only matches its exact
-- name: ?p=list[&q=filter], ?p=edit&path=...&i=N, and POSTs to ?p=save and
-- ?p=preview (application/x-www-form-urlencoded).

VP.tweb = VP.tweb or {}
local W = VP.tweb
local M = VP.tmodel
local H = PCSX.Html
local BASE = '/api/v1/lua/vp'

-- The rich editor's script, read once from the directory browser.lua is in.
do
    W.richScript = VP.readFile and VP.readFile('translate-web.js')
    if not W.richScript then
        print('translate-web: translate-web.js not found, the editor stays plain text')
    end
end

local function decode(s)
    return (s:gsub('+', ' '):gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

local function encode(s)
    return (tostring(s):gsub('[^%w%-%._~/]', function(c) return string.format('%%%02X', c:byte()) end))
end

local function parseForm(s)
    local t = {}
    for pair in (s or ''):gmatch('[^&]+') do
        local k, v = pair:match('^([^=]*)=?(.*)$')
        t[decode(k)] = decode(v)
    end
    return t
end

local function link(params)
    local parts = {}
    for _, kv in ipairs(params) do parts[#parts + 1] = kv[1] .. '=' .. encode(kv[2]) end
    return BASE .. '?' .. table.concat(parts, '&')
end

local function response(status, body, headers)
    local h = { 'HTTP/1.1 ' .. status }
    for k, v in pairs(headers or {}) do h[#h + 1] = k .. ': ' .. v end
    h[#h + 1] = 'Content-Length: ' .. #body
    h[#h + 1] = 'Connection: close'
    return table.concat(h, '\r\n') .. '\r\n\r\n' .. body
end

local function html(status, title, body)
    local page = H.html {
        H.head {
            H.meta { charset = 'utf-8' },
            H.title(title),
            H.style(H.raw [[
body { font-family: sans-serif; margin: 1em; background: #1d1f23; color: #ddd; }
a { color: #8cf; } textarea, input { background: #2a2d33; color: #eee; border: 1px solid #555; }
textarea { width: 100%; font-family: monospace; font-size: 14px; }
.cols { display: flex; gap: 1.5em; align-items: flex-start; } .cols > div { flex: 1; } .pages { display: flex; flex-wrap: wrap; gap: 0 1em; }
.red { color: #f66; } .green { color: #6d6; } .yellow { color: #ec4; } .dim { color: #999; }
input[type=number] { width: 5em; }
.screen img { width: 640px; image-rendering: pixelated; border: 1px solid #555; }
.rich { background: #2a2d33; color: #eee; border: 1px solid #555; font-family: monospace; font-size: 14px;
        white-space: pre-wrap; min-height: 6em; padding: 2px; overflow-wrap: anywhere; }
.rich[contenteditable=true] { min-height: 9em; } .rich:focus { outline: 1px solid #8cf; }
.chip { background: #3d5a80; color: #fff; border-radius: 3px; padding: 0 3px; margin: 0 1px; font-size: 12px;
        user-select: all; cursor: default; } .chip-new { background: #80603d; }
img.gamepage { image-rendering: pixelated; border: 1px solid #555; display: block; margin: 4px 0; }
table.list td { padding: 1px 1em 1px 0; } .hist { font-family: monospace; font-size: 12px; }
]]),
        },
        H.body(body),
    }
    return response(status, H.render(page), { ['Content-Type'] = 'text/html; charset=utf-8' })
end

local function redirect(url) return response('303 See Other', '', { Location = url }) end

-- path -> room script viewer, over the whole disc, built on first use.
function W.index()
    if W.scripts then return W.scripts end
    local iso = PCSX.getCurrentIso()
    if not VP.vfs.identify(iso) then return nil, 'The loaded disc is not Valkyrie Profile.' end
    local list, byPath = {}, {}
    local function walk(node, path)
        local children = VP.vfs.expand(node)
        for _, v in ipairs(node.viewers or {}) do
            if v.name == 'Room script' then
                list[#list + 1] = path
                byPath[path] = v
            end
        end
        for _, c in ipairs(children) do walk(c, path .. '/' .. c.name) end
    end
    local function walkDir(dir, path)
        for _, c in ipairs(VP.vfs.expand(dir)) do
            if c.isDir then walkDir(c, path .. '/' .. c.name) else walk(c, path .. '/' .. c.name) end
        end
    end
    walkDir(VP.vfs.expand(VP.vfs.root(iso))[2], '')
    W.scripts = { list = list, byPath = byPath }
    return W.scripts
end

local function ensureDb()
    if not M.db and not M.dbError then M.open(M.path) end
    return M.db, M.dbError
end

local function header(back)
    local target, source = M.languages()
    return H.div {
        H.a { href = link { { 'p', 'list' } }, 'Scripts' }, ' | ', H.a { href = link { { 'p', 'glyphs' } }, 'Glyphs' },
        ' | database ', H.code(M.openPath or M.path),
        M.db and H.form { method = 'post', action = link { { 'p', 'languages' } }, style = 'display: inline',
            ' | translating from ',
            H.input { type = 'text', name = 'source', value = source, size = 6, title = 'BCP 47 tag, e.g. en' },
            ' to ', H.input { type = 'text', name = 'target', value = target, size = 6, title = 'BCP 47 tag, e.g. fr' },
            H.input { type = 'hidden', name = 'back', value = back or BASE },
            ' ', H.input { type = 'submit', value = 'Set' }, ' ', VP.languages.describe(target),
        } or false,
        -- The disc is opened on the host, so its path is set from the emulator
        -- (Translate tab or VP_DISC_JP), never from this page.
        ' | Japanese disc ', VP.jp.status() == 'ok' and H.code(VP.jp.disc.exe) or
            H.span { class = 'dim', VP.jp.status() == 'unset' and 'not opened' or VP.jp.status() },
    }
end

-- A text-form field that the rich editor can show as chips: the textarea is
-- what the form posts, the div the chips. lang drives the browser spellchecker.
local function richPair(textarea, lang, readonly)
    textarea.attrs.lang = lang
    textarea.attrs.spellcheck = readonly and 'false' or 'true'
    return H.div { class = 'rich-pair',
        textarea,
        H.div { class = 'rich', lang = lang, spellcheck = readonly and 'false' or 'true',
            contenteditable = not readonly and 'true' or false, style = 'display: none' },
    }
end

local function listPage(q)
    local idx, err = W.index()
    if not idx then return html('200 OK', 'Error', { H.p { class = 'red', err } }) end
    local rows = {}
    for _, path in ipairs(idx.list) do
        if not q or q == '' or path:lower():find(q:lower(), 1, true) then
            rows[#rows + 1] = H.tr { H.td { H.a { href = link { { 'p', 'edit' }, { 'path', path } }, path } } }
        end
    end
    return html('200 OK', 'VP translation', {
        H.h1 'Valkyrie Profile translation',
        header(),
        H.form { method = 'get', action = BASE,
            H.input { type = 'hidden', name = 'p', value = 'list' },
            H.input { type = 'text', name = 'q', value = q or '', placeholder = 'filter, e.g. 3613' },
            ' ', H.input { type = 'submit', value = 'Filter' },
        },
        H.p(string.format('%d of %d room scripts', #rows, #idx.list)),
        H.table { class = 'list', rows },
    })
end

-- Each page drawn in the game font (VP.glyphs.pagePng, the layout the ImGui
-- preview draws), at twice the game's resolution, with its text as alt text.
local function pagesBlock(window, pages, font)
    local out = {}
    for p, lines in ipairs(pages) do
        if #pages > 1 then out[#out + 1] = H.div(string.format('page %d/%d', p, #pages)) end
        local png = VP.glyphs.pagePng(window, lines, font)
        local text = table.concat(lines, '\n')
        out[#out + 1] = H.img { class = 'gamepage', width = 640, height = 480, alt = text, title = text,
            src = 'data:image/png;base64,' .. base64.encode(png) }
    end
    return out
end

local function screenBlock()
    local armed = VP.preview.armed()
    return H.div { class = 'screen',
        H.h3 'Game screen',
        H.img { id = 'screen', src = '/api/v1/screen/still', alt = 'game screen' },
        H.form { method = 'post', action = link { { 'p', 'preview' } },
            H.input { type = 'hidden', name = 'back', value = '' , id = 'back' },
            H.input { type = 'hidden', name = 'on', value = armed and '0' or '1' },
            H.input { type = 'submit', value = armed and 'Stop showing translations in game' or
                'Show translations in game' },
            ' ', armed and 'Applies when the game next loads a room. Needs the debugger enabled.' or 'Off.',
        },
        #VP.preview.log > 0 and H.p('Last: ' .. VP.preview.log[#VP.preview.log]) or false,
        H.label { H.input { type = 'checkbox', id = 'live', checked = true }, ' refresh every second' },
        H.script(H.raw [[
document.getElementById('back').value = location.pathname + location.search;
setInterval(function() {
  if (document.getElementById('live').checked)
    document.getElementById('screen').src = '/api/v1/screen/still?t=' + Date.now();
}, 1000);
]]),
    }
end

-- The edit page. `e` is the edit state to show (the database's, or the one
-- just posted when a save failed), `conflict` their row on a stale save.
local function editPage(path, i, e, message, conflict)
    local idx, err = W.index()
    if not idx then return html('200 OK', 'Error', { H.p { class = 'red', err } }) end
    local room = idx.byPath[path]
    if not room then return html('404 Not Found', 'Not found', { H.p { class = 'red', 'No room script ' .. path } }) end
    local db, dberr = ensureDb()
    if not db then return html('200 OK', 'Error', { H.p { class = 'red', dberr } }) end
    local ptrs, perr = VP.vfs.ptrs(room)
    if not ptrs then return html('200 OK', 'Error', { H.p { class = 'red', tostring(perr) } }) end
    local extra = room.extra
    room.lookup = room.lookup or resolveFont(extra.font)
    local lookup = room.lookup
    i = math.max(extra.first, math.min(#ptrs, i or extra.first))
    e = e or M.loadEdit(extra, i, lookup)

    local c = M.counts(extra, #ptrs)
    local nx = M.nextUntranslated(extra, #ptrs, i)
    local function at(n) return link { { 'p', 'edit' }, { 'path', path }, { 'i', n } } end
    local nav = H.p {
        string.format('Script %s: %d strings, %d untranslated, %d draft, %d reviewed. ', extra.key,
            #ptrs - extra.first + 1, c[0], c[1], c[2]),
        i > extra.first and H.a { href = at(i - 1), '< previous' } or '< previous', ' | ',
        string.format('pointer %d of %d', i, #ptrs), ' | ',
        i < #ptrs and H.a { href = at(i + 1), 'next >' } or 'next >', ' | ',
        nx and H.a { href = at(nx), 'next untranslated' } or 'every string is translated',
    }

    local tokens, perr2, ppos = M.parse(extra, e)
    local fit = {}
    local trPages, trWindow = {}, nil
    if tokens then
        local window, pages, problems, notes = M.translationPreview(extra, i, e, tokens, lookup)
        trPages, trWindow = pages, window
        if #problems == 0 and #notes == 0 then fit[1] = H.p { class = 'green', 'Fits the box.' } end
        for _, p in ipairs(problems) do fit[#fit + 1] = H.p { class = 'red', p } end
        for _, n in ipairs(notes) do fit[#fit + 1] = H.p { class = 'yellow', n } end
    else
        fit[1] = H.p { class = 'red', string.format('At byte %d: %s', ppos, perr2) }
    end
    local origWindow, origPages = M.originalPreview(ptrs[i], extra, i, lookup)
    local jps, jerr = VP.jp.string(extra, i)
    local jpBlock
    if jps then
        jpBlock = H.div {
            H.h3 { 'Japanese original ', H.span { class = 'dim', string.format('(JP pointer %d, %s)', jps.ptr,
                jps.how == 'same' and 'same index' or 'paired by the room logic') } },
            H.textarea { rows = 4, readonly = true, lang = 'ja', spellcheck = 'false', jps.text },
        }
    else
        jpBlock = H.div { H.h3 'Japanese original', H.p { class = 'dim', jerr } }
    end

    local statuses = {}
    for s = 0, 2 do
        statuses[#statuses + 1] = H.label {
            H.input { type = 'radio', name = 'status', value = s, checked = e.status == s }, ' ',
            VP.tdb.statusNames[s], ' ',
        }
    end
    local function boxField(label, name)
        return H.label { ' ', label, ' ', H.input { type = 'number', name = name, value = e[name], min = 0, size = 5 } }
    end

    local target, source = M.languages()
    local conflictBlock = false
    if conflict then
        conflictBlock = H.div { class = 'red',
            H.h3 'Save conflict',
            H.p(string.format('%s saved version %d of this string while you were editing version %d.',
                conflict.author or 'Someone', conflict.version, e.base)),
            conflict.deletedAt and H.p 'Their version deletes the translation.' or false,
            H.p('Theirs (' .. (VP.tdb.statusNames[conflict.status] or '?') .. '):'),
            richPair(H.textarea { rows = 4, readonly = true,
                conflict.tokens and VP.text.toEditable(conflict.tokens, lookup) or '' }, target, true),
            H.p 'Yours is in the editor below. Save again to keep yours over theirs, or',
            H.a { href = at(i), 'take theirs' }, '.',
        }
    end

    local hist = {}
    for _, line in ipairs(M.history(extra, i, lookup)) do hist[#hist + 1] = H.div(line) end

    return html('200 OK', path .. ' #' .. i, {
        H.h1 { path, ' #', i },
        header(at(i)),
        nav,
        conflictBlock,
        H.div { class = 'cols',
            H.div {
                H.h3 'Original',
                richPair(H.textarea { rows = 4, readonly = true, VP.text.toEditable(extra.tokens[i], lookup) },
                    source, true),
                jpBlock,
                H.form { method = 'post', action = link { { 'p', 'save' } },
                    H.input { type = 'hidden', name = 'path', value = path },
                    H.input { type = 'hidden', name = 'i', value = i },
                    -- The version this edit started from; a conflict raises it to theirs.
                    H.input { type = 'hidden', name = 'base', value = conflict and conflict.version or e.base },
                    H.h3 'Translation',
                    H.p {
                        H.label { H.input { type = 'checkbox', id = 'rich-toggle' }, ' control codes as chips' },
                        ' (as plain text they are {tags}, and {{ and }} are braces) ',
                        H.span { id = 'rich-message', class = 'red' },
                    },
                    richPair(H.textarea { name = 'text', rows = 6, e.text }, target, false),
                    e.sourceChanged and H.p { class = 'red', 'The original text changed since this translation was saved.' }
                        or false,
                    H.p {
                        H.label { H.input { type = 'checkbox', name = 'override', value = '1', checked = e.override },
                            ' Override box' },
                        boxField('x', 'boxX'), boxField('y', 'boxY'), boxField('width', 'boxW'),
                        boxField('height', 'boxH'),
                    },
                    H.p(statuses),
                    H.p {
                        H.label { 'translator ', H.input { type = 'text', name = 'author', size = 12,
                            value = e.author or M.author } }, ' ',
                        H.input { type = 'text', name = 'note', value = e.note, placeholder = 'note', size = 40 }, ' ',
                        H.input { type = 'submit', value = 'Save' },
                        string.format(' (editing version %d)', e.base),
                    },
                },
                message and H.p { class = message.class, message.text } or false,
                fit,
                H.div { class = 'pages',
                    H.div { H.h3 'Original page', pagesBlock(origWindow, origPages) },
                    jps and H.div { H.h3 'Japanese page', pagesBlock(jps.window, jps.pages, 'JP') } or false,
                    H.div { H.h3 'Translated page', pagesBlock(trWindow, trPages, M.charset()) },
                },
                H.h3 'History',
                H.div { class = 'hist', hist },
            },
            H.div { screenBlock() },
        },
        W.richScript and H.script(H.raw(W.richScript)) or false,
    })
end

local function save(form)
    local path, i = form.path, tonumber(form.i)
    local idx = W.index()
    local room = idx and idx.byPath[path or '']
    if not room or not i then return html('400 Bad Request', 'Bad request', { H.p 'Missing path or pointer.' }) end
    local db, dberr = ensureDb()
    if not db then return html('200 OK', 'Error', { H.p { class = 'red', dberr } }) end
    VP.vfs.ptrs(room)
    local extra = room.extra
    room.lookup = room.lookup or resolveFont(extra.font)
    local e = M.loadEdit(extra, i, room.lookup)
    e.text = (form.text or ''):gsub('\r\n', '\n')
    e.status = tonumber(form.status) or e.status
    e.note = form.note or ''
    if form.author and form.author ~= '' then e.author = form.author end
    e.override = form.override == '1'
    for _, k in ipairs({ 'boxX', 'boxY', 'boxW', 'boxH' }) do e[k] = math.max(0, tonumber(form[k]) or e[k]) end
    local expected = tonumber(form.base) or 0
    e.base = expected
    local tokens, perr = M.parse(extra, e)
    if not tokens then return editPage(path, i, e, { class = 'red', text = 'Not saved: ' .. perr }) end
    local result, r = M.save(extra, i, e, tokens, expected, room.lookup)
    if result == 'saved' then
        return redirect(link { { 'p', 'edit' }, { 'path', path }, { 'i', i }, { 'saved', r.version } })
    elseif result == 'conflict' then
        return editPage(path, i, e, nil, r)
    end
    return editPage(path, i, e, { class = 'red', text = tostring(r) })
end

function W.handle(request)
    local q = parseForm(request.urlData.query)
    local p = q.p or 'list'
    local form = request.method == 'POST' and parseForm(request.body) or {}
    if p == 'list' then return listPage(q.q) end
    if p == 'edit' then
        local msg = q.saved and { class = 'green', text = 'Saved as version ' .. q.saved } or nil
        return editPage(q.path, tonumber(q.i), nil, msg)
    end
    if p == 'save' and request.method == 'POST' then return save(form) end
    if p == 'languages' and request.method == 'POST' then
        local db, dberr = ensureDb()
        if not db then return html('200 OK', 'Error', { H.p { class = 'red', dberr } }) end
        local ok, err = M.setLanguages(form.target or '', form.source or '')
        if not ok then return html('400 Bad Request', 'Bad language', { H.p { class = 'red', err } }) end
        local back = form.back or ''
        if not back:match('^/') then back = BASE end
        return redirect(back)
    end
    if p == 'preview' and request.method == 'POST' then
        local db, dberr = ensureDb()
        if form.on == '1' and db then VP.preview.arm(db) elseif form.on == '0' then VP.preview.disarm() end
        local back = form.back or ''
        if not back:match('^/') then back = BASE end
        return redirect(back)
    end
    local route = W.routes[p]
    if route then return route(request, q, form) end
    return html('404 Not Found', 'Not found', { H.p('Unknown page ' .. p) })
end

-- Other pages (translate-web-glyphs.lua) register here: routes[p](request,
-- query, form), with the helpers they share.
W.routes = W.routes or {}
W.util = { html = html, link = link, redirect = redirect, header = header, ensureDb = ensureDb, BASE = BASE }

PCSX.WebServer = PCSX.WebServer or {}
PCSX.WebServer.Handlers = PCSX.WebServer.Handlers or {}
PCSX.WebServer.Handlers['vp'] = function(request)
    local ok, r = pcall(W.handle, request)
    if ok then return r end
    return html('500 Internal Server Error', 'Error', { H.pre { class = 'red', tostring(r) } })
end
