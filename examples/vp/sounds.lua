-- Sound records: a small header, a 0x3C-byte descriptor, then raw SPU ADPCM.
--
--   u32 descriptor offset (0x1c, 0x20, 0x24 or 0x28)
--   u32 0x80000004
--   u32 descriptor offset - 8
--   ...  a few bytes of unknown purpose
--   descriptor: u32 descriptor size + ADPCM size, u32 ADPCM size at +0x1c
--   ADPCM data at descriptor offset + 0x3c
--
-- The .wag files, the SOUNDS/SFX entries and room archive tag 23 use it.

VP.sounds = VP.sounds or {}

local DESC = 0x3c

function VP.sounds.parse(file)
    local size = file:size()
    if size < 0x28 + DESC then return nil end
    local hdr = file:readU32At(0)
    if hdr ~= 0x1c and hdr ~= 0x20 and hdr ~= 0x24 and hdr ~= 0x28 then return nil end
    if file:readU32At(4) ~= 0x80000004 or file:readU32At(8) ~= hdr - 8 then return nil end
    local total = file:readU32At(hdr)
    local adpcm = file:readU32At(hdr + 0x1c)
    if total ~= adpcm + DESC or hdr + total > size then return nil end
    local snd = { hdr = hdr, adpcmOffset = hdr + DESC, adpcmSize = adpcm, size = size, desc = {} }
    for i = 0, DESC - 4, 4 do snd.desc[#snd.desc + 1] = file:readU32At(hdr + i) end
    -- Check the ADPCM frames: shift nibble 0..12, flags 0..7, and find the end flag.
    local frames, bad, endFrame = 0, 0, nil
    for off = snd.adpcmOffset, snd.adpcmOffset + adpcm - 16, 16 do
        local b0, b1 = file:readU8At(off), file:readU8At(off + 1)
        frames = frames + 1
        if bit.band(b0, 15) > 12 or b1 > 7 then bad = bad + 1 end
        if not endFrame and bit.band(b1, 1) ~= 0 then endFrame = frames end
    end
    snd.frames, snd.badFrames, snd.endFrame = frames, bad, endFrame
    return snd
end

-- The descriptor carries no field that is obviously a sample rate, so the
-- rate is a knob.
function VP.sounds.viewer(snd, openFile)
    local lines = {
        string.format('Sound record: descriptor at 0x%x, %d bytes of SPU ADPCM at 0x%x', snd.hdr, snd.adpcmSize, snd.adpcmOffset),
        string.format('%d frames (%d samples), %d malformed, end flag on frame %s',
            snd.frames, snd.frames * 28, snd.badFrames, tostring(snd.endFrame)),
        string.format('%d bytes after the ADPCM data', snd.size - snd.adpcmOffset - snd.adpcmSize),
        'Descriptor words:',
    }
    for i, w in ipairs(snd.desc) do lines[#lines + 1] = string.format('  +%02x  %08x', (i - 1) * 4, w) end
    local text = table.concat(lines, '\n')
    local v = { name = 'Sound', rate = 22050 }
    function v.draw()
        if PCSX.SPU and PCSX.SPU.playAudio then
            imgui.PushItemWidth(150)
            local changed, n = imgui.InputInt('sample rate', v.rate, 100, 1000)
            if changed then v.rate = math.max(1, math.min(176400, n)) end
            imgui.PopItemWidth()
            imgui.SameLine()
            if imgui.Button('Play') then
                if v.sound then v.sound:stop() end
                local ok, err = pcall(function()
                    local data = openFile():readAt(snd.adpcmSize, snd.adpcmOffset)
                    v.sound = PCSX.SPU.playAudio(data, { format = 'spu', rate = v.rate })
                end)
                v.err = not ok and tostring(err) or nil
            end
            imgui.SameLine()
            if imgui.Button('Stop') and v.sound then v.sound:stop() end
            if v.sound and v.sound:isPlaying() then
                imgui.SameLine()
                imgui.TextUnformatted('playing')
            end
            if v.err then imgui.TextUnformatted('Error: ' .. v.err) end
        end
        imgui.TextUnformatted(text)
    end
    return v
end

-- Dump handler for music entries: the SLZ sequence at +4 goes through the
-- normal SLZ path, the bank is written as is.
function process_bgm(file, fileInfo)
    local off = file:readU32At(0)
    local seq = deepCopy(fileInfo)
    seq.dir = fileInfo.dir .. '/' .. fileInfo.name
    seq.name = fileInfo.name .. '-seq'
    seq.ext = 'seq'
    processOneFile(file:subFile(4, off - 4), seq)
    local bank = deepCopy(seq)
    bank.name = fileInfo.name .. '-bank'
    bank.ext = 'bank'
    processOneFile(file:subFile(off, file:size() - off), bank)
end
