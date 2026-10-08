-- Native Polymorphic automation evaluator. Inputs are compiled automation
-- configurations and a host-owned external-state snapshot.
local values=require('noisemaker.compiler.values')
local ffi=require('ffi')
local M={}
local wallTimeMillis
if ffi.os=='Windows' then
  ffi.cdef[[typedef struct { unsigned int low; unsigned int high; } NMFileTime;
    void __stdcall GetSystemTimeAsFileTime(NMFileTime *time);]]
  local kernel=ffi.load('kernel32')
  local stamp=ffi.new('NMFileTime[1]')
  wallTimeMillis=function()
    kernel.GetSystemTimeAsFileTime(stamp)
    local high,low=tonumber(stamp[0].high),tonumber(stamp[0].low)
    -- Split 2^32 before division so every intermediate integer remains exact
    -- in Lua's double representation, even for current FILETIME values.
    return high*429496+math.floor((high*7296+low)/10000)-11644473600000
  end
else
  if ffi.os=='OSX' then
    ffi.cdef[[typedef struct { long tv_sec; int tv_usec; } NMTimeval;
      int gettimeofday(NMTimeval *time, void *zone);]]
  else
    ffi.cdef[[typedef struct { long tv_sec; long tv_usec; } NMTimeval;
      int gettimeofday(NMTimeval *time, void *zone);]]
  end
  local stamp=ffi.new('NMTimeval[1]')
  wallTimeMillis=function()
    if ffi.C.gettimeofday(stamp,nil)~=0 then error('System wall clock unavailable') end
    return tonumber(stamp[0].tv_sec)*1000+math.floor(tonumber(stamp[0].tv_usec)/1000)
  end
end
M.wallTimeMillis=wallTimeMillis
local TAU=math.pi*2
local RANGES={unit={min=0,max=1},oscillatorSpeed={min=-20,max=20},oscillatorOffset={min=-1,max=1},oscillatorSeed={min=1,max=9999},midiSensitivity={min=0,max=10}}
local NODES={
  {-0.9894009349916499,-0.9445750230732326,-0.8656312023878318,-0.755404408355003,-0.6178762444026438,-0.4580167776572274,-0.2816035507792589,-0.0950125098376374,0.0950125098376374,0.2816035507792589,0.4580167776572274,0.6178762444026438,0.755404408355003,0.8656312023878318,0.9445750230732326,0.9894009349916499},
  {-0.9602898564975363,-0.7966664774136267,-0.525532409916329,-0.1834346424956498,0.1834346424956498,0.525532409916329,0.7966664774136267,0.9602898564975363},
  {-0.8611363115940526,-0.3399810435848563,0.3399810435848563,0.8611363115940526},
  {-0.5773502691896257,0.5773502691896257}
}
local WEIGHTS={
  {0.0271524594117541,0.0622535239386479,0.0951585116824928,0.1246289712555339,0.1495959888165767,0.1691565193950025,0.1826034150449236,0.1894506104550685,0.1894506104550685,0.1826034150449236,0.1691565193950025,0.1495959888165767,0.1246289712555339,0.0951585116824928,0.0622535239386479,0.0271524594117541},
  {0.1012285362903763,0.2223810344533745,0.3137066458778873,0.362683783378362,0.362683783378362,0.3137066458778873,0.2223810344533745,0.1012285362903763},
  {0.3478548451374538,0.6521451548625461,0.6521451548625461,0.3478548451374538},
  {1,1}
}
local function finite(n) return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function integer(n) return finite(n) and n%1==0 end
local function rem(a,b) return a-b*math.modf(a/b) end
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function scale(value,range)
  if type(range)~='table' or not finite(range.min) or not finite(range.max) then return value end
  return range.min+value*(range.max-range.min)
end
local function automationType(config)
  if type(config)~='table' then return nil end
  local kind=config.type or (type(config._ast)=='table' and config._ast.type)
  if kind=='Oscillator' or kind=='Midi' or kind=='Audio' then return kind end
  return nil
