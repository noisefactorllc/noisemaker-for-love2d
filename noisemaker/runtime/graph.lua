local values=require('noisemaker.compiler.values')
local M={}
function M.keys(t) return require('noisemaker.catalog.registry').keys(t or {}) end
function M.decode(x,active)
 if x==values.NULL or x==values.UNDEFINED or type(x)~='table' then return x end
 active=active or {}
 if active[x] then error('Cyclic graph value') end
 active[x]=true
 if x['$type']=='undefined' then active[x]=nil;return values.UNDEFINED end
 if x['$type']=='map' then
  local out=values.object()
  for _,entry in ipairs(x.entries) do values.set(out,M.decode(entry[1],active),M.decode(entry[2],active)) end
  active[x]=nil;return out
 end
 if x['$type']=='number' then
  local n=x.value;active[x]=nil
  if n=='NaN' then return 0/0 elseif n=='Infinity' then return math.huge elseif n=='-Infinity' then return -math.huge elseif n=='-0' then return -0.0 end
  error('Unknown tagged number')
 end
 if x['$type'] then error('Unsupported graph value tag '..tostring(x['$type'])) end
 local out=(values.isArray(x) or #x>0) and values.array() or values.object()
 for _,key in ipairs(M.keys(x)) do
  if key~='__nm_order' then local child=M.decode(x[key],active); if child~=values.UNDEFINED then values.set(out,key,child) end end
 end
 active[x]=nil;return out
end
function M.dimension(spec,screen,uniforms,diagnostics)
 uniforms=uniforms or {}
 local result
 if type(spec)=='number' then result=spec
 elseif spec==nil or spec==values.NULL or spec==values.UNDEFINED or spec=='screen' or spec=='auto' or spec=='input' or spec=='resolution' then result=screen
 elseif type(spec)=='string' and spec:sub(-1)=='%' then result=screen*assert(tonumber(spec:sub(1,-2)),'Invalid percentage dimension')/100
 elseif type(spec)=='table' and spec.param then
  local value=uniforms[spec.param]; local found=value~=nil and value~=values.UNDEFINED
  if not found then value=spec.paramDefault or 64 end
  if spec.multiply~=nil then value=value*spec.multiply end
  if spec.power~=nil then value=value^spec.power end
  if not found and (spec.multiply~=nil or spec.power~=nil) and spec.default~=nil then value=spec.default end
  result=value
 elseif type(spec)=='table' and spec.screenDivide then result=math.floor(screen/(uniforms[spec.screenDivide] or spec.default or 1)+0.5)
 elseif type(spec)=='table' and spec.scale then
  result=math.floor(screen*spec.scale)
  if spec.clamp then result=math.max(spec.clamp.min or -math.huge,math.min(spec.clamp.max or math.huge,result)) end
 else
  result=screen
  if diagnostics then diagnostics[#diagnostics+1]={stage='dimension',code='ERR_DIMENSION_FALLBACK',spec=spec,fallback='screen'} end
 end
 assert(type(result)=='number' and result==result and result~=math.huge and result~=-math.huge,'Nonfinite dimension')
 return math.max(1,math.floor(result))
end
local known={}
for field in ('id program entryPoint drawMode drawBuffers count countUniform repeat blend conditions workgroups storageBuffers storageTextures name type clear viewport samplerTypes inputs outputs uniforms effectKey effectFunc effectNamespace nodeId stepIndex uniformSpecs uniformAliases inheritsVolumeSize scopedParams defines'):gmatch('%S+') do known[field]=true end
function M.validate(graph)
 local function fail(code,message,pass) return nil,{{stage='graph',code=code,message=message,pass=pass}} end
 if type(graph)~='table' or type(graph.passes)~='table' or type(graph.programs)~='table' then return fail('ERR_GRAPH','Expected passes and programs') end
 local ids={}
 for i,pass in ipairs(graph.passes) do
  if type(pass)~='table' or type(pass.id)~='string' or ids[pass.id] then return fail('ERR_GRAPH','Invalid or duplicate pass id',i) end
  ids[pass.id]=true
  for _,key in ipairs(M.keys(pass)) do if key~='__nm_order' and not known[key] then return fail('ERR_GRAPH_FIELD','Unknown execution field '..tostring(key),pass.id) end end
  if not graph.programs[pass.program] then return fail('ERR_PROGRAM_NOT_FOUND',tostring(pass.program),pass.id) end
  local effective=pass.outputs~=nil and pass.outputs or pass.storageTextures
  if type(effective)~='table' or #M.keys(effective)==0 then return fail('ERR_GRAPH_OUTPUT','Pass has no outputs',pass.id) end
  for _,bindings in ipairs({pass.inputs or {},pass.outputs or {},pass.storageTextures or {}}) do
   for _,key in ipairs(M.keys(bindings)) do if type(bindings[key])~='string' then return fail('ERR_GRAPH_BINDING','Texture binding must be string',pass.id) end end
  end
 end
 return true
end
return M
