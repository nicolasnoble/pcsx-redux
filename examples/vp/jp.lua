-- The Japanese script beside the English one. A JP disc is opened next to the
-- US disc being translated (VP_DISC_JP, or VP.jp.setDisc from either view),
-- and each US room is paired with the JP room 117 index entries further on,
-- string by string through VP.jpmatch. Read only: nothing here writes.

VP.jp = VP.jp or {}
local J = VP.jp
J.rooms = J.rooms or {}

J.offset = J.offset or 117 -- JP room archives are 3721-4849, US ones 3604-4732

-- Opens a JP disc. Returns true, or nil and why.
function J.setDisc(path)
    J.path, J.err, J.dir, J.rooms = path, nil, nil, {}
    if not path or path == '' then return nil end
    local iso = PCSX.openIso(path)
    local disc = VP.vfs.identify(iso)
    if not disc or disc.region ~= 'JP' then
        J.err = 'not a Japanese Valkyrie Profile disc'
        return nil, J.err
    end
    -- Expanding a disc's index rewrites the globals the US tree read its own
    -- index from; put them back afterwards.
    local savedEntries, savedIsos = VP.globals.index.entries, VP.globals.isos
    local ok, err = pcall(function()
        for _, c in ipairs(VP.vfs.expand(VP.vfs.root(iso))) do
            if c.name == 'Game index' then
                for _, g in ipairs(VP.vfs.expand(c)) do
                    if g.name == 'GAME' then
                        for _, d in ipairs(VP.vfs.expand(g)) do
                            if d.name == 'ROOMS' then J.dir = d end
                        end
                    end
                end
            end
        end
    end)
    VP.globals.index.entries, VP.globals.isos = savedEntries, savedIsos
    if not ok or not J.dir then
        J.err = ok and 'no room archives on this disc' or tostring(err)
        return nil, J.err
    end
    J.iso, J.disc = iso, disc
    return true
end

-- VP_DISC_JP opens on first use: the file map is only built once every file of
-- the example has loaded.
local function ensure()
    if not J.path and not J.tried and os.getenv('VP_DISC_JP') then
        J.tried = true
        J.setDisc(os.getenv('VP_DISC_JP'))
    end
end

-- 'unset', 'ok' or the error message.
function J.status()
    ensure()
    if J.err then return J.err end
    return J.dir and 'ok' or 'unset'
end

local function roomExtra(jpIndex)
    for _, f in ipairs(VP.vfs.expand(J.dir)) do
        if f.index == jpIndex then
            local found
            local function walk(node)
                local children = VP.vfs.expand(node)
                for _, v in ipairs(node.viewers or {}) do
                    if not found and v.load and VP.vfs.ptrs(v) and v.extra.key then found = v.extra end
                end
                for _, c in ipairs(children) do walk(c) end
            end
            walk(f)
            return found
        end
    end
end

-- The pairing for a US room script extra: { how =, map =, jp = JP extra,
-- lookup = }, or nil and why.
function J.forUS(extra)
    ensure()
    if not J.dir then return nil, J.err or 'no Japanese disc loaded' end
    if not extra.index then return nil, 'not a room script' end
    local r = J.rooms[extra.index]
    if r == nil then
        local ok, jp = pcall(roomExtra, extra.index + J.offset)
        if ok and jp then
            r = VP.jpmatch.pair(extra, jp)
            r.jp, r.lookup = jp, resolveFont(jp.font)
        else
            r = false
        end
        J.rooms[extra.index] = r
    end
    if not r then return nil, 'no Japanese room ' .. (extra.index + J.offset) end
    return r
end

-- The JP string paired with US pointer i: { text =, ptr =, window =, pages = }
-- (pages wrapped and scrolled in the JP box, for the JP font), or nil and why.
function J.string(extra, i)
    local r, err = J.forUS(extra)
    if not r then return nil, err end
    local j = r.map[i]
    if not j then
        return nil, r.how == 'none' and 'the two room logics differ, no Japanese string is paired here'
            or 'no Japanese string pairs with this one'
    end
    local jp = r.jp
    local tb = jp.textboxes[j]
    local head = VP.tmodel.windowHead(tb)
    local box = VP.tmodel.originalBox(tb)
    local pages = VP.glyphs.pagesFromTokens(jp.tokens[j], r.lookup, jp.style)
    pages = VP.glyphs.scrollPages((VP.glyphs.wrapPages(pages, box.width, 'JP')), box.height)
    return {
        text = VP.text.toEditable(jp.tokens[j], r.lookup, jp.style),
        ptr = j,
        how = r.how,
        window = head and VP.glyphs.windowGeometry(head) or nil,
        pages = pages,
    }
end

