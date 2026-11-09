-- Pairs the strings of a US room script with those of the JP room it was
-- translated from. Both are extract_room_script extras. The room logic opens
-- each string through a textbox opcode, and the US logic is the JP logic with
-- the text swapped, so the order in which the two logics open their strings
-- pairs them:
--
--   'same'   the logics open the same pointers in the same order and both
--            scripts have as many pointers: every string pairs by index.
--   'logic'  the logics open as many strings but not the same pointers: the
--            k-th opened US pointer pairs with the k-th opened JP one, if that
--            is one to one. Pointers no opcode opens stay unpaired.
--   'none'   the logics differ: nothing is paired.
--
-- Returns { how =, map = { [usPtr] = jpPtr } }.

VP.jpmatch = VP.jpmatch or {}

local function count(extra)
    local n, i = 0, extra.first
    while extra.tokens[i] do
        n = n + 1
        i = i + 1
    end
    return n
end

function VP.jpmatch.pair(us, jp)
    local ur, jr = us.textRefs or {}, jp.textRefs or {}
    local map = {}
    if #ur ~= #jr then return { how = 'none', map = map } end
    local same = count(us) == count(jp)
    for k = 1, #ur do
        if ur[k] ~= jr[k] then same = false end
    end
    if same then
        local i = us.first
        while us.tokens[i] do
            map[i] = i
            i = i + 1
        end
        return { how = 'same', map = map }
    end
    local back = {}
    for k = 1, #ur do
        local u, j = ur[k], jr[k]
        if (map[u] and map[u] ~= j) or (back[j] and back[j] ~= u) or not us.tokens[u] or not jp.tokens[j] then
            return { how = 'none', map = {} }
        end
        map[u], back[j] = j, u
    end
    return { how = 'logic', map = map }
end
