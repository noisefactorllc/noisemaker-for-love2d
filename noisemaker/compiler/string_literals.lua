local json=require('noisemaker.json')
local M={}
function M.decodeJsonStringLiteralContent(raw)
  local ok,value=pcall(json.decode,'"'..raw..'"')
  if ok and type(value)=='string' then return value end
  local escapes={['\'']='\'',['"']='"',['\\']='\\',n='\n',r='\r',t='\t',b='\b',f='\f',v='\v',['0']='\0'}
  local out={}
  local i=1
  while i<=#raw do
    local c=raw:sub(i,i)
    if c=='\\' and i<#raw then
      local nextChar=raw:sub(i+1,i+1)
      out[#out+1]=escapes[nextChar] or ('\\'..nextChar)
      i=i+2
    else out[#out+1]=c;i=i+1 end
  end
  return table.concat(out)
end
return M
