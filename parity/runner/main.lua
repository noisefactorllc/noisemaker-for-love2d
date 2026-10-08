local root=love.filesystem.getSource()..'/../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local json=require('noisemaker.json')
local values=require('noisemaker.compiler.values')
local compiler=require('noisemaker.compiler.init')
local renderer=require('noisemaker.runtime.renderer')
local resources=require('noisemaker.runtime.resources')
local function parent(path)return path:match('^(.*)/[^/]+$') or '.' end
local function read(path)local f=assert(io.open(path,'rb'));local data=f:read('*a');f:close();return data end
local function write(path,data)local f=assert(io.open(path,'wb'));f:write(data);f:close()end
local function captureBytes(canvas,width,height,flipRows)
 local data=canvas:newImageData();local rgba=love.image.newImageData(width,height,'rgba8')
 rgba:mapPixel(function(x,y)local red,green,blue,alpha=data:getPixel(x,flipRows and height-1-y or y);return red,green,blue,alpha end)
 local bytes=rgba:getString();data:release();rgba:release();return bytes
end
local function colorStats(bytes)
 local colors,nonzero={},0
 for i=1,#bytes,4 do
  local red,green,blue=bytes:byte(i,i+2)
  if red~=0 or green~=0 or blue~=0 then nonzero=nonzero+1 end
  colors[red..','..green..','..blue]=true
 end
 local count=0;for _ in pairs(colors) do count=count+1 end
 return nonzero,count
