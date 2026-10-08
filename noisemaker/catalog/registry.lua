local encoded = require('noisemaker.catalog.definitions')

local M = {}
local effects = {}
local order = setmetatable({}, {__mode = 'k'})

local function decode(value)
  if type(value) ~= 'table' then return value end
  if value.__nm_type == 'null' then return require('noisemaker.compiler.values').NULL end
  if value.__nm_type == 'array' then
    local result = {}
    for i, item in ipairs(value.items) do result[i] = decode(item) end
    return result
  end
  assert(value.__nm_type == 'object', 'invalid catalog value')
  local result, keys = {}, {}
  for _, entry in ipairs(value.entries) do
    result[entry[1]] = decode(entry[2])
    keys[#keys + 1] = entry[1]
  end
  order[result] = keys
  return result
end

function M.keys(object)
  local keys = order[object]
  if keys then local result={};for i,key in ipairs(keys) do result[i]=key end;return result end
  if type(object) == 'table' and rawget(object, '__nm_order') then
    return require('noisemaker.compiler.values').keys(object)
  end
  keys = {}
  for key in pairs(object or {}) do if key ~= '__nm_order' then keys[#keys + 1] = key end end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

function M.orderedObject()
  local object={}
  order[object]={}
  return object
end

function M.set(object,key,value)
  if object[key]==nil then
    local keys=order[object]
    if keys then keys[#keys+1]=key end
  end
  object[key]=value
end

function M.getEffect(name)
  return effects[name]
end

function M.getAllEffects()
  return effects
end

function M.registerEffect(name, definition)
  if type(name)=='table' and definition==nil then definition=name; name=nil end
  local validationDefinition=definition
  if type(definition)=='table' and definition.starter~=nil then
    if type(definition.starter)~='boolean' then
      return nil,{{stage='registration',severity='error',code='ERR_PORTABLE_DEFINITION',message='"starter" must be a boolean'}}
    end
    validationDefinition={}
    for key,value in pairs(definition) do
      if key~='starter' then validationDefinition[key]=value end
    end
  end
  local errors=require('noisemaker.catalog.effect_validator').validateEffectDefinition(validationDefinition)
  if #errors>0 then
    local diagnostics={}
    for _,message in ipairs(errors) do diagnostics[#diagnostics+1]={stage='registration',severity='error',code='ERR_PORTABLE_DEFINITION',message=message} end
    return nil,diagnostics
  end
  local namespace=definition.namespace or 'user'
  local func=definition.func
  if type(func)~='string' or not func:match('^[A-Za-z_][A-Za-z0-9_]*$') then
    return nil,{{stage='registration',severity='error',code='ERR_PORTABLE_FUNCTION',message='Portable effect func must be a DSL identifier'}}
  end
  for _,pass in ipairs(definition.passes or {}) do
    local shaders=definition.shaders and definition.shaders[pass.program]
    if not shaders or not (type(shaders.glsl)=='string' and shaders.glsl~='' or
      type(shaders.vertex)=='string' and shaders.vertex~='' and type(shaders.fragment)=='string' and shaders.fragment~='') then
      return nil,{{stage='registration',severity='error',code='ERR_PORTABLE_GLSL_REQUIRED',
        message='Portable effect program '..tostring(pass.program)..' requires GLSL source'}}
    end
  end
  local primary=name or namespace .. '.' .. func
  effects[primary]=definition
  effects[namespace .. '.' .. func]=definition
  effects[namespace .. '/' .. (definition.name or func)]=definition
  effects[func]=definition
  return true
end

function M.unregisterEffect(name)
  local exists = effects[name] ~= nil
  effects[name] = nil
  return exists
end

function M.attachShaders(name, shaders)
  local effect = effects[name]
  if not effect then return nil, 'unknown effect: ' .. tostring(name) end
  effect.shaders = shaders
  return true
end

for _, entry in ipairs(encoded.entries) do
  local id, definition = entry[1], decode(entry[2])
  local namespace, name = id:match('^([^/]+)/(.+)$')
  local func = definition.func
  effects[id] = definition
  effects[namespace .. '.' .. name] = definition
  if func then
    effects[func] = definition
    effects[namespace .. '.' .. func] = definition
  end
end

return M
