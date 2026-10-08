-- Fold only scalar GLSL sin/cos calls whose arguments are pure float constants.
-- Firefox WebGL2's translator folds these before GPU execution; the native
-- driver can evaluate the same constant cosine with lower precision.
local ffi = require('ffi')
local lexer = require('noisemaker.shaders.lexer')
local float = ffi.new('float[1]')
local M = {}

local function f32(value)
  if value ~= value or value == math.huge or value == -math.huge then return nil end
  float[0] = value
  value = tonumber(float[0])
  if value ~= value or value == math.huge or value == -math.huge then return nil end
  return value
end

local function significant(tokens)
  local result = {}
  for _, token in ipairs(tokens) do
    if token.kind ~= 'whitespace' and token.kind ~= 'comment' and token.kind ~= 'directive' then
      result[#result + 1] = token
    end
  end
  return result
end

local function atomicMacro(body)
  if #body == 1 then
    return body[1].kind == 'number' or body[1].kind == 'identifier'
  end
  if #body < 3 or body[1].text ~= '(' then return false end
  local depth = 0
  for i, token in ipairs(body) do
    if token.text == '(' then depth = depth + 1
    elseif token.text == ')' then
      depth = depth - 1
      if depth == 0 and i ~= #body then return false end
      if depth < 0 then return false end
    end
  end
  return depth == 0
end

local function expression(tokens, macros, active)
  local i = 1
  local parseSum, parseProduct, parseUnary
  local function primary()
    local token = tokens[i]
    if not token then return nil end
    if token.text == '(' then
      i = i + 1
      local value = parseSum()
      if not value or not tokens[i] or tokens[i].text ~= ')' then return nil end
      i = i + 1
      return value
    end
    if token.kind == 'number' then
      -- A bare integer has a different GLSL type and is not a scalar-float
      -- constant expression on its own. Reject it instead of coercing it.
      if not token.text:find('%.') and not token.text:find('[eE]') then return nil end
      local value = tonumber(token.text)
      if not value then return nil end
      i = i + 1
      return f32(value)
    end
    if token.kind == 'identifier' then
      local name = token.text
      local body = macros[name]
      -- Macros substitute tokens, not values. An unparenthesized expression
      -- can change precedence at its use site, so only atomic bodies are safe.
      if not body or not atomicMacro(body) or active[name] then return nil end
      active[name] = true
      local value = expression(body, macros, active)
      active[name] = nil
      if not value then return nil end
      i = i + 1
      return value
    end
    return nil
  end
  parseUnary = function()
    local token = tokens[i]
    if token and (token.text == '+' or token.text == '-') then
      i = i + 1
      local value = parseUnary()
      if not value then return nil end
      return f32(token.text == '-' and -value or value)
    end
    return primary()
  end
  parseProduct = function()
    local value = parseUnary()
    if not value then return nil end
    while tokens[i] and (tokens[i].text == '*' or tokens[i].text == '/') do
      local op = tokens[i].text
      i = i + 1
      local right = parseUnary()
      if not right or (op == '/' and right == 0) then return nil end
      value = f32(op == '*' and value * right or value / right)
      if not value then return nil end
    end
    return value
  end
  parseSum = function()
    local value = parseProduct()
    if not value then return nil end
    while tokens[i] and (tokens[i].text == '+' or tokens[i].text == '-') do
      local op = tokens[i].text
      i = i + 1
      local right = parseProduct()
      if not right then return nil end
      value = f32(op == '+' and value + right or value - right)
      if not value then return nil end
    end
    return value
  end
  local value = parseSum()
  if i <= #tokens then return nil end
  return value
end

local function macroBody(source)
  local tokens = lexer.lex(source)
  return tokens and significant(tokens) or nil
end

local function literal(value)
  local result = string.format('%.9g', value)
  if not result:find('[%.eE]') then result = result .. '.0' end
  return result
end

local function overlaps(edits, first, last)
  for _, edit in ipairs(edits) do
    if edit.last < edit.first then
      if edit.first >= first and edit.first <= last + 1 then return true end
    elseif edit.first <= last and edit.last >= first then
      return true
    end
  end
  return false
end

local returnTypes = {float = true, double = true, int = true, uint = true, bool = true,
  vec2 = true, vec3 = true, vec4 = true, dvec2 = true, dvec3 = true, dvec4 = true,
  ivec2 = true, ivec3 = true, ivec4 = true, uvec2 = true, uvec3 = true,
  uvec4 = true, bvec2 = true, bvec3 = true, bvec4 = true}

local function userFunctions(tokens)
  local shadows = {}
  for i, token in ipairs(tokens) do
    if token.kind == 'identifier' and (token.text == 'sin' or token.text == 'cos')
        and tokens[i + 1] and tokens[i + 1].text == '('
        and tokens[i - 1] and returnTypes[tokens[i - 1].text] then
      local depth = 1
      for j = i + 2, #tokens do
        if tokens[j].text == '(' then depth = depth + 1
        elseif tokens[j].text == ')' then
          depth = depth - 1
          if depth == 0 then
            if tokens[j + 1] and (tokens[j + 1].text == '{' or tokens[j + 1].text == ';') then
              shadows[token.text] = true
            end
            break
          end
        end
      end
    end
  end
  return shadows
end

function M.append(tokens, edits, externalDefines)
  local retained = {}
  for _, token in ipairs(tokens) do
    if token.kind ~= 'whitespace' and token.kind ~= 'comment' then retained[#retained + 1] = token end
  end
  tokens = retained
  local macros, conditional = {}, 0
  local functionShadows = userFunctions(tokens)
  local macroOverrides = {}
  for name in pairs(externalDefines or {}) do
    if name == 'sin' or name == 'cos' then macroOverrides[name] = true end
  end
  local count = 0
  for i, token in ipairs(tokens) do
    if token.kind == 'directive' then
      local directive, rest = token.text:match('^#%s*([%a_][%w_]*)%s*(.-)%s*$')
      if directive == 'if' or directive == 'ifdef' or directive == 'ifndef' then conditional = conditional + 1
      elseif directive == 'endif' then conditional = math.max(0, conditional - 1)
      elseif directive == 'define' then
        local name = rest:match('^([%a_][%w_]*)')
        if name then
          local body = rest:sub(#name + 1):match('^%s+(.+)$')
          macros[name] = body and conditional == 0 and macroBody(body) or nil
          if name == 'sin' or name == 'cos' then macroOverrides[name] = true end
        end
      elseif directive == 'undef' then
        local name = rest:match('^([%a_][%w_]*)')
        if name then macros[name] = nil end
        if name == 'sin' or name == 'cos' then macroOverrides[name] = conditional ~= 0 end
      end
    elseif token.kind == 'identifier' and (token.text == 'sin' or token.text == 'cos')
        and not functionShadows[token.text] and not macroOverrides[token.text] then
      local open = tokens[i + 1]
      if open and open.text == '(' then
        local depth, close = 1, nil
        for j = i + 2, #tokens do
          if tokens[j].text == '(' then depth = depth + 1
          elseif tokens[j].text == ')' then
            depth = depth - 1
            if depth == 0 then close = j; break end
          end
        end
        if close then
          local args, bad = {}, false
          for j = i + 2, close - 1 do
            local t = tokens[j]
            if t.kind == 'directive' then bad = true; break end
            if t.kind ~= 'whitespace' and t.kind ~= 'comment' then args[#args + 1] = t end
          end
          local angle = not bad and expression(args, macros, {}) or nil
          if angle and not overlaps(edits, token.start, tokens[close].stop) then
            local value = f32(math[token.text](angle))
            if value then
              edits[#edits + 1] = {first = token.start, last = tokens[close].stop, text = literal(value), line = token.line}
              count = count + 1
            end
          end
        end
      end
    end
  end
  return count
end

return M
