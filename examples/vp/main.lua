PCSX.settings.emulator.FullCaching = true

VP = { globals = {}, constants = {}, arguments = { dump = true, dumpGlyphs = false } }

dofile 'base64.lua'
dofile 'constants.lua'
dofile 'filemap.lua'
dofile 'font.lua'
dofile 'font-database.lua'
dofile 'index.lua'
dofile 'iso.lua'
dofile 'process.lua'
dofile 'room.lua'
dofile 'slz.lua'
dofile 'utils.lua'

generateFileMap()
decodeFonts()

probeIsoFile 'C:/Games/PSX/vp/vp-disc1.cue'
probeIsoFile 'C:/Games/PSX/vp/vp-disc2.cue'

readIndex()
processAllFiles()

PCSX.quit()
