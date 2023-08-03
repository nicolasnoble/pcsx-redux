VP.globals.isos = {
    US = {},
    JP = {},
}

function probeIsoFile(file)
    local iso = PCSX.openIso(file)
    local reader = iso:createReader()
    local binUSCD1 = reader:open 'SLUS_011.56;1'
    local binUSCD2 = reader:open 'SLUS_011.79;1'
    local binJPCD1 = reader:open 'SLPM_863.79;1'
    local binJPCD2 = reader:open 'SLPM_863.80;1'
    local binSquished = reader:open 'VALKYRIE.EXE;1'

    if not binUSCD1:failed() then
        VP.globals.isos.US.CD1 = { iso = iso }
    elseif not binUSCD2:failed() then
        VP.globals.isos.US.CD2 = { iso = iso }
    elseif not binJPCD1:failed() then
        VP.globals.isos.JP.CD1 = { iso = iso }
    elseif not binJPCD2:failed() then
        VP.globals.isos.JP.CD2 = { iso = iso }
    elseif not binSquished:failed() then
        VP.globals.isos.US.CD1 = { iso = iso }
        VP.globals.isos.US.CD2 = { iso = iso }
    end
end
