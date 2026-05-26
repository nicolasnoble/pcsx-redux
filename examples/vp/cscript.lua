-- Handler for .cscript single-script containers. Unlike .arm/.sarc/.agx/.carc
-- (which are non-SLZ archives whose internal entries each get their own SLZ
-- handling), a .cscript file is itself the outer SLZ container. The outer
-- processOneFile decompresses the SLZ and calls this handler ONCE PER CHUNK:
-- chunk 1 = script, chunk 2 = font. We accumulate state keyed by the outer
-- file's dir (constant across the chunks of one cscript) and invoke the simple-
-- script extractor when both halves have arrived.
function process_cscript(file, fileInfo)
    if not VP.globals.cscriptStates then VP.globals.cscriptStates = {} end
    local key = fileInfo.dir
    local state = VP.globals.cscriptStates[key]
    if not state then
        state = { script = nil, font = nil }
        VP.globals.cscriptStates[key] = state
    end

    if not state.script then
        state.script = file:dup()
    elseif not state.font then
        state.font = file:dup()
    else
        error('Too many cscript chunks for ' .. key)
    end

    if state.script and state.font then
        extract_simple_script(fileInfo.dir, state.script, state.font, 'primary')
        state.script:close()
        state.font:close()
        VP.globals.cscriptStates[key] = nil
    end
end