end
local function normalizeVolumes(graph,limit)
 local changes=values.array()
 for index,pass in ipairs(graph.passes) do
  for _,key in ipairs(values.keys(pass.uniforms or {})) do
   if resources.isVolumeSizeUniform(key) then
    local requested=pass.uniforms[key]
    if type(requested)=='number' then
     local effective=resources.clampVolumeSize(requested,limit)
     if effective~=requested then
      changes[#changes+1]={passIndex=index-1,key=key,requested=requested,effective=effective}
     end
    end
   end
  end
 end
 resources.clampGraphVolumes(graph,limit)
 return changes
end
local function referenceDeltaTime(time,requested)
 local lastTime=time-requested
 if lastTime<=0 then return 0 end
 local delta=time-lastTime
 return delta<0 and 1/600 or delta
end
function love.load()
 local ok,err=xpcall(function()
  local nativeMaxTextureSize=love.graphics.getSystemLimits().texturesize
  local capsOutput=os.getenv('NM_PARITY_CAPS_OUTPUT')
  if capsOutput then write(capsOutput,json.encode({maxTextureSize=nativeMaxTextureSize}));return end
  local inputPath=assert(os.getenv('NM_PARITY_INPUT'),'NM_PARITY_INPUT required')
  local manifest=json.decode(read(inputPath))
  local output=assert(os.getenv('NM_PARITY_OUTPUT'),'NM_PARITY_OUTPUT required')
  local commonMaxTextureSize=manifest.capabilities and manifest.capabilities.commonMaxTextureSize
  if commonMaxTextureSize~=nil then
   assert(manifest.capabilities.nativeMaxTextureSize==nativeMaxTextureSize and
    type(commonMaxTextureSize)=='number' and commonMaxTextureSize==math.floor(commonMaxTextureSize) and
    commonMaxTextureSize>0 and commonMaxTextureSize<=nativeMaxTextureSize,
    'Negotiated texture limits differ from the native GPU')
  end
  local report={runtime={love.getVersion()},lua=jit.version,renderer={love.graphics.getRendererInfo()},capabilities={nativeMaxTextureSize=nativeMaxTextureSize,commonMaxTextureSize=commonMaxTextureSize},cases=values.array()}
  for _,case in ipairs(manifest.cases) do
   local r;local borrowed={}
   local success,result=xpcall(function()
    if case.portable then local success,diagnostics=require('noisemaker').registerEffect(case.portable);if not success then error(json.encode(diagnostics)) end end
    local graph,diagnostics=compiler.compile(case.source);if not graph then error(json.encode(diagnostics)) end
    local capture=case.capture or {};local width,height=capture.width or 257,capture.height or 129
    local common=capture.commonMaxTextureSize
    if common~=nil then
     assert(type(common)=='number' and common==math.floor(common) and common>0 and common<=nativeMaxTextureSize,
      'Invalid negotiated commonMaxTextureSize')
     if commonMaxTextureSize then assert(common==commonMaxTextureSize,'Case texture limit differs from negotiated limit') end
    else common=nativeMaxTextureSize end
    local volumeSizeChanges=normalizeVolumes(graph,common)
    r,diagnostics=renderer.new(graph,{width=width,height=height,texturePooling=capture.texturePooling==true});if not r then error(json.encode(diagnostics)) end
    if capture.reset==false then error('A fresh case requires reset:true') end
    if capture.seed~=nil and capture.seed~=values.NULL and capture.seedPolicy~='authored' then
     local automation=require('noisemaker.runtime.automation')
     local steps={}
     for _,pass in ipairs(graph.passes) do
      if pass.uniforms and pass.uniforms.seed~=nil and not automation.isAutomationValue(pass.uniforms.seed) and not steps[pass.stepIndex] then
       assert(r:setParameter(pass.stepIndex,'seed',capture.seed))
       steps[pass.stepIndex]=true
      end
     end
     r.uniforms.seed=capture.seed
    end
    local consumed=values.array()
    for _,spec in ipairs(capture.inputs or {}) do
     assert(not spec.asset:find('..',1,true) and spec.asset:sub(1,1)~='/','Input path must stay in root')
     assert(spec.assetRoot==nil or spec.assetRoot=='capture','Unknown input asset root')
     local assetRoot=spec.assetRoot=='capture' and parent(inputPath) or root
     local bytes=read(assetRoot..'/'..spec.asset)
     local channels=spec.format=='rgba32f' and 16 or 4
     assert(#bytes==spec.width*spec.height*channels and love.data.encode('string','hex',love.data.hash('sha256',bytes))==spec.sha256,'Input hash/dimensions differ')
     local data=love.image.newImageData(spec.width,spec.height,spec.format or 'rgba8',bytes);local image=love.graphics.newImage(data,{linear=true});data:release()
     image:setFilter(spec.kind=='mesh' and 'nearest' or 'linear',spec.kind=='mesh' and 'nearest' or 'linear');borrowed[#borrowed+1]=image
     local ids={}
     if not spec.effect then for _,pass in ipairs(graph.passes) do for sampler,id in pairs(pass.inputs or {}) do if sampler==spec.binding or id==spec.binding then ids[id]=true elseif spec.kind=='mesh' and id:sub(1,#spec.binding+7)==spec.binding..'_chain_' then ids[spec.binding]=true end end end end
     if spec.kind=='mesh' and spec.component=='uvs' then ids[spec.binding]=true end
     if spec.effect then
      local matched=0
      for _,pass in ipairs(graph.passes) do
       local effect=type(pass.effectKey)=='string' and pass.effectKey:gsub('%.','/') or ''
       if effect==spec.effect then matched=matched+1;assert(pass.inputs and pass.inputs[spec.uniform],'Texture fixture uniform is not bound '..spec.uniform);ids[pass.inputs[spec.uniform]]=true end
      end
      assert(matched>0,'Texture fixture has no executing effect '..spec.effect)
     end
     assert(next(ids),'No input binding '..spec.binding)
     for id in pairs(ids) do assert(r:setInput(id,image,{origin=spec.origin or 'top-left'})) end
     if spec.binding=='imageTex' and not spec.effect then
      local steps={}
      for _,pass in ipairs(r.graph.passes) do
       local effect=type(pass.effectKey)=='string' and pass.effectKey:gsub('%.','/') or ''
       local step=pass.stepIndex or 0
       if effect=='synth/media' and not steps[step] then
        assert(r:setParameter(step,'imageSize',{spec.width,spec.height}))
        steps[step]=true
       end
      end
     end
     consumed[#consumed+1]={kind=spec.kind or 'texture',binding=spec.binding,sha256=spec.sha256,vertexCount=spec.vertexCount}
    end
    local midi,midiSnapshot
    if capture.midi then
     assert(type(capture.midi)=='table' and type(capture.midi.notes)=='table' and
      type(capture.midi.clockCount)=='number' and capture.midi.clockCount>=0 and
      capture.midi.clockCount==math.floor(capture.midi.clockCount),'Invalid captured MIDI state')
     midi={channels={},clockCount=capture.midi.clockCount}
     midiSnapshot={clockCount=midi.clockCount,notes=values.array()}
     for _,note in ipairs(capture.midi.notes) do
      local channel,key,velocity=note.channel,note.key,note.velocity
      assert(type(channel)=='number' and channel==math.floor(channel) and channel>=1 and channel<=16 and
       type(key)=='number' and key==math.floor(key) and key>=0 and key<=127 and
       type(velocity)=='number' and velocity==math.floor(velocity) and velocity>=1 and velocity<=127,
       'Invalid captured MIDI note')
      local state=midi.channels[channel] or {keys={}}
      state.keys[key]=velocity
      midi.channels[channel]=state
      midiSnapshot.notes[#midiSnapshot.notes+1]={channel=channel,key=key,velocity=velocity}
     end
    end
    local canvas
    for i=0,(capture.frames or 1)-1 do
     local time=(capture.time or .25)+(capture.advanceTime and i*(capture.deltaTime or 1/60) or 0)
     canvas,diagnostics=r:render{time=time,deltaTime=referenceDeltaTime(time,capture.deltaTime or 0),frame=(capture.frame or 0)+i,midi=midi}
     if not canvas then error(json.encode(diagnostics)) end
    end
    local function selected()
     if not capture.surface then return captureBytes(canvas,width,height),nil end
     local surface=r.resources.surfaces[capture.surface];assert(surface,'Missing authored capture surface '..capture.surface)
     local texture=r.frameReadTextures and r.frameReadTextures[capture.surface]
     assert(texture,'Missing final frame binding for authored surface '..capture.surface)
     assert(texture:getWidth()==width and texture:getHeight()==height,'Authored surface dimensions differ from resolution')
     local slot=texture==surface.read and 'read' or texture==surface.write and 'write' or nil
     assert(slot,'Final frame binding is not the authored surface texture')
     return captureBytes(texture,width,height,true),slot
    end
    local bytes,surfaceId=selected();local settled=not capture.settleMs or capture.settleMs==0
    if os.getenv('NM_PARITY_DEBUG_PRESENT')=='1' then write(output..'/'..case.id..'.present.rgba',captureBytes(canvas,width,height)) end
    if not settled then
     local deadline=love.timer.getTime()+capture.settleMs/1000
     local nextFrame=(capture.frame or 0)+(capture.frames or 1)
     while love.timer.getTime()<deadline do
      love.timer.sleep(.25)
      canvas,diagnostics=r:render{time=capture.time or .25,frame=nextFrame,midi=midi};if not canvas then error(json.encode(diagnostics)) end;nextFrame=nextFrame+1
      canvas,diagnostics=r:render{time=capture.time or .25,frame=nextFrame,midi=midi};if not canvas then error(json.encode(diagnostics)) end;nextFrame=nextFrame+1
      local nextBytes,nextId=selected()
      if nextBytes==bytes then bytes,surfaceId=nextBytes,nextId;settled=true;break end
      bytes,surfaceId=nextBytes,nextId
     end
     assert(settled,'Authored fixture did not settle within '..capture.settleMs..' ms')
    end
    write(output..'/'..case.id..'.rgba',bytes)
    if capture.requireColorVariation then local _,colors=colorStats(bytes);assert(colors>1,'Authored fixture requires color variation') end
    if os.getenv('NM_PARITY_PNG')=='1' then
     local rgba=love.image.newImageData(width,height,'rgba8',bytes);local png=rgba:encode('png')
     write(output..'/'..case.id..'.png',png:getString());png:release();rgba:release()
    end
    return {id=case.id,status='rendered',width=width,height=height,passes=#graph.passes,captureSurface=capture.surface,surfaceId=surfaceId,settled=settled,consumed=consumed,midiSnapshot=midiSnapshot,commonMaxTextureSize=common,volumeSizeChanges=volumeSizeChanges}
   end,function(e)return tostring(e)end)
   if r then r:release() end
   for _,image in ipairs(borrowed) do image:release() end
   if not success then result={id=case.id,status='failed',message=result} end
   report.cases[#report.cases+1]=result
   print(case.id..': '..result.status..(result.message and ' '..result.message or ''))
  end
  write(output..'/candidate.json',json.encode(report))
 end,debug.traceback)
 love.graphics.setCanvas()
 if not ok then io.stderr:write(tostring(err),'\n') end
 love.event.quit(ok and 0 or 1)
end
