local sourceRoot=love.filesystem.getSource():match('^(.*)/examples/viewer$')
if sourceRoot then package.path=sourceRoot..'/?.lua;'..sourceRoot..'/?/init.lua;'..package.path end
local viewer=require('examples.viewer.session')
local session
local program='search synth\nsolid(color: #ff9933).write(o0)\nrender(o0)'
local status=''
local droppedProgram=false
local elapsed,paused,parameters,selected=0,false,{},1
local registry=require('noisemaker.catalog.registry')
local function listParameters()
 parameters={};selected=1;local seen={}
 for _,pass in ipairs(session.renderer.graph.passes) do
  local definition=pass.effectKey and registry.getEffect(pass.effectKey)
  for _,name in ipairs(registry.keys(definition and definition.globals or {})) do
   local spec=definition.globals[name];local value=pass.uniforms and pass.uniforms[name];local id=tostring(pass.stepIndex)..':'..name
   if type(value)=='number' and not spec.choices and not seen[id] then
    parameters[#parameters+1]={step=pass.stepIndex,name=name,value=value,spec=spec};seen[id]=true
   end
  end
 end
end

local function reload()
  local source=droppedProgram and program or (love.filesystem.read('program.dsl') or program)
  local canvas,diagnostics=session:replace(source,{time=love.timer.getTime()})
  if canvas then listParameters() end
  status=canvas and 'F5 reload | Drop DSL | R reset | Space pause | [ ] parameter | +/- value' or (diagnostics and diagnostics[1] and diagnostics[1].message or 'Program failed')
end

function love.load()
  local width,height=love.graphics.getDimensions()
  session=viewer.new(width,height)
  reload()
  if os.getenv('NM_VIEWER_SMOKE')=='1' then
    assert(session.canvas);love.keypressed('r');love.keypressed('=');assert(session:resize(257,129));assert(session:render{time=.25});session:release();print('packaged viewer smoke passed');love.event.quit(0)
  end
end

function love.update(dt)
  if paused then return end
  elapsed=elapsed+dt
  if session.renderer then
    local _,diagnostics=session:render({time=elapsed})
    if diagnostics then status=diagnostics[1].message end
  end
end

function love.draw()
  if session.canvas then
    love.graphics.setColor(1,1,1,1)
    love.graphics.draw(session.canvas,0,0,0,love.graphics.getWidth()/session.canvas:getWidth(),love.graphics.getHeight()/session.canvas:getHeight())
  end
  love.graphics.setColor(0,0,0,.75)
  love.graphics.rectangle('fill',0,love.graphics.getHeight()-48,love.graphics.getWidth(),48)
  love.graphics.setColor(1,1,1,1)
  love.graphics.print(status,8,love.graphics.getHeight()-43)
  local param=parameters[selected]
  if param then love.graphics.print('Step '..param.step..' '..param.name..': '..string.format('%.5g',param.value),8,love.graphics.getHeight()-23) end
end

function love.keypressed(key)
  if key=='f5' then reload()
  elseif key=='space' then paused=not paused
  elseif key=='r' and session.renderer then session.renderer:reset();elapsed=0
  elseif (key=='[' or key==']') and #parameters>0 then selected=(selected-1+(key==']' and 1 or -1))%#parameters+1
  elseif (key=='=' or key=='+' or key=='-' or key=='kp+' or key=='kp-') and parameters[selected] then
    local param=parameters[selected];local spec=param.spec
    local step=spec.step or (spec.type=='int' and 1 or .01)
    local value=param.value+((key=='-' or key=='kp-') and -step or step)
    value=math.max(spec.min or -math.huge,math.min(spec.max or math.huge,value))
    local ok,diags=session.renderer:setParameter(param.step,param.name,value)
    if ok then param.value=value else status=diags[1].message end
  end
end

function love.resize(width,height)
  local ok,diagnostics=session:resize(width,height)
  if not ok then status=diagnostics[1].message end
end

function love.quit() if session then session:release() end end

function love.filedropped(file)
 local ok,err=file:open('r')
 if not ok then status=tostring(err);return end
 local source,readError=file:read();file:close()
 if not source then status=tostring(readError);return end
 local canvas,diags=session:replace(source,{time=elapsed})
 if canvas then program=source;droppedProgram=true;listParameters();status='Loaded '..file:getFilename() else status=diags[1].message end
end
