local json=require('noisemaker.json')
local lexer=require('noisemaker.compiler.lexer')
local parser=require('noisemaker.compiler.parser')
local values=require('noisemaker.compiler.values')
local expressions=require('noisemaker.compiler.expressions')
local automation=require('noisemaker.runtime.automation')
local inputs=require('noisemaker.runtime.inputs')
local hooks=require('noisemaker.runtime.hooks')
local arrays={tokens=true,plans=true,vars=true,chain=true,args=true,path=true,body=true,elif=true,imports=true,searchOrder=true,
  elements=true,value=false,leadingComments=true,trailingComments=true,subchainArgumentDiagnostics=true}
local function portable(x,key,includePosition)
  if x==values.NULL or x==nil then return values.NULL end
  if x==values.UNDEFINED then return {['$type']='undefined'} end
  if type(x)=='number' and (x~=x or x==math.huge or x==-math.huge) then
    return values.NULL
  end
  if type(x)~='table' then return x end
  local isArray=arrays[key] or (#x>0 and not values.isObject(x))
  local out=isArray and values.array() or values.object()
  if isArray then
    for i=1,#x do out[i]=portable(x[i],nil,includePosition) end
  else
    for _,k in ipairs(values.keys(x)) do
      if (k~='position' or includePosition or not (type(x[k])=='table' and x[k].start~=nil and x[k].column~=nil)) and k~='subchainArgumentDiagnostics' and k~='__nm_order' then
        values.set(out,k,portable(x[k],k,includePosition))
      end
    end
  end
  return out
end
local function runOne(item)
  if item.automationClockProbe then
    local now=automation.wallTimeMillis()
    local note={key=127,velocity=127,gate=1,time=now-250}
    local config={type='Midi',channel=1,mode=3,min=0,max=1,sensitivity=1}
    return {ok=true,value={wallTime=now,resolved=automation.resolve(config,0,nil,{midi={channels={[1]=note}}})}}
  end
  if item.valuesProbe then
    local object=values.object({beta=2,alpha=1})
    local keys=values.keys(object)
    keys[1]='mutated'
    return {ok=true,value={keys=values.keys(object),indexKeys=values.keys(values.object({['10']=10,['2']=2,['1']=1})),roundtrip=json.decode(json.encode(object))}}
  end
  if item.hooksRNG then
    local rng=hooks.seededRNG(item.hooksRNG.seed)
    local out=values.array()
    for i=1,item.hooksRNG.count do out[i]=rng:next() end
    return {ok=true,value=out}
  end
  if item.hooksLifecycle then
    local spec=item.hooksLifecycle
    local calls=values.array()
    local context={width=spec.width,height=spec.height,upload=function(id,data,width,height,format)
      calls[#calls+1]={id=id,width=width,height=height,format=format,length=#data}
    end}
    local manager=hooks.new({passes=spec.passes},context)
    manager:initialize()
    local first=#calls
    local initial=manager:update(0,0)
    manager:parameter(spec.stepIndex or 1,'alpha',0.25)
    local afterAlpha=#calls
    manager:parameter(spec.stepIndex or 1,'density',0.75)
    local afterDensity=#calls
    manager:resize(spec.width+1,spec.height+1)
    local afterResize=#calls
    manager:setMediaDimensions('synth.media',320,240)
    local updated=manager:update(1,1)
    local inherited=manager:parameterOverrides()
    local recreated=hooks.new({passes=spec.passes},{width=spec.width+1,height=spec.height+1,upload=context.upload,paramOverrides=inherited})
    local inheritedDensity=recreated.nodes.node_1 and recreated.nodes.node_1.params.density
    local inheritedAgain=recreated:parameterOverrides()
    recreated:release()
    manager:release()
    return {ok=true,value={calls=calls,initialUploads=first,afterAlpha=afterAlpha,afterDensity=afterDensity,inheritedDensity=inheritedDensity,inheritedAgain=inheritedAgain,
      afterResize=afterResize,initialUniforms=portable(initial),updatedUniforms=portable(updated)}}
  end
  if item.hooksTransaction then
    local spec=item.hooksTransaction
    local uploads=0
    local manager=hooks.new({passes=spec.passes},{width=spec.width,height=spec.height,upload=function() uploads=uploads+1 end})
    manager:initialize()
    manager:setMediaDimensions('synth.media',320,240)
    local initialUploads=uploads
    local initialDensity=manager.nodes.node_1.params.density
    local initialOverrides=manager:parameterOverrides()
    local attempted=0
    local accepted,err=pcall(function()
      manager:prepareParameter(spec.stepIndex,'density',0.75,function()
        attempted=attempted+1
        error('injected upload failure')
      end)
    end)
    local afterFailure={accepted=accepted,errorMatched=not accepted and tostring(err):find('injected upload failure',1,true)~=nil,
      density=manager.nodes.node_1.params.density,overrides=manager:parameterOverrides(),uploads=uploads,attempted=attempted}
    local alphaUploads=0
    local alpha=manager:prepareParameter(spec.stepIndex,'alpha',0.25,function() alphaUploads=alphaUploads+1 end)
    local afterAlpha={candidate=alpha~=nil,uploads=alphaUploads,originalAlpha=manager.nodes.node_1.params.alpha,
      nextAlpha=alpha.nodes.node_1.params.alpha,mediaWidth=alpha.mediaWidth,mediaHeight=alpha.mediaHeight,
      mediaInitialized=alpha.mediaInitialized}
    local stagedUploads=0
    local density=alpha:prepareParameter(spec.stepIndex,'density',0.75,function() stagedUploads=stagedUploads+1 end)
    local afterDensity={stagedUploads=stagedUploads,originalDensity=manager.nodes.node_1.params.density,
      nextDensity=density.nodes.node_1.params.density,overrides=density:parameterOverrides(),
      irrelevant=density:prepareParameter(999,'density',0.1)==nil,
      unchanged=density:prepareParameter(spec.stepIndex,'density',0.75)==nil}
    manager:release()
    return {ok=true,value={initialUploads=initialUploads,initialDensity=initialDensity,
      initialOverrides=initialOverrides,afterFailure=afterFailure,afterAlpha=afterAlpha,afterDensity=afterDensity}}
  end
  if item.hooksOverlay then
    local spec=item.hooksOverlay
    local bytes,segments=hooks.renderOverlay(spec.effect,spec.width,spec.height,spec.params)
    local out=values.array()
    for i=1,#bytes do out[i]=bytes:byte(i) end
    return {ok=true,value=out,segments=segments}
  end
  if item.hooksTrace then
    local opts=item.hooksTrace
    if opts.colorMode=='fibers' then opts.colorFn=function(rng) return {r=math.floor(rng:float()*200+55),g=math.floor(rng:float()*200+55),b=math.floor(rng:float()*200+55),a=0.5} end
    elseif opts.colorMode=='hair' then opts.colorFn=function(rng) return {r=math.floor(rng:float()*30),g=math.floor(rng:float()*30),b=math.floor(rng:float()*30),a=0.666} end
    else opts.colorFn=function() return {r=255,g=255,b=255,a=1} end end
    local out=values.array()
    hooks.traceWorms(opts,function(x1,y1,x2,y2,width,color,exposure,w,iter)
      out[#out+1]={x1,y1,x2,y2,width,color.r,color.g,color.b,color.a*exposure,w,iter}
    end)
    return {ok=true,value=out}
  end
  if item.paletteIndex~=nil then return {ok=true,value=portable(inputs.expandPalette(item.paletteIndex))} end
  if item.inputSnapshot then
    local manager=inputs.new({needsMidiNoteGrid=item.needsMidiNoteGrid})
    local uniforms,textures,external=manager:update(item.inputSnapshot)
    local out={uniforms=portable(uniforms),textures=portable(textures)}
    if item.midiSelector and external.midi then
      local selected=external.midi:getPortState(item.midiSelector)
      out.selectedMidi=selected and portable(selected:getChannel(item.midiSelector.channel or 1)) or values.NULL
    end
    if item.audioSelector and external.audio then
      out.selectedAudio=portable(external.audio:getDeviceChannelState(item.audioSelector))
    end
    return {ok=true,value=out}
  end
  if item.automation then
    local ok,value=pcall(automation.resolve,item.automation,item.time,item.range,item.external or {},{wallTime=item.wallTime or 1000})
    if not ok then return {ok=false,error=tostring(value)} end
    return {ok=true,value=portable(value)}
  end
  if item.expression then
    local callback,diagnostic=expressions.compile(item.expression)
    if not callback then return {ok=false,error=diagnostic} end
    local ok,value=pcall(callback,item.state or {})
    if not ok then return {ok=false,error=tostring(value)} end
    return {ok=true,value=portable(value)}
  end
  local source=item.source
  local ok,tokens=pcall(lexer.lex,source)
  if not ok then
    return {ok=false,stage='lexer',error=portable(tokens.diagnostic or {message=tostring(tokens)})}
  end
  local publicTokens=values.array()
  for _,token in ipairs(tokens) do
    publicTokens[#publicTokens+1]={type=token.type,lexeme=token.lexeme,line=token.line,col=token.col,position=token.position}
  end
  local parseOk,ast=pcall(parser.parse,tokens,item.options or {})
  if not parseOk then
    return {ok=false,stage='parser',tokens=portable(publicTokens,'tokens',true),error=portable(ast.diagnostic or {message=tostring(ast)})}
  end
  return {ok=true,tokens=portable(publicTokens,'tokens',true),ast=portable(ast)}
end
local inputPath=os.getenv('NM_FRONTEND_INPUT')
local outputPath=os.getenv('NM_FRONTEND_OUTPUT')
assert(inputPath and outputPath,'NM_FRONTEND_INPUT and NM_FRONTEND_OUTPUT required')
local f=assert(io.open(inputPath,'rb'));local contents=f:read('*a');f:close()
local input=json.decode(contents)
local output=values.array()
for _,item in ipairs(input) do output[#output+1]=runOne(item) end
local serialized=json.encode(output)
local surrogatePattern=string.char(0xED)..'['..string.char(0xA0)..'-'..string.char(0xBF)..']['..string.char(0x80)..'-'..string.char(0xBF)..']'
serialized=serialized:gsub(surrogatePattern,function(chunk)
  local a,b,c=chunk:byte(1,3)
  return string.format('\\u%04x',(a-0xE0)*4096+(b-0x80)*64+(c-0x80))
end)
f=assert(io.open(outputPath,'wb'));f:write(serialized);f:close()
print('frontend differential runner: '..#output..' cases')
