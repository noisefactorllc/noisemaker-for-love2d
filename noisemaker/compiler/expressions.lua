-- Native evaluator for the dynamic-expression subset of the Polymorphic DSL.
-- It parses the expression into an AST; source is never passed to Lua's loader.
local values=require('noisemaker.compiler.values')
local M={}
local UNDEFINED=values.UNDEFINED
local NULL=values.NULL
local function truthy(x) return values.truthy(x) end
local function jsNumber(x)
  if x==UNDEFINED or x==nil then return 0/0 end
  if x==NULL or x==false or x=='' then return 0 end
  if x==true then return 1 end
  if type(x)=='number' then return x end
  if type(x)=='string' then return tonumber(x) or 0/0 end
  return 0/0
end
local function jsString(x)
  if x==UNDEFINED or x==nil then return 'undefined' end
  if x==NULL then return 'null' end
  if x==true then return 'true' end
  if x==false then return 'false' end
  return tostring(x)
end
local function jsType(x)
  if x==UNDEFINED or x==nil then return 'undefined' end
  if x==NULL or type(x)=='table' then return 'object' end
  return type(x)
end
local mathBuiltin={
  sin=math.sin,cos=math.cos,tan=math.tan,asin=math.asin,acos=math.acos,atan=math.atan,
  atan2=math.atan2 or function(y,x) return math.atan(y/x) end,
  abs=math.abs,floor=math.floor,ceil=math.ceil,sqrt=math.sqrt,exp=math.exp,
  log=math.log,pow=math.pow or function(a,b) return a^b end,min=math.min,max=math.max,
  round=function(x) return math.floor(x+0.5) end,
  trunc=function(x) return x<0 and math.ceil(x) or math.floor(x) end,
  sign=function(x) return x<0 and -1 or (x>0 and 1 or 0) end,
  PI=math.pi,E=math.exp(1),LN2=math.log(2),LN10=math.log(10),SQRT2=math.sqrt(2),
}
local function tokenize(src)
  local tokens={}
  local i,n=1,#src
  local function add(kind,text) tokens[#tokens+1]={kind=kind,text=text,pos=i} end
  while i<=n do
    local c=src:sub(i,i)
    if c:match('%s') then i=i+1
    elseif c=='/' and src:sub(i+1,i+1)=='*' then
      local close=src:find('*/',i+2,true)
      if not close then error('unterminated comment') end
      i=close+2
    elseif c=='/' and src:sub(i+1,i+1)=='/' then break
    elseif c:match('[%a_]') or c=='$' then
      local a,b=src:find('^[%a_$][%w_$]*',i)
      add('ident',src:sub(a,b));i=b+1
    elseif c:match('%d') or (c=='.' and src:sub(i+1,i+1):match('%d')) then
      local j=i
      local integer=src:match('^%d[%d_]*',i)
      if integer then j=i+#integer else j=i end
      if src:sub(j,j)=='.' then
        j=j+1
        local frac=src:match('^[%d_]*',j) or ''
        j=j+#frac
      elseif not integer then
        local frac=src:match('^%.[%d_]+',i)
        j=i+#frac
      end
      local exponent=src:match('^[eE][+-]?[%d_]+',j)
      if exponent then j=j+#exponent end
      local raw=src:sub(i,j-1)
      local number=tonumber((raw:gsub('_','')))
      if not number then error('invalid number') end
      add('number',number);i=j
    elseif c=='\'' or c=='"' then
      local quote=c
      local j=i+1
      local out={}
      local escapes={n='\n',r='\r',t='\t',b='\b',f='\f',v='\v',['0']='\0',['\\']='\\',['"']='"',["'"]="'"}
      while j<=n and src:sub(j,j)~=quote do
        local v=src:sub(j,j)
        if v=='\\' then
          local nextChar=src:sub(j+1,j+1)
          if nextChar=='' then error('unterminated string') end
          out[#out+1]=escapes[nextChar] or nextChar
          j=j+2
        else out[#out+1]=v;j=j+1 end
      end
      if j>n then error('unterminated string') end
      add('string',table.concat(out));i=j+1
    else
      local operator
      for _,candidate in ipairs{'===','!==','>>>','**','<=','>=','==','!=','&&','||','??','<<','>>','++','--','+=','-=','*=','/='} do
        if src:sub(i,i+#candidate-1)==candidate then operator=candidate;break end
      end
      if not operator then operator=c end
      if not operator:match('^[%+%-%*/%%<>=!&|?%:%.%(%)%[%],%^~]+$') then
        error('unsupported token '..operator)
      end
      add(operator,operator);i=i+#operator
    end
  end
  tokens[#tokens+1]={kind='EOF',text='',pos=n+1}
  return tokens
end
local precedence={['??']=1,['||']=2,['&&']=3,['|']=4,['^']=5,['&']=6,
  ['==']=7,['!=']=7,['===']=7,['!==']=7,
  ['<']=8,['>']=8,['<=']=8,['>=']=8,
  ['<<']=9,['>>']=9,['>>>']=9,
  ['+']=10,['-']=10,['*']=11,['/']=11,['%']=11,['**']=12}
local function parse(tokens)
  local at=1
  local function peek() return tokens[at] end
  local function advance() local t=peek();at=at+1;return t end
  local function expect(kind)
    if peek().kind~=kind then error('expected '..kind..' at '..peek().pos) end
    return advance()
  end
  local expression
  local function primary()
    local t=advance()
    if t.kind=='number' or t.kind=='string' then return {kind='literal',value=t.text} end
    if t.kind=='ident' then
      if t.text=='true' then return {kind='literal',value=true} end
      if t.text=='false' then return {kind='literal',value=false} end
      if t.text=='null' then return {kind='literal',value=NULL} end
      if t.text=='undefined' then return {kind='literal',value=UNDEFINED} end
      if t.text=='typeof' or t.text=='void' then return {kind='unary',op=t.text,right=expression(13)} end
      return {kind='ident',name=t.text}
    end
    if t.kind=='(' then local node=expression(0);expect(')');return node end
    if t.kind=='+' or t.kind=='-' or t.kind=='!' or t.kind=='~' then
      return {kind='unary',op=t.kind,right=expression(13)}
    end
    error('unexpected '..t.kind..' at '..t.pos)
  end
  local function postfix(node)
    while true do
      local t=peek()
      if t.kind=='.' then
        advance();local field=expect('ident');node={kind='member',base=node,key=field.text}
      elseif t.kind=='[' then
        advance();local key=expression(0);expect(']');node={kind='index',base=node,key=key}
      elseif t.kind=='(' then
        advance();local args={}
        if peek().kind~=')' then
          args[#args+1]=expression(0)
          while peek().kind==',' do advance();args[#args+1]=expression(0) end
        end
        expect(')');node={kind='call',callee=node,args=args}
      else break end
    end
    return node
  end
  expression=function(minimum)
    local node=postfix(primary())
    while true do
      local t=peek()
      if t.kind=='?' and minimum<=0 then
        advance();local yes=expression(0);expect(':');local no=expression(0)
        node={kind='ternary',condition=node,yes=yes,no=no}
      else
        local p=precedence[t.kind]
        if not p or p<minimum then break end
        advance()
        local rhs=expression(t.kind=='**' and p or p+1)
        node={kind='binary',op=t.kind,left=node,right=rhs}
      end
    end
    return node
  end
  local node=expression(0)
  if peek().kind~='EOF' then error('unexpected '..peek().kind..' at '..peek().pos) end
  return node
end
local function property(base,key)
  if base==NULL or base==UNDEFINED or base==nil then error('cannot read property of null or undefined') end
  if type(base)=='string' and key=='length' then return #base end
  if type(base)~='table' then return UNDEFINED end
  if type(key)=='number' and key>=0 and key%1==0 and (values.isArray(base) or #base>0) then
    return base[key+1] or UNDEFINED
  end
  return base[key] or UNDEFINED
end
local function jsEqual(a,b,strict)
  if a==UNDEFINED and b==NULL or a==NULL and b==UNDEFINED then return not strict end
  if strict then return a==b end
  if type(a)==type(b) then return a==b end
  if type(a)=='boolean' then a=jsNumber(a) end
  if type(b)=='boolean' then b=jsNumber(b) end
  if type(a)=='number' or type(b)=='number' then return jsNumber(a)==jsNumber(b) end
  return a==b
end
local function evaluate(node,state)
  local kind=node.kind
  if kind=='literal' then return node.value end
  if kind=='ident' then
    if node.name=='state' then return state end
    if state and state[node.name]~=nil then return state[node.name] end
    if node.name=='Math' then return mathBuiltin end
    if node.name=='NaN' then return 0/0 end
    if node.name=='Infinity' then return math.huge end
    if node.name=='Number' then return jsNumber end
    if node.name=='String' then return jsString end
    return UNDEFINED
  end
  if kind=='member' then return property(evaluate(node.base,state),node.key) end
  if kind=='index' then return property(evaluate(node.base,state),evaluate(node.key,state)) end
  if kind=='call' then
    local fn=evaluate(node.callee,state)
    if type(fn)~='function' then error('expression target is not callable') end
    local args={}
    for i,arg in ipairs(node.args) do args[i]=evaluate(arg,state) end
    return fn(unpack(args))
  end
  if kind=='unary' then
    local op=node.op
    if op=='typeof' and node.right.kind=='ident' and not state[node.right.name] then return 'undefined' end
    local v=evaluate(node.right,state)
    if op=='+' then return jsNumber(v) end
    if op=='-' then return -jsNumber(v) end
    if op=='!' then return not truthy(v) end
    if op=='~' then return require('bit').bnot(jsNumber(v)) end
    if op=='typeof' then return jsType(v) end
    if op=='void' then return UNDEFINED end
  end
  if kind=='ternary' then
    if truthy(evaluate(node.condition,state)) then return evaluate(node.yes,state) end
    return evaluate(node.no,state)
  end
  if kind=='binary' then
    local op=node.op
    local a=evaluate(node.left,state)
    if op=='&&' then if truthy(a) then return evaluate(node.right,state) else return a end end
    if op=='||' then if truthy(a) then return a else return evaluate(node.right,state) end end
    if op=='??' then if a==NULL or a==UNDEFINED then return evaluate(node.right,state) else return a end end
    local b=evaluate(node.right,state)
    if op=='+' then
      if type(a)=='string' or type(b)=='string' then return jsString(a)..jsString(b) end
      return jsNumber(a)+jsNumber(b)
    end
    if op=='-' then return jsNumber(a)-jsNumber(b) end
    if op=='*' then return jsNumber(a)*jsNumber(b) end
    if op=='/' then return jsNumber(a)/jsNumber(b) end
    if op=='%' then local x,y=jsNumber(a),jsNumber(b);return x-y*math.modf(x/y) end
    if op=='**' then return jsNumber(a)^jsNumber(b) end
    if op=='<' then return jsNumber(a)<jsNumber(b) end
    if op=='<=' then return jsNumber(a)<=jsNumber(b) end
    if op=='>' then return jsNumber(a)>jsNumber(b) end
    if op=='>=' then return jsNumber(a)>=jsNumber(b) end
    if op=='===' or op=='==' then return jsEqual(a,b,op=='===') end
    if op=='!==' or op=='!=' then return not jsEqual(a,b,op=='!==') end
    local bit=require('bit')
    if op=='&' then return bit.band(jsNumber(a),jsNumber(b)) end
    if op=='|' then return bit.bor(jsNumber(a),jsNumber(b)) end
    if op=='^' then return bit.bxor(jsNumber(a),jsNumber(b)) end
    if op=='<<' then return bit.lshift(jsNumber(a),jsNumber(b)) end
    if op=='>>' then return bit.arshift(jsNumber(a),jsNumber(b)) end
    if op=='>>>' then return bit.rshift(jsNumber(a),jsNumber(b)) end
  end
  error('unsupported expression node')
end
function M.compile(source)
  if type(source)~='string' then return nil,{code='S001',stage='semantic',severity='error',message='Dynamic expression source must be a string'} end
  local ok,ast=pcall(function() return parse(tokenize(source)) end)
  if not ok then return nil,{code='S001',stage='semantic',severity='error',message="Invalid function expression: '"..source:sub(1,50).."'",detail=tostring(ast)} end
  return function(state) return evaluate(ast,state or {}) end
end
function M.evaluate(source,state)
  local callback,diagnostic=M.compile(source)
  if not callback then return nil,diagnostic end
  local ok,value=pcall(callback,state or {})
  if not ok then return nil,{code='R001',stage='runtime',severity='error',message=tostring(value)} end
  return value
end
return M
