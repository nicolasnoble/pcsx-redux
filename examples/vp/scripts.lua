-- Resolve a font (table of glyph entries from extractFont) into a lookup table
-- mapping integer glyph index -> character string. Unknown glyphs surface as
-- '<??>' in the lookup; they're also recorded in the extra-glyphs report.
function resolveFont(font)
    local r = {}
    for k, v in pairs(font) do
        if v.text then
            r[k] = v.text
        else
            r[k] = '<??>'
        end
    end
    return r
end

-- Extract a simple (non-room) script. The script blob has a small header pointing
-- to where the variable-width-encoded text begins, followed by (unk, ptr) pairs
-- indexing into the text region. Used by .agx-internal scripts, .carc scripts,
-- and .cscript top-level scripts.
function extract_simple_script(fname, script, font, style)
    print('Processing simple script ' .. fname)
    mkdir(fname)

    local fontData = extractFont(font, { dir = fname .. '/FONT', name = 'font' })
    local lookup = resolveFont(fontData)

    script:rSeek(0)
    local scriptBegin = script:readU32()

    local nPtrs = 1
    local ptrs = {}
    local unks = {}
    local tell = tonumber(script:rTell())
    while tell < scriptBegin do
        unks[nPtrs] = script:readU32()
        ptrs[nPtrs] = script:readU32()
        tell = tonumber(script:rTell())
        nPtrs = nPtrs + 1
    end
    -- Sentinel terminator so the last ptr's end is well-defined.
    ptrs[nPtrs] = script:size() - scriptBegin
    nPtrs = nPtrs - 1

    local ptrsContents = {}
    for i = 1, nPtrs do
        ptrsContents[i] = ''
        script:rSeek(scriptBegin + ptrs[i])
        local endPos = scriptBegin + ptrs[i + 1]
        while tonumber(script:rTell()) ~= endPos do
            local r, rr = extractChar(script, lookup, style)
            if r then
                ptrsContents[i] = ptrsContents[i] .. r
            elseif tonumber(script:rTell()) ~= endPos then
                ptrsContents[i] = ptrsContents[i] .. '<ZERO>'
            end
        end
    end

    if VP.arguments.dump then
        local o = Support.File.open(fname .. '-script.txt', 'TRUNCATE')
        for i = 1, nPtrs do
            o:write('<ptr ' .. i .. ' - ' .. (unks[i] or 0) .. '>\n')
            o:write(ptrsContents[i])
            o:write('\n')
        end
        o:close()
    end

    return ptrsContents
end
