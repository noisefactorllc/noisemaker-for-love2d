local json=require('noisemaker.json')
local values=require('noisemaker.compiler.values')
local compiler=require('noisemaker.compiler.init')
local arrays={plans=true,diagnostics=true,chain=true,vars=true,searchNamespaces=true,passes=true,errors=true,
  mediaSteps=true,usage=true,entries=true,states=true,inputs=false,outputs=false,conditions=false}
local activeProbes
local function portable(value,key)
  if value==nil or value==values.NULL then return values.NULL end
  if value==values.UNDEFINED then return {['$type']='undefined'} end
  if type(value)=='number' then
    if value~=value then return {['$type']='number',value='NaN'} end
    if value==math.huge then return {['$type']='number',value='Infinity'} end
    if value==-math.huge then return {['$type']='number',value='-Infinity'} end
    if value==0 and 1/value==-math.huge then return {['$type']='number',value='-0'} end
  end
  if type(value)=='function' then
    assert(activeProbes and #activeProbes>0,'Function probe states required for graph differential')
    local evaluations=values.array()
    for _,state in ipairs(activeProbes) do
      local ok,result=pcall(value,json.decode(json.encode(state)))
      if ok then evaluations[#evaluations+1]={status='returned',value=portable(result==nil and values.UNDEFINED or result)}
      else evaluations[#evaluations+1]={status='threw',error=tostring(result)} end
    end
    return {['$type']='functionProbe',source='<native function>',evaluations=evaluations}
  end
  if type(value)~='table' then return value end
  local array=arrays[key] or values.isArray(value) or (#value>0 and not values.isObject(value))
  local result=array and values.array() or values.object()
  if array then
    for i=1,#value do result[i]=portable(value[i]) end
  else
    for _,name in ipairs(values.keys(value)) do
      if name~='__nm_order' then values.set(result,name,portable(value[name],name)) end
    end
  end
  return result
end
local function run(source,probeStates)
  activeProbes=probeStates
  local ok,tokens=pcall(compiler.lex,source)
  if not ok then return {status='refused',stage='lex',error=portable(tokens.diagnostic or tokens)} end
  local ast
  ok,ast=pcall(compiler.parse,tokens)
  if not ok then return {status='refused',stage='parse',error=portable(ast.diagnostic or ast)} end
  local validated
  ok,validated=pcall(compiler.validate,ast)
  if not ok then return {status='refused',stage='validate',error=portable(validated.diagnostic or validated)} end
  for _,diagnostic in ipairs(validated.diagnostics or {}) do
    if diagnostic.severity=='error' then return {status='refused',stage='validate',validate=portable(validated),diagnostics=portable(validated.diagnostics,'diagnostics')} end
  end
  local expansion
  ok,expansion=pcall(compiler.expand,validated)
  if not ok then return {status='refused',stage='expand',error=portable(expansion.diagnostic or expansion)} end
  if #expansion.errors>0 then return {status='refused',stage='expand',expand=portable(expansion),errors=portable(expansion.errors,'errors')} end
  local graph,diagnostics=compiler.compile(source)
  if not graph then return {status='refused',stage='graph',diagnostics=portable(diagnostics,'diagnostics')} end
  return {status='compiled',validate=portable(validated),expand=portable(expansion),graph=portable(graph)}
end
local inputPath=os.getenv('NM_GRAPH_INPUT')
local outputPath=os.getenv('NM_GRAPH_OUTPUT')
assert(inputPath and outputPath,'NM_GRAPH_INPUT and NM_GRAPH_OUTPUT required')
local f=assert(io.open(inputPath,'rb')); local input=json.decode(f:read('*a')); f:close()
local output=values.array()
for _,item in ipairs(input) do output[#output+1]=run(item.source,item.probeStates) end
f=assert(io.open(outputPath,'wb')); f:write(json.encode(output)); f:close()
print('graph differential runner: '..#output..' cases')
