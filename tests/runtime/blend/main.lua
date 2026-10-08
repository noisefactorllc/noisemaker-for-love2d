local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local renderer=require('noisemaker.runtime.renderer')
local function shader(color)
 return {glsl=string.format('out vec4 fragColor; void main(){fragColor=vec4(%.9f,%.9f,%.9f,%.9f);}',color[1],color[2],color[3],color[4])}
end
local function runCase(blend,expected,label)
 local graph={passes={
  {id='base',program='base',inputs={},outputs={color='local0'},uniforms={}},
  {id='over',program='over',inputs={},outputs={color='local0'},uniforms={},blend=blend},
  {id='copy',program='copy',inputs={sourceTex='local0'},outputs={color='global_o0'},uniforms={}},
 },programs={base=shader{.2,.3,.4,.25},over=shader{.5,.1,.2,.4},copy={glsl='in vec2 v_texCoord; uniform sampler2D sourceTex; out vec4 fragColor; void main(){fragColor=texture(sourceTex,v_texCoord);}'}},textures={local0={width='screen',height='screen',format='rgba16f'}},allocations={},renderSurface='o0'}
 local instance,diagnostics=renderer.new(graph,{width=17,height=9})
 assert(instance,diagnostics and diagnostics[1].message)
 local output,errors=instance:render{}
 assert(output,errors and errors[1].message)
 local data=output:newImageData()
 local observed={data:getPixel(0,0)}
 for i=1,4 do assert(math.abs(observed[i]-expected[i])<.002,string.format('%s channel%d %.6f expected %.6f',label,i,observed[i],expected[i])) end
 data:release();instance:release()
end
local function runOverlappingPoints()
 local graph={passes={
  {id='base',program='base',inputs={},outputs={color='local0'},uniforms={}},
  {id='points',program='points',drawMode='points',count=2,inputs={},outputs={color='local0'},uniforms={},blend=true},
  {id='copy',program='copy',inputs={sourceTex='local0'},outputs={color='global_o0'},uniforms={}},
 },programs={
  base=shader{.1,0,0,.1},
  points={vertex='out vec4 vColor; void main(){gl_PointSize=3.0;gl_Position=vec4(0,0,0,1);vColor=vec4(.25,0,0,.2);}',fragment='in vec4 vColor;out vec4 fragColor;void main(){fragColor=vColor;}'},
  copy={glsl='in vec2 v_texCoord;uniform sampler2D sourceTex;out vec4 fragColor;void main(){fragColor=texture(sourceTex,v_texCoord);}'},
 },textures={local0={width='screen',height='screen',format='rgba16f'}},allocations={},renderSurface='o0'}
 local instance,diagnostics=renderer.new(graph,{width=17,height=9});assert(instance,diagnostics and diagnostics[1].message)
 local output,errors=instance:render{};assert(output,errors and errors[1].message)
 local data=output:newImageData();local r,g,b,a=data:getPixel(8,4)
 assert(math.abs(r-.6)<.002 and math.abs(a-.5)<.002,string.format('overlap %.6f %.6f',r,a))
 data:release();instance:release()
end
local function runMRT()
 local base={glsl='layout(location=0) out vec4 a;layout(location=1) out vec4 b;void main(){a=vec4(.1,.2,.3,.1);b=vec4(.2,.3,.4,.2);}'}
 local over={glsl='layout(location=0) out vec4 a;layout(location=1) out vec4 b;void main(){a=vec4(.2,.1,.1,.2);b=vec4(.1,.2,.1,.3);}'}
 local copy={glsl='in vec2 v_texCoord;uniform sampler2D sourceTex;out vec4 fragColor;void main(){fragColor=texture(sourceTex,v_texCoord);}'}
 local graph={passes={
  {id='base',program='base',inputs={},outputs={a='localA',b='localB'},uniforms={}},
  {id='over',program='over',inputs={},outputs={a='localA',b='localB'},uniforms={},blend=true},
  {id='copy',program='copy',inputs={sourceTex='localB'},outputs={color='global_o0'},uniforms={}},
 },programs={base=base,over=over,copy=copy},textures={localA={width='screen',height='screen',format='rgba16f'},localB={width='screen',height='screen',format='rgba16f'}},allocations={},renderSurface='o0'}
 local instance,diagnostics=renderer.new(graph,{width=17,height=9});assert(instance,diagnostics and diagnostics[1].message)
 local output,errors=instance:render{};assert(output,errors and errors[1].message)
 local data=output:newImageData();local r,g,b,a=data:getPixel(0,0)
 assert(math.abs(r-.3)<.002 and math.abs(g-.5)<.002 and math.abs(b-.5)<.002 and math.abs(a-.5)<.002,string.format('MRT blend %.6f %.6f %.6f %.6f',r,g,b,a))
 data:release();instance:release()
end
local function runAllocationFailure()
 local graph={passes={
  {id='base',program='base',inputs={},outputs={color='global_o0'},uniforms={}},
  {id='over',program='over',inputs={},outputs={color='global_o0'},uniforms={},blend=true},
 },programs={base=shader{.2,.3,.4,.25},over=shader{.5,.1,.2,.4}},textures={},allocations={},renderSurface='o0'}
 local instance,diagnostics=renderer.new(graph,{width=17,height=9});assert(instance,diagnostics and diagnostics[1].message)
 local g=love.graphics
 local oldNewCanvas=g.newCanvas
 local calls,first=0,nil
 g.newCanvas=function(...)
  calls=calls+1
  if calls==2 then error('injected second scratch allocation failure') end
  local canvas=oldNewCanvas(...)
  if calls==1 then first=canvas end
  return canvas
 end
 local output,errors=instance:render{}
 g.newCanvas=oldNewCanvas
 assert(not output and errors and errors[1].message:find('injected second scratch allocation failure',1,true))
 assert(first and (function() for _,resource in ipairs(instance.resources.owned) do if resource==first then return true end end end)(),'first scratch must be tracked despite second allocation failure')
 instance:release()
 local stillLive=pcall(first.getDimensions,first)
 assert(not stillLive,'first scratch must be released with renderer')
end
local function run()
 runCase(true,{.7,.4,.6,.65},'ONE ONE')
 runCase({'ONE','ONE'},{.7,.4,.6,.65},'ONE ONE array')
 runCase({'ONE','ONE_MINUS_SRC_ALPHA'},{.62,.28,.44,.55},'ONE ONE_MINUS_SRC_ALPHA')
 runCase({'SRC_ALPHA','ONE_MINUS_SRC_ALPHA'},{.32,.22,.32,.31},'SRC_ALPHA ONE_MINUS_SRC_ALPHA')
 runOverlappingPoints()
 runMRT()
 runAllocationFailure()
 print('BLEND-PIXELS WebGL RGB and alpha factors match for all authored blend modes')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
