local source = love.filesystem.getSource()
local root = source .. '/../..'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
local capabilities = require('noisemaker.runtime.capabilities')

local function sourceHashes()
  local files = {
    ['noisemaker/runtime/capabilities.lua'] = root .. '/noisemaker/runtime/capabilities.lua',
    ['parity/capabilities/main.lua'] = source .. '/main.lua',
    ['parity/capabilities/conf.lua'] = source .. '/conf.lua',
  }
  local hashes = {}
  for name, path in pairs(files) do
    local file, err = io.open(path, 'rb')
    if not file then error('source hash read ' .. name .. ': ' .. tostring(err)) end
    local bytes = file:read('*a')
    file:close()
    hashes[name] = love.data.encode('string', 'hex', love.data.hash('sha256', bytes))
  end
  return hashes
end

function love.load()
  local ok, report = pcall(capabilities.run, love)
  if not ok then
    report = {schema = 'noisemaker-love-capabilities-v1', ok = false, fatal = tostring(report)}
  end
  local hashOk, hashes = pcall(sourceHashes)
  if hashOk then report.sourceHashes = hashes
  else report.ok = false; report.sourceError = tostring(hashes) end
  local output = os.getenv('NM_CAPABILITIES_RESULT')
  if output and output ~= '' then
    local file, err = io.open(output, 'wb')
    if file then file:write('CAPABILITIES-RESULT ' .. capabilities.json(report), '\n'); file:close()
    else io.stderr:write('CAPABILITIES-OUTPUT-ERROR ' .. tostring(err) .. '\n'); report.ok = false; report.outputError = tostring(err) end
  end
  print('CAPABILITIES-RESULT ' .. capabilities.json(report))
  os.exit(report.ok and 0 or 1)
end
