local values = require('noisemaker.compiler.values')
local M = {}
M.RESERVED_KEYWORDS = {
  ['let']='LET', render='RENDER', write='WRITE', write3d='WRITE3D',
  ['true']='TRUE', ['false']='FALSE', ['if']='IF', elif='ELIF', ['else']='ELSE',
  ['break']='BREAK', ['continue']='CONTINUE', ['return']='RETURN', search='SEARCH', subchain='SUBCHAIN'
}
local punctuation = {['.']='DOT',['(']='LPAREN',[')']='RPAREN',['{']='LBRACE',['}']='RBRACE',
  ['[']='LBRACKET',[']']='RBRACKET',[',']='COMMA',[':']='COLON',['=']='EQUAL',
  [';']='SEMICOLON',['+']='PLUS',['-']='MINUS',['*']='STAR',['/']='SLASH'}
local function digit(c) return c and c >= 48 and c <= 57 end
local function letter(c) return c and ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)) end
local function hex(c) return digit(c) or (c and ((c>=65 and c<=70) or (c>=97 and c<=102))) end
function M.lex(source)
  local units, starts, ends = values.utf16(source)
  local n = #units
  local function u(i) return units[i+1] end
  local function ch(i)
    local c = u(i)
    if not c then return nil end
    if c < 128 then return string.char(c) end
    if c >= 0xD800 and c <= 0xDFFF then
      return string.char(0xE0 + math.floor(c/4096), 0x80 + math.floor(c/64)%64, 0x80 + c%64)
    end
    return source:sub(starts[i+1], ends[i+1])
  end
  local function slice(a,b)
    if a >= b then return '' end
    return source:sub(starts[a+1], ends[b])
  end
  local i, line, col = 0, 1, 1
  local srcLine, srcCol, anchor = 1, 1, 0
  local tokens = {}
  local function advancePosition(a,b)
    for k=a,b-1 do
      if u(k) == 10 then srcLine,srcCol = srcLine+1,1 else srcCol=srcCol+1 end
    end
  end
  local function add(t, lexeme, tokenLine, tokenCol, finish)
    advancePosition(anchor,i)
    local position={line=srcLine,column=srcCol,start=i,['end']=finish}
    advancePosition(i,finish)
    anchor=finish
    tokens[#tokens+1]={type=t,lexeme=lexeme,line=tokenLine,col=tokenCol,position=position}
  end
  local function fail(code,message,start,finish)
    local errorLine,column=1,1
    for k=0,start-1 do
      if u(k)==10 then errorLine,column=errorLine+1,1 else column=column+1 end
    end
    error({message=message,diagnostic={code=code,stage='lexer',severity='error',message=message,
      location={line=errorLine,column=column},span={start=start,['end']=finish}}},0)
  end
  while i<n do
    local c=u(i)
    if c==32 or c==9 or c==13 then i,col=i+1,col+1
    elseif c==10 then i,line,col=i+1,line+1,1
    else
      local startLine,startCol=line,col
      if c==47 and u(i+1)==47 then
        local j=i+2
        while j<n and u(j)~=10 do j=j+1 end
        add('COMMENT',slice(i,j),startLine,startCol,j)
        col,i=col+j-i,j
      elseif c==47 and u(i+1)==42 then
        local j,endLine,endCol=i+2,line,col+2
        while j<n and not (u(j)==42 and u(j+1)==47) do
          if u(j)==10 then endLine,endCol=endLine+1,1 else endCol=endCol+1 end
          j=j+1
        end
        if j>=n then fail('L003',string.format('Unterminated comment at line %d col %d',startLine,startCol),i,n) end
        j=j+2
        add('COMMENT',slice(i,j),startLine,startCol,j)
        line,col,i=endLine,endCol+2,j
      else
        local prefix,tokenType
        if (c==111 or c==115) and digit(u(i+1)) then prefix,tokenType=1,(c==111 and 'OUTPUT_REF' or 'SOURCE_REF')
        elseif c==118 and u(i+1)==111 and u(i+2)==108 and digit(u(i+3)) then prefix,tokenType=3,'VOL_REF'
        elseif c==103 and u(i+1)==101 and u(i+2)==111 and digit(u(i+3)) then prefix,tokenType=3,'GEO_REF'
        elseif c==120 and u(i+1)==121 and u(i+2)==122 and digit(u(i+3)) then prefix,tokenType=3,'XYZ_REF'
        elseif c==118 and u(i+1)==101 and u(i+2)==108 and digit(u(i+3)) then prefix,tokenType=3,'VEL_REF'
        elseif c==114 and u(i+1)==103 and u(i+2)==98 and u(i+3)==97 and digit(u(i+4)) then prefix,tokenType=4,'RGBA_REF'
        elseif c==109 and u(i+1)==101 and u(i+2)==115 and u(i+3)==104 and digit(u(i+4)) then prefix,tokenType=4,'MESH_REF' end
        if tokenType then
          local j=i+prefix
          while j<n and digit(u(j)) do j=j+1 end
          local lexeme=slice(i,j)
          if tokenType=='OUTPUT_REF' and (not tokens[#tokens] or tokens[#tokens].type~='DOT') and
            not lexeme:match('^o[0-7]$') then
            fail('L004',string.format("Output surface reference '%s' is out of range; expected o0-o7 at line %d col %d",lexeme,startLine,startCol),i,j)
          end
          add(tokenType,lexeme,startLine,startCol,j)
          col,i=col+j-i,j
        elseif c==35 then
          local j=i+1
          while j<n and hex(u(j)) do j=j+1 end
          local len=j-i
          if len==4 or len==7 or len==9 then
            add('HEX',slice(i,j),startLine,startCol,j)
            col,i=col+len,j
          else fail('L001',string.format("Unexpected character '#' at line %d col %d",line,col),i,i+1) end
        elseif c==40 and u(i+1)==41 then
          local j=i+2
          while u(j)==32 or u(j)==9 do j=j+1 end
          if u(j)==61 and u(j+1)==62 then
            j=j+2
            while u(j)==32 or u(j)==9 do j=j+1 end
            local depth,exprStart=0,j
            while j<n do
              local x=u(j)
              if x==40 then depth=depth+1
              elseif x==41 then if depth==0 then break end; depth=depth-1
              elseif depth==0 and (x==44 or x==59 or x==10 or x==125) then break end
              j=j+1
            end
            add('FUNC',slice(exprStart,j):match('^%s*(.-)%s*$'),startLine,startCol,j)
            col,i=col+j-i,j
          else add('LPAREN','(',startLine,startCol,i+1); i,col=i+1,col+1 end
        elseif c==46 and digit(u(i+1)) then
          local j=i+1
          while j<n and digit(u(j)) do j=j+1 end
          add('NUMBER',slice(i,j),startLine,startCol,j)
          col,i=col+j-i,j
        elseif punctuation[ch(i)] then
          add(punctuation[ch(i)],ch(i),startLine,startCol,i+1)
          i,col=i+1,col+1
        elseif c==34 and u(i+1)==34 and u(i+2)==34 then
          local j=i+3
          while j<n-2 and not (u(j)==34 and u(j+1)==34 and u(j+2)==34) do
            if u(j)==10 then line,col=line+1,0 end
            j=j+1
          end
          if j>=n-2 then fail('L002',string.format('Unterminated triple-quoted string at line %d col %d',startLine,startCol),i,n) end
          local content=slice(i+3,j)
          add('STRING',content,startLine,startCol,j+3)
          local last=content:match('.*\n(.*)$')
          if last then col=#values.utf16(last)+4 else col=col+j-i+3 end
          i=j+3
        elseif c==34 or c==39 then
          local j=i+1
          while j<n and u(j)~=c and u(j)~=10 do
            if u(j)==92 and j+1<n then j=j+2 else j=j+1 end
          end
          if j>=n or u(j)==10 then fail('L002',string.format('Unterminated string literal at line %d col %d',line,col),i,j) end
          add('STRING',slice(i+1,j),startLine,startCol,j+1)
          col,i=col+j-i+1,j+1
        elseif digit(c) then
          local j=i
          while j<n and digit(u(j)) do j=j+1 end
          if u(j)==46 and digit(u(j+1)) then
            j=j+1
            while j<n and digit(u(j)) do j=j+1 end
          end
          add('NUMBER',slice(i,j),startLine,startCol,j)
          col,i=col+j-i,j
        elseif letter(c) or c==95 then
          local j=i
          while j<n and (letter(u(j)) or digit(u(j)) or u(j)==95) do j=j+1 end
          local lexeme=slice(i,j)
          add(M.RESERVED_KEYWORDS[lexeme] or 'IDENT',lexeme,startLine,startCol,j)
          col,i=col+j-i,j
        else
          fail('L001',string.format("Unexpected character '%s' at line %d col %d",ch(i),line,col),i,i+1)
        end
      end
    end
  end
  add('EOF','',line,col,n)
  return tokens
end
return M
