function split(str, delimiter)
    local result = {}
    for match in (str .. delimiter):gmatch('(.-)' .. delimiter) do
        table.insert(result, match)
    end
    return result
end

function mkdir(path)
    if not VP.arguments.dump then return end
    local fragments = split(path, '/')
    local subpath = ''
    for _, fragment in pairs(fragments) do
        subpath = subpath .. fragment
        lfs.mkdir(subpath)
        subpath = subpath .. '/'
    end
end

function dumpFile(from, to)
    if not VP.arguments.dump then return end
    if type(from) == 'table' and from._type == 'File' then
        local data = from:readAt(from:size(), 0)
        to:writeAt(data, 0)
    else
        to:writeAt(from, 0)
    end
end

function deepCopy(object)
    if type(object) == 'table' then
        local copy = {}
        for k, v in pairs(object) do
            copy[k] = deepCopy(v)
        end
        return copy
    end

    return object
end

local base64lut = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function decodeBase64(data)
    data = string.gsub(data, '[^' .. base64lut .. '=]', '')
    return (data:gsub('.', function(x)
        if (x == '=') then return '' end
        local r, f='', (base64lut:find(x) - 1)
        for i = 6, 1, -1 do r = r..(f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0') end
        return r
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if (#x ~= 8) then return '' end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == '1' and 2 ^ (8 - i) or 0) end
        return string.char(c)
    end))
end
