local values = require('noisemaker.compiler.values')
local M = {}
local NULL = values.NULL
local DEFAULT_NAMESPACES = {'io','classicNoisedeck','synth','mixer','filter','render','points','synth3d','filter3d','user'}
local stages = {P001='parser',P002='parser',P003='parser',P004='parser',P005='parser',P006='parser',P007='parser',P008='parser',P009='parser',P010='parser'}
local severity = {P008='warning',P009='warning',P010='warning'}
local function set(items)
  local out={}
  for _,item in ipairs(items) do out[item]=true end
  return out
end
local exprStart=set{'PLUS','MINUS','NUMBER','HEX','FUNC','STRING','IDENT','OUTPUT_REF','SOURCE_REF','VOL_REF','GEO_REF','MESH_REF','XYZ_REF','VEL_REF','RGBA_REF','LPAREN','LBRACKET','TRUE','FALSE'}
local memberTypes=set{'IDENT','SOURCE_REF','OUTPUT_REF','VOL_REF','GEO_REF','MESH_REF','XYZ_REF','VEL_REF','RGBA_REF','LET','RENDER','TRUE','FALSE','IF','ELIF','ELSE','BREAK','CONTINUE','RETURN','WRITE','WRITE3D','SUBCHAIN'}
local namespaceTypes=set{'IDENT','RENDER','WRITE','WRITE3D','TRUE','FALSE','IF','ELIF','ELSE','BREAK','CONTINUE','RETURN'}
local function copyArray(a)
  local b={}
  for i=1,#a do b[i]=a[i] end
  return b
