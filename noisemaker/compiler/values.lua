local bit = require('bit')
local M = {}
M.NULL = setmetatable({}, { __tostring = function() return 'null' end })
M.UNDEFINED = setmetatable({}, { __tostring = function() return 'undefined' end })
local array_mt = { __nm_kind = 'array' }
local object_mt = { __nm_kind = 'object' }
local function arrayIndex(key)
  local number = type(key)=='number' and key or type(key)=='string' and tonumber(key) or nil
  if number and number>=0 and number<4294967295 and number%1==0 and tostring(number)==tostring(key) then return number end
end
local function keyLess(a,b)
  local ai,bi=arrayIndex(a),arrayIndex(b)
  if ai and bi then return ai<bi end
  if ai then return true end
  if bi then return false end
  return tostring(a)<tostring(b)
end
function M.array(items) return setmetatable(items or {}, array_mt) end
function M.object(items)
  local out = setmetatable(items or {}, object_mt)
  if not rawget(out, '__nm_order') then
    local order = {}
    for key in pairs(out) do
      if key ~= '__nm_order' then order[#order + 1] = key end
    end
    table.sort(order, keyLess)
    rawset(out, '__nm_order', order)
  end
  return out
end
function M.isArray(v) return type(v) == 'table' and getmetatable(v) == array_mt end
function M.isObject(v) return type(v) == 'table' and getmetatable(v) == object_mt end
function M.isNull(v) return v == M.NULL end
function M.isUndefined(v) return v == M.UNDEFINED or v == nil end
function M.set(obj, key, value)
  if rawget(obj, key) == nil then
    local order = rawget(obj, '__nm_order')
    if order then order[#order + 1] = key end
  end
  rawset(obj, key, value)
  return obj
end
function M.keys(obj)
  local order = rawget(obj, '__nm_order')
  if order then
    local copy = {}
    for i = 1, #order do copy[i] = order[i] end
    return copy
  end
  local keys = {}
  for key in pairs(obj) do if key ~= '__nm_order' then keys[#keys+1] = key end end
  table.sort(keys, keyLess)
  return keys
end
function M.truthy(value)
  if value == nil or value == false or value == M.NULL or value == M.UNDEFINED then return false end
  if type(value) == 'number' and (value == 0 or value ~= value) then return false end
  if value == '' then return false end
  return true
end
function M.utf16(source)
  local units, starts, ends = {}, {}, {}
  local byte = 1
  while byte <= #source do
    local b = source:byte(byte)
    local cp, width
    if b < 128 then cp, width = b, 1
    elseif b >= 194 and b <= 223 then cp, width = b - 192, 2
    elseif b >= 224 and b <= 239 then cp, width = b - 224, 3
    elseif b >= 240 and b <= 244 then cp, width = b - 240, 4
    else cp, width = 65533, 1 end
    if width > 1 then
      local valid = byte + width - 1 <= #source
      if valid then
        for j=1,width-1 do
          local tail = source:byte(byte+j)
          if tail < 128 or tail > 191 then valid = false; break end
          cp = cp * 64 + tail - 128
        end
      end
      if not valid or cp > 1114111 or (cp >= 55296 and cp <= 57343) or
         (width == 2 and cp < 128) or (width == 3 and cp < 2048) or (width == 4 and cp < 65536) then
        cp, width = 65533, 1
      end
    end
    if cp <= 65535 then
      units[#units+1], starts[#starts+1], ends[#ends+1] = cp, byte, byte+width-1
    else
      cp = cp - 65536
      local start = byte
      units[#units+1], starts[#starts+1], ends[#ends+1] = 55296 + math.floor(cp/1024), start, byte+width-1
      units[#units+1], starts[#starts+1], ends[#ends+1] = 56320 + cp%1024, start, byte+width-1
    end
    byte = byte + width
  end
  return units, starts, ends
end
function M.hashSource(source)
  local units = M.utf16(source)
  local hash = 0
  for i=1,#units do hash = bit.tobit(hash * 31 + units[i]) end
  if hash == 0 then return '0' end
  local negative = hash < 0
  local value = math.abs(hash)
  local chars = '0123456789abcdefghijklmnopqrstuvwxyz'
  local s = ''
  while value > 0 do
    local digit = value % 36
    s = chars:sub(digit+1,digit+1) .. s
    value = math.floor(value/36)
  end
  return (negative and '-' or '') .. s
end
return M
