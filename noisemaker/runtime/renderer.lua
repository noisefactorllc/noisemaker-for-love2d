local graphlib=require('noisemaker.runtime.graph')
local values=require('noisemaker.compiler.values')
local adapter=require('noisemaker.shaders.adapter')
local executor=require('noisemaker.runtime.executor')
local inputlib=require('noisemaker.runtime.inputs')
local hooklib=require('noisemaker.runtime.hooks')
local resourceLib=require('noisemaker.runtime.resources')
local preflight=require('noisemaker.runtime.preflight')
local M={}
local Renderer={};Renderer.__index=Renderer
local unpack=unpack or table.unpack
local function keys(t) return graphlib.keys(t) end
local function actual(x) return x~=nil and x~=values.NULL and x~=values.UNDEFINED end
local function copy(t) local out={};for _,k in ipairs(keys(t or {})) do if k~='__nm_order' then out[k]=t[k] end end;return out end
local function global(id) return type(id)=='string' and id:match('^global_(.+)$') end
local function stateSurface(name) return name=='xyz' or name=='vel' or name=='rgba' or name=='trail' or name:match('_xyz$') or name:match('_vel$') or name:match('_rgba$') or name:match('_trail$') or name:find('state',1,true) or name:find('State',1,true) or name:match('^xyz_node_%d+$') or name:match('^vel_node_%d+$') or name:match('^rgba_node_%d+$') or name:match('^points_trail_node_%d+$') end
local function fail(code,message,fields) local d=fields or {};d.code=code;d.message=message;error(d,0) end
local function dispose(resources) for i=#resources,1,-1 do pcall(resources[i].release,resources[i]) end end
local function own(list,item) list[#list+1]=item;return item end
local function boundCanvases()
 local active=love.graphics.getCanvas();local result={}
 if type(active)=='userdata' then result[active]=true
 elseif type(active)=='table' then
  for _,item in pairs(active) do if type(item)=='userdata' then result[item]=true elseif type(item)=='table' and item[1] then result[item[1]]=true end end
 end
 return result
end
local function retirementSafe(resources,reused,bound)
 for _,resource in ipairs(resources.owned) do
  if bound[resource] and not (reused and reused[resource]) then
   return nil,{{stage='lifecycle',code='ERR_RESOURCE_IN_USE',message='Unbind the borrowed output Canvas before replacing or releasing it'}}
  end
 end
 return true
end
local function guard(stage,fn)
 local g=love.graphics
 g.push('all')
 local ok,result=xpcall(function()
  g.origin();g.setScissor();g.setShader();g.setCanvas();g.setColor(1,1,1,1);g.setColorMask(true,true,true,true)
  g.setBlendMode('replace','premultiplied');g.setDepthMode();g.setMeshCullMode('none');g.setWireframe(false);g.setPointSize(1)
  return fn()
 end,function(e) if type(e)=='table' then e.stage=e.stage or stage;return e end;return {stage=stage,code='ERR_RUNTIME',message=tostring(e)} end)
 local restored,restoreError=pcall(g.pop)
 if not restored then return nil,{{stage='state',code='ERR_STATE_RESTORE',message=tostring(restoreError)}} end
 if not ok then return nil,{result} end
 return result==nil and true or result
end
local function validSize(w,h)
 return type(w)=='number' and w==math.floor(w) and w>0 and type(h)=='number' and h==math.floor(h) and h>0
end
local function gatherUniforms(graph)
 local out={};for _,pass in ipairs(graph.passes) do for _,k in ipairs(keys(pass.uniforms)) do out[k]=pass.uniforms[k] end end;return out
end
function Renderer:_allocate(w,h,previous)
 return resourceLib.allocate(self.graph,w,h,self.uniforms,previous,self.texturePooling)
end
local function normalizedOutputs(pass)
 local out=values.object()
 if pass.storageTextures then for _,k in ipairs(keys(pass.storageTextures)) do values.set(out,k,pass.storageTextures[k]) end end
 if pass.outputs then
  if pass.storageTextures or pass.outputs.outputBuffer then out=values.object() end
  for _,k in ipairs(keys(pass.outputs)) do values.set(out,k=='outputBuffer' and 'color' or k,pass.outputs[k]) end
 end
 return out
end
function M.new(graph,options,hookOverrides)
 options=options or {}
 if not love or not love.graphics then return nil,{{stage='capability',code='ERR_LOVE_REQUIRED',message='LÖVE graphics context required'}} end
 if type(options)~='table' or not validSize(options.width,options.height) then return nil,{{stage='dimensions',code='ERR_DIMENSIONS',message='Positive integer width and height required'}} end
 local decoded,decodeResult=pcall(graphlib.decode,graph)
 if not decoded then return nil,{{stage='graph',code='ERR_GRAPH',message=tostring(decodeResult)}} end
 graph=decodeResult
 local checked,valid,diagnostics=pcall(graphlib.validate,graph)
 if not checked then return nil,{{stage='graph',code='ERR_GRAPH',message=tostring(valid)}} end
 if not valid then return nil,diagnostics end
 local clamped,clampError=pcall(resourceLib.clampGraphVolumes,graph,love.graphics.getSystemLimits().texturesize)
 if not clamped then return nil,{{stage='graph',code='ERR_GRAPH',message=tostring(clampError)}} end
 local firstTouch,writtenSurfaces,feedbackSurfaces={},{},{}
 for _,pass in ipairs(graph.passes) do
  for _,id in pairs(pass.inputs or {}) do local name=global(id);if name and not firstTouch[name] then firstTouch[name]='read' end end
  for _,id in pairs(normalizedOutputs(pass)) do
   local name=global(id)
   if name then
    if not firstTouch[name] then firstTouch[name]='write' end
    writtenSurfaces[name]=true
   end
  end
 end
 for name,touch in pairs(firstTouch) do if touch=='read' and writtenSurfaces[name] then feedbackSurfaces[name]=true end end
 local self=setmetatable({texturePooling=options.texturePooling==true,graph=graph,width=options.width,height=options.height,uniforms=gatherUniforms(graph),feedbackSurfaces=feedbackSurfaces,external={},externalSources={},owned={},programs={},meshes={},frameIndex=0,lastTime=0,released=false,provenance={},lastPassCount=0,uploads={},inputManager=inputlib.new({needsMidiNoteGrid=(function() for _,pass in ipairs(graph.passes) do if pass.inputs and pass.inputs.midiNoteGrid then return true end end;return false end)()})},Renderer)
 local result,errors=guard('prepare',function()
  for _,pass in ipairs(graph.passes) do
   local id=pass.program..':'..(pass.drawMode or 'fullscreen')
   if not self.programs[id] then
    local spec=copy(graph.programs[pass.program]);spec.drawMode=pass.drawMode;spec.outputs=keys(normalizedOutputs(pass))
    local adapted,diag=adapter.adapt(spec)
    if not adapted then diag.stage='shader';diag.program=pass.program;diag.message=diag.message or diag.detail;error(diag,0) end
    local ok,shader=pcall(love.graphics.newShader,adapted.pixel,adapted.vertex)
    if not ok then fail('ERR_SHADER_COMPILE',tostring(shader),{stage='shader',program=pass.program,provenance=adapted.provenance}) end
    own(self.owned,shader)
    for _,name in ipairs(keys(adapted.uniforms)) do
     local uniform=adapted.uniforms[name]
     local ty=uniform.type
     if (ty=='uint' or ty:match('^ivec[234]$') or ty:match('^uvec[234]$')) and shader:hasUniform(name) then
      fail('ERR_UNIFORM_TYPE','Active '..ty..' uniform '..name..' cannot be bound through the source WebGL2 uniform contract',{stage='capability',program=pass.program,uniform=name,uniformType=ty,provenance=adapted.provenance})
     end
    end
    self.programs[id]={shader=shader,uniforms=adapted.uniforms,adapted=adapted,spec=spec}
    self.provenance[id]=adapted.provenance
   end
  end
  self.resources=self:_allocate(self.width,self.height)
  preflight.check(self.graph,self.resources,self.programs)
  self.hooks=self:_makeHooks(self.width,self.height,self.uploads,hookOverrides)
  return self
 end)
 if not result then for _,entry in pairs(self.uploads) do entry.texture:release() end;if self.resources then dispose(self.resources.owned) end;dispose(self.owned);return nil,errors end
 return self
end
function Renderer:_alive() if self.released then return nil,{{stage='lifecycle',code='ERR_RELEASED',message='Renderer has been released'}} end;return true end
function Renderer:_input(id,reads)
 local uploaded=self.uploads[id] or self.uploads[id:gsub('_chain_%d+$','')]
 local texture=uploaded and uploaded.texture or self.external[id] or self.external[id:gsub('_chain_%d+$','')]
 if texture then return texture end
 local name=global(id)
 return name and reads[name] or self.resources.textures[id] or self.resources.textures.__black
end
local function flipInto(source,target,owner)
 local g=love.graphics
 g.setBlendMode('replace','premultiplied');g.setColor(1,1,1,1)
 if source:getTextureType()=='volume' then
  if not owner.volumeInputShader then
   owner.volumeInputShader=own(owner.owned,g.newShader([[#pragma language glsl3
uniform sampler3D sourceVolume;
uniform vec3 sourceSize;
uniform float sourceLayer;
vec4 effect(vec4 color,Image image,vec2 uv,vec2 pixel){return texture(sourceVolume,vec3(pixel.x/sourceSize.x,1.0-pixel.y/sourceSize.y,sourceLayer));}
]]))
  end
  local shader=owner.volumeInputShader
  g.setShader(shader);shader:send('sourceVolume',source);shader:send('sourceSize',{source:getWidth(),source:getHeight(),source:getDepth()})
  for layer=1,source:getDepth() do
   g.setCanvas({{target,layer=layer}});shader:send('sourceLayer',(layer-.5)/source:getDepth())
   g.rectangle('fill',0,0,source:getWidth(),source:getHeight())
  end
 else
  g.setCanvas(target);g.setShader();g.draw(source,0,source:getHeight(),0,1,-1)
 end
 g.setCanvas()
end
local function send(shader,name,value,spec)
 if not actual(value) or not shader:hasUniform(name) then return end
 local ty=spec and spec.type or ''
 if ty:find('sampler',1,true) or ty=='Image' then shader:send(name,value);return end
 if type(value)=='boolean' then if ty~='bool' then value=value and 1 or 0 end end
 if type(value)=='table' then
  local n=tonumber(ty:match('vec(%d)'))
  if n then local vector={};for i=1,n do vector[i]=value[i] or 0 end;shader:send(name,vector)
  elseif spec and spec.count>1 then shader:send(name,unpack(value))
  elseif ty:match('mat') then shader:send(name,'column',value)
  else return end
 elseif type(value)=='number' or type(value)=='boolean' or type(value)=='userdata' then shader:send(name,value) end
end
function Renderer:_mesh(w,h,count,drawMode)
 local instanced=drawMode=='billboards' or drawMode=='point_quads'
 local key=drawMode=='fullscreen' and ('full:'..w..':'..h) or ('geometry:'..drawMode)
 local previous=self.meshes[key]
 if previous and (drawMode=='fullscreen' or instanced or previous:getVertexCount()>=count) then
  if not instanced and drawMode~='fullscreen' then previous:setDrawRange(1,count) end
  return previous
 end
 local vertices,mode
 if drawMode=='fullscreen' then vertices={{0,0,0,0},{2*w,0,2,0},{0,2*h,0,2}};mode='triangles'
 elseif drawMode=='point_quads' then vertices={{-.5,-.5,0,0},{.5,-.5,1,0},{.5,.5,1,1},{-.5,-.5,0,0},{.5,.5,1,1},{-.5,.5,0,1}};mode='triangles'
 else
  local n=drawMode=='billboards' and 6 or count
  vertices={};for i=1,n do vertices[i]={0,0,0,0} end;mode=drawMode=='points' and 'points' or 'triangles'
 end
 local mesh=love.graphics.newMesh({{'VertexPosition','float',2},{'VertexTexCoord','float',2}},vertices,mode,'static')
 local ready,err=pcall(function() if not instanced and drawMode~='fullscreen' then mesh:setDrawRange(1,count) end end)
 if not ready then mesh:release();error(err,0) end
 own(self.owned,mesh);self.meshes[key]=mesh
 if previous then
  for i=#self.owned,1,-1 do if self.owned[i]==previous then table.remove(self.owned,i);break end end
  previous:release()
 end
 return mesh
end
function Renderer:_retireFullscreenMeshes()
 local retired={}
 for key,mesh in pairs(self.meshes) do
  if key:sub(1,5)=='full:' then retired[mesh]=true;self.meshes[key]=nil;mesh:release() end
 end
 local kept={}
 for _,resource in ipairs(self.owned) do if not retired[resource] then kept[#kept+1]=resource end end
 self.owned=kept
end
function Renderer:_resolved(pass,time,globals,external)
 local uniforms=copy(pass.uniforms)
 local automation=package.loaded['noisemaker.runtime.automation']
 if not automation then local ok,module=pcall(require,'noisemaker.runtime.automation');if ok then automation=module end end
 for _,name in ipairs(keys(pass.uniforms)) do
  local value=uniforms[name]
  if automation and automation.resolve then uniforms[name]=automation.resolve(value,time,pass.uniformSpecs and pass.uniformSpecs[name],external)
  elseif type(value)=='table' and not values.isArray(value) and (#value==0) then fail('ERR_AUTOMATION','Automation evaluator unavailable',{pass=pass.id,uniform=name}) end
 end
 return uniforms
end
local function skip(pass,uniforms,globals)
 local conditions=pass.conditions or {}
 for _,c in ipairs(conditions.skipIf or {}) do local value=uniforms[c.uniform];if not actual(value) then value=globals[c.uniform] end;if value==c.equals then return true end end
 for _,c in ipairs(conditions.runIf or {}) do local value=uniforms[c.uniform];if not actual(value) then value=globals[c.uniform] end;if value~=c.equals then return true end end
 return false
end
local function repeatCount(pass,uniforms,globals)
 local n=pass['repeat'];if type(n)=='string' then n=globals[n] or uniforms[n] end
 if type(n)=='number' and (n~=n or n==math.huge or n==-math.huge) then
  fail('ERR_REPEAT_COUNT','Nonfinite pass repeat count',{pass=pass.id})
 end
 return type(n)=='number' and math.max(1,math.floor(n)) or 1
end
function Renderer:_execute(pass,uniforms,globals,reads,writes)
 return executor.execute(self,pass,uniforms,globals,reads,writes)
end
function Renderer:render(frame)
 local alive,d=self:_alive();if not alive then return nil,d end
 frame=frame or {}
 return guard('render',function()
  for _,entry in pairs(self.externalSources) do if entry.converted then flipInto(entry.texture,entry.converted,self) end end
  local time=frame.time or 0;local delta=frame.deltaTime
  if delta==nil then delta=self.lastTime>0 and time-self.lastTime or 0;if delta<0 then delta=1/600 end end
  local globals=copy(self.uniforms)
  local inputUniforms,inputTextures,externalState=self.inputManager:update(frame)
  for name,spec in pairs(inputTextures) do globals[name]=self:_upload(name,spec.data,spec.width,spec.height,spec.format,false,self.uploads) end
  for name,value in pairs(inputUniforms) do globals[name]=value end
  local hookUniforms=self.hooks:update(time,delta)
  globals.time=time;globals.deltaTime=delta;globals.frame=frame.frame or self.frameIndex
  globals.resolution={self.width,self.height};globals.fullResolution={self.width,self.height};globals.tileOffset={0,0};globals.aspect=self.width/self.height;globals.aspectRatio=globals.aspect;globals.renderScale=1;globals.midiClockCount=frame.midiClockCount or inputUniforms.midiClockCount or 0
  for _,key in ipairs({'audioWaveform','audioSpectrum','midiNoteGrid'}) do if frame[key] then globals[key]=frame[key] end end
  local reads,writes={},{};for name,s in pairs(self.resources.surfaces) do reads[name]=s.read;writes[name]=s.write end
  local count=0
  for _,pass in ipairs(self.graph.passes) do
   local uniforms=self:_resolved(pass,time,globals,externalState)
   for name,value in pairs(hookUniforms[pass.effectKey] or hookUniforms[type(pass.effectKey)=='string' and pass.effectKey:gsub('%.','/') or ''] or {}) do if not actual(uniforms[name]) then uniforms[name]=value end end
   if not skip(pass,uniforms,globals) then
    local repeats=repeatCount(pass,uniforms,globals)
    for _=1,repeats do
     self:_execute(pass,uniforms,globals,reads,writes);count=count+1
     if repeats>1 then for _,id in ipairs((function()local out={};for _,k in ipairs(keys(pass.outputs))do out[#out+1]=pass.outputs[k]end;return out end)()) do local name=global(id);if name then local s=self.resources.surfaces[name];s.read,s.write=reads[name],writes[name] end end end
    end
   end
  end
  resourceLib.generateMipmaps(self.graph,self.resources)
  local output=reads[self.graph.renderSurface or 'o0']
  if not output then fail('ERR_RENDER_SURFACE','Graph has no render surface') end
  for name,s in pairs(self.resources.surfaces) do if stateSurface(name) or self.feedbackSurfaces[name] then s.read,s.write=reads[name],writes[name] else s.read,s.write=s.write,s.read end end
  local presented=self.resources.textures.__present
  love.graphics.setCanvas(presented);love.graphics.setShader();love.graphics.setDepthMode();love.graphics.setMeshCullMode('none');love.graphics.setBlendMode('replace','premultiplied')
  love.graphics.draw(output,0,self.height,0,self.width/output:getWidth(),-self.height/output:getHeight())
  love.graphics.setCanvas()
  self.lastTime=time;self.frameIndex=self.frameIndex+1;self.lastPassCount=count;self.output=presented;self.frameReadTextures=reads
  return presented
 end)
end
function Renderer:setInput(binding,texture,options)
 local alive,d=self:_alive();if not alive then return nil,d end
 if type(binding)~='string' or (texture~=nil and type(texture)~='userdata') then return nil,{{stage='input',code='ERR_INPUT',message='Expected a binding name and LÖVE Texture'}} end
 if texture then
  local usable,isTexture=pcall(function()
   if not texture:typeOf('Texture') then return false end
   texture:getWidth();texture:getHeight();return true
  end)
  if not usable then return nil,{{stage='input',code='ERR_INPUT_RELEASED',message='Input Texture has been released or is unusable'}} end
  if not isTexture then return nil,{{stage='input',code='ERR_INPUT',message='Expected a LÖVE Texture'}} end
 end
 if options~=nil and (type(options)~='table' or options.origin~='bottom-left' and options.origin~='top-left' and options.origin~=nil) then
  return nil,{{stage='input',code='ERR_INPUT_ORIGIN',message='Input origin must be top-left or bottom-left'}}
 end
 local origin=options and options.origin or 'top-left'
 if texture then
  local textureType=texture:getTextureType()
  local samplerTypes={sampler2D='2d',sampler2DShadow='2d',Image='2d',sampler3D='volume',samplerCube='cube',sampler2DArray='array'}
  for _,pass in ipairs(self.graph.passes) do
   local info=self.programs[pass.program..':'..(pass.drawMode or 'fullscreen')]
   for _,sampler in ipairs(keys(pass.inputs)) do
    local id=pass.inputs[sampler]
    if id==binding or id:gsub('_chain_%d+$','')==binding then
     local uniform=info.uniforms[sampler]
     local expected=uniform and samplerTypes[uniform.type]
     if expected and expected~=textureType and info.shader:hasUniform(sampler) then
      return nil,{{stage='input',code='ERR_INPUT_TYPE',message=uniform.type..' input '..binding..' requires a '..expected..' texture',pass=pass.id,uniform=sampler}}
     end
    end
   end
  end
 end
 local function mediaDimensions(w,h)
  local found=false
  for _,pass in ipairs(self.graph.passes) do
   if pass.effectKey=='synth/media' or pass.effectKey=='synth.media' then
    local matches=false
    for _,sampler in ipairs(keys(pass.inputs)) do local id=pass.inputs[sampler];if id==binding or id:gsub('_chain_%d+$','')==binding then matches=true end end
    if matches then found=true end
   end
  end
  if found then self.hooks:setMediaDimensions('synth/media',w,h) end
 end
 local old=self.externalSources[binding]
 if texture==nil then
  self.externalSources[binding]=nil;self.external[binding]=nil
  if old and old.converted then old.converted:release() end
  mediaDimensions(1,1)
  return true
 end
 local converted
 if origin=='top-left' then
  local pending
  local result,diagnostics=guard('input',function()
   local format=texture:getFormat()
   if not love.graphics.getCanvasFormats()[format] then format='rgba8' end
   local settings={format=format,readable=true,msaa=0,dpiscale=1}
   local target
   if texture:getTextureType()=='volume' then settings.type='volume';target=love.graphics.newCanvas(texture:getWidth(),texture:getHeight(),texture:getDepth(),settings)
   elseif texture:getTextureType()=='2d' then target=love.graphics.newCanvas(texture:getWidth(),texture:getHeight(),settings)
   else fail('ERR_INPUT_TYPE','Top-left conversion supports 2D and volume textures') end
   pending=target
   target:setFilter(texture:getFilter());target:setWrap(texture:getWrap())
   flipInto(texture,target,self)
   return target
  end)
  if not result then if pending then pending:release() end;return nil,diagnostics end
  converted=result
 end
 self.externalSources[binding]={texture=texture,origin=origin,converted=converted}
 self.external[binding]=converted or texture
 if old and old.converted then old.converted:release() end
 mediaDimensions(texture:getWidth(),texture:getHeight())
 return true
end
function Renderer:setParameter(stepIndex,name,value)
 local alive,d=self:_alive();if not alive then return nil,d end
 if type(stepIndex)~='number' or stepIndex%1~=0 or stepIndex<0 or type(name)~='string' or name=='' then
  return nil,{{stage='parameter',code='ERR_PARAMETER',message='Expected a nonnegative step index and parameter name'}}
 end
 if value==nil or value==values.NULL or value==values.UNDEFINED then
  return nil,{{stage='parameter',code='ERR_UNIFORM_VALUE',message='Parameter value is required'}}
 end
 if type(value)=='table' and #value==0 and not (type(value.fn)=='function' or require('noisemaker.runtime.automation').isAutomationValue(value)) then
  return nil,{{stage='parameter',code='ERR_UNIFORM_VALUE',message='Expected a scalar, vector, or compiled automation value'}}
 end
 local define
 for _,pass in ipairs(self.graph.passes) do if pass.stepIndex==stepIndex and pass.effectKey then
  local definition=require('noisemaker.catalog.registry').getEffect(pass.effectKey)
  local parameter=definition and definition.globals and definition.globals[name]
  if parameter and (parameter.type=='float' or parameter.type=='int' or parameter.type=='boolean' or parameter.type=='member') and type(value)=='table' and not (type(value.fn)=='function' or require('noisemaker.runtime.automation').isAutomationValue(value)) then
   return nil,{{stage='parameter',code='ERR_UNIFORM_VALUE',message='Expected scalar or automation for '..name}}
  end
  if parameter and parameter.define then define=parameter.define;break end
 end end
 if define then
  local bound=boundCanvases()
  return guard('parameter',function()
   local graph=graphlib.decode(self.graph)
   for _,pass in ipairs(graph.passes) do if pass.stepIndex==stepIndex then
    local spec=graph.programs[pass.program]
    spec.defines=spec.defines or values.object();values.set(spec.defines,define,value)
    pass.uniforms=pass.uniforms or values.object();values.set(pass.uniforms,name,value)
   end end
   local candidate,diags=M.new(graph,{width=self.width,height=self.height,texturePooling=self.texturePooling},self.hooks:parameterOverrides())
   if not candidate then error(diags[1],0) end
   for binding,entry in pairs(self.externalSources) do
    local ok,inputDiags=candidate:setInput(binding,entry.texture,{origin=entry.origin})
    if not ok then candidate:release();error(inputDiags[1],0) end
   end
   local allocated,nextResources=pcall(candidate._allocate,candidate,self.width,self.height,self.resources)
   if not allocated then candidate:release();error(nextResources,0) end
   local safe,retireErrors=retirementSafe(self.resources,nextResources.reused,bound)
   if not safe then resourceLib.abort(nextResources);candidate:release();error(retireErrors[1],0) end
   dispose(candidate.resources.owned);candidate.resources=nextResources
   local retiring={}
   for _,resource in ipairs(self.resources.owned) do if not nextResources.reused[resource] then retiring[#retiring+1]=resource end end
   self.resources.owned=retiring
   candidate.frameIndex=self.frameIndex;candidate.lastTime=self.lastTime
   candidate.inputManager:release();candidate.inputManager=self.inputManager;self.inputManager=nil
   self:release()
   for key in pairs(self) do self[key]=nil end
   for key,entry in pairs(candidate) do self[key]=entry end
   return true
  end)
 end

 if resourceLib.isVolumeSizeUniform(name) then
  value=resourceLib.clampVolumeSize(value,love.graphics.getSystemLimits().texturesize)
 end
 local palette
 if name=='palette' then
  local expanded,result=pcall(inputlib.expandPalette,value)
  if not expanded then return nil,{{stage='parameter',code='ERR_UNIFORM_VALUE',message=tostring(result)}} end
  palette=result
 end
 local changes,seen,scopedNames={}, {}, {}
 local function change(pass,key,newValue)
  if not pass.uniforms or pass.uniforms[key]==nil then return end
  if not seen[pass] then seen[pass]={} end
  if not seen[pass][key] then
   changes[#changes+1]={pass=pass,name=key,old=pass.uniforms[key]}
   seen[pass][key]=true
  end
  pass.uniforms[key]=newValue
 end
 for _,pass in ipairs(self.graph.passes) do if pass.stepIndex==stepIndex or (pass.stepIndex==nil and stepIndex==0) then
  change(pass,name,value)
  local explicit=pass.scopedParams and pass.scopedParams[name]
  if explicit then change(pass,explicit,value);scopedNames[explicit]=true end
  for _,alias in ipairs(keys(pass.uniformAliases)) do if pass.uniformAliases[alias]==name and alias~=name then change(pass,alias,value) end end
  for _,scoped in ipairs(keys(pass.uniforms)) do
   if scoped:sub(1,#name+1)==name..'_' and (scoped:match('_chain_%d+$') or scoped:match('_node_%d+$')) then
    change(pass,scoped,value);scopedNames[scoped]=true
   end
  end
 end end
 if #changes==0 then return nil,{{stage='parameter',code='ERR_PARAMETER',message='Unknown step parameter '..tostring(name),stepIndex=stepIndex}} end
 for scoped in pairs(scopedNames) do
  for _,pass in ipairs(self.graph.passes) do
   if pass.uniforms and pass.uniforms[scoped]~=nil then
    change(pass,scoped,value)
    if name=='volumeSize' and pass.inheritsVolumeSize then change(pass,name,value) end
   end
  end
 end
 if palette then for _,entry in ipairs(changes) do for key,v in pairs(palette) do change(entry.pass,key,v) end end end
 self.uniforms=gatherUniforms(self.graph)
 local resize=false
 local affected={ [name]=true }
 for scoped in pairs(scopedNames) do affected[scoped]=true end
 for _,id in ipairs(keys(self.graph.textures)) do
  local spec=self.graph.textures[id]
  for _,dimension in ipairs({spec.width,spec.height,spec.depth}) do
   if type(dimension)=='table' and (affected[dimension.param] or affected[dimension.screenDivide]) then resize=true end
  end
 end
 local bound=boundCanvases()
 local nextHooks,nextResources,stagedUploads=nil,nil,{}
 local prepared,diagnostics=guard('parameter',function()
  nextHooks=self.hooks:prepareParameter(stepIndex,name,value,function(id,data,w,h,format) self:_upload(id,data,w,h,format,true,stagedUploads) end)
  if resize then
   nextResources=self:_allocate(self.width,self.height,self.resources)
   preflight.check(self.graph,nextResources,self.programs)
   local safe,retireErrors=retirementSafe(self.resources,nextResources.reused,bound);if not safe then error(retireErrors[1],0) end
  end
  return true
 end)
 if not prepared then
  for _,entry in ipairs(changes) do entry.pass.uniforms[entry.name]=entry.old end
  self.uniforms=gatherUniforms(self.graph)
  if nextResources then resourceLib.abort(nextResources) end
  if nextHooks then nextHooks:release() end
  for _,entry in pairs(stagedUploads) do entry.texture:release() end
  return nil,diagnostics
 end
 if nextResources then local previous=self.resources;self.resources=nextResources;resourceLib.release(previous,nextResources) end
 if nextHooks then self.hooks:release();self.hooks=nextHooks end
 for id,entry in pairs(stagedUploads) do if self.uploads[id] then self.uploads[id].texture:release() end;self.uploads[id]=entry end
 self.output=nil
 return true
end
function Renderer:resize(w,h)
 local alive,d=self:_alive();if not alive then return nil,d end
 if not validSize(w,h) then return nil,{{stage='dimensions',code='ERR_DIMENSIONS',message='Positive integer width and height required'}} end
 local bound=boundCanvases()
 return guard('resize',function()
  local previous=self.resources
  local resources=self:_allocate(w,h,previous)
  local admitted,admissionError=pcall(preflight.check,self.graph,resources,self.programs)
  if not admitted then resourceLib.abort(resources);error(admissionError,0) end
  local safe,retireErrors=retirementSafe(previous,resources.reused,bound)
  if not safe then resourceLib.abort(resources);error(retireErrors[1],0) end
  local uploads={}
  local success,newHooks=pcall(self._makeHooks,self,w,h,uploads,self.hooks:parameterOverrides())
  if not success then resourceLib.abort(resources);for _,entry in pairs(uploads) do entry.texture:release() end;error(newHooks,0) end
  if self.hooks and self.hooks.hasMedia and self.hooks.mediaInitialized then
   newHooks:setMediaDimensions('synth/media',self.hooks.mediaWidth,self.hooks.mediaHeight)
  end
  self.resources=resources;self.width=w;self.height=h;self.output=nil;self.frameReadTextures=nil
  self:_retireFullscreenMeshes()
  self.hooks:release();self.hooks=newHooks
  for _,entry in pairs(self.uploads) do entry.texture:release() end;self.uploads=uploads
  resourceLib.release(previous,resources);return true
 end)
end
function Renderer:reset()
 local alive,d=self:_alive();if not alive then return nil,d end
 return guard('reset',function()
  for _,texture in ipairs(self.resources.owned) do
   if texture:typeOf('Canvas') then
    if texture:getTextureType()=='volume' then for layer=1,texture:getDepth() do love.graphics.setCanvas({{texture,layer=layer}});love.graphics.clear(0,0,0,0) end
    else love.graphics.setCanvas(texture);love.graphics.clear(0,0,0,0) end
   end
  end
  love.graphics.setCanvas();self.frameIndex=0;self.lastTime=0;self.output=nil;self.frameReadTextures=nil;return true
 end)
end
function Renderer:copyTo(destination)
 local alive,d=self:_alive();if not alive then return nil,d end
 if not self.output then return nil,{{stage='copy',code='ERR_NO_FRAME',message='Render before copying output'}} end
 if type(destination)~='userdata' or not destination:typeOf('Canvas') or destination==self.output then return nil,{{stage='copy',code='ERR_COPY_TARGET',message='Copy destination must be a distinct Canvas'}} end
 return guard('copy',function()love.graphics.setCanvas(destination);love.graphics.draw(self.output,0,0,0,destination:getWidth()/self.output:getWidth(),destination:getHeight()/self.output:getHeight());return destination end)
end
function Renderer:release()
 if self.released then return true end
 local safe,errors=retirementSafe(self.resources,nil,boundCanvases());if not safe then return nil,errors end
 dispose(self.resources.owned);dispose(self.owned);for _,entry in pairs(self.uploads) do entry.texture:release() end;self.uploads={};self.hooks:release();if self.inputManager then self.inputManager:release() end
 for _,entry in pairs(self.externalSources) do if entry.converted then entry.converted:release() end end
 self.externalSources={};self.external={};self.output=nil;self.released=true;return true
end
function Renderer:_upload(id,data,w,h,format,flip,uploads)
 uploads=uploads or self.uploads
 format=({rgba32float='rgba32f',rgba16float='rgba16f'})[format] or format or 'rgba8'
 local imageData,image,target
 local ok,texture=xpcall(function()
  if type(data)=='string' then imageData=love.image.newImageData(w,h,format,data)
  else
   imageData=love.image.newImageData(w,h,format)
   imageData:mapPixel(function(x,y)local at=(y*w+x)*4;return data[at+1] or 0,data[at+2] or 0,data[at+3] or 0,data[at+4] or 0 end)
  end
  local previous=uploads[id]
  if not flip and previous and previous.texture:typeOf('Image') and previous.texture:getWidth()==w and previous.texture:getHeight()==h and previous.format==format then
   previous.texture:replacePixels(imageData);return previous.texture
  end
  image=love.graphics.newImage(imageData,{linear=true})
  image:setFilter(flip and 'linear' or 'nearest',flip and 'linear' or 'nearest')
  if not flip then return image end
  target=love.graphics.newCanvas(w,h,{format=format,dpiscale=1})
  love.graphics.setCanvas(target);love.graphics.setShader();love.graphics.setBlendMode('replace','premultiplied')
  love.graphics.draw(image,0,h,0,1,-1);love.graphics.setCanvas();target:setFilter('linear','linear')
  return target
 end,function(e)return e end)
 if imageData then imageData:release() end
 if image and (not ok or texture~=image) then image:release() end
 if not ok then if target then target:release() end;error(texture,0) end
 if uploads[id] and uploads[id].texture~=texture then uploads[id].texture:release() end
 uploads[id]={texture=texture,format=format}
 return texture
end
function Renderer:_makeHooks(w,h,uploads,overrides)
 local hooks=hooklib.new(self.graph,{width=w,height=h,paramOverrides=overrides,
  upload=function(id,data,width,height,format) self:_upload(id,data,width,height,format,true,uploads) end})
 hooks:initialize();return hooks
end
return M
