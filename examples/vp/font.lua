function decodeFonts()
    for k, v in pairs(VP.constants.font) do
        v.data = decodeBase64(v.data)
    end
    for k, v in pairs(VP.constants.fontJP) do
        v.data = decodeBase64(v.data)
    end
end