end
M.isAutomationValue=function(value) return automationType(value)~=nil end
local function hash21(px,py,s)
  local x=rem(px*234.34+s,1)
  local y=rem(py*435.345+s,1)
  if x<0 then x=x+1 end
  if y<0 then y=y+1 end
  local p=x+y+(x+y)*34.23
  return rem(x*y*p,1)
end
local function noise2D(px,py,s)
  local ix,iy=math.floor(px),math.floor(py)
  local fx,fy=px-ix,py-iy
  fx=fx*fx*(3-2*fx);fy=fy*fy*(3-2*fy)
  local a,b,c,d=hash21(ix,iy,s),hash21(ix+1,iy,s),hash21(ix,iy+1,s),hash21(ix+1,iy+1,s)
  return a*(1-fx)*(1-fy)+b*fx*(1-fy)+c*(1-fx)*fy+d*fx*fy
end
local function oscNoise(t,seed)
  local angle=rem(t,1)*TAU
  local x,y=math.cos(angle)*2,math.sin(angle)*2
  return (noise2D(x+seed,y+seed,seed)+noise2D(x+seed*2,y+seed*2,seed))*0.5
end
local function oscNoise2D(time,speed,seed)
  local function periodic(x,v) return (math.sin((x-v)*TAU)+1)*0.5 end
  local px=(math.abs(rem(seed,16))+0.5)/16
  local py=(math.abs(rem(math.floor(seed/16),16))+0.5)/16
  local timeNoise=noise2D(px,py,seed+12345)
  local valueNoise=noise2D(px,py,seed)
  return periodic(periodic(time,timeNoise)*speed,valueNoise)
end
local function oscPrimitive(kind,x)
  local whole=math.floor(x)
  local fraction=x-whole
  if kind==0 then return x*0.5-math.sin(x*TAU)/(2*TAU) end
  if kind==1 then
    local partial=fraction<0.5 and fraction*fraction or (2*fraction-fraction*fraction-0.5)
    return whole*0.5+partial
  end
  if kind==2 then return whole*0.5+fraction*fraction*0.5 end
  if kind==3 then return x-(whole*0.5+fraction*fraction*0.5) end
  if kind==4 then return whole*0.5+math.max(0,fraction-0.5) end
  return nil
end
local function indexed(collection,index,zeroBased)
  if type(collection)~='table' then return nil end
  if values.isArray(collection) or #collection>0 then return collection[index+(zeroBased and 1 or 0)] end
  return collection[index] or collection[tostring(index)]
end
local function midiPortState(external,config)
  local midi=external and external.midi
  if type(midi)~='table' then return nil end
  if type(midi.getPortState)=='function' then return midi:getPortState(config) end
  return midi
end
local function midiChannel(state,index)
  if type(state.getChannel)=='function' then return state:getChannel(index) end
  if state.channels then return indexed(state.channels,index,false) end
  error('MIDI state requires getChannel or channels')
