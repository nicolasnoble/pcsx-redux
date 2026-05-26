PCSX.settings.emulator.FullCaching = true

-- Respect any VP table pre-populated by -exec arguments (e.g. for overriding
-- VP.arguments.disc1 / disc2 paths) so the user doesn't have to edit this file
-- to run against discs in different locations.
VP = VP or {}
VP.globals = VP.globals or {}
VP.constants = VP.constants or {}
VP.arguments = VP.arguments or {}
if VP.arguments.dump == nil then VP.arguments.dump = true end
if VP.arguments.dumpGlyphs == nil then VP.arguments.dumpGlyphs = false end
if VP.arguments.sloppyExtract == nil then VP.arguments.sloppyExtract = false end

-- Support.extra.dofile resolves relative paths against the calling script's
-- directory, so the example works regardless of cwd at invocation time.
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

generateFileMap()
decodeFonts()

-- Disc paths can be overridden by passing -exec to pcsx-redux BEFORE -dofile:
--   pcsx-redux -cli \
--       -exec "VP={arguments={disc1='/path/to/cd1.cue', disc2='/path/to/cd2.cue'}}" \
--       -dofile main.lua
VP.arguments.disc1 = VP.arguments.disc1 or 'C:/Games/PSX/vp/vp-disc1.cue'
VP.arguments.disc2 = VP.arguments.disc2 or 'C:/Games/PSX/vp/vp-disc2.cue'

probeIsoFile(VP.arguments.disc1)
probeIsoFile(VP.arguments.disc2)

readIndex()

if VP.arguments.dump then
    mkdir 'DUMP/GAME'
    VP.globals.lookupRooms = Support.File.open('DUMP/GAME/rooms.lua', 'TRUNCATE')
    VP.globals.lookupRooms:write 'rooms_lookup = {\n'
end

processAllFiles()

if VP.globals.lookupRooms then
    VP.globals.lookupRooms:write '}\n'
    VP.globals.lookupRooms:close()
end

if VP.arguments.dump and VP.globals.allTexts then
    local o = Support.File.open('DUMP/GAME/rooms.xml', 'TRUNCATE')
    o:write '<roomscripts>\n'
    for k, v in ipairs(VP.globals.allTexts) do
        o:write('\n<ptr n="' .. k .. '"/>\n' .. v .. '\n')
    end
    o:write '</roomscripts>\n'
    o:close()
end

PCSX.quit()
