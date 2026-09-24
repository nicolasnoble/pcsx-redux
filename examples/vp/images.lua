-- Image viewers for browser nodes: TIM files, and raw pixel data with
-- user-supplied geometry. The decoding lives in resources/fileviewers.lua,
-- which the GUI loads at startup and the ISO browser uses too; this only
-- adapts it to nodes, whose content is opened on demand.

VP.images = VP.images or {}

function VP.images.parseTim(file) return PCSX.FileViewers.parseTim(file) end

function VP.images.timViewer(node, tim) return PCSX.FileViewers.timViewer(node.open, tim) end

function VP.images.rawViewer(node) return PCSX.FileViewers.rawViewer(node.open) end
