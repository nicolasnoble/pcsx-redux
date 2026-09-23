-- Image viewers: TIM files, and raw pixel data with user-supplied geometry.
--
-- Both decode into an RGBA buffer and upload it as a GL texture, re-uploading
-- only when a knob changes. Sub-byte pixels are taken low bits first, as the
-- PlayStation GPU stores them.

VP.images = VP.images or {}

local MAX_DIM = 4096

-- 15-bit PlayStation colour to 0xAABBGGRR. 0x0000 is transparent, as the GPU
-- treats it when drawing textures.
local function psxColour(c)
    if c == 0 then return 0 end
    local r = bit.band(c, 0x1f)
    local g = bit.band(bit.rshift(c, 5), 0x1f)
    local b = bit.band(bit.rshift(c, 10), 0x1f)
    r = bit.bor(bit.lshift(r, 3), bit.rshift(r, 2))
    g = bit.bor(bit.lshift(g, 3), bit.rshift(g, 2))
    b = bit.bor(bit.lshift(b, 3), bit.rshift(b, 2))
    return bit.bor(0xff000000, bit.lshift(b, 16), bit.lshift(g, 8), r)
end

local function grey(v, max)
    local g = math.floor(v * 255 / max)
    return bit.bor(0xff000000, bit.lshift(g, 16), bit.lshift(g, 8), g)
end

-- A texture holder: upload(pix, w, h) replaces the content, draw(zoom) shows it.
local function newTexture()
    local t = {}
    function t:upload(pix, w, h)
        if not self.id then
            local id = ffi.new('GLuint[1]')
            gl.glGenTextures(1, id)
            self.id = id[0]
        end
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.id)
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST)
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST)
        gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 4)
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, w, h, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, pix)
        self.w, self.h = w, h
    end
    function t:draw(zoom)
        if self.id and self.w then imgui.Image(tonumber(self.id), self.w * zoom, self.h * zoom) end
    end
    return t
end

-- Reads `count` pixels of `bpp` bits starting at `offset` bits into `data`,
-- calling put(index, value).
local function readPixels(data, size, byteOffset, bpp, count, put)
    if bpp >= 8 then
        local step = bpp / 8
        for i = 0, count - 1 do
            local p = byteOffset + i * step
            if p + step > size then return end
            local v
            if bpp == 8 then
                v = data[p]
            elseif bpp == 16 then
                v = data[p] + data[p + 1] * 256
            else
                v = data[p] + data[p + 1] * 256 + data[p + 2] * 65536
            end
            put(i, v)
        end
    else
        local perByte = 8 / bpp
        local mask = bit.lshift(1, bpp) - 1
        for i = 0, count - 1 do
            local p = byteOffset + math.floor(i / perByte)
            if p >= size then return end
            local shift = (i % perByte) * bpp
            put(i, bit.band(bit.rshift(data[p], shift), mask))
        end
    end
end

local function readAll(file)
    local size = file:size()
    return file:readAt(size, 0), size
end

-- TIM parsing. Returns nil if the file is not structurally a TIM. A TIM whose
-- pixel block claims more bytes than the file holds is returned with
-- truncated = true.
local timBpp = { [0] = 4, [1] = 8, [2] = 16, [3] = 24 }

function VP.images.parseTim(file)
    local size = file:size()
    if size < 20 or file:readU32At(0) ~= 0x10 then return nil end
    local flags = file:readU32At(4)
    if bit.band(flags, bit.bnot(0xf)) ~= 0 then return nil end
    local tim = { bpp = timBpp[bit.band(flags, 3)], hasClut = bit.band(flags, 8) ~= 0, size = size }
    local off = 8
    if tim.hasClut then
        local len = file:readU32At(off)
        local w, h = file:readU16At(off + 8), file:readU16At(off + 10)
        if len ~= 12 + w * h * 2 or off + len > size then return nil end
        tim.clut = { x = file:readU16At(off + 4), y = file:readU16At(off + 6), w = w, h = h, offset = off + 12 }
        off = off + len
    end
    if off + 12 > size then return nil end
    local len = file:readU32At(off)
    local w, h = file:readU16At(off + 8), file:readU16At(off + 10)
    if w == 0 or h == 0 then return nil end
    local expected = 12 + w * h * 2
    if len ~= expected then
        -- The room backgrounds carry a pixel block length larger than their
        -- data, while w * h ends exactly at the end of the file. Accept that
        -- case and nothing looser.
        if off + expected ~= size then return nil end
        tim.badLength = len
    end
    tim.pix = { x = file:readU16At(off + 4), y = file:readU16At(off + 6), w = w, h = h, offset = off + 12 }
    tim.truncated = off + expected > size
    tim.width = math.floor(w * 16 / tim.bpp)
    tim.height = h
    if tim.clut and tim.bpp <= 8 then
        tim.paletteSize = tim.bpp == 4 and 16 or 256
        tim.palettes = math.max(1, math.floor(tim.clut.w * tim.clut.h / tim.paletteSize))
    end
    return tim
end

