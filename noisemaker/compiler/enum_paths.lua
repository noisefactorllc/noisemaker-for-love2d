local M={}
function M.normalizeMemberPath(value)
  if value==nil or value==false then return nil end
  local parts={}
  if type(value)=='table' then
    for _,v in ipairs(value) do if type(v)=='string' and #v>0 then parts[#parts+1]=v end end
  elseif type(value)=='string' then
    for part in value:gmatch('[^.]+') do
      local trimmed=part:match('^%s*(.-)%s*$')
      if #trimmed>0 then parts[#parts+1]=trimmed end
    end
  elseif type(value)=='number' then parts[1]=tostring(value)
  else return nil end
  return #parts>0 and parts or nil
end
function M.pathStartsWith(path,prefix)
  if type(prefix)~='table' or #prefix==0 then return true end
  if type(path)~='table' or #path<#prefix then return false end
  for i=1,#prefix do if path[i]~=prefix[i] then return false end end
  return true
end
local function suffix(path,first)
  local out={}
  for i=first,#path do out[#out+1]=path[i] end
  return out
end
local function head(path,last)
  local out={}
  for i=1,last do out[#out+1]=path[i] end
  return out
end
local function concat(a,b)
  local out={}
  for _,v in ipairs(a) do out[#out+1]=v end
  for _,v in ipairs(b) do out[#out+1]=v end
  return out
end
function M.applyEnumPrefix(path,prefix)
  if type(path)~='table' or #path==0 then return path end
  if type(prefix)~='table' or #prefix==0 then return suffix(path,1) end
  if M.pathStartsWith(path,prefix) then return suffix(path,1) end
  for i=2,#prefix do
    if M.pathStartsWith(path,suffix(prefix,i)) then return concat(head(prefix,i-1),path) end
  end
  return concat(prefix,path)
end
function M.stripEnumPrefix(path,prefix)
  path=M.normalizeMemberPath(path)
  prefix=M.normalizeMemberPath(prefix)
  if not path or not prefix then return path end
  if M.pathStartsWith(path,prefix) then return suffix(path,#prefix+1) end
  for i=#prefix,2,-1 do
    local ending=suffix(prefix,i)
    if M.pathStartsWith(path,ending) then return suffix(path,#ending+1) end
  end
  return path
end
return M
