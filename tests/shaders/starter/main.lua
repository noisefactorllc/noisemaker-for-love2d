local root = love.filesystem.getSource() .. '/../../..'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path

local function run()
  local nm = require('noisemaker')
  local effect = {
    name='StarterProbe', namespace='user', func='starterGpuProbe', starter=true,
    passes={{program='main', inputs={}, outputs={fragColor='outputTex'}}},
    shaders={main={glsl=[[
#version 300 es
precision highp float;
in vec2 v_texCoord;
out vec4 fragColor;
void main() { fragColor = vec4(v_texCoord.x, v_texCoord.y, 0.25, 1.0); }
]]}},
  }
  local registered, registrationErrors = nm.registerEffect(effect)
  assert(registered, registrationErrors and registrationErrors[1] and registrationErrors[1].message)
  local graph, compileErrors = nm.compile('search user\nstarterGpuProbe().write(o0)\nrender(o0)')
  assert(graph, compileErrors and compileErrors[1] and compileErrors[1].message)
  local renderer, prepareErrors = nm.newRenderer(graph, {width=9, height=7})
  assert(renderer, prepareErrors and prepareErrors[1] and prepareErrors[1].message)
  local frame, renderErrors = renderer:render({time=0})
  assert(frame, renderErrors and renderErrors[1] and renderErrors[1].message)
  local pixels = frame:newImageData()
  local function check(x, y)
    local actual = {pixels:getPixel(x, y)}
    local expected = {(x + 0.5) / 9, (6.5 - y) / 7, 0.25, 1}
    for channel=1,4 do
      assert(math.abs(actual[channel] - expected[channel]) < 0.003,
        string.format('starter=true pixel %d,%d channel %d: %.6f ~= %.6f', x, y, channel, actual[channel], expected[channel]))
    end
  end
  check(0, 0)
  check(8, 6)
  pixels:release()
  renderer:release()
  print('STARTER-PIXELS Portable starter=true compiles and renders both corners')
end

function love.load()
  local ok, error = xpcall(run, debug.traceback)
  if not ok then io.stderr:write(tostring(error) .. '\n') end
  love.event.quit(ok and 0 or 1)
end
