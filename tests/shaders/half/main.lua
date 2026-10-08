local root = love.filesystem.getSource() .. '/../../..'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
local adapter = require('noisemaker.shaders.adapter')
local source = [[
#version 300 es
uniform vec2 inputPair;
out vec4 fragColor;
void main() {
  uint packed = packHalf2x16(inputPair);
  vec2 decoded = unpackHalf2x16(packed);
  uint roundtrip = packHalf2x16(decoded);
  fragColor = vec4(float(packed & 0xffffu), float(packed >> 16u), float(roundtrip & 0xffffu), float(roundtrip >> 16u));
}
]]
local cases = {
  {0.0, -1/math.huge, 0x0000, 0x8000, 'signed zero'},
  {1.0, -2.0, 0x3c00, 0xc000, 'normal'},
  {2^-14, 2^-24, 0x0400, 0x0001, 'normal/subnormal boundary'},
  {-2^-24, 2^-25, 0x8001, 0x0000, 'negative subnormal and tie to even zero'},
  {3 * 2^-25, 1023 * 2^-24, 0x0002, 0x03ff, 'subnormal ties and max subnormal'},
  {1 + 2^-11, 1 + 2^-11 + 2^-23, 0x3c00, 0x3c01, 'normal ties to even'},
  {65504, 70000, 0x7bff, 0x7c00, 'finite maximum and overflow'},
  {math.huge, -math.huge, 0x7c00, 0xfc00, 'infinities'},
}
local function run()
  local adapted, err = adapter.adapt{pixel=source, path='tests/shaders/half'}
  assert(adapted, err and err.detail)
  local shader = love.graphics.newShader(adapted.pixel, adapted.vertex)
  local canvas = love.graphics.newCanvas(1, 1, {format='rgba32f', dpiscale=1})
  local mesh = love.graphics.newMesh({{0,0,0,0},{1,0,1,0},{1,1,1,1},{0,0,0,0},{1,1,1,1},{0,1,0,1}},'triangles','static')
  love.graphics.push('all')
  love.graphics.setBlendMode('replace','premultiplied')
  love.graphics.setColor(1,1,1,1)
  for _, case in ipairs(cases) do
    shader:send('inputPair', {case[1],case[2]})
    love.graphics.setCanvas(canvas)
    love.graphics.setShader(shader)
    love.graphics.draw(mesh)
    love.graphics.setCanvas()
    local data = canvas:newImageData()
    local a,b,c,d = data:getPixel(0,0)
    assert(a == case[3] and b == case[4] and c == case[3] and d == case[4],
      string.format('%s: got %d,%d,%d,%d expected %d,%d',case[5],a,b,c,d,case[3],case[4]))
    data:release()
  end
  local allHalfSource = [[
#version 300 es
out vec4 fragColor;
void main() {
  uint bits = uint(floor(gl_FragCoord.x)) + 256u * uint(floor(gl_FragCoord.y));
  float decoded = unpackHalf2x16(bits).x;
  uint repacked = packHalf2x16(vec2(decoded, 0.0));
  fragColor = vec4(float(bits), float(repacked & 0xffffu), 0.0, 1.0);
}
]]
  local allAdapted = assert(adapter.adapt{pixel=allHalfSource, path='tests/shaders/half/all-patterns'})
  local allShader = love.graphics.newShader(allAdapted.pixel, allAdapted.vertex)
  local allCanvas = love.graphics.newCanvas(256, 256, {format='rgba32f',dpiscale=1})
  love.graphics.setCanvas(allCanvas)
  love.graphics.setShader(allShader)
  love.graphics.draw(mesh)
  love.graphics.setCanvas()
  local allData = allCanvas:newImageData()
  local checked = 0
  for y = 0, 255 do
    for x = 0, 255 do
      local bits, repacked = allData:getPixel(x,y)
      local exponent = math.floor(bits / 1024) % 32
      local mantissa = bits % 1024
      if exponent ~= 31 or mantissa == 0 then
        assert(bits == repacked, string.format('half pattern 0x%04x repacked to 0x%04x', bits, repacked))
        checked = checked + 1
      end
    end
  end
  assert(checked == 63490, 'wrong half-pattern denominator: ' .. checked)
  allData:release()
  allCanvas:release()
  allShader:release()
  love.graphics.pop()
  canvas:release()
  mesh:release()
  shader:release()
  print('HALF-PACK-VECTORS passed ' .. #cases .. ' float vectors and ' .. checked .. ' finite half patterns on ' .. select(4,love.graphics.getRendererInfo()))
end
function love.load()
  local ok, err = xpcall(run, debug.traceback)
  if not ok then io.stderr:write(tostring(err) .. '\n') end
  os.exit(ok and 0 or 1)
end