end
local function join(a) return table.concat(a,', ') end
function M.parse(tokens,options)
  options=options or {}
  local current=1
  local function peek(offset) return tokens[current+(offset or 0)] or tokens[#tokens] end
  local function advance() local token=peek(); current=current+1; return token end
  local function parserError(code,message,token,override)
    local diag={code=code,stage=stages[code],severity=override or severity[code] or 'error',message=message,
      location=NULL,span=NULL}
    local position=token and token.position
    if position and position.line and position.column and position.start and position['end'] then
      diag.location={line=position.line,column=position.column}
      diag.span={start=position.start,['end']=position['end']}
    elseif token and token.line and token.col and token.line>0 and token.col>0 then
      diag.location={line=token.line,column=token.col}
    end
    return {message=message,diagnostic=diag}
  end
  local function fail(code,message,token,override) error(parserError(code,message,token,override),0) end
  local function expect(t,message)
    local token=peek()
    if token.type==t then return advance() end
    fail(t=='RPAREN' and 'P002' or 'P001',string.format('%s at line %d col %d',message,token.line,token.col),token)
  end
  local function collectComments()
    local comments={}
    while peek().type=='COMMENT' do comments[#comments+1]=advance().lexeme end
    return comments
  end
  local function attachComments(node,comments)
    if #comments>0 then node.leadingComments=comments end
  end
  local function catComments(a,b)
    for _,v in ipairs(b) do a[#a+1]=v end
    return a
  end
  local parseAdditive, parseCall, parseChain, parseStatement, parseBlock
  local function toNumber(node)
    if node.type~='Number' then
      fail('P001','Expected number',{position=node.position,line=node.loc and node.loc.line,col=node.loc and node.loc.col})
    end
    return node.value
  end
  local function transformParamCall(call,nameToken,kind)
    local args,kwargs=call.args,call.kwargs or {}
    local paramOrder,keywordOnly,defaults
    if kind=='osc' then
      paramOrder={'type','min','max','speed','offset','seed'}
      keywordOnly={}
      defaults={type={type='Member',path={'oscKind','sine'}},min={type='Number',value=0},max={type='Number',value=1},speed={type='Number',value=1},offset={type='Number',value=0},seed={type='Number',value=1}}
    elseif kind=='midi' then
      paramOrder={'channel','mode','min','max','sensitivity'}
      keywordOnly={'name','id','cc','nrpn','zone','members'}
      defaults={mode={type='Member',path={'midiMode','velocity'}},min={type='Number',value=0},max={type='Number',value=1},sensitivity={type='Number',value=1}}
    else
      paramOrder={'band','min','max'}
      keywordOnly={'channel','name','id'}
      defaults={min={type='Number',value=0},max={type='Number',value=1}}
    end
    local valid={}
    for _,name in ipairs(paramOrder) do valid[name]=true end
    for _,name in ipairs(keywordOnly) do valid[name]=true end
    if kind~='osc' and #args>#paramOrder then
      local msg=kind=='midi' and 'midi() name, id, cc, nrpn, zone and members are keyword-only' or 'audio() channel, name and id are keyword-only'
      fail('P003',string.format('%s at line %d col %d',msg,nameToken.line,nameToken.col),nameToken)
    end
    for _,key in ipairs(values.keys(kwargs)) do
      if not valid[key] then
        local list={}
        for _,v in ipairs(paramOrder) do list[#list+1]=v end
        for _,v in ipairs(keywordOnly) do list[#list+1]=v end
        fail('P003',string.format("%s() unknown parameter '%s' at line %d col %d. Valid: %s",kind,key,nameToken.line,nameToken.col,join(list)),nameToken)
      end
    end
    local resolved,posCursor={},1
    for index,name in ipairs(paramOrder) do
      if kwargs[name]~=nil then resolved[name]=kwargs[name]
      elseif kind=='osc' and args[index]~=nil then resolved[name]=args[index]
      elseif kind~='osc' and posCursor<=#args then resolved[name]=args[posCursor]; posCursor=posCursor+1
      else resolved[name]=defaults[name] end
    end
    if kind~='osc' and posCursor<=#args then
      fail('P003',string.format('%s() has an excess positional argument at line %d col %d',kind,nameToken.line,nameToken.col),nameToken)
    end
    if kind=='osc' then
      return {type='Oscillator',oscType=resolved.type,min=resolved.min,max=resolved.max,speed=resolved.speed,offset=resolved.offset,seed=resolved.seed,loc={line=nameToken.line,col=nameToken.col}}
    end
    local function requireCondition(condition,message)
      if condition then fail('P003',string.format('%s at line %d col %d',message,nameToken.line,nameToken.col),nameToken) end
    end
    if kind=='midi' then
      requireCondition(not resolved.channel and kwargs.zone==nil,"midi() requires 'channel' or 'zone' argument")
      requireCondition(resolved.channel and kwargs.zone~=nil,"midi() 'channel' and 'zone' are mutually exclusive")
      requireCondition(kwargs.members~=nil and kwargs.zone==nil,"midi() 'members' requires 'zone'")
      requireCondition(kwargs.id~=nil and kwargs.name==nil,"midi() 'id' requires readable 'name'")
    else
      requireCondition(not resolved.band,"audio() requires 'band' argument")
      requireCondition(kwargs.id~=nil and kwargs.name==nil,"audio() 'id' requires readable 'name'")
      requireCondition(kwargs.name~=nil and kwargs.channel==nil,"audio() selected device requires both 'name' and 'channel'")
    end
    for _,name in ipairs{'name','id'} do
      local value=kwargs[name]
      if value then
        requireCondition(value.type~='String',string.format("%s() '%s' requires a quoted string",kind,name))
        requireCondition(#value.value==0,string.format("%s() '%s' must not be empty",kind,name))
      end
    end
    if kind=='midi' then
      return {type='Midi',channel=resolved.channel,mode=resolved.mode,min=resolved.min,max=resolved.max,sensitivity=resolved.sensitivity,
        cc=kwargs.cc,nrpn=kwargs.nrpn,zone=kwargs.zone,members=kwargs.members,name=kwargs.name,id=kwargs.id,loc={line=nameToken.line,col=nameToken.col}}
    end
    return {type='Audio',band=resolved.band,min=resolved.min,max=resolved.max,channel=kwargs.channel,name=kwargs.name,id=kwargs.id,loc={line=nameToken.line,col=nameToken.col}}
  end
  local function transformFrom(call,nameToken)
    local function bad(message) fail('P007',string.format('%s at line %d col %d',message,nameToken.line,nameToken.col),nameToken) end
    if call.kwargs and next(call.kwargs) then bad("'from' does not support named arguments") end
    if #call.args~=2 then bad("'from' requires exactly two arguments (namespace, call)") end
    local namespaceArg,targetArg=call.args[1],call.args[2]
    if not namespaceArg or (namespaceArg.type~='Ident' and namespaceArg.type~='Member') then bad("'from' namespace argument must be an identifier") end
    local namespaceName=namespaceArg.type=='Member' and table.concat(namespaceArg.path,'.') or namespaceArg.name
    if not namespaceName or namespaceName=='' then bad("'from' namespace argument must be non-empty") end
    local targetCall=targetArg
    if targetArg and targetArg.type=='Chain' and #targetArg.chain==1 then targetCall=targetArg.chain[1] end
    if not targetCall or targetCall.type~='Call' then bad("'from' second argument must be a call expression") end
    local replacement={}
    for k,v in pairs(targetCall) do replacement[k]=v end
    replacement.args=copyArray(targetCall.args or {})
    if targetCall.kwargs then local kw={}; for k,v in pairs(targetCall.kwargs) do kw[k]=v end; replacement.kwargs=kw end
    replacement.namespace={name=namespaceName,path={namespaceName},explicit=true,source='from',resolved=namespaceName,searchOrder={namespaceName},fromOverride=true}
    return replacement
  end
  local function hasCallAfterDot(index)
    local k=index+1
    if not tokens[k] or tokens[k].type~='DOT' then return false end
    while tokens[k] and tokens[k].type=='DOT' do
      local seg=tokens[k+1]
      if not seg or not memberTypes[seg.type] then return false end
      k=k+2
    end
    return tokens[k] and tokens[k].type=='LPAREN' or false
  end
  local function parseKwarg(obj)
    local key=expect('IDENT','Expected identifier').lexeme
    expect('COLON',"Expect ':'")
    if not exprStart[peek().type] then
      local t=peek(); fail('P001',string.format("Expected expression after '=' at line %d col %d",t.line,t.col),t)
    end
    values.set(obj,key,parseAdditive())
  end
  parseCall=function()
    local nameToken=expect('IDENT','Expected identifier')
    if peek().type=='DOT' and peek(1).type=='IDENT' and peek(2).type=='LPAREN' then
      fail('P007',string.format("Inline namespace syntax '%s.%s()' is not allowed. Use 'search %s' at the start of the program instead, at line %d col %d",nameToken.lexeme,peek(1).lexeme,nameToken.lexeme,nameToken.line,nameToken.col),nameToken)
    end
    expect('LPAREN',"Expect '('")
    local args,kwargs={},values.object()
    local keyword,positional=false,false
    local allowMixed=nameToken.lexeme=='midi' or nameToken.lexeme=='audio'
    if peek().type~='RPAREN' then
      while true do
        if peek().type=='IDENT' and peek(1).type=='COLON' then
          if positional and not allowMixed then
            local t=peek(); fail('P007',string.format('Cannot mix positional and keyword arguments at line %d col %d',t.line,t.col),t)
          end
          keyword=true; parseKwarg(kwargs)
        else
          if keyword and not allowMixed then
            local t=peek(); fail('P007',string.format('Cannot mix positional and keyword arguments at line %d col %d',t.line,t.col),t)
          end
          positional=true; args[#args+1]=parseAdditive()
        end
        if peek().type~='COMMA' then break end
        advance()
        if peek().type=='RPAREN' then break end
      end
    end
    expect('RPAREN',"Expect ')'")
    local call={type='Call',name=nameToken.lexeme,args=args}
    if keyword then call.kwargs=kwargs end
    if call.name=='from' then return transformFrom(call,nameToken) end
    if call.name=='osc' then
      local valid=set{'type','min','max','speed','offset','seed'}
      local only=true
      for _,key in ipairs(values.keys(kwargs)) do if not valid[key] then only=false end end
      local first=args[1]
      local firstKind=first and first.type=='Member' and first.path and first.path[1]=='oscKind'
      local bare=#args==0 and #values.keys(kwargs)==0
      if kwargs.type or firstKind or bare or (#values.keys(kwargs)>0 and only) then
        return transformParamCall(call,nameToken,'osc')
      end
    end
    if call.name=='midi' then return transformParamCall(call,nameToken,'midi') end
    if call.name=='audio' then return transformParamCall(call,nameToken,'audio') end
    if call.name=='read' then
      local node={type='Read',surface=args[1] or kwargs.tex or kwargs.surface,loc={line=nameToken.line,col=nameToken.col}}
      if kwargs._skip and kwargs._skip.type=='Boolean' and kwargs._skip.value==true then node._skip=true end
      return node
    end
    if call.name=='read3d' then
      local node={type='Read3D',tex3d=args[1] or kwargs.tex3d,geo=args[2] or kwargs.geo or NULL,loc={line=nameToken.line,col=nameToken.col}}
      if kwargs._skip and kwargs._skip.type=='Boolean' and kwargs._skip.value==true then node._skip=true end
      return node
    end
    return call
  end
  local function parsePrimary()
    local token=peek()
    local t=token.type
    if t=='NUMBER' then advance(); return {type='Number',value=tonumber(token.lexeme)} end
    if t=='STRING' then advance(); return {type='String',value=token.lexeme} end
    if t=='HEX' then
      advance()
      local h=token.lexeme:sub(2)
      local r,g,b,a
      if #h==3 then r=tonumber(h:sub(1,1)..h:sub(1,1),16);g=tonumber(h:sub(2,2)..h:sub(2,2),16);b=tonumber(h:sub(3,3)..h:sub(3,3),16);a=1
      else r=tonumber(h:sub(1,2),16);g=tonumber(h:sub(3,4),16);b=tonumber(h:sub(5,6),16);a=#h==8 and tonumber(h:sub(7,8),16)/255 or 1 end
      return {type='Color',value={r/255,g/255,b/255,a}}
    end
    if t=='LBRACKET' then
      advance()
      local elements={}
      if peek().type~='RBRACKET' then
        elements[#elements+1]=parseAdditive()
        while peek().type=='COMMA' do advance(); elements[#elements+1]=parseAdditive() end
      end
      if peek().type~='RBRACKET' then
        local bad=peek(); fail('P001',string.format("Expected ']' at line %d col %d",bad.line,bad.col),bad)
      end
      advance()
      local node={type='ArrayLiteral',elements=elements,loc={line=token.line,col=token.col}}
      if token.position then setmetatable(node,{__index={position=token.position}}) end
      return node
    end
    if t=='FUNC' then advance(); return {type='Func',src=token.lexeme} end
    if t=='TRUE' then advance(); return {type='Boolean',value=true} end
    if t=='FALSE' then advance(); return {type='Boolean',value=false} end
    if t=='IDENT' then
      if token.lexeme=='Math' and peek(1).type=='DOT' and peek(2).type=='IDENT' and peek(2).lexeme=='PI' then
        advance();advance();advance();return {type='Number',value=math.pi}
      end
      if peek(1).type=='LPAREN' or hasCallAfterDot(current) then
        local chain=parseChain('expression')
        return #chain==1 and chain[1] or {type='Chain',chain=chain}
      end
      advance()
      local path={token.lexeme}
      while peek().type=='DOT' do
        local nextToken=peek(1)
        if peek(2).type=='LPAREN' then break end
        if not memberTypes[nextToken.type] then
          fail('P001',string.format("Expected identifier after '.' at line %d col %d",nextToken.line,nextToken.col),nextToken)
        end
        advance();advance();path[#path+1]=nextToken.lexeme
      end
      if #path>1 then return {type='Member',path=path} end
      return {type='Ident',name=path[1]}
    end
    local refs={OUTPUT_REF='OutputRef',SOURCE_REF='SourceRef',VOL_REF='VolRef',GEO_REF='GeoRef',XYZ_REF='XyzRef',VEL_REF='VelRef',RGBA_REF='RgbaRef',MESH_REF='MeshRef'}
    if refs[t] then advance(); return {type=refs[t],name=token.lexeme} end
    if t=='LPAREN' then advance(); local expr=parseAdditive();expect('RPAREN',"Expect ')'");return expr end
    fail('P001',string.format('Unexpected token %s at line %d col %d',t,token.line,token.col),token)
  end
  local function parseUnary()
    if peek().type=='PLUS' then advance();return parseUnary() end
    if peek().type=='MINUS' then advance();return {type='Number',value=-toNumber(parseUnary())} end
    return parsePrimary()
  end
  local function parseMultiplicative()
    local node=parseUnary()
    while peek().type=='STAR' or peek().type=='SLASH' do
      local op=advance().type
      local right=parseUnary()
      node={type='Number',value=op=='STAR' and toNumber(node)*toNumber(right) or toNumber(node)/toNumber(right)}
    end
    return node
  end
  parseAdditive=function()
    local node=parseMultiplicative()
    while peek().type=='PLUS' or peek().type=='MINUS' do
      local op=advance().type
      local right=parseMultiplicative()
      node={type='Number',value=op=='PLUS' and toNumber(node)+toNumber(right) or toNumber(node)-toNumber(right)}
    end
    return node
  end
  local function parseWriteCall()
    local token=peek()
    local tokenType=token.type
    local loc={line=token.line,col=token.col}
    if tokenType=='WRITE' then
      advance();expect('LPAREN',"Expect '('")
      local t=peek()
      local refs={OUTPUT_REF='OutputRef',XYZ_REF='XyzRef',VEL_REF='VelRef',RGBA_REF='RgbaRef',MESH_REF='MeshRef'}
      local surface
      if refs[t.type] then surface={type=refs[t.type],name=advance().lexeme}
      elseif t.type=='IDENT' and t.lexeme=='none' then surface={type='OutputRef',name=advance().lexeme}
      else fail('P005',string.format('write() requires an explicit surface reference (e.g., o0, o1, xyz0, vel0, rgba0, mesh0, none) at line %d col %d',t.line,t.col),t) end
      expect('RPAREN',"Expect ')'")
      return {type='Write',surface=surface,loc=loc}
    elseif tokenType=='WRITE3D' then
      advance();expect('LPAREN',"Expect '('")
      local t=peek()
      if t.type~='IDENT' and t.type~='OUTPUT_REF' and t.type~='VOL_REF' then
        fail('P005',string.format('Expected tex3d reference in write3d() at line %d col %d',t.line,t.col),t)
      end
      local refType={IDENT='Ident',OUTPUT_REF='OutputRef',VOL_REF='VolRef'}
      local tex3d={type=refType[t.type],name=advance().lexeme}
      expect('COMMA',"Expect ',' between tex3d and geo in write3d()")
      t=peek()
      if t.type~='IDENT' and t.type~='OUTPUT_REF' and t.type~='GEO_REF' then
        fail('P005',string.format('Expected geo reference in write3d() at line %d col %d',t.line,t.col),t)
      end
      refType={IDENT='Ident',OUTPUT_REF='OutputRef',GEO_REF='GeoRef'}
      local geo={type=refType[t.type],name=advance().lexeme}
      expect('RPAREN',"Expect ')'")
      return {type='Write3D',tex3d=tex3d,geo=geo,loc=loc}
    end
    fail('P005',string.format('Expected write or write3d at line %d col %d',token.line,token.col),token)
  end
  local function parseSubchainCall()
    local nameToken=advance()
    expect('LPAREN',"Expect '(' after subchain")
    local argDiagnostics={}
    local function report(code,message,token)
      if options.subchainArguments=='strict' then fail(code,message,token,'error') end
      local d={code=code,message=message,severity=severity[code]}
      if token.position then
        d.location={line=token.position.line,column=token.position.column}
        d.span={start=token.position.start,['end']=token.position['end']}
      elseif token.line and token.col then d.location={line=token.line,column=token.col} end
      argDiagnostics[#argDiagnostics+1]=d
    end
    local kwargs={}
    if peek().type~='RPAREN' then
      if peek().type=='STRING' then
        kwargs.name={type='String',value=advance().lexeme}
      elseif peek().type=='IDENT' and peek(1).type=='COLON' then
        while peek().type=='IDENT' and peek(1).type=='COLON' do
          local keyToken=advance();local key=keyToken.lexeme;advance()
          if peek().type~='STRING' then
            local t=peek();fail('P006',string.format('Expected string value for subchain %s at line %d col %d',key,t.line,t.col),t)
          end
          local value=advance().lexeme
          if key~='name' and key~='id' then
            report('P008',string.format("Unknown subchain argument '%s' at line %d col %d. Valid keys: name, id. The value is discarded.",key,keyToken.line,keyToken.col),keyToken)
          elseif kwargs[key]~=nil then
            report('P009',string.format("Duplicate subchain argument '%s' at line %d col %d. The last value wins.",key,keyToken.line,keyToken.col),keyToken)
          end
          kwargs[key]={type='String',value=value}
          if peek().type=='COMMA' then advance()
          elseif peek().type=='IDENT' and peek(1).type=='COLON' then
            local t=peek();report('P010',string.format("Missing ',' between subchain arguments at line %d col %d",t.line,t.col),t)
          end
        end
      end
    end
    expect('RPAREN',"Expect ')' after subchain arguments")
    expect('LBRACE',"Expect '{' to start subchain body")
    local body={}
    while peek().type~='RBRACE' do
      local comments=collectComments()
      if peek().type=='RBRACE' then break end
      if peek().type~='DOT' then
        local t=peek();fail('P006',string.format("Expected '.' before chain element in subchain body at line %d col %d",t.line,t.col),t)
      end
      advance();catComments(comments,collectComments())
      local call=parseCall()
      attachComments(call,comments)
      body[#body+1]=call
    end
    expect('RBRACE',"Expect '}' to end subchain body")
    if #body==0 then fail('P006',string.format('Subchain body cannot be empty at line %d col %d',nameToken.line,nameToken.col),nameToken) end
    local node={type='Subchain',name=kwargs.name and kwargs.name.value or NULL,id=kwargs.id and kwargs.id.value or NULL,
      body=body,loc={line=nameToken.line,col=nameToken.col}}
    if #argDiagnostics>0 then setmetatable(node,{__index={subchainArgumentDiagnostics=argDiagnostics}}) end
    return node
  end
  parseChain=function(context)
    local calls={parseCall()}
    while true do
      local saved=current
      local comments=collectComments()
      if peek().type~='DOT' then current=saved;break end
      advance();catComments(comments,collectComments())
      local nextType=peek().type
      local node
      if nextType=='WRITE' or nextType=='WRITE3D' then
        if context=='expression' then
          local t=peek();fail('P005',string.format("'.write()' is only allowed in statement context at line %d col %d",t.line,t.col),t)
        end
        node=parseWriteCall()
      elseif nextType=='SUBCHAIN' then node=parseSubchainCall()
      else node=parseCall() end
      attachComments(node,comments)
      calls[#calls+1]=node
    end
    return calls
  end
  parseBlock=function()
    expect('LBRACE',"Expect '{'")
    local body={}
    while peek().type~='RBRACE' do
      body[#body+1]=parseStatement()
      while peek().type=='SEMICOLON' do advance() end
    end
    expect('RBRACE',"Expect '}'")
    return body
  end
  parseStatement=function()
    local t=peek()
    if t.type=='SEARCH' then fail('P004',string.format("'search' directive is only allowed at the start of the program at line %d col %d",t.line,t.col),t) end
    if t.type=='LET' then
      advance()
      local name=expect('IDENT','Expected identifier').lexeme
      expect('EQUAL',"Expect '='")
      if not exprStart[peek().type] then
        t=peek();fail('P001',string.format("Expected expression after '=' at line %d col %d",t.line,t.col),t)
      end
      return {type='VarAssign',name=name,expr=parseAdditive()}
    end
    if t.type=='IF' then
      advance();expect('LPAREN',"Expect '('")
      local condition=parseAdditive()
      expect('RPAREN',"Expect ')'")
      local thenBody=parseBlock()
      local elif={}
      while peek().type=='ELIF' do
        advance();expect('LPAREN',"Expect '('")
        local c=parseAdditive();expect('RPAREN',"Expect ')'")
        elif[#elif+1]={condition=c,['then']=parseBlock()}
      end
      local elseBranch=NULL
      if peek().type=='ELSE' then advance();elseBranch=parseBlock() end
      return {type='IfStmt',condition=condition,['then']=thenBody,elif=elif,['else']=elseBranch}
    end
    if t.type=='BREAK' then advance();return {type='Break'} end
    if t.type=='CONTINUE' then advance();return {type='Continue'} end
    if t.type=='RETURN' then
      advance()
      if exprStart[peek().type] then return {type='Return',value=parseAdditive()} end
      return {type='Return'}
    end
    local chain=parseChain()
    local write,write3d=NULL,NULL
    local last=chain[#chain]
    if last.type=='Write' then write=last.surface
    elseif last.type=='Write3D' then write3d={tex3d=last.tex3d,geo=last.geo} end
    return {chain=chain,write=write,write3d=write3d}
  end
  local programSearchOrder
  local programNamespace={imports={},default=NULL}
  local validNamespaces=options.validNamespaces or DEFAULT_NAMESPACES
  local validSet=set(validNamespaces)
  local function parseSearchDirective()
    if programSearchOrder then
      local t=peek();fail('P004',string.format('Only one search directive is allowed per program at line %d col %d',t.line,t.col),t)
    end
    advance()
    local namespaces={}
    local function validate(token)
      local valid=options.isValidNamespace and options.isValidNamespace(token.lexeme) or validSet[token.lexeme]
      if not valid then
        fail('P004',string.format("Invalid namespace '%s' at line %d col %d. Valid namespaces: %s",token.lexeme,token.line,token.col,join(validNamespaces)),token)
      end
    end
    local t=peek()
    if not namespaceTypes[t.type] then fail('P004',string.format('Expected namespace identifier after search at line %d col %d',t.line,t.col),t) end
    advance();validate(t);namespaces[#namespaces+1]=t.lexeme
    while peek().type=='COMMA' do
      advance();t=peek()
      if not namespaceTypes[t.type] then fail('P004',string.format('Expected namespace identifier after comma at line %d col %d',t.line,t.col),t) end
      advance();validate(t);namespaces[#namespaces+1]=t.lexeme
    end
    programSearchOrder=namespaces
    for _,name in ipairs(namespaces) do programNamespace.imports[#programNamespace.imports+1]={name=name,source='search',explicit=true} end
    programNamespace.default={name=namespaces[1],source='search',explicit=true}
    while peek().type=='SEMICOLON' do advance() end
  end
  local plans,vars,render,trailingComments={},{},NULL,{}
  local function parseRenderDirective()
    advance();expect('LPAREN',"Expect '('")
    if peek().type~='OUTPUT_REF' then fail('P005','Expected output reference in render()',peek()) end
    local out={type='OutputRef',name=advance().lexeme}
    expect('RPAREN',"Expect ')'")
    return out
  end
  while peek().type~='EOF' do
    if peek().type=='SEMICOLON' then advance()
    else
      local comments=collectComments()
      if peek().type=='EOF' then catComments(trailingComments,comments);break end
      if peek().type~='SEMICOLON' then
        if peek().type=='SEARCH' then
          if #plans>0 or #vars>0 or render~=NULL then
            local t=peek();fail('P004',string.format("'search' directive must appear before other statements at line %d col %d",t.line,t.col),t)
          end
          parseSearchDirective()
        elseif peek().type=='RENDER' then
          if render~=NULL then
            local t=peek();fail('P005',string.format('Duplicate render() directive at line %d col %d',t.line,t.col),t)
          end
          render=parseRenderDirective()
          while peek().type=='SEMICOLON' do advance() end
          attachComments(render,comments)
          catComments(trailingComments,collectComments())
          break
        else
          local statement=parseStatement()
          attachComments(statement,comments)
          if statement.type=='VarAssign' then vars[#vars+1]=statement else plans[#plans+1]=statement end
          while peek().type=='SEMICOLON' do advance() end
        end
      end
    end
  end
  local eof=expect('EOF','Expected end of input')
  if not programSearchOrder or #programSearchOrder==0 then
    fail('P004',"Missing required 'search' directive. Every program must start with 'search <namespace>, ...' to specify namespace search order.",eof)
  end
  local program={type='Program',plans=plans,render=render,
    namespace={imports=programNamespace.imports,default=programNamespace.default,searchOrder=copyArray(programSearchOrder)}}
  if #vars>0 then program.vars=vars end
  if #trailingComments>0 then program.trailingComments=trailingComments end
  return program
end
return M
