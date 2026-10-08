local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local renderer=require('noisemaker.runtime.renderer')
local function run(format)
 local graph={passes={
  {id='solid',program='solid',inputs={},outputs={color='local0'},uniforms={}},
  {id='copy',program='copy',inputs={sourceTex='local0'},outputs={color='global_o0'},uniforms={}},
 },programs={solid={glsl='out vec4 fragColor;void main(){fragColor=vec4(.25,.5,.75,.4);}'},copy={glsl='in vec2 v_texCoord;uniform sampler2D sourceTex;out vec4 fragColor;void main(){fragColor=texture(sourceTex,v_texCoord);}'}},textures={local0={width='screen',height='screen',format=format}},allocations={},renderSurface='o0'}
 local r,diagnostics=renderer.new(graph,{width=17,height=9});assert(r,diagnostics and diagnostics[1].message)
 local output,errors=r:render{};assert(output,errors and errors[1].message)
 local data=output:newImageData();local a,b,c,d=data:getPixel(0,0)
 assert(love.graphics.isGammaCorrect(),'fixture must exercise gamma-correct host mode')
 assert(math.abs(a-.25)<.002 and math.abs(b-.5)<.002 and math.abs(c-.75)<.002 and math.abs(d-.4)<.002,string.format('gamma %s %.6f %.6f %.6f %.6f',format,a,b,c,d))
 print(string.format('GAMMA %s %s %.8f %.8f %.8f %.8f',tostring(love.graphics.isGammaCorrect()),format,a,b,c,d))
 data:release();r:release()
end
local function upload()
 local graph={passes={{id='copy',program='copy',inputs={sourceTex='generated'},outputs={color='global_o0'},uniforms={}}},
  programs={copy={glsl='in vec2 v_texCoord;uniform sampler2D sourceTex;out vec4 fragColor;void main(){fragColor=texture(sourceTex,v_texCoord);}'}},textures={},allocations={},renderSurface='o0'}
 local r=assert(renderer.new(graph,{width=2,height=2}))
 for _,flip in ipairs({false,true})do
  r:_upload('generated',string.rep(string.char(64,128,192,102),4),2,2,'rgba8',flip)
  local output=assert(r:render{});local pixels=output:newImageData();local red,green,blue,alpha=pixels:getPixel(0,0)
  assert(math.abs(red-64/255)<.002 and math.abs(green-128/255)<.002 and math.abs(blue-192/255)<.002 and math.abs(alpha-102/255)<.002,'Internal generated pixels must not be sRGB-decoded by gamma-correct host mode')
  pixels:release()
 end
 r:release()
end
function love.load()local ok,err=xpcall(function()run('rgba16f');run('rgba8');upload()end,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