local function timInfo(tim)
    local lines = {
        string.format('%d bpp, %dx%d pixels, VRAM %d,%d', tim.bpp, tim.width, tim.height, tim.pix.x, tim.pix.y),
    }
    if tim.clut then
        lines[#lines + 1] = string.format('CLUT block %dx%d at VRAM %d,%d', tim.clut.w, tim.clut.h, tim.clut.x, tim.clut.y)
    end
    if tim.badLength then
        lines[#lines + 1] = string.format('Pixel block length field says %d, the pixels take %d.',
            tim.badLength, tim.pix.w * tim.pix.h * 2 + 12)
    end
    if tim.truncated then
        lines[#lines + 1] = string.format('Pixel block needs %d bytes, the file has %d.',
            tim.pix.w * tim.pix.h * 2 + 12, tim.size - tim.pix.offset + 12)
    end
    return table.concat(lines, '\n')
end

local function decodeTim(file, tim, palette)
    local data, size = readAll(file)
    local w, h = tim.width, tim.height
    local pix = ffi.new('uint32_t[?]', w * h)
    local lut
    if tim.paletteSize then
        lut = {}
        local base = tim.clut.offset + palette * tim.paletteSize * 2
        for i = 0, tim.paletteSize - 1 do
            local p = base + i * 2
            lut[i] = p + 1 < size and psxColour(data[p] + data[p + 1] * 256) or 0
        end
    end
    readPixels(data, size, tim.pix.offset, tim.bpp, w * h, function(i, v)
        if lut then
            pix[i] = lut[v] or 0
        elseif tim.bpp == 16 then
            pix[i] = psxColour(v)
        elseif tim.bpp == 24 then
            pix[i] = bit.bor(0xff000000, v)
        else
            pix[i] = grey(v, bit.lshift(1, tim.bpp) - 1)
        end
    end)
    return pix, w, h
end

-- Viewer for a structurally valid TIM.
function VP.images.timViewer(node, tim)
    local v = { name = 'TIM', palette = 0, zoom = 2, texture = newTexture() }
    function v.draw()
        imgui.TextUnformatted(timInfo(tim))
        if tim.truncated then return end
        local dirty = not v.uploaded
        if tim.palettes and tim.palettes > 1 then
            local changed, n = imgui.SliderInt('palette', v.palette, 0, tim.palettes - 1)
            if changed then v.palette, dirty = n, true end
        end
        local zc, z = imgui.SliderInt('zoom', v.zoom, 1, 8)
        if zc then v.zoom = z end
        if dirty then
            local ok, err = pcall(function()
                v.texture:upload(decodeTim(node.open(), tim, v.palette))
            end)
            v.err = not ok and tostring(err) or nil
            v.uploaded = true
        end
        if v.err then imgui.TextUnformatted('Error: ' .. v.err) end
        v.texture:draw(v.zoom)
    end
    return v
end

-- Viewer for arbitrary data with user geometry.
local rawBpps = { 1, 2, 4, 8, 16, 24 }

function VP.images.rawViewer(node)
    local v = { name = 'Raw image', bppIndex = 4, width = 256, height = 0, header = 0, zoom = 2, texture = newTexture() }
    function v.draw()
        local dirty = not v.uploaded
        for i, b in ipairs(rawBpps) do
            if i > 1 then imgui.SameLine() end
            if imgui.RadioButton(b .. ' bpp', v.bppIndex == i) then
                if v.bppIndex ~= i then v.bppIndex, dirty = i, true end
            end
        end
        imgui.PushItemWidth(200)
        local c, n
        c, n = imgui.InputInt('width', v.width, 1, 16)
        if c then v.width, dirty = math.max(1, math.min(MAX_DIM, n)), true end
        c, n = imgui.InputInt('height (0 = fit)', v.height, 1, 16)
        if c then v.height, dirty = math.max(0, math.min(MAX_DIM, n)), true end
        c, n = imgui.InputInt('header bytes', v.header, 1, 16)
        if c then v.header, dirty = math.max(0, n), true end
        c, n = imgui.SliderInt('zoom', v.zoom, 1, 8)
        if c then v.zoom = n end
        imgui.PopItemWidth()
        if dirty then
            local ok, err = pcall(function()
                local file = node.open()
                local data, size = readAll(file)
                local bpp = rawBpps[v.bppIndex]
                local w = v.width
                local available = math.max(0, size - v.header)
                local h = v.height
                if h == 0 then h = math.ceil(available * 8 / bpp / w) end
                h = math.max(1, math.min(MAX_DIM, h))
                local pix = ffi.new('uint32_t[?]', w * h)
                local max = bpp <= 8 and (bit.lshift(1, bpp) - 1) or nil
                readPixels(data, size, v.header, bpp, w * h, function(i, val)
                    if bpp == 16 then
                        pix[i] = bit.bor(0xff000000, psxColour(val))
                    elseif bpp == 24 then
                        pix[i] = bit.bor(0xff000000, val)
                    else
                        pix[i] = grey(val, max)
                    end
                end)
                v.texture:upload(pix, w, h)
                v.info = string.format('%dx%d, %d bytes after the header', w, h, available)
            end)
            v.err = not ok and tostring(err) or nil
            v.uploaded = true
        end
        if v.info then imgui.TextUnformatted(v.info) end
        if v.err then imgui.TextUnformatted('Error: ' .. v.err) end
        v.texture:draw(v.zoom)
    end
    return v
end
