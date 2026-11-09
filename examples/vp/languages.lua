-- Target languages: the letters a translation into each one needs that the
-- retail font does not have. A translation database names its target language
-- (a BCP 47 tag, VP.tdb settings), and its charset is the retail font plus that
-- language's letters: the editor refuses any other character, and the in-game
-- preview appends only those letters to a room's font.
--
-- The letters' widths are advances like every retail glyph's: the bitmap plus
-- one blank column, the same as the letter an accent sits on. Sets are keyed
-- by primary language subtag, so fr-CA uses fr.

VP.languages = VP.languages or {}
local L = VP.languages

local fr = {}
fr['æ'] = { width = 10, height = 12, data = 'AAAAAAAAAAAAd4AIgH8AiICIAHcAAAAA' }
fr['à'] = { width = 6, height = 12, data = 'AAAAQAAgAAAAcAAIAHgAiACIAHgAAAAA' }
fr['â'] = { width = 6, height = 12, data = 'AAAAIABQAAAAcAAIAHgAiACIAHgAAAAA' }
fr['ç'] = { width = 6, height = 12, data = 'AAAAAAAAAAAAcACIAIAAgACIAHAAIABA' }
fr['è'] = { width = 6, height = 12, data = 'AAAAQAAgAAAAcACIAPgAgACIAHAAAAAA' }
fr['ê'] = { width = 6, height = 12, data = 'AAAAIABQAAAAcACIAPgAgACIAHAAAAAA' }
fr['é'] = { width = 6, height = 12, data = 'AAAAEAAgAAAAcACIAPgAgACIAHAAAAAA' }
fr['ë'] = { width = 6, height = 12, data = 'AAAAAABQAAAAcACIAPgAgACIAHAAAAAA' }
fr['î'] = { width = 3, height = 12, data = 'AAAAQACgAAAAQABAAEAAQABAAEAAAAAA' }
fr['ï'] = { width = 3, height = 12, data = 'AAAAAACgAAAAQABAAEAAQABAAEAAAAAA' }
fr['œ'] = { width = 10, height = 12, data = 'AAAAAAAAAAAAd4CIgI8AiICIAHcAAAAA' }
fr['ô'] = { width = 6, height = 12, data = 'AAAAIABQAAAAcACIAIgAiACIAHAAAAAA' }
fr['ù'] = { width = 6, height = 12, data = 'AAAAQAAgAAAAiACIAIgAiACYAGgAAAAA' }
fr['û'] = { width = 6, height = 12, data = 'AAAAIABQAAAAiACIAIgAiACYAGgAAAAA' }
fr['ü'] = { width = 6, height = 12, data = 'AAAAAABQAAAAiACIAIgAiACYAGgAAAAA' }

L.sets = {
    en = { name = 'English', letters = {} },
    fr = { name = 'French', letters = fr },
}

-- A well-formed BCP 47 tag, in the shape this tool needs: a 2-3 letter
-- language, then subtags of 1-8 letters or digits.
function L.valid(tag)
    if type(tag) ~= 'string' or not tag:match('^%a%a%a?$') and not tag:match('^%a%a%a?%-') then return false end
    for sub in tag:gmatch('[^-]+') do
        if #sub > 8 or sub:match('[^%w]') then return false end
    end
    return not tag:match('%-%-') and not tag:match('%-$')
end

function L.primary(tag) return (tostring(tag or ''):match('^(%a+)') or ''):lower() end

-- Display name of a tag, e.g. 'French (fr-CA)'.
function L.describe(tag)
    local set = L.sets[L.primary(tag)]
    return (set and set.name or 'no letter set') .. ' (' .. tostring(tag) .. ')'
end

-- The retail font is what font-database.lua holds; VP.constants.font becomes
-- the retail font plus every language's letters, which is what the glyph atlas
-- draws from.
VP.constants.retailFont = VP.constants.retailFont or VP.constants.font
local union = {}
for k, v in pairs(VP.constants.retailFont) do union[k] = v end
for _, set in pairs(L.sets) do
    for k, v in pairs(set.letters) do union[k] = v end
end
VP.constants.font = union

local cache = {}
-- Characters a translation into `tag` may use: the retail font plus the
-- letters of its language. A language with no set gets the retail font.
function L.charset(tag)
    local key = L.primary(tag)
    if cache[key] then return cache[key] end
    local cs = {}
    for k, v in pairs(VP.constants.retailFont) do cs[k] = v end
    local set = L.sets[key]
    for k, v in pairs(set and set.letters or {}) do cs[k] = v end
    cache[key] = cs
    return cs
end
