-- Valkyrie Profile disc browser.
--
-- Load a Valkyrie Profile disc in the emulator, then run this script:
--   pcsx-redux -iso <disc.cue> -dofile examples/vp/browser.lua
-- or load it from the Lua console with Support.extra.dofile.
--
-- The tree is read straight from the loaded disc: nothing is extracted. SLZ
-- files and archives are decompressed and split when their node is opened.

VP = VP or {}
VP.globals = VP.globals or {}
VP.constants = VP.constants or {}
VP.arguments = VP.arguments or {}
VP.arguments.dump = false
VP.arguments.dumpGlyphs = false

local d = Support.extra.dofile

d 'base64.lua'
d 'constants.lua'
d 'filemap.lua'
d 'font.lua'
d 'font-database.lua'
d 'index.lua'
d 'iso.lua'
d 'process.lua'
d 'text.lua'
d 'disasm.lua'
d 'scripts.lua'
d 'room.lua'
d 'arcgfx.lua'
d 'carc.lua'
d 'cscript.lua'
d 'slz.lua'
d 'utils.lua'
d 'vfs.lua'
d 'glyphs.lua'
-- The GUI loads this resource at startup; without a GUI (-no-ui) it does not.
if not (PCSX.FileViewers and PCSX.FileViewers.parseTim) then d '../../resources/fileviewers.lua' end
d 'images.lua'
d 'sounds.lua'
d 'loadlog.lua'

generateFileMap()
decodeFonts()

local browser = {
    iso = nil,
    disc = nil,
    root = nil,
    selected = nil,
    viewer = 1,
    nextId = 0,
}
VP.browser = browser

function browser.refresh()
    browser.iso = PCSX.getCurrentIso()
    browser.disc = VP.vfs.identify(browser.iso)
    browser.root = browser.disc and VP.vfs.root(browser.iso) or nil
    browser.selected = nil
end

local function formatSize(n)
    if not n then return '' end
    if n >= 1024 * 1024 then return string.format('%.1f MB', n / (1024 * 1024)) end
    if n >= 1024 then return string.format('%.1f KB', n / 1024) end
    return n .. ' B'
end

local function nodeId(node)
    if not node.id then
        browser.nextId = browser.nextId + 1
        node.id = browser.nextId
    end
    return node.id
end

local function drawNode(node)
    local flags = imgui.constant.TreeNodeFlags.OpenOnArrow + imgui.constant.TreeNodeFlags.SpanAvailWidth
    if VP.vfs.isLeaf(node) then flags = flags + imgui.constant.TreeNodeFlags.Leaf end
    if browser.selected == node then flags = flags + imgui.constant.TreeNodeFlags.Selected end
    local label = node.name
    if node.kind then label = label .. ' - ' .. node.kind end
    if node.size then label = label .. '  (' .. formatSize(node.size) .. ')' end
    if #node.viewers > 0 then label = label .. '  [' .. node.viewers[1].name .. ']' end
    if node.forceOpen then
        imgui.SetNextItemOpen(true)
        node.forceOpen = nil
    end
    local open = imgui.TreeNodeEx(label .. '##' .. nodeId(node), flags)
    if imgui.IsItemClicked() and not imgui.IsItemToggledOpen() then
        browser.selected = node
        browser.viewer = 1
    end
    if open then
        for _, child in ipairs(VP.vfs.expand(node)) do drawNode(child) end
        if node.err then imgui.TextUnformatted('error: ' .. node.err) end
        imgui.TreePop()
    end
end

