local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local renderer=require('noisemaker.runtime.renderer')
local values=require('noisemaker.compiler.values')
local function case(source,uniforms,expected,label)
 local graph={passes={{id='uniform',program='p',inputs={},outputs={color='global_o0'},uniforms=uniforms}},programs={p={glsl=source}},textures={},allocations={},renderSurface='o0'}
 local r,diagnostics=renderer.new(graph,{width=17,height=9});assert(r,diagnostics and diagnostics[1].message)
 local out,errors=r:render{};assert(out,errors and errors[1].message)
 local data=out:newImageData();local seen={data:getPixel(0,0)}
 for i=1,4 do assert(math.abs(seen[i]-expected[i])<.002,string.format('%s channel%d %.6f expected %.6f',label,i,seen[i],expected[i])) end
 data:release();r:release()
end
local function run()
 case('uniform vec3 color;out vec4 fragColor;void main(){fragColor=vec4(isnan(color.x)?1.0:0.0,isnan(color.y)?1.0:0.0,isnan(color.z)?1.0:0.0,1.0);}',{color='#000000'},{1,1,1,1},'nonnumeric string vec3 NaN')
 case('uniform vec3 color;out vec4 fragColor;void main(){fragColor=vec4(color,1.0);}',{color='0.25'},{.25,.25,.25,1},'numeric string scalar replicated')
 case('uniform vec4 tint;uniform float gain;uniform int mode;uniform bool enabled;out vec4 fragColor;void main(){fragColor=vec4(float(mode)/10.0,enabled?1.0:0.0,gain,tint.w);}',{tint=values.array{.1,.2,.3},gain='0.375',mode='2.9',enabled='false'},{.2,0,.375,1},'vec4 missing fourth and JS integer/bool coercion')
 print('UNIFORM-COERCION numeric/non-numeric strings, scalar vector replication, fourth default and int/bool')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
