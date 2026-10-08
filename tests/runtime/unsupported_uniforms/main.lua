local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local renderer=require('noisemaker.runtime.renderer')
local function graph(kind,referenced)
 local source='uniform '..kind..' value;out vec4 fragColor;void main(){fragColor=vec4('..(referenced and (kind=='uint' and 'float(value)' or 'float(value.x)') or '0.25')..',0.0,0.0,1.0);}'
 return {passes={{id='p',program='p',inputs={},outputs={color='global_o0'},uniforms={value={2,3}}}},programs={p={glsl=source}},textures={},allocations={},renderSurface='o0'}
end
local function run()
 local g=love.graphics
 local host=g.newCanvas(7,9);g.setCanvas(host);g.setColor(.2,.3,.4,.5)
 for _,kind in ipairs({'ivec2','uvec2','uint'}) do
  local r,diagnostics=renderer.new(graph(kind,true),{width=17,height=9})
  assert(not r and diagnostics and diagnostics[1].stage=='capability' and diagnostics[1].code=='ERR_UNIFORM_TYPE',kind..' should report unsupported active uniform')
  assert(g.getCanvas()==host and math.abs(select(1,g.getColor())-.2)<.001,'state restored on '..kind..' failure')
  local inactive,errors=renderer.new(graph(kind,false),{width=17,height=9})
  assert(inactive,errors and errors[1].message);assert(inactive:render{});inactive:release()
 end
 g.setCanvas();host:release()
 print('UNIFORM-CAPABILITY active ivec/uvec/uint rejected and optimized-out declarations accepted; host state restored')
end
function love.load()local ok,err=xpcall(run,debug.traceback);love.graphics.setCanvas();if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
