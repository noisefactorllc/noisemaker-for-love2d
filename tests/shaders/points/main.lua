local root = love.filesystem.getSource() .. '/../../..'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
local adapter = require('noisemaker.shaders.adapter')
local function run()
  local g=love.graphics
  local pixel = [[in vec4 vColor; out vec4 fragColor; void main(){fragColor=vColor;}]]
  local vertex = [[out vec4 vColor;
void main() {
  int id = gl_VertexID;
  gl_PointSize = id == 0 ? 1.0 : 7.0;
  float x = id == 0 ? 8.0 : 24.0;
  gl_Position = vec4(x / 16.0 - 1.0, 0.0, 0.0, 1.0);
  vColor = vec4(1.0);
}]]
  local adapted, err = adapter.adapt{pixel=pixel,vertex=vertex,drawMode='points'}
  assert(adapted, err and err.detail)
  assert(adapted.drawMode == 'point_quads')
  local fixed = assert(adapter.adapt{pixel=pixel,vertex=[[
    out vec4 vColor;
    void main(){int id=gl_VertexID;vColor=vec4(1.0);if(id<0){gl_PointSize=0.0;gl_Position=vec4(2.0);return;}gl_PointSize=1.0;gl_Position=vec4(0.0,0.0,0.0,1.0);}
  ]],drawMode='points'})
  assert(fixed.pointNativeSize==1 and fixed.drawMode~='point_quads','fixed positive point size must use native rasterization')
  assert(fixed.vertex:find('gl_VertexID',1,true),'native points must preserve hardware vertex IDs')
  assert(fixed.vertex:find('nmPointSize <= 0.0',1,true),'zero-size branches must be culled')
  local macro = assert(adapter.adapt{pixel=pixel,vertex=[[
    #if 0
    #define SET_SIZE gl_PointSize = 1.0
    #endif
    out vec4 vColor;
    void main(){gl_Position=vec4(0.0,0.0,0.0,1.0);gl_PointSize=1.0;vColor=vec4(1.0);}
  ]],drawMode='points'})
  assert(not macro.pointNativeSize and macro.drawMode=='point_quads','preprocessor point-size writes must decline fixed-size proof')
  local shader = love.graphics.newShader(adapted.pixel,adapted.vertex)
  local mesh = love.graphics.newMesh({
    {-0.5,-0.5,0,0}, {0.5,-0.5,1,0}, {0.5,0.5,1,1},
    {-0.5,-0.5,0,0}, {0.5,0.5,1,1}, {-0.5,0.5,0,1},
  },'triangles','static')
  local reference = love.graphics.newCanvas(32,32,{format='rgba8',dpiscale=1})
  local candidate = love.graphics.newCanvas(32,32,{format='rgba8',dpiscale=1})
  love.graphics.push('all')
  love.graphics.setBlendMode('replace','premultiplied')
  love.graphics.setColor(1,1,1,1)
  love.graphics.setCanvas(reference)
  love.graphics.clear(0,0,0,0)
  love.graphics.setPointSize(1)
  love.graphics.points(8,16)
  love.graphics.setPointSize(7)
  love.graphics.points(24,16)
  love.graphics.setCanvas(candidate)
  love.graphics.clear(0,0,0,0)
  love.graphics.setShader(shader)
  love.graphics.drawInstanced(mesh,2)
  love.graphics.setCanvas()
  local expected = reference:newImageData()
  local actual = candidate:newImageData()
  local difference, first = 0, nil
  for y=0,31 do for x=0,31 do
    local er,eg,eb,ea=expected:getPixel(x,y)
    local ar,ag,ab,aa=actual:getPixel(x,y)
    if math.abs(er-ar)>0.001 or math.abs(eg-ag)>0.001 or math.abs(eb-ab)>0.001 or math.abs(ea-aa)>0.001 then
      difference=difference+1
      if not first then first=string.format('%d,%d expected %.2f alpha %.2f got %.2f alpha %.2f',x,y,er,ea,ar,aa) end
    end
  end end
  love.graphics.pop()
  actual:release(); expected:release(); candidate:release(); reference:release(); shader:release()
  assert(difference==0, string.format('point quad differs at %d pixels; first %s',difference,first or 'none'))
  local coordPixel = [[out vec4 fragColor; void main(){fragColor=vec4(gl_PointCoord,0.0,1.0);}]]
  local coordVertex = [[void main(){gl_Position=vec4(0.0,0.0,0.0,1.0);gl_PointSize=7.0;}]]
  local coordAdapted = assert(adapter.adapt{pixel=coordPixel,vertex=coordVertex,drawMode='points'})
  assert(coordAdapted.pointNativeSize==7,'fixed point size must use native point rasterization')
  local coordShader = g.newShader(coordAdapted.pixel,coordAdapted.vertex)
  local pointMesh = g.newMesh({{0,0,0,0}},'points','static')
  local coordCanvas = g.newCanvas(32,32,{format='rgba8',dpiscale=1})
  g.push('all');g.setCanvas(coordCanvas);g.clear(0,0,0,0);g.setShader(coordShader);g.setBlendMode('replace','premultiplied');g.setPointSize(7);g.draw(pointMesh);g.setCanvas();g.pop()
  local coordData = coordCanvas:newImageData()
  local s,t,_,opacity=coordData:getPixel(15,16)
  assert(math.abs(s-3/7)<0.01 and math.abs(t-3/7)<0.01 and opacity>0.99,string.format('point coordinates must match source point square: %.4f %.4f %.4f',s,t,opacity))
  coordData:release();coordCanvas:release();coordShader:release()
  local clipped = assert(adapter.adapt{pixel=pixel,vertex=[[
    out vec4 vColor;
    void main(){gl_Position=vec4(1.05,0.0,0.0,1.0);gl_PointSize=7.0;vColor=vec4(1.0);}
  ]],drawMode='points'})
  local clippedShader = g.newShader(clipped.pixel,clipped.vertex)
  local clippedCanvas = g.newCanvas(32,32,{format='rgba8',dpiscale=1})
  g.push('all');g.setCanvas(clippedCanvas);g.clear(0,0,0,0);g.setShader(clippedShader);g.setBlendMode('replace','premultiplied');g.setPointSize(7);g.draw(pointMesh);g.setCanvas();g.pop()
  local clippedData=clippedCanvas:newImageData()
  assert(select(4,clippedData:getPixel(31,15))>0.99,'source point can extend into viewport from beyond clip center')
  assert(select(4,clippedData:getPixel(28,15))==0,'point edge must not extend beyond its source square')
  clippedData:release();clippedCanvas:release();clippedShader:release();pointMesh:release();mesh:release()
  local zeroSize = assert(adapter.adapt{pixel='out vec4 fragColor;void main(){fragColor=vec4(1.0);}',vertex=[[
    void main(){gl_Position=vec4(0.0,0.0,0.0,1.0);gl_PointSize=0.0;return;gl_PointSize=7.0;}
  ]],drawMode='points'})
  assert(zeroSize.pointNativeSize==7,'zero and fixed-positive writes should retain native points')
  local zeroShader=g.newShader(zeroSize.pixel,zeroSize.vertex)
  local zeroMesh=g.newMesh({{0,0,0,0}},'points','static')
  local zeroCanvas=g.newCanvas(1,1,{format='rgba8',dpiscale=1})
  g.push('all');g.setCanvas(zeroCanvas);g.clear(0,0,0,0);g.setShader(zeroShader);g.setPointSize(7);g.draw(zeroMesh);g.setCanvas();g.pop()
  local zeroData=zeroCanvas:newImageData()
  assert(select(4,zeroData:getPixel(0,0))==0,'zero-size source point must be clipped even on one-pixel targets')
  zeroData:release();zeroCanvas:release();zeroMesh:release();zeroShader:release()
  local helperMesh=g.newMesh({{0,0,0,0},{0,0,0,0}},'points','static')
  local helperFixed=assert(adapter.adapt{pixel=pixel,vertex=[[
    out vec4 vColor;
    void hidePoint(){gl_PointSize=0.0;}
    void showPoint(){gl_PointSize=7.0;}
    void main(){int id=gl_VertexID;if(id==0)hidePoint();else showPoint();
      gl_Position=vec4((id==0?8.0:24.0)/16.0-1.0,0.0,0.0,1.0);vColor=vec4(1.0);}
  ]],drawMode='points'})
  assert(helperFixed.pointNativeSize==7 and helperFixed.drawMode~='point_quads','helper writes with one positive size must use native points')
  local helperFixedShader=g.newShader(helperFixed.pixel,helperFixed.vertex)
  local helperCanvas=g.newCanvas(32,32,{format='rgba8',dpiscale=1})
  g.push('all');g.setCanvas(helperCanvas);g.clear(0,0,0,0);g.setShader(helperFixedShader);g.setBlendMode('replace','premultiplied');g.setPointSize(7);g.draw(helperMesh);g.setCanvas();g.pop()
  local helperData=helperCanvas:newImageData()
  assert(select(4,helperData:getPixel(8,16))==0 and select(4,helperData:getPixel(24,16))>0.99 and select(4,helperData:getPixel(21,16))>0.99,
    'helper point-size writes must preserve native zero and seven-pixel coverage')
  helperData:release();helperFixedShader:release()
  local helperDynamic=assert(adapter.adapt{pixel=pixel,vertex=[[
    out vec4 vColor;
    void setSize(int id){gl_PointSize=id==0?1.0:7.0;}
    void main(){int id=gl_VertexID;setSize(id);
      gl_Position=vec4((id==0?8.0:24.0)/16.0-1.0,0.0,0.0,1.0);vColor=vec4(1.0);}
  ]],drawMode='points'})
  assert(helperDynamic.drawMode=='point_quads','dynamic helper writes must use instanced quads')
  local helperDynamicShader=g.newShader(helperDynamic.pixel,helperDynamic.vertex)
  local helperQuad=g.newMesh({{-0.5,-0.5,0,0},{0.5,-0.5,1,0},{0.5,0.5,1,1},
    {-0.5,-0.5,0,0},{0.5,0.5,1,1},{-0.5,0.5,0,1}},'triangles','static')
  g.push('all');g.setCanvas(helperCanvas);g.clear(0,0,0,0);g.setShader(helperDynamicShader);g.setBlendMode('replace','premultiplied');g.drawInstanced(helperQuad,2);g.setCanvas();g.pop()
  helperData=helperCanvas:newImageData()
  local wide=select(4,helperData:getPixel(21,16))
  local firstCount,firstPixel=0,nil
  for y=0,31 do for x=0,15 do if select(4,helperData:getPixel(x,y))>0.5 then firstCount=firstCount+1;firstPixel=firstPixel or (x..','..y) end end end
  assert(firstCount==1 and firstPixel=='7,15' and wide>0.99,
    string.format('helper point-size writes must preserve instanced one- and seven-pixel coverage: first %d %s wide %.4f',firstCount,firstPixel or 'none',wide))
  helperData:release();helperDynamicShader:release()
  local helperCollision=assert(adapter.adapt{pixel=pixel,vertex=[[
    float nmPointSize=99.0;
    vec4 nmPointClip(vec4 center,float size,vec4 corner){return vec4(0.0);}
    out vec4 vColor;
    void setSize(int id){gl_PointSize=id==0?1.0:7.0;}
    void main(){int id=gl_VertexID;setSize(id);
      gl_Position=vec4((id==0?8.0:24.0)/16.0-1.0,0.0,0.0,1.0);vColor=vec4(1.0);}
  ]],drawMode='points'})
  assert(helperCollision.vertex:find('nmPointSize_1',1,true) and helperCollision.vertex:find('nmPointClip_1',1,true),
    'generated point helpers must avoid source identifiers')
  local collisionShader=g.newShader(helperCollision.pixel,helperCollision.vertex)
  local macroSize=assert(adapter.adapt{pixel='out vec4 fragColor;void main(){fragColor=vec4(1.0);}',vertex=[[
    #define SET_SIZE(v) gl_PointSize = (v)
    void main(){SET_SIZE(7.0);gl_Position=vec4(0.0,0.0,0.0,1.0);}
  ]],drawMode='points'})
  assert(macroSize.drawMode=='point_quads' and not macroSize.vertex:find('gl_PointSize',1,true),
    'preprocessor point-size writes must reach the instanced accumulator')
  local macroSizeShader=g.newShader(macroSize.pixel,macroSize.vertex)
  g.push('all');g.setCanvas(helperCanvas);g.clear(0,0,0,0);g.setShader(macroSizeShader);g.setBlendMode('replace','premultiplied');g.setPointSize(1);g.drawInstanced(helperQuad,1);g.setCanvas();g.pop()
  helperData=helperCanvas:newImageData()
  local macroPixels=0
  for y=0,31 do for x=0,31 do if select(4,helperData:getPixel(x,y))>0.5 then macroPixels=macroPixels+1 end end end
  assert(macroPixels==49,'macro point-size write must draw a seven-pixel square, got '..macroPixels)
  helperData:release();macroSizeShader:release()
  collisionShader:release();helperQuad:release();helperCanvas:release();helperMesh:release()
  print('POINT-RASTER-PIXELS variable and fixed point-size geometry passed')
end
function love.load()
  local ok, err = xpcall(run,debug.traceback)
  if not ok then io.stderr:write(tostring(err)..'\n') end
  os.exit(ok and 0 or 1)
end
