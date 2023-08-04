VP.globals.filemap = { }

--[[
local mapspans = {
    { idx_s = 3604, idx_e = 4732, data = { dir = 'GAME/ROOMS', ext = 'arm', ftype = 'arcroom', }, },
}

local mapspans = {
    { idx_s = 3721, idx_e = 4849, data = { dir = 'GAME/ROOMS', ext = 'arm', ftype = 'arcroom', }, },
}
]]--

local mapspans = {
    { idx_s =    9, idx_e =  131, data = { dir = 'SOUNDS/ATK+DEATH', ext = 'wag' }, },
    { idx_s =  132, idx_e =  365, data = { dir = 'SOUNDS/SUMMONS+NAMES', ext = 'wag' }, },
    { idx_s =  366, idx_e =  417, data = { dir = 'SOUNDS/FINISH', ext = 'wag' }, },
    { idx_s =  418, idx_e =  617, data = { dir = 'SOUNDS/ENDS', ext = 'wag' }, },
    { idx_s =  619, idx_e =  897, data = { dir = 'SOUNDS/FAILED+MAGICS', ext = 'wag' }, },
    { idx_s =  898, idx_e = 1020, data = { dir = 'SOUNDS/BOSS', ext = 'wag' }, },
    { idx_s = 1022, idx_e = 1525, data = { dir = 'GFX/FRIENDS+FOES', ext = 'agx', ftype = 'arcgfx' }, },
    { idx_s = 1526, idx_e = 1637, data = { dir = 'SOUNDS/COMBATTALKS', ext = 'wag' }, },
    { idx_s = 1639, idx_e = 1661, data = { dir = 'GFX/UNKNOWN01', ext = 'agx', ftype = 'arcgfx', }, },
    { idx_s = 1662, idx_e = 1687, data = { dir = 'SOUNDS/UNKNOWN01', ext = 'wag' }, },
    { idx_s = 1688, idx_e = 1698, data = { dir = 'GFX/UNKNOWN02', ext = 'agx', ftype = 'arcgfx', }, },
    { idx_s = 1700, idx_e = 1704, data = { dir = 'GFX/UNKNOWN03', ext = 'agx', ftype = 'arcgfx', }, },
    { idx_s = 1705, idx_e = 1805, data = { dir = 'SOUNDS/UNKNOWN02', ext = 'wag' }, },
    { idx_s = 1806, idx_e = 1810, data = { dir = 'GFX/UNKNOWN04', ext = 'agx', ftype = 'arcgfx', }, },
    { idx_s = 1811, idx_e = 1823, data = { dir = 'SOUNDS/MAGIC01', ext = 'wag' }, },
    { idx_s = 1826, idx_e = 1837, data = { dir = 'SOUNDS/MAGIC02', ext = 'wag' }, },
    { idx_s = 1840, idx_e = 1852, data = { dir = 'SOUNDS/MAGIC03', ext = 'wag' }, },
    { idx_s = 1855, idx_e = 1866, data = { dir = 'SOUNDS/MAGIC04', ext = 'wag' }, },
    { idx_s = 1869, idx_e = 1880, data = { dir = 'SOUNDS/MAGIC05', ext = 'wag' }, },
    { idx_s = 1883, idx_e = 1894, data = { dir = 'SOUNDS/MAGIC06', ext = 'wag' }, },
    { idx_s = 1897, idx_e = 1908, data = { dir = 'SOUNDS/MAGIC07', ext = 'wag' }, },
    { idx_s = 1911, idx_e = 1923, data = { dir = 'SOUNDS/MAGIC08', ext = 'wag' }, },
    { idx_s = 1926, idx_e = 1938, data = { dir = 'SOUNDS/MAGIC09', ext = 'wag' }, },
    { idx_s = 1941, idx_e = 1953, data = { dir = 'SOUNDS/MAGIC10', ext = 'wag' }, },
    { idx_s = 1956, idx_e = 1967, data = { dir = 'SOUNDS/MAGIC11', ext = 'wag' }, },
    { idx_s = 1970, idx_e = 1982, data = { dir = 'SOUNDS/MAGIC12', ext = 'wag' }, },
    { idx_s = 1985, idx_e = 1985, data = { dir = 'SOUNDS/MAGIC13', ext = 'wag' }, },
    { idx_s = 1988, idx_e = 2017, data = { dir = 'GFX/UNKNOWN05', ext = 'agx', ftype = 'arcgfx', }, },
    { idx_s = 2018, idx_e = 2095, data = { dir = 'SOUNDS/DEATHS', ext = 'wag' }, },
    { idx_s = 2096, idx_e = 2097, data = { dir = 'SOUNDS/UNKNOWN03', ext = 'wag', }, },
    { idx_s = 2098, idx_e = 2172, data = { dir = 'SOUNDS/VICTORY', ext = 'wag', }, },


    { idx_s = 2175, idx_e = 2186, data = { dir = 'MISC/MENUS', ext = 'sarc', ftype = 'arcroom', }, },

    { idx_s = 2187, idx_e = 2211, data = { dir = 'GFX/STATUSPIC' }, },
    { idx_s = 2296, idx_e = 2319, data = { dir = 'GFX/UNKNOWN06' }, },
    { idx_s = 3299, idx_e = 3505, data = { dir = 'GFX/FACE' }, },

    { idx_s = 3604, idx_e = 4732, data = { dir = 'GAME/ROOMS', ext = 'arm', ftype = 'arcroom', }, },

    { idx_s = 4766, idx_e = 4793, data = { dir = 'GFX/CDCHANGE', ext = 'tim' }, },
    { idx_s = 4808, idx_e = 4846, data = { dir = 'GFX/PORTRAITS', ext = 'tim' }, },
    { idx_s = 4847, idx_e = 4859, data = { dir = 'GFX/BGX', ext = 'tim' }, },
}

