local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local renderer=require('noisemaker.runtime.renderer')
local function graph(repeats,uniforms)
 return {passes={{id='repeat',program='solid',['repeat']=repeats,inputs={},outputs={fragColor='global_o0'},uniforms=uniforms or {}}},
  programs={solid={glsl='out vec4 fragColor;void main(){fragColor=vec4(1.0);}' }},textures={},allocations={},renderSurface='o0'}
end
local function run()
 for _,invalid in ipairs({math.huge,-math.huge,0/0}) do
  for _,named in ipairs({false,true}) do
   local instance,diagnostics=renderer.new(graph(named and 'loops' or invalid,named and {loops=invalid} or {}),{width=4,height=4})
   assert(instance,diagnostics and diagnostics[1].message)
   local calls=0
   instance._execute=function() calls=calls+1;if calls==2 then error('bounded repeat audit stop') end end
   local frame,errors=instance:render{}
   assert(not frame and errors and errors[1].code=='ERR_REPEAT_COUNT' and calls==0,
    'Nonfinite repeat must fail before any pass executes')
   if named then
    assert(instance:setParameter(0,'loops',3))
    instance._execute=function() calls=calls+1 end
    local recovered,recoveryErrors=instance:render{}
    assert(recovered and calls==3,recoveryErrors and recoveryErrors[1].message)
   end
   assert(instance:release())
  end
 end
 for _,case in ipairs({{3,{}},{'loops',{loops=3}}}) do
  local instance,diagnostics=renderer.new(graph(case[1],case[2]),{width=4,height=4})
  assert(instance,diagnostics and diagnostics[1].message)
  local calls=0
  instance._execute=function() calls=calls+1 end
  local frame,errors=instance:render{}
  assert(frame and calls==3,errors and errors[1].message)
  assert(instance:release())
 end
 print('REPEAT-COUNT rejects nonfinite numeric and uniform counts before execution; finite repeats retain behavior')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