local function drawPreview(v)
    local ptrs, err = VP.vfs.ptrs(v)
    if not ptrs then
        imgui.TextUnformatted('Error: ' .. tostring(err))
        return
    end
    local font = browser.disc and browser.disc.region or 'US'
    v.previewPtr = v.previewPtr or v.first
    local changed, n = imgui.SliderInt('pointer', v.previewPtr, v.first, #ptrs)
    if changed then v.previewPtr = n end
    local i = v.previewPtr
    local window, pages = VP.glyphs.parse(ptrs[i])
    if window then
        imgui.TextUnformatted(string.format('window %d,%d %dx%d', window.x, window.y, window.width, window.height))
        if window.unknown and #window.unknown > 0 then
            imgui.SameLine()
            imgui.TextUnformatted('(set at runtime: ' .. table.concat(window.unknown, ', ') .. ')')
        end
    end
    for p, lines in ipairs(pages) do
        if #pages > 1 then imgui.TextUnformatted(string.format('page %d/%d', p, #pages)) end
        local missing = VP.glyphs.drawPage(window, lines, font, 2)
        if missing > 0 then imgui.TextUnformatted(missing .. ' characters without a glyph') end
    end
end

local function drawViewer(node)
    imgui.TextUnformatted(node.name .. (node.size and ('  ' .. formatSize(node.size)) or ''))
    -- Opening the node once computes its children, which is where script
    -- viewers get attached for archive entries.
    if not node.isDir then VP.vfs.expand(node) end
    local tabs = {}
    for _, v in ipairs(node.viewers) do tabs[#tabs + 1] = v end
    if not node.imageViewers then
        node.imageViewers = {}
        if not node.isDir then
            local ok, tim = pcall(function() return VP.images.parseTim(node.open()) end)
            if ok and tim then node.imageViewers[#node.imageViewers + 1] = VP.images.timViewer(node, tim) end
            local okS, snd = pcall(function() return VP.sounds.parse(node.open()) end)
            if okS and snd then node.imageViewers[#node.imageViewers + 1] = VP.sounds.viewer(snd) end
            node.imageViewers[#node.imageViewers + 1] = VP.images.rawViewer(node)
        end
    end
    for _, v in ipairs(node.imageViewers) do tabs[#tabs + 1] = v end
    if not node.hexViewer then
        node.hexViewer = { name = 'Hex', render = function() return VP.vfs.hexdump(node) end }
    end
    tabs[#tabs + 1] = node.hexViewer
    imgui.safe.BeginTabBar('viewers', function()
        for _, v in ipairs(node.viewers) do
            if v.load then
                imgui.safe.BeginTabItem('Preview', function()
                    imgui.safe.BeginChild('preview', 0, 0, 0, function() drawPreview(v) end)
                end)
            end
        end
        for _, v in ipairs(tabs) do
            imgui.safe.BeginTabItem(v.name, function()
                imgui.safe.BeginChild('text', 0, 0, 0, imgui.constant.WindowFlags.HorizontalScrollbar, function()
                    if v.draw then v.draw() else imgui.TextUnformatted(VP.vfs.render(v)) end
                end)
            end)
        end
    end)
end

function DrawImguiFrame()
    imgui.SetNextWindowSize(1000, 700, imgui.constant.Cond.FirstUseEver)
    imgui.safe.Begin('Valkyrie Profile browser', function()
        if imgui.Button('Refresh') or browser.iso == nil then browser.refresh() end
        imgui.SameLine()
        if browser.disc then
            local d = browser.disc
            imgui.TextUnformatted(string.format('Valkyrie Profile (%s) disc %d - %s', d.region, d.disc, d.exe))
        else
            imgui.TextUnformatted('No Valkyrie Profile disc loaded')
        end
        if not browser.root then return end
        imgui.Separator()
        imgui.safe.BeginChild('tree', 400, 0, imgui.constant.ChildFlags.Borders + imgui.constant.ChildFlags.ResizeX, function()
            drawNode(browser.root)
        end)
        imgui.SameLine()
        imgui.safe.BeginChild('view', 0, 0, imgui.constant.ChildFlags.Borders, function()
            if browser.selected then drawViewer(browser.selected) end
        end)
    end)
    imgui.SetNextWindowSize(700, 400, imgui.constant.Cond.FirstUseEver)
    imgui.safe.Begin('Valkyrie Profile load log', function() VP.loadlog.draw() end)
end
