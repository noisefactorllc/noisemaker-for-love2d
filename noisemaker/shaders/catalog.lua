local manifest = require('noisemaker.shaders.source.manifest')
local M = {}
local location = debug.getinfo(1, 'S').source:sub(2)
local packageRoot = location:match('^(.*)/noisemaker/shaders/catalog%.lua$')
local function read(path)
  local contents
  if love and love.filesystem then contents = love.filesystem.read(path) end
  if not contents and packageRoot then
    local file = io.open(packageRoot .. '/' .. path, 'rb')
    if file then contents = file:read('*a'); file:close() end
  end
  return contents
end
function M.get(effect, program)
  local entry = manifest.programs[effect .. '/' .. program]
  if not entry then return nil, {code = 'ERR_SHADER_MISSING', effect = effect, program = program} end
  local result = {paths = {}, hashes = {}}
  for extension, file in pairs(entry.files) do
    local bytes = read(file.path)
    if not bytes then return nil, {code = 'ERR_SHADER_SOURCE_MISSING', path = file.path} end
    result[extension] = bytes
    result.paths[extension] = file.path
    result.hashes[extension] = file.sha256
  end
  result.vertex = result.vert
  result.fragment = result.frag or result.glsl
  result.pixel = result.fragment
  return result
end
M.manifest = manifest
return M
