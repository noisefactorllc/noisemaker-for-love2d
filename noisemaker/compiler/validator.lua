local registry = require('noisemaker.catalog.registry')
local values = require('noisemaker.compiler.values')
local M = {}

local NULL = values.NULL
local messages = {
  S001 = 'Unknown identifier', S002 = 'Argument out of range',
  S003 = 'Variable used before assignment', S004 = 'Cannot assign null or undefined',
  S005 = 'Illegal chain structure', S006 = 'Starter chain missing write() call',
  S007 = 'Deprecated parameter alias', S008 = 'Deprecated effect'
}
-- Hard removal date that upstream paramAliases.js states for all parameter aliases.
local ALIAS_EOL_DATE = '2027-06-01'
local stateValues = {time=true, frame=true, mouse=true, resolution=true, seed=true, a=true,
  u1=true,u2=true,u3=true,u4=true,s1=true,s2=true,b1=true,b2=true,a1=true,a2=true,deltaTime=true}
local stateSurfaces = {time=true,frame=true,mouse=true,resolution=true,seed=true,a=true}
local stringAllow = {['text.text']=true,['text.font']=true,['text.justify']=true,['text.style']=true}

-- Identifier nodes that already have their S003 for a read before the let, in the validate
-- call in progress. Copies of a marked node stay marked, as upstream reuses the node itself.
local activeReads
local function copy(value)
  if type(value) ~= 'table' or value == NULL then return value end
  local result = values.isArray(value) and values.array() or {}
  for k, v in pairs(value) do if k ~= '__nm_order' then result[k] = copy(v) end end
  if value.type=='Call' and type(result.args)=='table' then result.args=values.array(result.args) end
  if activeReads and activeReads[value] then activeReads[result] = true end
  return result
end

-- A symbol's value in place of the identifier that names it. `_varRef` records the outermost
-- name, as upstream substitute() does.
local function substituteSymbol(node, symbols)
  if type(node) ~= 'table' or node.type ~= 'Ident' or not symbols[node.name] then return node end
  local result = copy(symbols[node.name])
  if type(result) == 'table' and result ~= NULL then result._varRef = node._varRef or node.name end
  return result
end

-- Upstream toBoolean: a number is true unless zero; any other value as JavaScript !!value.
local function toBoolean(value)
  if type(value) == 'number' then return value ~= 0 end
  return values.truthy(value)
end

local function arraycopy(value)
  local result = {}
  for i, item in ipairs(value or {}) do result[i] = copy(item) end
  return result
end

local function toSurface(node)
  if type(node) ~= 'table' then return nil end
  local kind = ({OutputRef='output',SourceRef='source',XyzRef='xyz',VelRef='vel',
    RgbaRef='rgba',MeshRef='mesh',VolRef='vol',GeoRef='geo'})[node.type]
  if kind then return {kind=kind,name=node.name} end
  if node.type == 'Ident' then
    if node.name == 'none' then return {kind='output',name='none'} end
    if stateSurfaces[node.name] then return {kind='state',name=node.name} end
  end
  return nil
end

local function starter(effect)
  if effect.starter~=nil then return effect.starter end
  local passes = effect.passes or {}
  if #passes == 0 then return true end
  for _, pass in ipairs(passes) do
    for _, value in pairs(pass.inputs or {}) do
      if value == 'inputTex' or value == 'inputTex3d' or type(value) == 'string' and value:match('^o[0-7]$') then
        return false
      end
    end
  end
  return true
end

local function clamp(value, def)
  if type(value) ~= 'number' then return value end
  if type(def.min) == 'number' and value < def.min then return def.min end
  if type(def.max) == 'number' and value > def.max then return def.max end
  return value
end

