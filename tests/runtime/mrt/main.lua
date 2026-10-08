local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local renderer=require('noisemaker.runtime.renderer')
local function near(a,b)return math.abs(a-b)<.002 end
local source='layout(location=0) out vec4 a;layout(location=1) out vec4 b;void main(){a=vec4(1,0,0,.3);b=vec4(0,1,0,.7);}'
local function run()
 local graph={passes={{id='mrt',program='mrt',inputs={},outputs={a='global_o0',b='other'},uniforms={}}},programs={mrt={glsl=source}},textures={other={width='screen',height='screen',format='rgba16f'}},allocations={},renderSurface='o0'}
 local r,diagnostics=renderer.new(graph,{width=17,height=9});assert(r,diagnostics and diagnostics[1].message)
 local out,errors=r:render{};assert(out,errors and errors[1].message)
 local first=out:newImageData();local second=r.resources.textures.other:newImageData()
 local ar,ag,ab,aa=first:getPixel(0,0);local br,bg,bb,ba=second:getPixel(0,0)
 assert(near(ar,1) and near(ag,0) and near(aa,.3),string.format('MRT0 %.5f %.5f %.5f %.5f',ar,ag,ab,aa))
 assert(near(br,0) and near(bg,1) and near(ba,.7),string.format('MRT1 %.5f %.5f %.5f %.5f',br,bg,bb,ba))
 first:release();second:release();r:release()
 local max=love.graphics.getSystemLimits().multicanvas
 local outputs,textures={},{}
 for i=1,max+1 do local name=string.format('out%02d',i);outputs[name]=name;textures[name]={width='screen',height='screen',format='rgba16f'} end
 local tooMany={passes={{id='limit',program='mrt',inputs={},outputs=outputs,uniforms={}}},programs={mrt={glsl=source}},textures=textures,allocations={},renderSurface='o0'}
 local host=love.graphics.newCanvas(4,4)
 love.graphics.setCanvas(host);love.graphics.setScissor(1,1,2,2);love.graphics.setColor(.2,.3,.4,.5)
 local instance,problems=renderer.new(tooMany,{width=17,height=9})
 assert(not instance and problems and problems[1].code=='ERR_MRT_LIMIT',problems and problems[1].message)
 assert(love.graphics.getCanvas()==host and select(1,love.graphics.getScissor())==1 and near(love.graphics.getColor(),.2),'host state not restored after MRT preflight')
 love.graphics.setCanvas();love.graphics.setScissor();host:release()
 print('MRT-PIXELS two outputs preserve independent RGBA; over-limit preflight restores host state')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