end
local function evaluateMidi(config,state,wallTime,min,max,sensitivity)
  if config._invalid or not state then return min end
  local mode=config.mode
  local hasZone=config.zone~=nil
  if hasZone and (config.channel~=nil or (config.zone~=0 and config.zone~=1)) then return min end
  if config.members~=nil and (not hasZone or not integer(config.members) or config.members<1 or config.members>15) then return min end
  if not hasZone and mode>=5 and (not integer(config.channel) or config.channel<1 or config.channel>16) then return min end
  local voice
  if hasZone and type(state.getZoneVoice)=='function' then voice=state:getZoneVoice(config) end
  if hasZone and not voice then return min end
  local channel=hasZone and voice.channel or midiChannel(state,config.channel)
  local note=voice or channel
  local gate=voice and 1 or note.gate
  local raw=0
  if mode==0 then raw=note.key
  elseif mode==1 then if gate==1 then raw=note.key end
  elseif mode==2 then if gate==1 then raw=note.velocity end
  elseif mode==3 then
    if gate==1 then raw=note.key*(1-math.min(1,(wallTime-note.time)*sensitivity*0.001)) end
  elseif mode==5 or mode==6 then
    local cc=config.cc~=nil and config.cc or 1
    if not integer(cc) or cc<0 or cc>(mode==6 and 31 or 127) then return min end
    local value=indexed(mode==6 and channel.cc14 or channel.cc,cc,true) or 0
    return min+(value/(mode==6 and 16383 or 127))*(max-min)
  elseif mode==7 then
    if not integer(config.nrpn) or config.nrpn<0 or config.nrpn>16382 then return min end
    local nrpn=channel.nrpn
    local value
    if nrpn and type(nrpn.get)=='function' then value=nrpn:get(config.nrpn)
    elseif nrpn then value=nrpn[config.nrpn] or nrpn[tostring(config.nrpn)] end
    return min+((value or 0)/16383)*(max-min)
  elseif mode==8 then return min+((channel.pitchBend or 8192)/16383)*(max-min)
  elseif mode==9 then return min+((channel.pressure or 0)/127)*(max-min)
  elseif mode==10 then
    local value=indexed(channel.polyPressure,note.key,true) or 0
    return min+(value/127)*(max-min)
  else
    if gate==1 then raw=note.velocity*(1-math.min(1,(wallTime-note.time)*sensitivity*0.001)) end
  end
  return min+(raw/127)*(max-min)
end
local function selectorIntent(config)
  local source=type(config._ast)=='table' and config._ast.type=='Audio' and config._ast or config
  return config.name~=nil or config.id~=nil or config.channel~=nil or source.name~=nil or source.id~=nil or source.channel~=nil
end
local function validAudioSelector(config)
  local source=type(config._ast)=='table' and config._ast.type=='Audio' and config._ast or config
  if source.name~=nil and config.name==nil or source.id~=nil and config.id==nil or source.channel~=nil and config.channel==nil then return false end
  if config.name~=nil and (type(config.name)~='string' or config.name=='') then return false end
  if config.id~=nil and (type(config.id)~='string' or config.id=='' or not config.name) then return false end
  return integer(config.channel) and config.channel>=1 and config.channel<=32
end
local function evaluateAudio(config,audio,min,max)
  if config._invalid or not audio then return min end
  local selected=audio
  if selectorIntent(config) then
    if not validAudioSelector(config) then return min end
    if type(audio.getDeviceChannelState)~='function' then return min end
    selected=audio:getDeviceChannelState(config)
  end
  if not selected then return min end
  local raw=0
  if config.band==0 then raw=selected.low
  elseif config.band==1 then raw=selected.mid
  elseif config.band==2 then raw=selected.high
  elseif config.band==3 then raw=selected.vol
  elseif config.band==4 then
    if selected.rawReady~=true then return min end
    raw=(clamp(selected.raw or 0,-1,1)+1)*0.5
  end
  return min+clamp(raw,0,1)*(max-min)
end
local evaluateAutomation,evaluateOscillator,integrateAutomation
local function field(value,time,range,external,depth,stack,fallback,context)
  if automationType(value) then return evaluateAutomation(value,time,range,external,depth+1,stack,context) end
  return finite(value) and value or fallback
end
local function dynamicFields(config)
  local fields=automationType(config)=='Midi' and {'min','max','sensitivity'} or {'min','max'}
  for _,name in ipairs(fields) do if automationType(config[name]) then return true end end
  return false
end
local function simpleIntegral(config,time)
  if config.speed==0 then return evaluateOscillator(config,0,nil,0,{},nil)*time end
  local raw=(oscPrimitive(config.oscType,config.offset+config.speed*time)-oscPrimitive(config.oscType,config.offset))/config.speed
  return config.min*time+(config.max-config.min)*raw