local function enumValue(path, symbols)
  if type(path) == 'string' then
    local parts = {}
    for part in path:gmatch('[^.]+') do parts[#parts+1] = part end
    path = parts
  end
  if type(path) ~= 'table' or #path == 0 then return nil end
  if symbols[path[1]] then
    local symbol = symbols[path[1]]
    if #path == 1 then return symbol.value or symbol end
  end
  if #path >= 4 then
    local effect = registry.getEffect(path[1] .. '.' .. path[2])
    local definition = effect and effect.globals and effect.globals[path[3]]
    return definition and definition.choices and definition.choices[path[4]] or nil
  end
  if #path == 2 and path[1]=='palette' then return require('noisemaker.catalog.palettes').names[path[2]] end
  local standard = {
    channel={r=0,g=1,b=2,a=3}, color={mono=0,rgb=1,hsv=2},
    oscType={sine=0,linear=1,sawtooth=2,sawtoothInv=3,square=4,noise1d=5,noise2d=6},
    oscKind={sine=0,tri=1,saw=2,sawInv=3,square=4,noise=5,noise1d=5,noise2d=6},
    midiMode={noteChange=0,gateNote=1,gateVelocity=2,triggerNote=3,velocity=4,cc=5,cc14=6,nrpn=7,pitchBend=8,pressure=9,polyPressure=10},
    midiZone={lower=0,upper=1}, audioBand={low=0,mid=1,high=2,vol=3,raw=4}
  }
  if #path == 2 then return standard[path[1]] and standard[path[1]][path[2]] end
  return nil
end

local function resolveArg(node, def, effectName, symbols, diagnostic)
  local kind = def.type == 'vec4' and 'color' or def.type
  node = substituteSymbol(node, symbols)
  if node and node.type == 'ArrayLiteral' then
    local result = {}
    for _, element in ipairs(node.elements or {}) do
      if element.type == 'Number' then result[#result+1] = element.value
      else diagnostic('S002', element, "Array element must be a number for '" .. def.name .. "' in " .. effectName .. '()'); result[#result+1] = 0 end
    end
    return result, 'array'
  end
  if kind == 'surface' then
    if node and node.type == 'String' then diagnostic('S001', node, "String literal not allowed for surface parameter '" .. def.name .. "'") end
    local surface = toSurface(node)
    if node and node.type == 'Read' then surface = toSurface(node.surface) end
    if node and node.type == 'Call' and node.name == 'read' then surface = toSurface((node.args or {})[1] or (node.kwargs or {}).tex) end
    if surface then return surface end
    if def.default then return toSurface({type='Ident',name=def.default}) or {kind='pipeline',name=def.default} end
    if not node then diagnostic('S001', {type='Call',name=effectName}, "Missing required surface argument '" .. def.name .. "' for " .. effectName .. '()')
    else diagnostic('S001', node, "Invalid surface reference '" .. tostring(node.name or node.type) .. "' for '" .. def.name .. "' in " .. effectName .. '()') end
    return NULL
  end
  if kind == 'volume' or kind == 'geometry' then
    local prefix = kind == 'volume' and 'vol' or 'geo'
    local name = node and node.name or def.default
    if name and (name == 'none' or name:match('^' .. prefix .. '[0-7]$')) then
      return {kind=prefix,name=name}
    end
    if node then diagnostic('S001', node, 'Invalid ' .. kind .. " reference '" .. tostring(name) .. "' for '" .. def.name .. "'") end
    return def.default and {kind=prefix,name=def.default} or NULL
  end
  if node and node.type == 'Call' and #(node.args or {}) == (node.name == 'vec2' and 2 or 4) and (
    (kind == 'vec2' and node.name == 'vec2') or
    (kind == 'color' and node.name == 'vec4' and type(def.default) == 'table' and def.default ~= NULL and #def.default == 4)) then
    -- vec2(x, y) on a vec2 parameter, and vec4(x, y, z, w) on a vec4 parameter, which upstream
    -- registers as `color` with its four-component default. Any other form, including a wrong
    -- component count, takes the branches below.
    local result = {}
    for i, element in ipairs(node.args) do
      if element.type == 'Number' then result[i] = element.value
      else diagnostic('S002',element,"Argument out of range for '" .. def.name .. "' in " .. effectName .. '()'); result[i] = 0 end
    end
    return result
  end
  if kind == 'color' then
    if node and node.type == 'Color' then return node.hex or copy(node.value) end
    if node and node.type == 'String' then diagnostic('S001',node,"String literal not allowed for color parameter '" .. def.name .. "'")
    elseif node and node.type ~= 'Ident' then diagnostic('S002',node,"Argument out of range for '" .. def.name .. "' in " .. effectName .. '()') end
    return copy(def.default)
  end
  if kind == 'vec3' or kind == 'vec4' then
    local size = kind == 'vec3' and 3 or 4
    if node and node.type == 'Call' and node.name == kind and #(node.args or {}) == size then
      local result = {}
      for i, element in ipairs(node.args) do
        if element.type == 'Number' then result[i] = element.value
        else diagnostic('S002',element,"Argument out of range for '" .. def.name .. "' in " .. effectName .. '()'); result[i] = 0 end
      end
      return result
    end
    if node and node.type == 'Color' then
      local result = {}
      for i=1,size do result[i] = node.value[i] end
      return result
    end
    if node and node.type == 'String' then diagnostic('S001',node,"String literal not allowed for " .. kind .. " parameter '" .. def.name .. "'") end
    return copy(def.default or (size == 3 and {0,0,0} or {0,0,0,1}))
  end
  if kind == 'string' then
    local func = effectName:match('%.([^.]*)$') or effectName
    if not stringAllow[func .. '.' .. def.name] then
      diagnostic('S001',node or {type='Call',name=func}, "String parameter '" .. def.name .. "' on effect '" .. func .. "' is NOT in the allowed string params list. String params are strictly controlled - use enums or choices instead.")
      return def.default
    end
    if not node then return def.default end
    if node.type == 'String' then return node.value end
    if node.type == 'Ident' and def.choices and def.choices[node.name] ~= nil then return def.choices[node.name] end
    diagnostic('S001',node,"String parameter '" .. def.name .. "' requires a quoted string literal, got " .. node.type)
    return def.default
  end
  if node and node.type == 'String' then
    diagnostic('S001',node,"String literal not allowed for numeric parameter '" .. def.name .. "' - strings are only valid for type: \"string\" parameters")
    return copy(def.default)
  end
  if kind == 'boolean' then
    if node and node.type == 'Boolean' then return node.value end
    if node and node.type == 'Number' then return node.value ~= 0 end
    if node and node.type == 'Ident' and stateValues[node.name] then
      local key=node.name
      return {fn=function(state) return values.truthy(state[key]) end}
    end
    if node and node.type == 'Func' then
      local fn,err=require('noisemaker.compiler.expressions').compile(node.src)
      if not fn then diagnostic('S001',node,"Invalid function for '" .. def.name .. "': '" .. tostring(node.src):sub(1,50) .. "'"); return def.default==true end
      -- _ast keeps the source text, as upstream keeps it for its unparser.
      return {fn=function(state) return values.truthy(fn(state)) end,_ast=copy(node)}
    end
    return def.default == true
  end
  if node and node.type == 'Func' then
    local fn,err=require('noisemaker.compiler.expressions').compile(node.src)
    if not fn then diagnostic('S001',node,"Invalid function for '" .. def.name .. "': '" .. tostring(node.src):sub(1,50) .. "'"); return copy(def.default) end
    return {fn=fn,min=def.min,max=def.max,_ast=copy(node)}
  end
  if node and (node.type == 'Oscillator' or node.type == 'Midi' or node.type == 'Audio') then
    return require('noisemaker.runtime.automation').compileAST(node,function(path) return enumValue(path,symbols) end,diagnostic)
  end
  if node and node.type == 'Ident' and stateValues[node.name] and not (def.choices and type(def.choices[node.name]) == 'number') then
    local key=node.name
    return {fn=function(state) return state[key] end,min=def.min,max=def.max,_ast=copy(node)}
  end
  local number
  if node and node.type == 'Number' then number = node.value
  elseif node and node.type == 'Boolean' then number = node.value and 1 or 0
  elseif node and node.type == 'Member' then number = enumValue(node.path, symbols)
  elseif node and node.type == 'Ident' then
    if def.choices then number = def.choices[node.name] end
    if number == nil and (def.enumPath or def.enum) then
      local prefix = def.enumPath or def.enum
      number = enumValue(prefix .. '.' .. node.name, symbols)
    end
  end
  if type(number) == 'number' then
    if kind == 'member' then return number end
    local bounded = clamp(number, def)
    if bounded ~= number then diagnostic('S002',node,"Argument out of range for '" .. def.name .. "' in " .. effectName .. '() (got ' .. number .. ', clamped to ' .. bounded .. ')') end
    -- A number that a let supplied keeps its variable name, as upstream keeps it.
    if (node.type == 'Number' or node.type == 'Boolean') and node._varRef then return {_varRef=node._varRef,value=bounded} end
    return bounded
  end
  if node and node.type == 'Ident' then diagnostic('S003',node)
  elseif node and node.type ~= 'Member' then diagnostic('S002',node,"Argument out of range for '" .. def.name .. "' in " .. effectName .. '()') end
  if kind == 'member' then
    local fallback = enumValue(def.default, symbols)
    return fallback or 0
  end
  return copy(def.default)
end

function M.validate(ast)
  local diagnostics, plans, symbols, tempIndex = {}, {}, {}, 0
  local searchOrder = ast.namespace and ast.namespace.searchOrder or {}
  if #searchOrder == 0 then error("Missing required 'search' directive. Every program must start with 'search <namespace>, ...' to specify namespace search order.") end
  local readsBeforeLet = setmetatable({}, {__mode='k'})
  local previousReads = activeReads
  activeReads = readsBeforeLet
  local function diagnostic(code, node, message)
    if type(node) == 'table' and readsBeforeLet[node] then return end
    local name
    if node then
      if node.type == 'Ident' or node.type == 'Call' then name=node.name
      elseif node.type == 'Member' and type(node.path)=='table' then name=table.concat(node.path,'.')
      elseif node.type == 'Func' and node.src then
        name='{' .. node.src:sub(1,30) .. (#node.src>30 and '...' or '') .. '}'
      elseif node.name then name=node.name
      elseif values.truthy(node.value) then name=tostring(node.value)
      else name='[' .. tostring(node.type or 'unknown') .. ']' end
    end
    local text = message or messages[code]
    if name and not text:find(name,1,true) and not text:find("'",1,true) then text = text .. ": '" .. name .. "'" end
    local item = {code=code,message=text,severity=(code == 'S002' or code == 'S007' or code == 'S008') and 'warning' or 'error'}
    item.nodeId = node and node.id or values.UNDEFINED
    if node and node.loc then item.location = {line=node.loc.line,column=node.loc.column or node.loc.col} end
    if name then item.identifier = tostring(name) end
    diagnostics[#diagnostics+1] = item
  end
  local function declareVar(declaration)
    local expr = copy(declaration.expr)
    if not expr or expr == NULL or expr.type == 'Ident' and (expr.name == 'null' or expr.name == 'undefined') then
      diagnostic('S004',declaration)
    else symbols[declaration.name] = expr end
  end
  -- Top-level lets are declared in statement order: each statement sees the lets written
  -- before it, and the latest assignment of a name wins. `pendingLets` holds the names of the
  -- lets that come after the current statement.
  local topLevelVars = ast.vars or {}
  local nextVar, pendingLets = 1, {}
  local function declareVarsBefore(planIndex)
    while nextVar <= #topLevelVars and (topLevelVars[nextVar].planIndex or 0) <= planIndex do
      declareVar(topLevelVars[nextVar])
      nextVar = nextVar + 1
    end
    pendingLets = {}
    for i = nextVar, #topLevelVars do pendingLets[topLevelVars[i].name] = true end
  end
  -- A statement that reads a variable before any let assigns it gets S003 "Variable used
  -- before assignment" at the identifier. Other diagnostics for that identifier are not added.
  local function reportReadsBeforeLet(node)
    if next(pendingLets) == nil or type(node) ~= 'table' or node == NULL or node == values.UNDEFINED then return end
    if node.type == 'Ident' and pendingLets[node.name] and not symbols[node.name] then
      if not readsBeforeLet[node] then
        local position = node.position
        diagnostic('S003', position and {type='Ident',name=node.name,loc={line=position.line,column=position.column}}
          or {type='Ident',name=node.name})
        readsBeforeLet[node] = true
      end
      return
    end
    for _, key in ipairs(values.keys(node)) do reportReadsBeforeLet(node[key]) end
  end
  local function resolveName(call)
    local order = call.namespace and call.namespace.searchOrder or searchOrder
    if call.namespace and call.namespace.resolved then
      local candidate = call.namespace.resolved .. '.' .. call.name
      if registry.getEffect(candidate) then return candidate end
    end
    for _, namespace in ipairs(order or {}) do
      local candidate = namespace .. '.' .. call.name
      if registry.getEffect(candidate) then return candidate end
    end
    return nil
  end
  local function processStatement(stmt,nested,input)
    local chain = {}
    local hasWrite = stmt.write and stmt.write ~= NULL or stmt.write3d and stmt.write3d ~= NULL
    if not hasWrite and not nested then
      if stmt.chain and stmt.chain[1] and stmt.chain[1].type == 'Call' then
        local name = resolveName(stmt.chain[1])
        if name and starter(registry.getEffect(name)) then diagnostic('S006',stmt.chain[1]) end
      end
      diagnostic('S001',(stmt.chain or {})[1], 'Chain must have explicit write() or write3d() target')
      return nil
    end
    local current = input or NULL
    local writeName = stmt.write and stmt.write ~= NULL and stmt.write.name or nil
    local function add(op,args,from,builtin,original)
      local index = tempIndex; tempIndex = tempIndex + 1
      local step = {op=op,args=args,from=from,temp=index}
      if builtin then step.builtin=true end
      if original and original.leadingComments then step.leadingComments=copy(original.leadingComments) end
      chain[#chain+1] = step
      current = index
      return step
    end
    for _, original in ipairs(stmt.chain or {}) do
      if original.type == 'Read' then
        local surface = toSurface(original.surface)
        if current ~= NULL then diagnostic('S001',original,'read() is a starter node and cannot be chained inline. Use standalone read() to start a new chain.')
        elseif not surface then diagnostic('S001',original,'read() requires a valid surface reference')
        else add('_read',{tex=surface},NULL,true,original) end
      elseif original.type == 'Write' then
        local surface = toSurface(original.surface)
        if not surface then diagnostic('S001',original,'write() requires a valid surface reference')
        elseif current == NULL then diagnostic('S005',original,'write() requires an input - cannot be first in chain')
        else add('_write',{tex=surface},current,true,original) end
      elseif original.type == 'Read3D' or original.type == 'Write3D' then
        local tex3d = original.tex3d and original.tex3d ~= NULL and {kind='vol',name=original.tex3d.name}
        local geo = original.geo and original.geo ~= NULL and {kind='geo',name=original.geo.name}
        if not tex3d or not geo then diagnostic('S001',original,original.type:lower() .. '() requires tex3d and geo references')
        elseif original.type == 'Read3D' and current ~= NULL then diagnostic('S001',original,'read3d() is a starter node and cannot be chained inline. Use standalone read3d() to start a new chain.')
        elseif original.type == 'Write3D' and current == NULL then diagnostic('S005',original,'write3d() requires an input - cannot be first in chain')
        else add(original.type == 'Read3D' and '_read3d' or '_write3d',{tex3d=tex3d,geo=geo},current,true,original) end
      elseif original.type == 'Subchain' then
        for _,report in ipairs(original.subchainArgumentDiagnostics or {}) do
          diagnostics[#diagnostics+1]={code=report.code,message=report.message,severity=report.severity,nodeId=original.id,location=report.location}
        end
        if current==NULL then diagnostic('S005',original,'subchain() requires an input - cannot be first in chain')
        else
          local args={name=original.name or NULL,id=original.id or NULL}
          add('_subchain_begin',args,current,true,original)
          local nestedPlan=processStatement({chain=original.body},true,current)
          for _,nestedStep in ipairs(nestedPlan.chain) do chain[#chain+1]=nestedStep end
          current=nestedPlan.final
          add('_subchain_end',copy(args),current,true)
        end
      elseif original.type == 'Call' then
        local call = copy(original)
        local merged = false
        if symbols[call.name] and symbols[call.name].type == 'Call' then
          merged = true
          local saved = symbols[call.name]
          call.name = saved.name
          local args = arraycopy(saved.args)
          for _, arg in ipairs(call.args or {}) do args[#args+1] = arg end
          call.args = args
          local kwargs = copy(saved.kwargs or {})
          for key,value in pairs(call.kwargs or {}) do kwargs[key] = value end
          call.kwargs = kwargs
        end
        local name = resolveName(call)
        if not name then diagnostic('S001',original,"Unknown effect: '" .. call.name .. "'")
        else
          local effect = registry.getEffect(name)
          if effect.hidden and effect.deprecatedBy then
            diagnostic('S008',original,"effect '" .. call.name .. "' is deprecated, use '" .. effect.deprecatedBy .. "' instead.")
          end
          local root = current == NULL
          if root and not starter(effect) then diagnostic('S005',original)
          else
            if not root and starter(effect) then diagnostic('S005',original) end
            local from = (root or starter(effect)) and NULL or current
            local kwargs = copy(call.kwargs or {})
            -- Resolve deprecated parameter aliases (upstream resolveParamAliases): the canonical
            -- name takes the alias's value unless both are given, and each alias warns.
            if call.kwargs and effect.paramAliases then
              for _, oldName in ipairs(registry.keys(effect.paramAliases)) do
                if kwargs[oldName] ~= nil then
                  local newName = effect.paramAliases[oldName]
                  if kwargs[newName] == nil then kwargs[newName] = kwargs[oldName] end
                  kwargs[oldName] = nil
                  -- Upstream rewrites the call's own kwargs unless a let supplied the call.
                  local own = not merged and original.kwargs
                  if own and own[oldName] ~= nil then
                    if own[newName] == nil then values.set(own, newName, own[oldName]) end
                    own[oldName] = nil
                    local order = rawget(own, '__nm_order')
                    if order then for i = #order, 1, -1 do if order[i] == oldName then table.remove(order, i) end end end
                  end
                  diagnostic('S007', merged and {type='Call',name=call.name} or call,
                    "param '" .. oldName .. "' is deprecated, use '" .. newName .. "' instead. Aliases will be removed on " .. ALIAS_EOL_DATE .. '.')
                end
              end
            end
            local args, argSources, seen = {}, nil, {}
            local definitions = {}
            for _, key in ipairs(registry.keys(effect.globals or {})) do
              local def = effect.globals[key]
              definitions[#definitions+1] = {name=key,type=def.type,default=def.default,min=def.min,max=def.max,
                choices=def.choices,enum=def.enum,enumPath=def.enumPath,defaultFrom=def.defaultFrom}
            end
            for i, def in ipairs(definitions) do
              local node = kwargs[def.name] or (call.args or {})[i]
              if node then seen[def.name] = true end
              node=substituteSymbol(node,symbols)
              local value, source
              if def.type=='surface' and node and (node.type=='Chain' or node.type=='Call' and node.name~='read') then
                local nestedPlan=processStatement({chain=node.type=='Chain' and node.chain or {node}},true)
                if nestedPlan then
                  for _,nestedStep in ipairs(nestedPlan.chain) do chain[#chain+1]=nestedStep end
                  if nestedPlan.final~=NULL then value={kind='temp',index=nestedPlan.final} end
                end
                if not value then value=resolveArg(nil,def,call.name,symbols,diagnostic) end
              else value, source = resolveArg(node,def,call.name,symbols,diagnostic) end
              if value == nil and def.defaultFrom and args[def.defaultFrom] ~= nil then value = copy(args[def.defaultFrom]) end
              if value ~= nil then args[def.name] = value end
              if source then argSources=argSources or {}; argSources[def.name]=source end
            end
            if kwargs._skip then
              args._skip = kwargs._skip.type == 'Boolean' and kwargs._skip.value or false
              seen._skip = true
            end
            for key,node in pairs(kwargs) do
              if not seen[key] then diagnostic('S001',node,"Unknown argument '" .. key .. "' for " .. call.name .. '()') end
            end
            local step = add(name,args,from,false,original)
            if call.namespace then
              step.namespace = {call={name=call.namespace.name or NULL,resolved=call.namespace.resolved or NULL,
                explicit=call.namespace.explicit == true,source=call.namespace.source or NULL}}
              if call.namespace.searchOrder then step.namespace.call.searchOrder = arraycopy(call.namespace.searchOrder) end
              if call.namespace.resolved then step.namespace.resolved = call.namespace.resolved end
            end
            if original.kwargs and next(original.kwargs) then step.rawKwargs = copy(original.kwargs) end
            if argSources then step.argSources=argSources end
          end
        end
      else
        diagnostic('S001',original,'Unsupported chain node: ' .. tostring(original.type))
      end
    end
    local write = stmt.write and stmt.write ~= NULL and {kind='output',name=stmt.write.name} or NULL
    local write3d = stmt.write3d and stmt.write3d ~= NULL and {
      tex3d={kind='vol',name=stmt.write3d.tex3d.name},geo={kind='geo',name=stmt.write3d.geo.name}} or NULL
    local plan = {chain=chain,write=write,write3d=write3d,final=current,states={}}
    if stmt.leadingComments then plan.leadingComments=copy(stmt.leadingComments) end
    return plan
  end
  local function evalExpr(node)
    local expr = substituteSymbol(copy(node), symbols)
    if type(expr) == 'table' and expr.type == 'Chain' and expr.chain and expr.chain[1] and expr.chain[1].type == 'Call' then
      local name = resolveName(expr.chain[1])
      if name and starter(registry.getEffect(name)) then diagnostic('S006',expr.chain[1]) end
    end
    if type(expr) == 'table' and expr.type == 'Member' then
      local resolved = enumValue(expr.path, symbols)
      if type(resolved) == 'number' then return {type='Number',value=resolved} end
      if resolved ~= nil then return resolved end
    end
    return expr
  end
  local function evalCondition(node, depth)
    depth = depth or 0
    local expr = evalExpr(node)
    if type(expr) ~= 'table' or expr == NULL then return false end
    if expr.type == 'Number' then return toBoolean(expr.value) end
    if expr.type == 'Boolean' then return expr.value == true end
    if expr.type == 'Func' then
      local fn = require('noisemaker.compiler.expressions').compile(expr.src)
      if not fn then diagnostic('S001',expr,"Invalid function expression: '" .. tostring(expr.src):sub(1,50) .. "'"); return false end
      return {fn=function(state) return toBoolean(fn(state)) end}
    end
    if expr.type == 'Ident' then
      if symbols[expr.name] and depth < 64 then return evalCondition(symbols[expr.name], depth + 1) end
      if stateValues[expr.name] then
        local key = expr.name
        return {fn=function(state) return toBoolean(state[key]) end}
      end
      diagnostic('S003',expr)
      return false
    end
    if expr.type == 'Member' then
      local resolved = enumValue(expr.path, symbols)
      if resolved ~= nil then return toBoolean(resolved) end
      diagnostic('S001',expr,"Unknown enum path: '" .. (type(expr.path) == 'table' and table.concat(expr.path,'.') or 'unknown') .. "'")
      return false
    end
    return false
  end
  local compileStmt
  -- A let inside a block applies to the rest of that block only, so a block cannot change how
  -- statements outside it compile.
  local function compileBlock(body)
    local result, shadowed, order = values.array(), {}, {}
    if type(body) ~= 'table' or body == NULL then return result end
    for _, statement in ipairs(body) do
      if statement.type == 'VarAssign' then
        if shadowed[statement.name] == nil then
          order[#order+1] = statement.name
          shadowed[statement.name] = symbols[statement.name] ~= nil and {value=symbols[statement.name]} or false
        end
        declareVar(statement)
        -- Kept as the parser node, like the top-level vars entries
        result[#result+1] = statement
      else
        local compiled = compileStmt(statement)
        if compiled then result[#result+1] = compiled end
      end
    end
    for _, name in ipairs(order) do
      local previous = shadowed[name]
      if previous then symbols[name] = previous.value else symbols[name] = nil end
    end
    return result
  end
  compileStmt = function(statement)
    if statement.type == 'IfStmt' then
      reportReadsBeforeLet(statement.condition)
      local cond = evalCondition(statement.condition)
      local thenBranch = compileBlock(statement['then'])
      local elif = values.array()
      for _, branch in ipairs(statement.elif or {}) do
        reportReadsBeforeLet(branch.condition)
        local branchCond = evalCondition(branch.condition)
        elif[#elif+1] = {cond=branchCond,['then']=compileBlock(branch['then'])}
      end
      local elseBranch = compileBlock(statement['else'])
      return {type='Branch',cond=cond,['then']=thenBranch,elif=elif,['else']=elseBranch}
    end
    if statement.type == 'Break' then return {type='Break'} end
    if statement.type == 'Continue' then return {type='Continue'} end
    if statement.type == 'Return' then
      local node = {type='Return'}
      if statement.value ~= nil and statement.value ~= NULL then
        reportReadsBeforeLet(statement.value)
        node.value = evalExpr(statement.value)
      end
      return node
    end
    reportReadsBeforeLet(statement.chain)
    return processStatement(statement)
  end
  -- Statements compile in order. Lets that come after the last statement are still declared,
  -- so their own checks run.
  for index, statement in ipairs(ast.plans or {}) do
    declareVarsBefore(index - 1)
    local plan = compileStmt(statement)
    if plan then plans[#plans+1] = plan end
  end
  declareVarsBefore(math.huge)
  activeReads = previousReads
  local render = ast.render and ast.render ~= NULL and ast.render.name or NULL
  local result = {plans=plans,diagnostics=diagnostics,render=render,vars=arraycopy(ast.vars),searchNamespaces=arraycopy(searchOrder)}
  if ast.trailingComments then result.trailingComments=copy(ast.trailingComments) end
  return result
end

return M
