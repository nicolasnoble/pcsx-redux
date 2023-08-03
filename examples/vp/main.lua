VP = { globals = {}, constants = {}, arguments = { dump = true } }

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
