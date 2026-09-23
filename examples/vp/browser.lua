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

local function drawViewer(node)
    imgui.TextUnformatted(node.name .. (node.size and ('  ' .. formatSize(node.size)) or ''))
    -- Opening the node once computes its children, which is where script
    -- viewers get attached for archive entries.
    if not node.isDir then VP.vfs.expand(node) end
    local tabs = {}
    for _, v in ipairs(node.viewers) do tabs[#tabs + 1] = v end
    if not node.hexViewer then
        node.hexViewer = { name = 'Hex', render = function() return VP.vfs.hexdump(node) end }
    end
    tabs[#tabs + 1] = node.hexViewer
    imgui.safe.BeginTabBar('viewers', function()
        for _, v in ipairs(tabs) do
            imgui.safe.BeginTabItem(v.name, function()
                imgui.safe.BeginChild('text', 0, 0, 0, imgui.constant.WindowFlags.HorizontalScrollbar, function()
                    imgui.TextUnformatted(VP.vfs.render(v))
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
end
