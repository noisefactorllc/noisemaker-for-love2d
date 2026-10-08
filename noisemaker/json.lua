-- JSON transport for development runners and data-only graph imports.
-- Images stay binary; this codec is not an image transport.
local v = require('noisemaker.compiler.values')
local M = {null=v.NULL}
local function utf8(n)
 if n<128 then return string.char(n) end
 if n<2048 then return string.char(192+math.floor(n/64),128+n%64) end
 if n<65536 then return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64) end
 return string.char(240+math.floor(n/262144),128+math.floor(n/4096)%64,128+math.floor(n/64)%64,128+n%64)
end
function M.decode(s)
 assert(type(s)=='string','JSON input must be a string')
 local i,n=1,#s
 local function fail(message) error('JSON at byte '..i..': '..message,0) end
 local function space() local _,last=s:find('^[ \t\r\n]*',i); i=(last or i-1)+1 end
 local function str()
  i=i+1; local out={}
  while i<=n do
   local c=s:sub(i,i); i=i+1
   if c=='"' then return table.concat(out) end
   if c=='\\' then
    local e=s:sub(i,i); i=i+1
    local escapes={['"']='"',['\\']='\\',['/']='/',b='\b',f='\f',n='\n',r='\r',t='\t'}
    if escapes[e] then out[#out+1]=escapes[e]
    elseif e=='u' then
     local hex=s:sub(i,i+3); if not hex:match('^%x%x%x%x$') then fail('invalid Unicode escape') end
     local cp=tonumber(hex,16); i=i+4
     if cp>=0xD800 and cp<=0xDBFF then
      if s:sub(i,i+1)~='\\u' then fail('unpaired high surrogate') end
      local low=tonumber(s:sub(i+2,i+5),16)
      if not low or low<0xDC00 or low>0xDFFF then fail('invalid low surrogate') end
      cp=0x10000+(cp-0xD800)*1024+low-0xDC00; i=i+6
     elseif cp>=0xDC00 and cp<=0xDFFF then fail('unpaired low surrogate') end
     out[#out+1]=utf8(cp)
    else fail('invalid escape') end
   elseif c:byte()<32 then fail('control character in string')
   else out[#out+1]=c end
  end
  fail('unterminated string')
 end
 local value
 value=function(depth)
  if depth>256 then fail('maximum nesting exceeded') end
  space(); local c=s:sub(i,i)
  if c=='"' then return str() end
  if c=='[' or c=='{' then
   local array=c=='['; local result=array and v.array() or v.object(); i=i+1; space()
   local closing=array and ']' or '}'
   if s:sub(i,i)==closing then i=i+1; return result end
   while true do
    if array then result[#result+1]=value(depth+1)
    else
     if s:sub(i,i)~='"' then fail('object key must be a string') end
     local key=str(); space(); if s:sub(i,i)~=':' then fail('expected colon') end
     if rawget(result,key)~=nil then fail('duplicate object key') end
     i=i+1; v.set(result,key,value(depth+1))
    end
    space(); c=s:sub(i,i); i=i+1
    if c==closing then return result end
    if c~=',' then fail('expected comma or '..closing) end
    space()
   end
  end
  for word,result in pairs({['true']=true,['false']=false,['null']=v.NULL}) do
   if s:sub(i,i+#word-1)==word then i=i+#word; return result end
  end
  local start=i
  if c=='-' then i=i+1 end
  if s:sub(i,i)=='0' then i=i+1
  elseif s:sub(i,i):match('[1-9]') then repeat i=i+1 until not s:sub(i,i):match('%d')
  else fail('expected value') end
  if s:sub(i,i)=='.' then
   i=i+1; if not s:sub(i,i):match('%d') then fail('expected fraction digits') end
   repeat i=i+1 until not s:sub(i,i):match('%d')
  end
  if s:sub(i,i):match('[eE]') then
   i=i+1; if s:sub(i,i):match('[+-]') then i=i+1 end
   if not s:sub(i,i):match('%d') then fail('expected exponent digits') end
   repeat i=i+1 until not s:sub(i,i):match('%d')
  end
  local number=tonumber(s:sub(start,i-1))
  if not number or number==math.huge or number==-math.huge then fail('nonfinite number') end
  return number
 end
 local result=value(0); space(); if i<=n then fail('trailing input') end; return result
end
local function quote(s)
 return '"'..s:gsub('[%z\1-\31\\"]',function(c)
  local escapes={['"']='\\"',['\\']='\\\\',['\n']='\\n',['\r']='\\r',['\t']='\\t'}
  return escapes[c] or string.format('\\u%04x',c:byte())
 end)..'"'
end
function M.encode(value)
 local seen={}
 local function encode(x,depth)
  if depth>256 then error('JSON maximum nesting exceeded') end
  if x==nil or x==v.NULL then return 'null' end
  if x==v.UNDEFINED then error('JSON undefined value') end
  local t=type(x)
  if t=='string' then return quote(x) end
  if t=='boolean' then return tostring(x) end
  if t=='number' then assert(x==x and x~=math.huge and x~=-math.huge,'JSON nonfinite number'); return string.format('%.17g',x) end
  assert(t=='table','JSON unsupported '..t); assert(not seen[x],'JSON cycle'); seen[x]=true
  local out={}
  if v.isArray(x) or (not v.isObject(x) and #x>0) then
   for j=1,#x do out[j]=encode(x[j],depth+1) end
   seen[x]=nil; return '['..table.concat(out,',')..']'
  end
  for _,key in ipairs(v.keys(x)) do
   assert(type(key)=='string','JSON object key must be string')
   if key~='__nm_order' and x[key]~=v.UNDEFINED then out[#out+1]=quote(key)..':'..encode(x[key],depth+1) end
  end
  seen[x]=nil; return '{'..table.concat(out,',')..'}'
 end
 return encode(value,0)
end
return M
