local root = love.filesystem.getSource() .. '/../../..'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
local adapter = require('noisemaker.shaders.adapter')

local function run()
  local source = 'out highp vec4 fragColor; void main(){fragColor=vec4(1.0,0.0,0.0,1.0);}'
  local program, diagnostic = adapter.adapt{pixel=source, path='test/precision-output'}
  assert(program, diagnostic and diagnostic.detail)
  local graphics = love.graphics
  local shader = graphics.newShader(program.pixel, program.vertex)
  local canvas = graphics.newCanvas(4, 4, {format='rgba8', dpiscale=1})
  local mesh = graphics.newMesh({{0,0,0,0},{8,0,2,0},{0,8,0,2}}, 'triangles', 'static')
  graphics.push('all')
  graphics.origin()
  graphics.setBlendMode('replace', 'premultiplied')
  graphics.setColor(1,1,1,1)
  graphics.setCanvas(canvas)
  graphics.clear(0,0,0,0)
  graphics.setShader(shader)
  graphics.draw(mesh)
  graphics.pop()
  local pixels = canvas:newImageData()
  local red, green, blue, alpha = pixels:getPixel(2,2)
  assert(red > .99 and green < .01 and blue < .01 and alpha > .99,
    string.format('Qualified fragment output rendered %.4f %.4f %.4f %.4f', red, green, blue, alpha))
  pixels:release(); mesh:release(); canvas:release(); shader:release()
  print('PRECISION-OUTPUT GPU pixel passed')
end

function love.load()
  local ok, err = xpcall(run, debug.traceback)
  if not ok then io.stderr:write(tostring(err), '\n') end
  love.event.quit(ok and 0 or 1)
end
