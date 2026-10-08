local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local renderer=require('noisemaker.runtime.renderer')
local graphlib=require('noisemaker.runtime.graph')
local preflight=require('noisemaker.runtime.preflight')

local pixel='out vec4 fragColor;void main(){fragColor=vec4(.25,.5,.75,1.);}'
local mrt='layout(location=0) out vec4 a;layout(location=1) out vec4 b;void main(){a=vec4(1.);b=vec4(1.);}'
local function make(outputs,mode,textures,source)
  return {passes={{id='probe',program='probe',drawMode=mode,inputs={},outputs=outputs,uniforms={}}},
    programs={probe={glsl=source or pixel}},textures=textures or {},allocations={},renderSurface='o0'}
end
local function reject(value,code)
  local instance,diags=renderer.new(value,{width=8,height=8})
  assert(not instance,'preflight admitted '..code)
  assert(diags and diags[1].code==code,diags and diags[1].message or 'missing diagnostic')
end

local function run()
  local g=love.graphics
  local storage=make(nil,nil,nil,pixel)
  storage.passes[1].storageTextures={color='global_o0'}
  assert(graphlib.validate(storage))
  local instance,diags=renderer.new(storage,{width=8,height=8})
  assert(instance,diags and diags[1].message)
  local output,errors=instance:render{}
  assert(output,errors and errors[1].message)
  local data=output:newImageData()
  local r,gr,b,a=data:getPixel(0,0)
  assert(math.abs(r-.25)<.01 and math.abs(gr-.5)<.01 and math.abs(b-.75)<.01 and math.abs(a-1)<.01)
  data:release();instance:release()

  local max=g.getSystemLimits().multicanvas
  local outputs,textures={},{}
  for i=1,max+1 do
    local name=string.format('out%02d',i)
    outputs[name]=name
    textures[name]={width=8,height=8,format='rgba16f'}
  end
  reject(make(outputs,nil,textures,mrt),'ERR_MRT_LIMIT')
  reject(make({a='a',b='b'},nil,{a={width=8,height=8},b={width=7,height=8}},mrt),'ERR_MRT_DIMENSIONS')

  local host=g.newCanvas(4,4)
  g.setCanvas(host);g.setScissor(1,1,2,2);g.setColor(.2,.3,.4,.5)
  local original=g.setCanvas
  g.setCanvas=function(target,...)
    if type(target)=='table' and target.depth then error('injected depth bind failure') end
    return original(target,...)
  end
  local failed,diagnostics=renderer.new(make({color='global_o0'},'triangles'),{width=8,height=8})
  g.setCanvas=original
  assert(not failed and diagnostics and diagnostics[1].code=='ERR_DEPTH_ATTACHMENT')
  assert(g.getCanvas()==host and select(1,g.getScissor())==1 and math.abs(g.getColor()-.2)<.001,
    'host state changed after failed depth preflight')
  g.setCanvas();g.setScissor();host:release()

  local oldTypes=g.getTextureTypes
  g.getTextureTypes=function() return {} end
  local ok,diagnostic=pcall(preflight.check,
    {passes={{id='volume',program='p',inputs={},outputs={color='out'}}},textures={volume={is3D=true}}},
    {textures={out={getDimensions=function() return 8,8 end,getWidth=function() return 8 end,getHeight=function() return 8 end,getTextureType=function() return '2d' end}},surfaces={}},
    {['p:fullscreen']={uniforms={},adapted={}}})
  g.getTextureTypes=oldTypes
  assert(not ok and type(diagnostic)=='table' and diagnostic.code=='ERR_VOLUME_UNAVAILABLE')

  local oldInstanced=g.drawInstanced
  g.drawInstanced=nil
  local instanced,instancingError=pcall(preflight.check,
    {passes={{id='instanced',program='p',drawMode='billboards',inputs={},outputs={color='out'}}},textures={}},
    {textures={out={}},surfaces={}},
    {['p:billboards']={uniforms={},adapted={}}})
  g.drawInstanced=oldInstanced
  assert(not instanced and type(instancingError)=='table' and instancingError.code=='ERR_INSTANCING_UNAVAILABLE')

  local aliasCanvas=g.newCanvas(8,8)
  local aliasGraph=make({a='a',b='b'},nil,nil,mrt)
  local aliasOk,aliasError=pcall(preflight.check,aliasGraph,
    {textures={a=aliasCanvas,b=aliasCanvas},surfaces={}},
    {['probe:fullscreen']={uniforms={},adapted={}}})
  assert(not aliasOk and type(aliasError)=='table' and aliasError.code=='ERR_MRT_ALIAS')
  aliasCanvas:release()
  local blendGraph=make({color='out'})
  blendGraph.passes[1].blend={'ZERO','ONE'}
  local blendCanvas=g.newCanvas(8,8)
  local blendOk,blendError=pcall(preflight.check,blendGraph,
    {textures={out=blendCanvas},surfaces={}},
    {['probe:fullscreen']={uniforms={},adapted={}}})
  assert(not blendOk and type(blendError)=='table' and blendError.code=='ERR_BLEND_FACTOR')
  blendCanvas:release()
  print('preflight: storage-only pixels, MRT limits, state restoration, volume/instancing APIs, alias/blend refusal')
end

function love.load()
  local ok,err=xpcall(run,debug.traceback)
  if not ok then io.stderr:write(tostring(err),'\n') end
  love.event.quit(ok and 0 or 1)
end
