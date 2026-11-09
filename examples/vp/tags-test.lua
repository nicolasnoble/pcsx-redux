-- Tests of the control-code manual (tags.lua): every tag counted on the disc
-- has a row, every row's argument width is the codec's, and the web page lists
-- every row. No disc needed (counts come from tag-counts.lua).
--
--   pcsx-redux -cli -dofile examples/vp/tags-test.lua
--
-- Red arm: VP_TAGS_RED=1 drops the aliases from the rows, which the counted-tag
-- check must catch.
local here = debug.getinfo(1, 'S').source:match('^@(.*/)') or './'
Support.extra.dofile(here .. 'browser.lua')
if os.getenv('VP_TAGS_RED') == '1' then
    VP.text.tagAliases.primary = {}
    print('red arm: aliases dropped from the manual')
end
local pass, fail = 0, 0
local function check(ok, what)
    if ok then pass = pass + 1 else fail = fail + 1 print('FAIL ' .. what) end
end
local rows = VP.tags.rows()
local byName = {}
for _, r in ipairs(rows) do byName[r.name] = r end
local counted = 0
for name, c in pairs(VP.tags.counts.tags) do
    counted = counted + 1
    check(byName[name] and byName[name].count == c.n, 'counted tag ' .. name .. ' has a row with its count')
end
check(counted > 0, 'tag-counts.lua lists tags')
for _, r in ipairs(rows) do
    check((VP.text.argBytes.primary[r.code] or 0) == r.args, r.name .. ' argument width matches the codec')
    check(r.status == 'measured' or r.status == 'observed-2009' or r.status == 'unknown', r.name .. ' status')
end
-- Every tag the editor parses has a row: round-trip one of each through the codec.
for _, r in ipairs(rows) do
    if r.code > 1 then
        local args = {}
        if r.fixed then for a in r.fixed:gmatch('%d+') do args[#args + 1] = tonumber(a) end
        else for i = 1, r.args do args[i] = 7 end end
        check(VP.text.tagName({ c = r.code, args = args }, 'primary') == r.name, r.name .. ' is what the editor writes')
    end
end
local page = VP.tweb.routes.tags({ method = 'GET' }, {})
check(page:match('^HTTP/1%.%d 200'), 'web page status')
local trs = select(2, page:gsub('<tr>', ''))
check(trs == #rows + 1, 'web page rows ' .. trs .. ' vs ' .. (#rows + 1))
print(string.format('TAGS %s: %d/%d checks, %d rows', fail == 0 and 'PASS' or 'FAIL', pass, pass + fail, #rows))
PCSX.quit(fail == 0 and 0 or 1)
