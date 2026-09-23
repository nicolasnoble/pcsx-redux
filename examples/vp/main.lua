PCSX.settings.emulator.FullCaching = true

-- Respect any VP table pre-populated by a wrapper script (e.g. for overriding
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
d 'sounds.lua'
d 'utils.lua'

generateFileMap()
decodeFonts()

-- Disc paths come from the VP_DISC1 / VP_DISC2 environment variables:
--   VP_DISC1=/path/to/cd1.cue VP_DISC2=/path/to/cd2.cue \
--       pcsx-redux -cli -dofile main.lua
-- Passing them with -exec does not work: -exec runs after -dofile. A wrapper
-- script that fills in VP.arguments and then dofiles this one works too.
VP.arguments.disc1 = VP.arguments.disc1 or os.getenv('VP_DISC1') or 'C:/Games/PSX/vp/vp-disc1.cue'
VP.arguments.disc2 = VP.arguments.disc2 or os.getenv('VP_DISC2') or 'C:/Games/PSX/vp/vp-disc2.cue'

probeIsoFile(VP.arguments.disc1)
probeIsoFile(VP.arguments.disc2)

if not VP.globals.isos.US.CD1 and not VP.globals.isos.US.CD2 then
    print('No Valkyrie Profile US disc found. Tried:')
    print('  ' .. VP.arguments.disc1)
    print('  ' .. VP.arguments.disc2)
    PCSX.quit(1)
    return
end

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
