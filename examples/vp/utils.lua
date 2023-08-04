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
