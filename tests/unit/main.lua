local source = love.filesystem.getSource()
local root = source .. '/../..'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
local ok, err = xpcall(function()
  assert(jit and jit.version, 'CPU checks require LuaJIT')
  dofile(root .. '/tests/capabilities.lua')
  dofile(root .. '/tests/catalog.lua')
  dofile(root .. '/tests/runtime/cpu.lua')
end, debug.traceback)
if not ok then io.stderr:write(tostring(err) .. '\n') end
os.exit(ok and 0 or 1)
