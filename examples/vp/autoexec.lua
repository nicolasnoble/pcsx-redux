-- vp-translate.zip runs this when the archive is mounted (pcsx-redux -archive
-- vp-translate.zip, or File > Open archive). It loads the disc browser with the
-- Translate tab, and registers the web view at /api/v1/lua/vp.
local missing = {}
if not PCSX.SQLite then missing[#missing + 1] = 'PCSX.SQLite (the translation database)' end
if not PCSX.Html then missing[#missing + 1] = 'PCSX.Html (the web view)' end
for _, m in ipairs(missing) do
    print('vp-translate: this build of PCSX-Redux has no ' .. m .. '; that part will not work')
end
Support.extra.dofile('browser.lua')
print('vp-translate: loaded')
