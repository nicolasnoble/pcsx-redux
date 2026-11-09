-- The Japanese pane: with a US disc loaded and a JP disc opened beside it,
-- the Translate model returns the JP string paired with a US one, and the web
-- edit page shows it (text and game-font page). A room whose logics differ
-- shows no JP string.
--
--   VP_DISC_JP=<jp.cue> VP_TDB=<scratch.tdb> pcsx-redux -cli -iso <us.cue> -dofile examples/vp/jp-pane-test.lua
--
-- VP_JP_PANE_RED=1 pairs US rooms with the JP room one entry too early, which
-- must fail. VP_JP_PANE_HTML=<file> writes the edit page there.

local here = debug.getinfo(1, 'S').source:match('^@(.*/)') or './'
Support.extra.dofile(here .. 'browser.lua')
if os.getenv('VP_JP_PANE_RED') == '1' then
    VP.jp.offset = 116
    print('red arm: JP room offset 116')
end

local failures = 0
local function check(ok, what)
    print((ok and 'ok   ' or 'FAIL ') .. what)
    if not ok then failures = failures + 1 end
end

check(VP.jp.status() == 'ok', 'JP disc opened: ' .. tostring(VP.jp.status()))
local idx = VP.tweb.index()
local function room(n)
    for _, path in ipairs(idx.list) do
        if path:find('/' .. n .. '%.arm') then
            local v = idx.byPath[path]
            VP.vfs.ptrs(v)
            return v.extra, path
        end
    end
end

local extra, path = room(3613)
check(extra and extra.index == 3613, 'US room 3613 found, extra.index = ' .. tostring(extra and extra.index))
local s, err = VP.jp.string(extra, 15)
check(s and s.text:find('プラチナ', 1, true) ~= nil, 'ptr 15 pairs with プラチナ: ' .. tostring(s and s.text or err))
check(s and #s.pages > 0 and #s.pages[1] > 0, 'JP pages laid out')
check(s and s.text:find('・・・', 1, true) ~= nil, 'the JP middle dots stay JP characters')
check(s and s.how == 'same' and s.ptr == 15, 'paired at the same index')

local e3610 = room(3610)
local s2, err2 = VP.jp.string(e3610, 10)
check(not s2 and err2 and err2:find('differ') ~= nil, 'room 3610 (logics differ) pairs nothing: ' .. tostring(err2))

local function urlencode(t) return (t:gsub('[^%w]', function(c) return string.format('%%%02X', c:byte()) end)) end
local page = PCSX.WebServer.Handlers['vp']({ method = 'GET', urlData = { query = 'p=edit&path=' .. urlencode(path) .. '&i=15' } })
check(page:find('Japanese original', 1, true) ~= nil, 'web page has the Japanese original')
check(page:find('lang="ja"', 1, true) ~= nil and page:find('プラチナ', 1, true) ~= nil, 'web page has the JP text, lang ja')
check(page:find('Japanese page', 1, true) ~= nil, 'web page has the JP game-font page')
check(page:find('SLPM_863.79', 1, true) ~= nil, 'web header names the JP disc')
local out = os.getenv('VP_JP_PANE_HTML')
if out then
    local f = io.open(out, 'w')
    f:write((page:gsub('^HTTP/.-\r\n\r\n', '')))
    f:close()
end

print(string.format('JP PANE %s: %d failures', failures == 0 and 'PASS' or 'FAIL', failures))
PCSX.quit(failures == 0 and 0 or 1)
