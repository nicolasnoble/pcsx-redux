-- Valkyrie Profile file load log.
--
-- Breakpoints on the SLUS CD loader record every file the game reads and
-- every executable it starts. The invokers only append raw numbers to a list;
-- names and formatting happen when the window is drawn.
--
-- Breakpoints only fire with the debugger enabled (the -debugger command line
-- flag, or Debug > Enable debugger).
--
-- SLUS_011.56 addresses:
--   0x8001175c  cdSeekFile(ctx, index), returns 0 while a read is in flight
--   0x8001190c  cdReadFile(ctx, dest, ...), reads the file last seeked
--   0x80011bc4  cdLoadFile(ctx, dest, index, ...), seek + read + wait
--   0x800105b0  execOverlay(ctx, buf, resetStack), decompresses buf to
--               0x8002f824 and jumps there

VP = VP or {}
VP.loadlog = VP.loadlog or {}
local loadlog = VP.loadlog

local ffi = require('ffi')

local CD_SEEK = 0x8001175c
local CD_READ = 0x8001190c
local CD_LOAD = 0x80011bc4
local CD_LOAD_END = 0x80011c40
local EXEC_OVERLAY = 0x800105b0
local CD_BUSY = 0x8002b5ec

loadlog.events = loadlog.events or {}

local function ram32(address)
    local mem = PCSX.getMemPtr()
    return ffi.cast('uint32_t*', mem + bit.band(address, 0x1ffffc))[0]
end

local function ram8(address)
    local mem = PCSX.getMemPtr()
    return mem[bit.band(address, 0x1fffff)]
end

-- The caller of interest is whoever asked for the file. When the call comes
-- from inside cdLoadFile, that is cdLoadFile's own caller, saved at 32(sp).
local function caller(regs)
    local ra = regs.GPR.n.ra
    if ra >= CD_LOAD and ra < CD_LOAD_END then return ram32(regs.GPR.n.sp + 32) end
    return ra
end

local function push(kind, regs, index, address)
    local events = loadlog.events
    events[#events + 1] = {
        kind = kind,
        cycle = PCSX.getCPUCycles(),
        index = index,
        address = address,
        caller = caller(regs),
    }
end

-- The last seek that went through, so the read after it knows its file.
local pendingIndex

local function onSeek()
    local regs = PCSX.getRegisters()
    -- A seek issued while a read is in flight returns 0 and cdLoadFile retries
    -- it in a loop. Only the one that goes through is logged.
    if ram8(CD_BUSY) ~= 0 then return true end
    pendingIndex = regs.GPR.n.a1
    return true
end

local function onRead()
    local regs = PCSX.getRegisters()
    if ram8(CD_BUSY) ~= 0 then return true end
    push('read', regs, pendingIndex, regs.GPR.n.a1)
    pendingIndex = nil
    return true
end

local function onExec()
    local regs = PCSX.getRegisters()
    -- The buffer is the destination of an earlier read; find which file it held.
    local buffer = regs.GPR.n.a1
    local index
    local events = loadlog.events
    for i = #events, 1, -1 do
        if events[i].kind == 'read' and events[i].address == buffer then
            index = events[i].index
            break
        end
    end
    push('exec', regs, index, 0x8002f824)
    return true
end

function loadlog.arm()
    loadlog.disarm()
    loadlog.breakpoints = {
        PCSX.addBreakpoint(CD_SEEK, 'Exec', 4, 'VP load log', onSeek, 'cdSeekFile'),
        PCSX.addBreakpoint(CD_READ, 'Exec', 4, 'VP load log', onRead, 'cdReadFile'),
        PCSX.addBreakpoint(EXEC_OVERLAY, 'Exec', 4, 'VP load log', onExec, 'execOverlay'),
    }
end

function loadlog.disarm()
    if not loadlog.breakpoints then return end
    for _, bp in ipairs(loadlog.breakpoints) do bp:remove() end
    loadlog.breakpoints = nil
end

function loadlog.clear()
    loadlog.events = {}
    pendingIndex = nil
end

local function fileName(index)
    if not index then return '?' end
    local info = VP.globals.filemap and VP.globals.filemap[index]
    if info then return info.dir .. '/' .. info.name end
    return string.format('%04i', index)
end

local function cycleString(cycle) return (tostring(cycle):gsub('ULL$', '')) end

-- GET /api/v1/lua/vp-loadlog[?since=N] with the web server enabled returns
-- one tab separated line per event, starting after the first N events:
-- event number, cycle, kind, index, file, address, caller.
PCSX.WebServer = PCSX.WebServer or {}
PCSX.WebServer.Handlers = PCSX.WebServer.Handlers or {}
PCSX.WebServer.Handlers['vp-loadlog'] = function(request)
    local since = tonumber((request.urlData.query or ''):match('since=(%d+)')) or 0
    local lines = {}
    local events = loadlog.events
    for i = since + 1, #events do
        local e = events[i]
        lines[#lines + 1] = string.format('%d\t%s\t%s\t%s\t%s\t%08x\t%08x', i, cycleString(e.cycle), e.kind,
                                          e.index and tostring(e.index) or '?', fileName(e.index), e.address, e.caller)
    end
    return table.concat(lines, '\n') .. (#lines > 0 and '\n' or '')
end

function loadlog.draw()
    local armed = loadlog.breakpoints ~= nil
    if imgui.Button(armed and 'Disarm' or 'Arm') then
        if armed then loadlog.disarm() else loadlog.arm() end
    end
    imgui.SameLine()
    if imgui.Button('Clear') then loadlog.clear() end
    imgui.SameLine()
    imgui.TextUnformatted(string.format('%d events', #loadlog.events))
    local flags = imgui.constant.TableFlags.Borders + imgui.constant.TableFlags.RowBg
                + imgui.constant.TableFlags.ScrollY + imgui.constant.TableFlags.Resizable
    imgui.safe.BeginTable('loadlog', 5, flags, function()
        imgui.TableSetupScrollFreeze(0, 1)
        imgui.TableSetupColumn('cycle')
        imgui.TableSetupColumn('event')
        imgui.TableSetupColumn('file')
        imgui.TableSetupColumn('address')
        imgui.TableSetupColumn('caller')
        imgui.TableHeadersRow()
        for _, e in ipairs(loadlog.events) do
            imgui.TableNextRow()
            imgui.TableNextColumn()
            imgui.TextUnformatted(cycleString(e.cycle))
            imgui.TableNextColumn()
            imgui.TextUnformatted(e.kind)
            imgui.TableNextColumn()
            imgui.TextUnformatted(fileName(e.index))
            imgui.TableNextColumn()
            imgui.TextUnformatted(string.format('%08x', e.address))
            imgui.TableNextColumn()
            imgui.TextUnformatted(string.format('%08x', e.caller))
        end
    end)
end
