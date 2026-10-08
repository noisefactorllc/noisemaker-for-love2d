-- Lower dynamic fixed-array indexes to the bounded form emitted by Firefox's
-- WebGL2 translator. The lexer supplies significant tokens and source offsets;
-- original shader files remain byte-for-byte unchanged.
local M={}
local builtinTypes={float=true,int=true,uint=true,bool=true,
 sampler2D=true,sampler3D=true,samplerCube=true,sampler2DArray=true,
 sampler2DShadow=true,samplerCubeShadow=true,sampler2DArrayShadow=true,
 isampler2D=true,isampler3D=true,isamplerCube=true,isampler2DArray=true,
 usampler2D=true,usampler3D=true,usamplerCube=true,usampler2DArray=true}
for _,prefix in ipairs({'vec','ivec','uvec','bvec'}) do
 for n=2,4 do builtinTypes[prefix..n]=true end
end
for rows=2,4 do
 builtinTypes['mat'..rows]=true
 for columns=2,4 do builtinTypes['mat'..rows..'x'..columns]=true end
end
local function bracketClose(code,start)
 local depth=0
 for i=start,#code do
  if code[i].text=='[' then depth=depth+1
  elseif code[i].text==']' then depth=depth-1;if depth==0 then return i end end
 end
end
local function matching(code,start,opening,closing)
 local depth=0
 for i=start,#code do
  if code[i].text==opening then depth=depth+1
  elseif code[i].text==closing then depth=depth-1;if depth==0 then return i end end
 end
end
local function statementEnd(code,start)
 local token=code[start] and code[start].text
 if not token then return nil end
 if token=='{' then return matching(code,start,'{','}') end
 if token=='for' or token=='while' or token=='if' or token=='switch' then
  local header=code[start+1] and code[start+1].text=='(' and start+1
  local close=header and matching(code,header,'(',')')
  local ending=close and statementEnd(code,close+1)
  if token=='if' and ending and code[ending+1] and code[ending+1].text=='else' then
   return statementEnd(code,ending+2)
  end
  return ending
 end
 if token=='do' then
  local ending=statementEnd(code,start+1)
  if not ending then return nil end
  for i=ending+1,#code do if code[i].text==';' then return i end end
 end
 local parens,brackets=0,0
 for i=start,#code do
  local value=code[i].text
  if value=='(' then parens=parens+1 elseif value==')' then parens=parens-1
  elseif value=='[' then brackets=brackets+1 elseif value==']' then brackets=brackets-1
  elseif value==';' and parens==0 and brackets==0 then return i end
 end
end
local function lookup(scopes,name)
 for i=#scopes,1,-1 do if scopes[i][name] then return scopes[i][name] end end
end
local function dynamicIndex(code,first,last,scopes,macros,types)
 -- Numeric and const expressions keep their authored compiler diagnostics.
 -- In particular, an invalid constant index must not become an accepted read.
 for i=first,last do
  local token=code[i]
  if token.kind=='identifier' and not types[token.text] and not macros[token.text] then
   local symbol=lookup(scopes,token.text)
   if not symbol or not symbol.constant then return true end
  end
 end
 return false
end
function M.append(code,edits,macros,helperName)
 local scopes,parens,pending={{}},{},nil
 local declaration,parenDepth=nil,0
 local lowered=false
 local loopEnds={}
 macros=macros or {}
 helperName=helperName or 'nmArrayIndexValue'
 local types={}
 for name in pairs(builtinTypes) do types[name]=true end
 for i=1,#code-2 do
  if code[i].text=='struct' and code[i+1].kind=='identifier' and code[i+2].text=='{' then
   types[code[i+1].text]=true
  end
 end
 for i,token in ipairs(code) do
  local value=token.text
  if (value=='for' or value=='while') and code[i+1] and code[i+1].text=='(' then
   local ending=statementEnd(code,i)
   if ending then scopes[#scopes+1]={};loopEnds[ending]=(loopEnds[ending] or 0)+1 end
  elseif value=='(' then
   parenDepth=parenDepth+1
   local name,returnType=code[i-1],code[i-2]
   local signature=name and name.kind=='identifier' and returnType and (types[returnType.text] or returnType.text=='void')
   parens[#parens+1]={arrays={},signature=signature}
  elseif value==')' then
   local frame=table.remove(parens)
   if frame and frame.signature and code[i+1] and code[i+1].text=='{' then pending=frame.arrays end
   parenDepth=parenDepth-1
   if declaration and parenDepth<declaration.depth then declaration=nil end
  elseif value=='{' then
   local scope=pending or {}
   scopes[#scopes+1]=scope
   pending=nil
  elseif value=='}' then
   if #scopes>1 then scopes[#scopes]=nil end
   declaration=nil
  elseif value==';' then declaration=nil
  elseif value==',' and declaration and parenDepth==declaration.depth then declaration.expectName=true
  elseif types[value] and code[i+1] and code[i+1].kind=='identifier' then
   declaration={type=value,constant=code[i-1] and code[i-1].text=='const',depth=parenDepth,expectName=true}
  elseif token.kind=='identifier' then
   local previous=code[i-1]
   local isMember=previous and previous.text=='.'
   local declaredType=declaration and declaration.expectName and declaration.type
   if declaredType then
    declaration.expectName=false
    -- Function names and struct fields are not variable declarations.
    if not (code[i+1] and code[i+1].text=='(') then
     local size=nil
     if code[i+1] and code[i+1].text=='[' then
      local close=bracketClose(code,i+1)
      if close==i+3 and code[i+2].kind=='number' then size=tonumber(code[i+2].text) end
     end
     local symbol={size=size,sampler=declaredType:find('sampler',1,true)~=nil,constant=declaration.constant}
     if #parens>0 and parens[#parens].signature then
      parens[#parens].arrays[value]=symbol
     else scopes[#scopes][value]=symbol end
    end
   elseif not isMember and code[i+1] and code[i+1].text=='[' then
   local close=bracketClose(code,i+1)
   if close then
     local symbol=lookup(scopes,value)
     if symbol and symbol.size and symbol.size>=1 and symbol.size==math.floor(symbol.size)
       and not symbol.sampler and close>i+2 and dynamicIndex(code,i+2,close-1,scopes,macros,types) then
      local prefix='int(clamp('..helperName..'('
      local suffix=string.format('), 0.0, %d.0))',symbol.size-1)
      edits[#edits+1]={first=code[i+2].start,last=code[i+2].start-1,text=prefix,line=token.line}
      edits[#edits+1]={first=code[close].start,last=code[close].start-1,text=suffix,line=token.line}
      lowered=true
     end
   end
   end
  end
  for _=1,loopEnds[i] or 0 do if #scopes>1 then scopes[#scopes]=nil end end
 end
 return lowered
end
return M
