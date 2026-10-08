-- Byte-preserving GLSL lexer for structural rewrites. Offsets are 1-based inclusive.
local M = {}
function M.lex(source)
  assert(type(source) == 'string', 'shader source must be a string')
  local result, i, line, column, atLineStart = {}, 1, 1, 1, true
  local n = #source
  local function emit(kind, last)
    local first, firstLine, firstColumn = i, line, column
    local value = source:sub(first, last)
    result[#result + 1] = {kind = kind, text = value, start = first, stop = last, line = firstLine, column = firstColumn}
    for j = first, last do
      local byte = source:byte(j)
      if byte == 10 then line, column, atLineStart = line + 1, 1, true
      elseif byte ~= 13 then
        column = column + 1
        if byte ~= 32 and byte ~= 9 then atLineStart = false end
      end
    end
    i = last + 1
  end
  while i <= n do
    local c, d = source:sub(i, i), source:sub(i + 1, i + 1)
    if c == '#' and atLineStart then
      local j = source:find('\n', i, true) or (n + 1)
      emit('directive', j - 1)
    elseif c == '/' and d == '/' then
      local j = source:find('\n', i, true) or (n + 1)
      emit('comment', j - 1)
    elseif c == '/' and d == '*' then
      local j = source:find('*/', i + 2, true)
      if not j then return nil, {code = 'ERR_SHADER_UNTERMINATED_COMMENT', line = line, column = column} end
      emit('comment', j + 1)
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        if source:sub(j, j) == '\\' then j = j + 2
        elseif source:sub(j, j) == c then break
        else j = j + 1 end
      end
      if j > n then return nil, {code = 'ERR_SHADER_UNTERMINATED_STRING', line = line, column = column} end
      emit('string', j)
    elseif c:match('%s') then
      local j = i + 1
      while j <= n and source:sub(j, j):match('%s') do j = j + 1 end
      emit('whitespace', j - 1)
    elseif c:match('[%a_]') then
      local j = i + 1
      while j <= n and source:sub(j, j):match('[%w_]') do j = j + 1 end
      emit('identifier', j - 1)
    elseif c:match('%d') or (c == '.' and d:match('%d')) then
      local j = i + 1
      while j <= n and source:sub(j, j):match('[%w_%.]') do j = j + 1 end
      emit('number', j - 1)
    else emit('punctuation', i) end
  end
  return result
end
return M