end
integrateAutomation=function(config,time,range,external,depth,stack,context)
  local integral
  local kind=automationType(config)
  local simple=kind=='Oscillator' and config.oscType>=0 and config.oscType<=4
  if simple then
    for _,name in ipairs{'min','max','speed','offset','seed'} do if not finite(config[name]) then simple=false;break end end
  end
  if simple then integral=simpleIntegral(config,time)
  elseif (kind=='Midi' or kind=='Audio') and not dynamicFields(config) then
    integral=evaluateAutomation(config,time,nil,external,depth+1,stack,context)*time
  else
    local order=math.min(depth+1,#NODES)
    local nodes,weights=NODES[order],WEIGHTS[order]
    local midpoint,half=time*0.5,time*0.5
    local sum=0
    for i=1,#nodes do
      local sample=midpoint+half*nodes[i]
      sum=sum+weights[i]*evaluateAutomation(config,sample,nil,external,depth+1,stack,context)
    end
    integral=half*sum
  end
  if type(range)~='table' or not finite(range.min) or not finite(range.max) then return integral end
  return range.min*time+integral*(range.max-range.min)
end
evaluateOscillator=function(config,time,external,depth,stack,context)
  local min=field(config.min,time,RANGES.unit,external,depth,stack,0,context)
  local max=field(config.max,time,RANGES.unit,external,depth,stack,1,context)
  local offset=field(config.offset,time,RANGES.oscillatorOffset,external,depth,stack,0,context)
  local seed=field(config.seed,time,RANGES.oscillatorSeed,external,depth,stack,1,context)
  local phase
  if automationType(config.speed) then phase=integrateAutomation(config.speed,time,RANGES.oscillatorSpeed,external,depth,stack,context)
  else phase=time*(finite(config.speed) and config.speed or 1) end
  local t=phase+offset
  local kind=config.oscType
  local raw=0
  if kind==0 then raw=(1-math.cos(t*TAU))*0.5
  elseif kind==1 then local f=t-math.floor(t);raw=1-math.abs(f*2-1)
  elseif kind==2 then raw=t-math.floor(t)
  elseif kind==3 then raw=1-(t-math.floor(t))
  elseif kind==4 then raw=(t-math.floor(t))>=0.5 and 1 or 0
  elseif kind==5 then raw=oscNoise(t,seed)
  elseif kind==6 then
    local speed=field(config.speed,time,RANGES.oscillatorSpeed,external,depth,stack,1,context)
    raw=oscNoise2D(time+offset,finite(speed) and speed or 1,seed)
  end
  return min+raw*(max-min)
end
evaluateAutomation=function(config,time,range,external,depth,stack,context)
  local kind=automationType(config)
  if not kind or depth>8 or stack[config] then return scale(0,range) end
  stack[config]=true
  local ok,value=pcall(function()
    if kind=='Oscillator' then return evaluateOscillator(config,time,external,depth,stack,context) end
    if kind=='Midi' then
      local midi=midiPortState(external,config)
      local min=field(config.min,time,RANGES.unit,external,depth,stack,0,context)
      local max=field(config.max,time,RANGES.unit,external,depth,stack,1,context)
      local sensitivity=field(config.sensitivity,time,RANGES.midiSensitivity,external,depth,stack,1,context)
      return evaluateMidi(config,midi,context.wallTime,min,max,sensitivity)
    end
    if config._invalid then return finite(config.min) and config.min or 0 end
    local min=field(config.min,time,RANGES.unit,external,depth,stack,0,context)
    local max=field(config.max,time,RANGES.unit,external,depth,stack,1,context)
    return evaluateAudio(config,external and external.audio,min,max)
  end)
  stack[config]=nil
  if not ok then error(value,0) end
  return scale(value,range)
end
function M.resolve(value,time,paramSpec,externalState,context)
  if not automationType(value) then return value end
  local result=evaluateAutomation(value,time,paramSpec,externalState or {},0,{},context or {wallTime=wallTimeMillis()})
  if paramSpec and paramSpec.type=='int' then return math.floor(result+0.5) end
  return result
end
M.evaluateAutomation=evaluateAutomation
M.evaluateOscillator=evaluateOscillator
local stringLiterals=require('noisemaker.compiler.string_literals')
local function cloneField(value)
  return value
end
function M.compileAST(node,resolveEnum,diagnostic)
  assert(type(node)=='table' and type(resolveEnum)=='function' and type(diagnostic)=='function')
  local function report(code,at,message) diagnostic(code,at,message) end
  local compile
  local function enum(at,enumName,fallback,valid,descriptor,fieldName)
    local result
    if at and at.type=='Number' then result=at.value
    elseif at and at.type=='Member' then result=resolveEnum(at.path)
    elseif at and at.type=='Ident' then result=resolveEnum({enumName,at.name}) end
    if type(result)=='table' and result.type=='Number' then result=result.value end
    if type(result)=='number' and valid[result] then return result end
    if at and at.type=='String' then report('S001',at,'String literal not allowed for '..descriptor..'() '..fieldName)
    else
      local message=descriptor=='audio' and fieldName=='band'
        and ('audio() band must resolve to an integer from 0 to 4 (got '..(result==nil and 'undefined' or tostring(result))..')')
        or (descriptor..'() '..fieldName..' must resolve to a supported enum value')
      report('S002',at,message)
    end
    return fallback
  end
  local function stringField(at,descriptor,fieldName)
    if at==nil then return nil end
    if at.type~='String' then
      report('S001',at,descriptor..'() '..fieldName..' requires a quoted string')
      return nil
    end
    if at.value=='' then
      report('S001',at,descriptor..'() '..fieldName..' must not be empty')
      return nil
    end
    return stringLiterals.decodeJsonStringLiteralContent(at.value)
  end
  local function number(at,descriptor,fieldName,fallback,opts,depth)
    if at==nil then return fallback end
    opts=opts or {}
    local function reject(code,message)
      if opts.onInvalid then opts.onInvalid() end
      report(code,at,message)
      return fallback
    end
    local value
    if at.type=='Number' then value=at.value
    elseif opts.allowBoolean and at.type=='Boolean' then value=at.value and 1 or 0
    elseif at.type=='Member' and opts.allowMember~=false then
      value=resolveEnum(at.path)
      if type(value)=='table' and value.type=='Number' then value=value.value end
    elseif automationType(at) and opts.allowAutomation then
      local compiled=compile(at,depth+1)
      if type(compiled)=='table' and compiled._invalid and opts.onInvalid then opts.onInvalid() end
      return compiled
    elseif at.type=='String' then
      return reject('S001','String literal not allowed for '..descriptor..'() '..fieldName)
    elseif at.type=='Ident' then
      return reject('S003',"Undefined automation source '"..at.name.."' for "..descriptor..'() '..fieldName)
    else
      return reject('S002',descriptor..'() '..fieldName..' must be a number'..(opts.allowAutomation and ' or automation source' or ''))
    end
    if not finite(value) then return reject('S002',descriptor..'() '..fieldName..' must resolve to a finite number') end
    if opts.integer and not integer(value) then return reject('S002',descriptor..'() '..fieldName..' must be an integer') end
    if opts.min~=nil and value<opts.min then
      return reject('S002',descriptor..'() '..fieldName..' must be at least '..opts.min..' (got '..value..')')
    end
    if opts.max~=nil and value>opts.max then
      return reject('S002',descriptor..'() '..fieldName..' must be at most '..opts.max..' (got '..value..')')
    end
    if opts.clamp01 then return clamp(value,0,1) end
    return value
  end
  compile=function(at,depth)
    if depth>8 then
      report('S001',at,'Automation nesting exceeds the maximum depth of 8')
      return 0
    end
    local kind=at.type
    if kind=='Oscillator' then
      local result={type='Oscillator',
        oscType=enum(at.oscType,'oscKind',0,{[0]=true,[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true},'osc','type'),
        min=number(at.min,'osc','min',0,{allowBoolean=true,allowAutomation=true,clamp01=true},depth),
        max=number(at.max,'osc','max',1,{allowBoolean=true,allowAutomation=true,clamp01=true},depth),
        speed=number(at.speed,'osc','speed',1,{allowBoolean=true,allowAutomation=true},depth),
        offset=number(at.offset,'osc','offset',0,{allowBoolean=true,allowAutomation=true},depth),
        seed=number(at.seed,'osc','seed',1,{allowBoolean=true,allowAutomation=true},depth),_ast=at}
      if at._varRef then result._varRef=at._varRef end
      return result
    end
    if kind=='Midi' then
      local mode=enum(at.mode,'midiMode',4,{[0]=true,[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,[7]=true,[8]=true,[9]=true,[10]=true},'midi','mode')
      local hasZone=at.zone~=nil
      local zone=hasZone and enum(at.zone,'midiZone',nil,{[0]=true,[1]=true},'midi','zone') or nil
      local validSelection=not hasZone or zone~=nil
      local members
      if at.members~=nil then
        members=number(at.members,'midi','members',nil,{integer=true,min=1,max=15,allowMember=false,onInvalid=function() validSelection=false end},depth)
        if not hasZone then validSelection=false end
      end
      if hasZone and at.channel~=nil then validSelection=false end
      local validChannel=true
      local channel=hasZone and nil or number(at.channel,'midi','channel',1,{integer=true,min=1,max=16,allowMember=false,onInvalid=function() validChannel=false end},depth)
      local validCc=true
      local cc
      if at.cc~=nil or mode==5 or mode==6 then
        cc=number(at.cc,'midi','cc',1,{integer=true,min=0,max=mode==6 and 31 or 127,allowMember=false,onInvalid=function() validCc=false end},depth)
      end
      local nrpn
      if at.nrpn~=nil or mode==7 then
        if at.nrpn==nil then report('S002',at,'midi() nrpn mode requires a parameter number');validSelection=false end
        nrpn=number(at.nrpn,'midi','nrpn',nil,{integer=true,min=0,max=16382,allowMember=false,onInvalid=function() validSelection=false end},depth)
      end
      local result={type='Midi',channel=channel,mode=mode,cc=cc,nrpn=nrpn,zone=zone,members=members,
        min=number(at.min,'midi','min',0,{allowBoolean=true,allowAutomation=true,clamp01=true},depth),
        max=number(at.max,'midi','max',1,{allowBoolean=true,allowAutomation=true,clamp01=true},depth),
        sensitivity=number(at.sensitivity,'midi','sensitivity',1,{allowBoolean=true,allowAutomation=true},depth),
        name=stringField(at.name,'midi','name'),id=stringField(at.id,'midi','id'),_ast=at}
      if not validCc or not validChannel or not validSelection then result._invalid=true end
      if at._varRef then result._varRef=at._varRef end
      return result
    end
    if kind=='Audio' then
      local band=enum(at.band,'audioBand',nil,{[0]=true,[1]=true,[2]=true,[3]=true,[4]=true},'audio','band')
      local validMin,validMax=true,true
      local min=number(at.min,'audio','min',0,{allowAutomation=true,allowMember=false,clamp01=true,onInvalid=function() validMin=false end},depth)
      local max=number(at.max,'audio','max',1,{allowAutomation=true,allowMember=false,clamp01=true,onInvalid=function() validMax=false end},depth)
      local channel,validChannel=nil,true
      if at.channel~=nil then
        if at.channel.type=='Number' and integer(at.channel.value) and at.channel.value>=1 and at.channel.value<=32 then channel=at.channel.value
        else
          validChannel=false
          if at.channel.type=='String' then report('S001',at.channel,'String literal not allowed for audio() channel')
          else report('S002',at.channel,'audio() channel must be a positive integer from 1 to 32 (got '..tostring(at.channel.value or at.channel.name or at.channel.type)..')') end
        end
      end
      local name=stringField(at.name,'audio','name')
      local id=stringField(at.id,'audio','id')
      local result={type='Audio',band=band,min=min,max=max,channel=channel,name=name,id=id,
        _invalid=band==nil or not validMin or not validMax or (at.name~=nil and name==nil) or (at.id~=nil and id==nil) or not validChannel,
        _ast=at}
      if at._varRef then result._varRef=at._varRef end
      return result
    end
    return 0
  end
  return compile(node,0)
end
return M