local handmap = {
    [   1] = { dir = 'MAIN/OVERLAY' },
    [   2] = { dir = 'MISC', ext = 'txt' },
    [   3] = { dir = 'MISC', ext = 'txt' },
    [   4] = { dir = 'MAIN/SOUNDS', ext = 'wag' },
    [   5] = { dir = 'MAIN/GFX' },
    [   6] = { dir = 'MAIN/MISC', ext = 'sarc', ftype = 'arcroom' },

    [ 618] = { dir = 'SOUNDS/MISC', ext = 'wag' },
    [1021] = { dir = 'SOUNDS/MISC', ext = 'wag' },

    -- main battle overlay
    [1490] = { dir = 'MAIN/OVERLAY'},

    [1824] = { dir = 'GFX/MAGIC01', ext = 'agx', ftype = 'arcgfx', },
    [1838] = { dir = 'GFX/MAGIC02', ext = 'agx', ftype = 'arcgfx', },
    [1853] = { dir = 'GFX/MAGIC03', ext = 'agx', ftype = 'arcgfx', },
    [1867] = { dir = 'GFX/MAGIC04', ext = 'agx', ftype = 'arcgfx', },
    [1881] = { dir = 'GFX/MAGIC05', ext = 'agx', ftype = 'arcgfx', },
    [1895] = { dir = 'GFX/MAGIC06', ext = 'agx', ftype = 'arcgfx', },
    [1909] = { dir = 'GFX/MAGIC07', ext = 'agx', ftype = 'arcgfx', },
    [1924] = { dir = 'GFX/MAGIC08', ext = 'agx', ftype = 'arcgfx', },
    [1939] = { dir = 'GFX/MAGIC09', ext = 'agx', ftype = 'arcgfx', },
    [1954] = { dir = 'GFX/MAGIC10', ext = 'agx', ftype = 'arcgfx', },
    [1968] = { dir = 'GFX/MAGIC11', ext = 'agx', ftype = 'arcgfx', },
    [1983] = { dir = 'GFX/MAGIC12', ext = 'agx', ftype = 'arcgfx', },
    [1986] = { dir = 'GFX/MAGIC13', ext = 'agx', ftype = 'arcgfx', },

    [2173] = { dir = 'MISC/GFX', ext = 'agx', ftype = 'arcgfx', },

    [2294] = { dir = 'MISC/SCRIPT', ext = 'script', ftype = 'cscript', },

    [4734] = { dir = 'MISC/SCRIPT', ext = 'sarc', ftype = 'arcroom', },

    [4797] = { dir = 'MISC/UNKNOWN', ext = 'carc', ftype = 'carc', },
    [4798] = { dir = 'MISC/UNKNOWN', ext = 'carc', ftype = 'carc', },
    [4799] = { dir = 'MISC/UNKNOWN', ext = 'carc', ftype = 'carc', },
    [4807] = { dir = 'MISC/UNKNOWN', ext = 'carc', ftype = 'carc', },

--
-- Videos
--

-- Intro
    [   8] = { dir = 'VIDEOS/MISC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
-- Magics
    [1825] = { dir = 'VIDEOS/MAGIC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [1839] = { dir = 'VIDEOS/MAGIC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [1854] = { dir = 'VIDEOS/MAGIC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [1868] = { dir = 'VIDEOS/MAGIC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [1882] = { dir = 'VIDEOS/MAGIC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [1896] = { dir = 'VIDEOS/MAGIC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [1910] = { dir = 'VIDEOS/MAGIC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [1940] = { dir = 'VIDEOS/MAGIC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [1955] = { dir = 'VIDEOS/MAGIC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [1969] = { dir = 'VIDEOS/MAGIC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [1984] = { dir = 'VIDEOS/MAGIC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [1987] = { dir = 'VIDEOS/MAGIC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
-- Small level videos
    [3507] = { dir = 'VIDEOS/LEVEL01', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3509] = { dir = 'VIDEOS/LEVEL02', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3510] = { dir = 'VIDEOS/LEVEL02', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3512] = { dir = 'VIDEOS/LEVEL03', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3515] = { dir = 'VIDEOS/LEVEL04', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3516] = { dir = 'VIDEOS/LEVEL04', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3518] = { dir = 'VIDEOS/LEVEL05', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3521] = { dir = 'VIDEOS/LEVEL06', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3523] = { dir = 'VIDEOS/LEVEL07', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3525] = { dir = 'VIDEOS/LEVEL08', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3526] = { dir = 'VIDEOS/LEVEL08', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3527] = { dir = 'VIDEOS/LEVEL08', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3528] = { dir = 'VIDEOS/LEVEL08', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3530] = { dir = 'VIDEOS/LEVEL09', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3531] = { dir = 'VIDEOS/LEVEL09', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3532] = { dir = 'VIDEOS/LEVEL09', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3534] = { dir = 'VIDEOS/LEVEL10', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3535] = { dir = 'VIDEOS/LEVEL10', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3536] = { dir = 'VIDEOS/LEVEL10', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3537] = { dir = 'VIDEOS/LEVEL10', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3538] = { dir = 'VIDEOS/LEVEL10', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3541] = { dir = 'VIDEOS/LEVEL11', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3544] = { dir = 'VIDEOS/LEVEL12', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3547] = { dir = 'VIDEOS/LEVEL13', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3550] = { dir = 'VIDEOS/LEVEL14', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3553] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3554] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3555] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3556] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3557] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3558] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3559] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3560] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3561] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3562] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3563] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3564] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3565] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3566] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3567] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3568] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3569] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3570] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3571] = { dir = 'VIDEOS/LEVEL15', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
-- Misc fullscreens
    [3574] = { dir = 'VIDEOS/MISC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3575] = { dir = 'VIDEOS/MISC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [3578] = { dir = 'VIDEOS/MISC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [4864] = { dir = 'VIDEOS/MISC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [4865] = { dir = 'VIDEOS/MISC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
    [4866] = { dir = 'VIDEOS/MISC', ext = 'str', mode = 'M2_RAW', sectorSize = 2336 },
}

function generateFileMap()
    for _, v in pairs(mapspans) do
        for i = v.idx_s, v.idx_e do
            VP.globals.filemap[i] = deepCopy(v.data)
            VP.globals.filemap[i].name = string.format('%04i', i)
            VP.globals.filemap[i].dir = 'DUMP/' .. VP.globals.filemap[i].dir
        end
    end

    for k, v in pairs(handmap) do
        VP.globals.filemap[k] = deepCopy(v)
        VP.globals.filemap[k].name = string.format('%04i', k)
        VP.globals.filemap[k].dir = 'DUMP/' .. v.dir
    end
end
