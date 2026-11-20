local M = {}
-- The directory part of a file path, or '.' for a bare name. Node passes Windows
-- paths with '\', so both separators count.
function M.parent(path) return path:match('^(.*)[/\\][^/\\]+$') or '.' end
return M
