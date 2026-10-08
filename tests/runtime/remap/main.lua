local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local renderer=require('noisemaker.runtime.renderer')
local function run()
 local source=[[#version 300 es
layout(std140) uniform RemapUniforms { vec4 data[275]; };
out vec4 fragColor;
void main(){fragColor=vec4(data[0].x+data[2].x/100.0,data[0].y+data[2].y/100.0,data[0].z,data[0].w+data[1].x);}
]]
 local graph={passes={{id='packed',program='p',inputs={},outputs={color='global_o0'},uniforms={bgColor={.1,.2,.3},bgAlpha=.4,zoneCount=.5}}},programs={p={glsl=source,uniformLayout={bgColor={slot=0,components='xyz'},bgAlpha={slot=0,components='w'},zoneCount={slot=1,components='x'},resolution={slot=2,components='xy'}}}},textures={},allocations={},renderSurface='o0'}
 local instance,diagnostics=renderer.new(graph,{width=17,height=9})
 assert(instance,diagnostics and diagnostics[1].message)
 local out,errors=instance:render{}
 assert(out,errors and errors[1].message)
 local data=out:newImageData()
 local r,g,b,a=data:getPixel(0,0)
 local function near(actual,expected) return math.abs(actual-expected)<0.002 end
 assert(near(r,.27) and near(g,.29) and near(b,.3) and near(a,.9),string.format('packed %.6f %.6f %.6f %.6f',r,g,b,a))
 data:release()
 assert(instance:setParameter(0,'zoneCount',.25))
 out=assert(instance:render{})
 data=out:newImageData();r,g,b,a=data:getPixel(0,0)
 assert(near(a,.65),string.format('dynamic packed alpha %.6f',a))
 data:release();instance:release()
 print('REMAP-PACKING 275-slot rgba32f texture exact slot components, resolution alias, dynamic update')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
