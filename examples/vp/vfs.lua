-- Lazy view of a Valkyrie Profile disc as a tree of nodes.
--
-- Nothing is extracted to disk. A node knows how to open its own content and,
-- on first expansion, how to list its children: SLZ containers expand into
-- their decompressed chunks, and the archive formats (arcroom / arcgfx / carc /
-- cscript) expand into their subfiles. Nodes that hold a complete script + font
-- pair get a text viewer that decodes the script through the glyph database.
--
-- Node fields:
--   name      label shown in the tree
--   size      content size in bytes, if known
--   open()    returns a File with the node's content
--   ftype     container format, from the file map (arcroom, arcgfx, carc, cscript)
--   ext       file extension, from the file map
--   tag       archive entry tag, for subfiles
--   children  nil until expand() has run
--   viewers   list of { name = ..., render = function() return text end }
--   err       error message from the last failed expansion, if any

VP.vfs = VP.vfs or {}

local function newNode(t)
    t.viewers = t.viewers or {}
    return t
end

local function bufferFile(data)
    local f = Support.File.buffer()
    f:writeAt(data, 0)
    return f
end

-- Returns the list of leaf files for a piece of content: the content itself if
-- it is not SLZ, or its decompressed chunks, recursively.
local function leafFiles(file)
    local sig = file:readU32At(0)
    if not isSLZ(sig) then return { file } end
    local ret = {}
    for _, chunk in ipairs(slzDecompress(file)) do
        for _, leaf in ipairs(leafFiles(bufferFile(chunk))) do ret[#ret + 1] = leaf end
    end
    return ret
end

local function scriptText(ptrs, first)
    local lines = {}
    for i = first or 1, #ptrs do
        lines[#lines + 1] = '<ptr ' .. i .. '>'
        lines[#lines + 1] = ptrs[i]
    end
    return table.concat(lines, '\n')
end

local function roomScriptViewer(script, font, index)
    return {
        name = 'Room script',
        render = function()
            local ptrs = extract_room_script('room', script, font, { index = index })
            return scriptText(ptrs, 3)
        end,
    }
end

local function simpleScriptViewer(script, font, style)
    return {
        name = 'Script',
        render = function()
            return scriptText(extract_simple_script('script', script, font, style))
        end,
    }
end

-- Pairs scripts with fonts across the entries of one archive, the same way the
-- dump handlers do, and attaches the viewer to the entry that completes a pair.
-- roleOf(child) returns a list of roles for the child's leaf files, in order,
-- or nil if the child plays no part in a pair.
local function pairScripts(children, roleOf, makeViewer)
    local script, font
    for _, child in ipairs(children) do
        local roles = roleOf(child)
        if roles then
            -- An entry may carry fewer leaves than roles: a .sarc script entry
            -- holds only the script when its font is a separate entry.
            local leaves = leafFiles(child.open())
            for i, leaf in ipairs(leaves) do
                local role = roles[i]
                if role == 'script' then
                    if script then error('Two scripts before a font in ' .. child.name) end
                    script = leaf
                elseif role == 'font' then
                    if font then error('Two fonts before a script in ' .. child.name) end
                    font = leaf
                end
            end
            if #leaves > #roles then error('Too many sub-chunks in ' .. child.name) end
        end
        if script and font then
            table.insert(child.viewers, 1, makeViewer(script, font))
            script, font = nil, nil
        end
    end
end

local function subNode(parent, i, tag, offset, size, file)
    return newNode({
        name = string.format('%04i-%08X', i, tag),
        size = size,
        tag = tag,
        open = function() return file:subFile(offset, size) end,
    })
end

local containers = {}

containers.arcroom = function(node, file)
    local nfiles = file:readU32At(0)
    local offset = file:readU32At(4)
    if nfiles * 8 + 8 ~= offset then error 'Bad archive format' end
    local children = {}
    for i = 1, nfiles do
        local tag = file:readU32At(8 * i)
        local size = file:readU32At(8 * i + 4)
        children[i] = subNode(node, i, tag, offset, size, file)
        offset = offset + size
    end
    if node.ext == 'arm' then
        pairScripts(children, function(c) if c.tag == 4 then return { 'script', 'font' } end end,
            function(s, f) return roomScriptViewer(s, f, node.index) end)
    elseif node.ext == 'sarc' then
        pairScripts(children, function(c)
            if c.tag == 4 then return { 'script', 'font' } end
            if c.tag == 7 then return { 'font' } end
        end, function(s, f) return simpleScriptViewer(s, f, 'primary') end)
    end
    return children
end

containers.arcgfx = function(node, file)
    local nfiles = file:readU32At(0)
    local children = {}
    local offset = 8 + nfiles * 8
    for i = 1, nfiles do
        local tag = file:readU32At(8 * i)
        local size = file:readU32At(8 * i + 4)
        children[i] = subNode(node, i, tag, offset, size, file)
        offset = offset + size
    end
    pairScripts(children, function(c)
        local f1 = bit.band(c.tag, 0xffffff00)
        if f1 == 0x00300900 then return { 'script' } end
        if f1 == 0x00300800 then return { 'font' } end
    end, function(s, f) return simpleScriptViewer(s, f, 'primary') end)
    return children
end

containers.carc = function(node, file)
    local size = file:size()
    local nfiles = file:readU32At(0)
    local index = {}
    for i = 1, nfiles do
        local packed = file:readU32At(4 * i)
        index[i] = { tag = bit.rshift(packed, 24), offset = bit.band(packed, 0xffffff) }
    end
    index[nfiles + 1] = { offset = size }
    local children = {}
    for i = 1, nfiles do
        local c = subNode(node, i, index[i].tag, index[i].offset, index[i + 1].offset - index[i].offset, file)
        if index[i].tag == 3 then c.ftype = 'carc' end
        children[i] = c
    end
    pairScripts(children, function(c)
        if c.tag == 2 then return { 'script' } end
        if c.tag == 1 then return { 'font' } end
    end, function(s, f) return simpleScriptViewer(s, f, 'secondary') end)
    return children
end

-- A cscript entry is an SLZ file whose two chunks are the script and the font.
local function attachCScript(node, chunks)
    if #chunks ~= 2 then error('cscript with ' .. #chunks .. ' chunks') end
    local script, font = chunks[1].open(), chunks[2].open()
    table.insert(node.viewers, 1, simpleScriptViewer(script, font, 'primary'))
end

-- Expands one content node: SLZ first, then the container format of the
-- node's ftype. The ftype carries over to the decompressed chunks, since that
-- is where the archive actually lives when the entry is compressed.
local function expandContent(node)
    local file = node.open()
    if file:size() >= 4 and isSLZ(file:readU32At(0)) then
        local children = {}
        for i, chunk in ipairs(slzDecompress(file)) do
            local data = chunk
            children[i] = newNode({
                name = string.format('chunk %02i', i),
                size = #data,
                ftype = node.ftype ~= 'cscript' and node.ftype or nil,
                ext = node.ext,
                index = node.index,
                open = function() return bufferFile(data) end,
            })
        end
        if node.ftype == 'cscript' then attachCScript(node, children) end
        return children
    end
    local handler = node.ftype and containers[node.ftype]
    if handler then return handler(node, file) end
    return {}
end

-- Identifies the disc from its executable name.
local discs = {
    ['SLUS_011.56'] = { region = 'US', disc = 1 },
    ['SLUS_011.79'] = { region = 'US', disc = 2 },
    ['SLPM_863.79'] = { region = 'JP', disc = 1 },
    ['SLPM_863.80'] = { region = 'JP', disc = 2 },
    ['VALKYRIE.EXE'] = { region = 'US', disc = 0 },
}

function VP.vfs.identify(iso)
    if not iso or iso:failed() then return nil end
    local reader = iso:createReader()
    for exe, info in pairs(discs) do
        local f = reader:open(exe .. ';1')
        if not f:failed() then
            f:close()
            return { exe = exe, region = info.region, disc = info.disc }
        end
        f:close()
    end
    return nil
end

local function isoDirNode(reader, iso, path, name)
    return newNode({
        name = name,
        isDir = true,
        expand = function()
            local children = {}
            for _, e in ipairs(reader:listDir(path)) do
                local full = path == '' and e.name or (path .. '/' .. e.name)
                if e.isDir then
                    children[#children + 1] = isoDirNode(reader, iso, full, e.name)
                else
                    children[#children + 1] = newNode({
                        name = e.name,
                        size = e.size,
                        open = function() return iso:open(e.lba, e.size, 'M2_FORM1') end,
                    })
                end
            end
            return children
        end,
    })
end

-- Builds the game index tree: the file map's directories as folders, and the
-- index entries present on this disc as files inside them.
local function indexNode(iso)
    return newNode({
        name = 'Game index',
        isDir = true,
        expand = function()
            VP.globals.index.entries = {}
            VP.globals.isos = { US = { CD1 = { iso = iso } }, JP = {} }
            readIndex()
            local root = { children = {}, byName = {} }
            local function dirFor(path)
                local d = root
                for part in path:gmatch('[^/]+') do
                    local sub = d.byName[part]
                    if not sub then
                        sub = newNode({ name = part, isDir = true, children = {}, byName = {} })
                        d.byName[part] = sub
                        d.children[#d.children + 1] = sub
                    end
                    d = sub
                end
                return d
            end
            for i = 1, VP.constants.indexCount - 1 do
                local entry = VP.globals.index.entries[i]
                if entry then
                    local info = VP.globals.filemap[i] or {}
                    local dir = (info.dir or 'DUMP/UNKNOWN'):gsub('^DUMP/', '')
                    local ext = info.ext or 'out'
                    local sectorSize = info.sectorSize or 2048
                    local mode = info.mode
                    local d = dirFor(dir)
                    d.children[#d.children + 1] = newNode({
                        name = string.format('%04i.%s', i, ext),
                        size = entry.size * sectorSize,
                        index = i,
                        ftype = info.ftype,
                        ext = ext,
                        open = function() return entry.iso:open(entry.lba, entry.size * sectorSize, mode) end,
                    })
                end
            end
            return root.children
        end,
    })
end

function VP.vfs.root(iso)
    local reader = iso:createReader()
    return newNode({
        name = 'Disc',
        isDir = true,
        expand = function()
            return { isoDirNode(reader, iso, '', 'ISO9660'), indexNode(iso) }
        end,
    })
end

-- Lists a node's children, computing them on first use. Errors are caught and
-- stored on the node so the UI can show them and keep going.
function VP.vfs.expand(node)
    if node.children then return node.children end
    local ok, ret = pcall(function()
        if node.expand then return node.expand() end
        return expandContent(node)
    end)
    if ok then
        node.children = ret
        node.err = nil
    else
        node.children = {}
        node.err = tostring(ret)
    end
    return node.children
end

-- A node is a leaf once expanded without children and without error, or if it
-- was never going to have any: plain files without an SLZ header or container
-- type. Directories and unexpanded content report false so the UI shows an
-- arrow until the first look.
function VP.vfs.isLeaf(node)
    if node.isDir then return false end
    if node.children then return #node.children == 0 end
    return false
end

-- Renders a viewer, caching the text on the viewer itself.
function VP.vfs.render(viewer)
    if viewer.text then return viewer.text end
    local ok, ret = pcall(viewer.render)
    viewer.text = ok and ret or ('Error: ' .. tostring(ret))
    return viewer.text
end

-- Hex dump of the first bytes of a node, as a fallback viewer.
function VP.vfs.hexdump(node, limit)
    limit = limit or 4096
    local ok, file = pcall(node.open)
    if not ok then return 'Error: ' .. tostring(file) end
    local size = file:size()
    local n = math.min(size, limit)
    local data = file:readAt(n, 0)
    local lines = { string.format('%d bytes', size) }
    for off = 0, n - 1, 16 do
        local hex, asc = {}, {}
        for j = 0, 15 do
            if off + j < n then
                local b = data[off + j]
                hex[#hex + 1] = string.format('%02x', b)
                asc[#asc + 1] = (b >= 32 and b < 127) and string.char(b) or '.'
            else
                hex[#hex + 1] = '  '
            end
        end
        lines[#lines + 1] = string.format('%08x  %s  %s', off, table.concat(hex, ' '), table.concat(asc))
    end
    if size > n then lines[#lines + 1] = string.format('... %d more bytes', size - n) end
    return table.concat(lines, '\n')
end
