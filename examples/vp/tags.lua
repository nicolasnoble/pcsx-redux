-- The control-code manual: one row per tag the translation editor shows,
-- built from the codec tables in text.lua (names, aliases, argument bytes),
-- with how often each occurs on USA disc 1 (tag-counts.lua, written by
-- tag-counts-gen.lua) and how much is known about what it does.
--
-- Status: 'measured' means re-observed in the running game; 'observed-2009'
-- means the name was given in 2009 from watching the game and has not been
-- re-checked; 'unknown' means nobody has named it.

VP.tags = VP.tags or {}

local notes = {
    newline = { status = 'measured',
        note = 'Starts a new line. In game, a string with more lines than its box scrolls up a line at a time (USA disc 1, room text, 2026-11-08).' },
}
for _, name in ipairs { 'new', 'pause', 'spd', 'rspd', 'clr', 'start', 'rep', 'rrep', 'siz', 'rsiz', 'var', 'delay',
    'ssync', 'port', 'dport' } do
    notes[name] = { status = 'observed-2009' }
end
VP.tags.notes = notes

local function argList(n)
    local names = { 'a', 'b', 'c', 'd' }
    local t = {}
    for i = 1, n do t[i] = names[i] end
    return t
end

-- Rows for the room-script (primary) style, in code order, aliases right after
-- the code they stand for. Each row: tag (as written in the editor), name,
-- code, args (argument bytes), count and strings (from tag-counts.lua, nil
-- when it was not generated), status, note.
function VP.tags.rows()
    local style = 'primary'
    local names, aliases, widths = VP.text.tagNames[style], VP.text.tagAliases[style], VP.text.argBytes[style]
    local counts = VP.tags.counts and VP.tags.counts.tags or nil
    local codes, seen = {}, {}
    local function add(c) if not seen[c] then seen[c] = true codes[#codes + 1] = c end end
    add(0) add(1)
    for c in pairs(names) do add(c) end
    for c in pairs(widths) do add(c) end
    if counts then
        for name in pairs(counts) do
            local c = tonumber(name:match('^c(%d+)$'))
            if c then add(c) end
        end
    end
    table.sort(codes)
    local rows = {}
    local function row(name, tag, c, nargs, fixed)
        local n = notes[name] or { status = 'unknown' }
        local cnt = counts and (counts[name] or { n = 0, strings = 0 })
        rows[#rows + 1] = { name = name, tag = tag, code = c, args = nargs, fixed = fixed,
            count = cnt and cnt.n, strings = cnt and cnt.strings, status = n.status, note = n.note }
    end
    for _, c in ipairs(codes) do
        local nargs = widths[c] or 0
        if c == 0 then
            row('newline', '(line break)', c, 0)
        elseif c == 1 then
            row('new', '{new}', c, 0)
        else
            local name = names[c] or ('c' .. c)
            local a = argList(nargs)
            row(name, '{' .. name .. (nargs > 0 and ' ' .. table.concat(a, ' ') or '') .. '}', c, nargs)
            local al = {}
            for aname, def in pairs(aliases) do
                if def[1] == c then al[#al + 1] = aname end
            end
            table.sort(al)
            for _, aname in ipairs(al) do
                row(aname, '{' .. aname .. '}', c, nargs, table.concat(aliases[aname][2], ' '))
            end
        end
    end
    return rows
end

-- One line of text for a row's arguments: "1 byte", "2 bytes, fixed 255 255".
function VP.tags.argText(r)
    local s = r.args == 0 and 'none' or (r.args .. (r.args == 1 and ' byte' or ' bytes'))
    if r.fixed then s = s .. ', fixed ' .. r.fixed end
    return s
end

VP.tags.statusText = {
    measured = 're-observed in the running game',
    ['observed-2009'] = 'named in 2009 from watching the game, not re-checked',
    unknown = 'nobody has named it',
}

-- What the counts range over, one line.
function VP.tags.scopeText()
    local c = VP.tags.counts
    if not c then return 'Counts not generated (run tag-counts-gen.lua with a disc).' end
    return string.format('Counts: room scripts of %s, %d distinct scripts (%d rooms), %d strings; ' ..
        '"strings" is how many strings use the tag at least once.', c.disc, c.scripts, c.rooms, c.strings)
end

-- Redux's Lua ImGui has no TextWrapped (a printf-style function).
local function wrapped(text)
    imgui.PushTextWrapPos(0)
    imgui.TextUnformatted(text)
    imgui.PopTextWrapPos()
end

-- The manual as an ImGui table, under a collapsing header (Translate tab).
function VP.tags.drawImgui()
    if VP.tags.openAtStart then imgui.SetNextItemOpen(true, imgui.constant.Cond.Once) end
    if not imgui.CollapsingHeader('Control codes (help)') then return end
    wrapped('Codes are written as {tags} in the translation. Arguments are bytes (0-255). ' ..
        'Status: measured = ' .. VP.tags.statusText.measured .. '; observed-2009 = ' ..
        VP.tags.statusText['observed-2009'] .. '; unknown = ' .. VP.tags.statusText.unknown .. '.')
    wrapped(VP.tags.scopeText())
    local flags = imgui.constant.TableFlags.Borders + imgui.constant.TableFlags.RowBg
        + imgui.constant.TableFlags.Resizable
    imgui.safe.BeginTable('vptags', 7, flags, function()
        imgui.TableSetupColumn('tag')
        imgui.TableSetupColumn('code')
        imgui.TableSetupColumn('arguments')
        imgui.TableSetupColumn('count')
        imgui.TableSetupColumn('strings')
        imgui.TableSetupColumn('status')
        imgui.TableSetupColumn('notes')
        imgui.TableHeadersRow()
        for _, r in ipairs(VP.tags.rows()) do
            imgui.TableNextRow()
            imgui.TableNextColumn() imgui.TextUnformatted(r.tag)
            imgui.TableNextColumn() imgui.TextUnformatted(string.format('%d', r.code))
            imgui.TableNextColumn() imgui.TextUnformatted(VP.tags.argText(r))
            imgui.TableNextColumn() imgui.TextUnformatted(r.count and tostring(r.count) or '-')
            imgui.TableNextColumn() imgui.TextUnformatted(r.strings and tostring(r.strings) or '-')
            imgui.TableNextColumn() imgui.TextUnformatted(r.status)
            imgui.TableNextColumn() wrapped(r.note or '')
        end
    end)
end
