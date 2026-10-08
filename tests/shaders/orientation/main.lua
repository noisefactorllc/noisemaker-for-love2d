local root = love.filesystem.getSource() .. '/../../..'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
local adapter = require('noisemaker.shaders.adapter')

local function run()
  local width, height = 257, 129
  local source = [[#version 300 es
in vec2 v_texCoord;
out vec4 fragColor;
void main(){fragColor=vec4(v_texCoord.x,v_texCoord.y,gl_FragCoord.y/129.0,1.0);}
]]
  local copy = [[#version 300 es
in vec2 v_texCoord;
uniform sampler2D inputTex;
out vec4 fragColor;
void main(){fragColor=texture(inputTex,v_texCoord);}
]]
  local a = assert(adapter.adapt{pixel=source})
  local b = assert(adapter.adapt{pixel=copy})
  local gradientShader = love.graphics.newShader(a.pixel,a.vertex)
  local copyShader = love.graphics.newShader(b.pixel,b.vertex)
  local mesh = love.graphics.newMesh({
    {0,0,0,0},{2*width,0,2,0},{0,2*height,0,2},
  }, 'triangles', 'static')
  local first = love.graphics.newCanvas(width,height,{format='rgba16f',dpiscale=1})
  local second = love.graphics.newCanvas(width,height,{format='rgba16f',dpiscale=1})
  love.graphics.push('all')
  love.graphics.setBlendMode('replace','premultiplied')
  love.graphics.setColor(1,1,1,1)
  love.graphics.setCanvas(first)
  love.graphics.setShader(gradientShader)
  love.graphics.draw(mesh)
  love.graphics.setCanvas(second)
  love.graphics.setShader(copyShader)
  copyShader:send('inputTex', first)
  love.graphics.draw(mesh)
  love.graphics.pop()
  local firstData, secondData = first:newImageData(), second:newImageData()
  local function near(actual, expected) return math.abs(actual-expected)<0.002 end
  local top={firstData:getPixel(0,0)}
  local bottom={firstData:getPixel(0,height-1)}
  assert(near(top[1],0.5/width) and near(top[2],0.5/height) and near(top[3],0.5/height),string.format('raw top %.6f %.6f %.6f',top[1],top[2],top[3]))
  assert(near(bottom[1],0.5/width) and near(bottom[2],(height-0.5)/height) and near(bottom[3],(height-0.5)/height),string.format('raw bottom %.6f %.6f %.6f',bottom[1],bottom[2],bottom[3]))
  for y=0,height-1 do
    for x=0,width-1 do
      local ar,ag,ab,aa=firstData:getPixel(x,y)
      local br,bg,bb,ba=secondData:getPixel(x,y)
      assert(ar==br and ag==bg and ab==bb and aa==ba,string.format('sampled copy differs at %d,%d: %.8f %.8f %.8f / %.8f %.8f %.8f',x,y,ar,ag,ab,br,bg,bb))
    end
  end
  print(string.format('ORIENTATION-PIXELS raw top %.6f %.6f %.6f; bottom %.6f %.6f %.6f; sampled copy identical %dx%d',top[1],top[2],top[3],bottom[1],bottom[2],bottom[3],width,height))
  firstData:release();secondData:release();first:release();second:release()
  mesh:release();gradientShader:release();copyShader:release()
end
function love.load()
  local ok,err=xpcall(run,debug.traceback)
  if not ok then io.stderr:write(tostring(err)..'\n') end
  os.exit(ok and 0 or 1)
end
