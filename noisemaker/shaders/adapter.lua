-- Structural GLSL 300 ES -> LÖVE GLSL 3 adapter. Original sources stay untouched.
local lexer = require('noisemaker.shaders.lexer')
local half = require('noisemaker.shaders.half')
local arrayIndex = require('noisemaker.shaders.array_index')
local constantTrig = require('noisemaker.shaders.constant_trig')
local M = {version = 5}

local function significant(tokens)
  local result = {}
  for _, token in ipairs(tokens) do
    if token.kind ~= 'whitespace' and token.kind ~= 'comment' and token.kind ~= 'directive' then
      result[#result + 1] = token
    end
  end
  return result
end

local function hash(source)
  if love and love.data then
    return love.data.encode('string', 'hex', love.data.hash('sha256', source))
  end
  return nil
end

local function diagnostic(code, message, token, path)
  return {code = code, detail = message, path = path, line = token and token.line, column = token and token.column}
end

local function add(edits, first, last, text, line)
  edits[#edits + 1] = {first = first, last = last, text = text or '', line = line or 0}
end

local function definesHeader(defines)
  local keys, lines = {}, {}
  for key in pairs(defines or {}) do if key ~= '__nm_order' then keys[#keys + 1] = key end end
  table.sort(keys)
  for _, key in ipairs(keys) do
    if not key:match('^[%a_][%w_]*$') then return nil, 'invalid define name: ' .. tostring(key) end
    local value = defines[key]
    if type(value) ~= 'number' and type(value) ~= 'boolean' and type(value) ~= 'string' then return nil, 'invalid define value: ' .. key end
    if type(value) == 'boolean' then value = value and 'true' or 'false' end
    value = tostring(value)
    if value:find('[\r\n]') then return nil, 'multiline define: ' .. key end
    lines[#lines + 1] = '#define ' .. key .. ' ' .. value .. '\n'
  end
  return table.concat(lines)
end

local function applyEdits(source, edits, prefix)
  for order, edit in ipairs(edits) do edit.order = order end
  table.sort(edits, function(a, b)
    if a.first ~= b.first then return a.first < b.first end
    local aInsert, bInsert = a.last < a.first, b.last < b.first
    if aInsert ~= bInsert then return aInsert end
    return a.order < b.order
  end)
  local chunks, lineMap, outputLine, cursor, sourceLine = {}, {}, 1, 1, 1
  local function append(text, inputLine, original)
    if text == '' then return end
    chunks[#chunks + 1] = text
    for i = 1, #text do
      if not lineMap[outputLine] then lineMap[outputLine] = inputLine end
      if text:byte(i) == 10 then
        outputLine = outputLine + 1
        if original then inputLine = inputLine + 1 end
      end
    end
  end
  append(prefix, 0, false)
  for _, edit in ipairs(edits) do
    if edit.first < cursor then return nil, nil, 'overlapping shader edits' end
    local prior = source:sub(cursor, edit.first - 1)
    append(prior, sourceLine, true)
    sourceLine = sourceLine + select(2, prior:gsub('\n', ''))
    append(edit.text, edit.line, false)
    sourceLine = sourceLine + select(2, source:sub(edit.first, edit.last):gsub('\n', ''))
    cursor = edit.last + 1
  end
  append(source:sub(cursor), sourceLine, true)
  return table.concat(chunks), lineMap
end

local function captureValue(reference, mode)
  if not mode then return reference end
  local alpha = reference .. '.a'
  return 'vec4(' .. alpha .. ', 0.0, 0.0, ' .. (mode == 'add' and '1.0' or alpha) .. ')'
end
local function captureAssignments(outputs, mode)
  if not mode then return '' end
  local lines = {}
  for _, output in ipairs(outputs) do
    local reference = 'love_Canvases[' .. output.location .. ']'
    lines[#lines + 1] = reference .. ' = ' .. captureValue(reference, mode) .. ';'
  end
  return table.concat(lines, '\n  ')
end
local function fixedPointSize(code)
  local positive, writes = nil, 0
  for i, token in ipairs(code) do
    if token.text == 'gl_PointSize' then
      local equals, literal, terminator = code[i + 1], code[i + 2], code[i + 3]
      if not equals or equals.text ~= '=' or not literal or literal.kind ~= 'number' or not terminator or terminator.text ~= ';' then return nil end
      local size = tonumber(literal.text)
      if not size or size < 0 or size == math.huge or size ~= size then return nil end
      if size > 0 then
        if positive and positive ~= size then return nil end
        positive = size
      end
      writes = writes + 1
    end
  end
  return writes > 0 and positive or nil
end
local outputQualifiers = {highp = true, mediump = true, lowp = true}
local function fragmentOutput(code, outIndex)
  local typeIndex = outIndex + (code[outIndex + 1] and outputQualifiers[code[outIndex + 1].text] and 2 or 1)
  local nameToken, semicolon = code[typeIndex + 1], code[typeIndex + 2]
  if code[typeIndex] and nameToken and nameToken.kind == 'identifier' and semicolon and semicolon.text == ';' then
    return nameToken, semicolon, typeIndex + 2
  end
end
local function stage(source, kind, spec)
  local tokens, lexError = lexer.lex(source)
  if not tokens then return nil, diagnostic(lexError.code, 'lexing failed', lexError, spec.path) end
  local code = significant(tokens)
  local edits, uniforms, outputs, outputName, mainOpen, mainClose = {}, {}, {}, nil, nil, nil
  local reserved = {}
  for name in pairs(spec.defines or {}) do reserved[name] = true end
  for _, token in ipairs(tokens) do
    if token.kind == 'identifier' then reserved[token.text] = true end
    if token.kind == 'directive' then
      for word in token.text:gmatch('[%a_][%w_]*') do reserved[word] = true end
    end
  end
  local function uniqueName(base)
    local name, suffix = base, 0
    while reserved[name] do suffix = suffix + 1; name = base .. '_' .. suffix end
    reserved[name] = true
    return name
  end
  if spec.captureAlpha and spec.captureAlpha ~= 'add' and spec.captureAlpha ~= 'src-alpha' then
    return nil, diagnostic('ERR_BLEND_CAPTURE', 'Unknown alpha capture mode', nil, spec.path)
  end
  local needsHalf = false
  local pointLowering = false
  local pointNativeSize
  if kind == 'vertex' then
    local directivePointSize, macroPointSize = false, false
    for _, token in ipairs(tokens) do
      if token.kind == 'directive' and token.text:find('gl_PointSize', 1, true) then
        directivePointSize = true
        if token.text:match('^#%s*define%s+') then macroPointSize = true end
      end
    end
    pointNativeSize = not directivePointSize and spec.drawMode == 'points' and fixedPointSize(code) or nil
    for _, token in ipairs(code) do if token.text == 'gl_PointSize' then pointLowering = not pointNativeSize; break end end
    if macroPointSize then pointLowering = true end
  end
  local pointSizeName = (pointLowering or pointNativeSize) and uniqueName('nmPointSize') or nil
  local pointClipName = pointLowering and uniqueName('nmPointClip') or nil
  local vertexReturn = pointLowering and ('return ' .. pointClipName .. '(gl_Position, ' .. pointSizeName .. ', vertex_position);')
    or pointNativeSize and ('return ' .. pointSizeName .. ' <= 0.0 ? vec4(2.0, 2.0, 2.0, 1.0) : gl_Position;')
    or 'return gl_Position;'
  local removed = {}
  for _, token in ipairs(tokens) do
    if token.kind == 'directive' and token.text:match('^#%s*version%s+') then
      add(edits, token.start, token.stop, '', token.line)
    elseif pointSizeName and token.kind == 'directive' and token.text:match('^#%s*define%s+')
        and token.text:find('gl_PointSize', 1, true) then
      add(edits, token.start, token.stop,
        (token.text:gsub('%f[%w_]gl_PointSize%f[^%w_]', pointSizeName)), token.line)
    end
  end
  local depth, i = 0, 1
  while i <= #code do
    local t = code[i]
    local value = t.text
    if value == '{' then depth = depth + 1
    elseif value == '}' then depth = depth - 1
    end
    if depth == 0 then
      if value == 'precision' and code[i + 3] and code[i + 3].text == ';' then
        add(edits, t.start, code[i + 3].stop, '', t.line)
        i = i + 3
      elseif value == 'layout' and code[i + 1] and code[i + 1].text == '(' then
        local j = i + 2
        while code[j] and code[j].text ~= ')' do j = j + 1 end
        if code[j] and code[j + 1] and code[j + 1].text == 'uniform' and code[j + 2] and code[j + 2].text == 'RemapUniforms' and code[j + 3] and code[j + 3].text == '{' then
          local k, braces = j + 3, 0
          repeat
            if code[k].text == '{' then braces = braces + 1 elseif code[k].text == '}' then braces = braces - 1 end
            k = k + 1
          until braces == 0 or not code[k]
          if not code[k] or code[k].text ~= ';' then return nil, diagnostic('ERR_SHADER_BLOCK', 'malformed RemapUniforms block', t, spec.path) end
          add(edits, t.start, code[k].stop, '', t.line)
          removed[#removed + 1] = {t.start, code[k].stop}
          uniforms.nmRemapDataTexture = {type = 'sampler2D', count = 1, lowering = 'synth/remap data[275] rgba32f texture'}
          i = k
        elseif kind == 'pixel' and code[j] and code[j + 1] and code[j + 1].text == 'out' then
          local nameToken, semicolon, endIndex = fragmentOutput(code, j + 1)
          if nameToken then
            local location
            for k = i + 2, j - 1 do if code[k].text == 'location' and code[k + 1] and code[k + 1].text == '=' then location = tonumber(code[k + 2].text) end end
            outputs[#outputs + 1] = {name = nameToken.text, location = location or #outputs}
            add(edits, t.start, semicolon.stop, '', t.line)
            removed[#removed + 1] = {t.start, semicolon.stop}
            i = endIndex
          end
        end
      elseif kind == 'pixel' and value == 'out' then
        local nameToken, semicolon, endIndex = fragmentOutput(code, i)
        if nameToken then
          outputs[#outputs + 1] = {name = nameToken.text, location = #outputs}
          add(edits, t.start, semicolon.stop, '', t.line)
          removed[#removed + 1] = {t.start, semicolon.stop}
          i = endIndex
        end
      elseif (kind == 'pixel' and value == 'in') or (kind == 'vertex' and value == 'out') then
        if code[i + 1] and code[i + 2] and code[i + 3] and code[i + 3].text == ';' then
          add(edits, t.start, t.stop, 'varying', t.line)
        end
      elseif value == 'uniform' and code[i + 1] and code[i + 2] then
        local ty, name = code[i + 1].text, code[i + 2].text
        local count = 1
        if code[i + 3] and code[i + 3].text == '[' and code[i + 4] then count = tonumber(code[i + 4].text) or 0 end
        uniforms[name] = {type = ty, count = count}
      elseif value == 'void' and code[i + 1] and code[i + 1].text == 'main' and code[i + 2] and code[i + 2].text == '(' and code[i + 3] and code[i + 3].text == ')' and code[i + 4] and code[i + 4].text == '{' then
        mainOpen = i + 4
        local k, braces = mainOpen, 0
        repeat
          if code[k].text == '{' then braces = braces + 1 elseif code[k].text == '}' then braces = braces - 1 end
          k = k + 1
        until braces == 0 or not code[k]
        if braces ~= 0 then return nil, diagnostic('ERR_SHADER_MAIN', 'unterminated main', t, spec.path) end
        mainClose = k - 1
        local signature
        if kind == 'pixel' then
          signature = (#outputs > 1 and 'void effect() {' or 'vec4 effect(vec4 nmDrawColor, Image nmSourceTexture, vec2 nmTexcoord, vec2 nmScreenCoords) {')
          if #outputs == 1 then outputName = outputs[1].name; signature = signature .. '\n  vec4 ' .. outputName .. ' = vec4(0.0);' end
        else
          signature = 'vec4 position(mat4 transform_projection, vec4 vertex_position) {'
        end
        add(edits, t.start, code[mainOpen].stop, signature, t.line)
        add(edits, code[mainClose].start, code[mainClose].start - 1,
          kind == 'vertex' and ('\n  ' .. vertexReturn .. '\n') or (#outputs > 1 and ('\n  ' .. captureAssignments(outputs, spec.captureAlpha) .. '\n') or '\n  return ' .. captureValue(outputName or 'vec4(0.0)', spec.captureAlpha) .. ';\n'),
          code[mainClose].line)
        i = mainClose
      end
    end
    i = i + 1
  end
  if not mainOpen then return nil, diagnostic('ERR_SHADER_MAIN', 'main() not found', nil, spec.path) end
  if uniforms.nmRemapDataTexture then
    for j, t in ipairs(code) do
      if t.text == 'data' and code[j + 1] and code[j + 1].text == '[' then
        local k, brackets = j + 1, 0
        repeat
          if code[k].text == '[' then brackets = brackets + 1 elseif code[k].text == ']' then brackets = brackets - 1 end
          k = k + 1
        until brackets == 0 or not code[k]
        local insideRemoved = false
        for _, range in ipairs(removed) do if t.start >= range[1] and t.start <= range[2] then insideRemoved = true end end
        if not insideRemoved and brackets == 0 then
          add(edits, t.start, code[k - 1].stop,
            'nmRemapData(' .. source:sub(code[j + 1].stop + 1, code[k - 1].start - 1) .. ')', t.line)
        end
      end
    end
  end
  for _, t in ipairs(code) do
    if t.text == 'number' then add(edits, t.start, t.stop, 'nmNumberValue', t.line) end
    if pointSizeName and t.text == 'gl_PointSize' then add(edits, t.start, t.stop, pointSizeName, t.line) end
    if pointLowering and t.text == 'gl_VertexID' then add(edits, t.start, t.stop, 'love_InstanceID', t.line)
    elseif kind == 'vertex' and spec.drawMode == 'billboards' and t.text == 'gl_VertexID' then
      add(edits, t.start, t.stop, '(love_InstanceID * 6 + gl_VertexID)', t.line)
    end
    if t.text == 'packHalf2x16' then add(edits, t.start, t.stop, 'nmPackHalf2x16', t.line); needsHalf = true end
    if t.text == 'unpackHalf2x16' then add(edits, t.start, t.stop, 'nmUnpackHalf2x16', t.line); needsHalf = true end
  end
  if kind == 'pixel' and #outputs > 1 then
    for _, t in ipairs(code) do
      if t.kind == 'identifier' then
        for _, output in ipairs(outputs) do
          if t.text == output.name then
            local insideRemoved = false
            for _, range in ipairs(removed) do if t.start >= range[1] and t.start <= range[2] then insideRemoved = true end end
            if not insideRemoved then add(edits, t.start, t.stop, 'love_Canvases[' .. output.location .. ']', t.line) end
          end
        end
      end
    end
  end
  for j = mainOpen + 1, mainClose - 1 do
    local t = code[j]
    if t.text == 'return' and code[j + 1] and code[j + 1].text == ';' then
      if kind == 'vertex' then add(edits, t.start, code[j + 1].stop, vertexReturn, t.line)
      elseif #outputs <= 1 then add(edits, t.start, code[j + 1].stop, 'return ' .. captureValue(outputName or 'vec4(0.0)', spec.captureAlpha) .. ';', t.line)
      elseif spec.captureAlpha then add(edits, t.start, code[j + 1].stop, captureAssignments(outputs, spec.captureAlpha) .. '\n  return;', t.line) end
    end
  end
  local header = '#pragma language glsl3\n'
  local definitions, defineError = definesHeader(spec.defines)
  if not definitions then return nil, diagnostic('ERR_SHADER_DEFINE', defineError, nil, spec.path) end
  header = header .. definitions
  if needsHalf then header = header .. half .. '\n' end
  if pointSizeName then header = header .. 'float ' .. pointSizeName .. ' = 1.0;\n' end
  if pointLowering then header = header .. 'vec4 ' .. pointClipName .. [[(vec4 center, float size, vec4 corner) {
  vec2 offset = corner.xy * max(size, 0.0) * (2.0 / love_ScreenSize.xy) * center.w;
  return center + vec4(offset, 0.0, 0.0);
}
]] end
  if uniforms.nmRemapDataTexture then
    header = header .. 'uniform sampler2D nmRemapDataTexture;\nvec4 nmRemapData(int slot) { return texelFetch(nmRemapDataTexture, ivec2(slot, 0), 0); }\n'
  end
  local function integerMacro(value)
    if type(value) == 'string' then
      value = value:gsub('//.*$', ''):gsub('/%*.-%*/%s*$', '')
      value = value:match('^%s*(%d+)%s*$') or value:match('^%s*%(%s*(%d+)%s*%)%s*$')
    end
    local number = tonumber(value)
    return number and number >= 1 and number == math.floor(number) and number or true
  end
  local macros, seen, conditionalDepth = {}, {}, 0
  for name, value in pairs(spec.defines or {}) do macros[name] = integerMacro(value); seen[name] = true end
  for _, token in ipairs(tokens) do
    if token.kind == 'directive' then
      local directive = token.text:match('^#%s*([%a_][%w_]*)')
      if directive == 'if' or directive == 'ifdef' or directive == 'ifndef' then
        conditionalDepth = conditionalDepth + 1
      elseif directive == 'endif' then
        conditionalDepth = math.max(0, conditionalDepth - 1)
      elseif directive == 'define' then
        local name, value = token.text:match('^#%s*define%s+([%a_][%w_]*)(.*)$')
        if name then
          macros[name] = seen[name] or conditionalDepth > 0 and true or integerMacro(value)
          seen[name] = true
        end
      elseif directive == 'undef' then
        local name = token.text:match('^#%s*undef%s+([%a_][%w_]*)')
        if name then macros[name] = true; seen[name] = true end
      end
    end
  end
  local helperName = uniqueName('nmArrayIndexValue')
  if arrayIndex.append(code, edits, macros, helperName) then
    header = header .. 'float ' .. helperName .. '(int index) { return float(index); }\n'
      .. 'float ' .. helperName .. '(uint index) { return float(index); }\n'
  end
  constantTrig.append(tokens, edits, spec.defines)
  local transformed, lineMap, applyError = applyEdits(source, edits, header)
  if not transformed then return nil, diagnostic('ERR_SHADER_EDIT', applyError, nil, spec.path) end
  return {source = transformed, uniforms = uniforms, outputs = outputs, lineMap = lineMap, pointLowering = pointLowering, pointNativeSize = pointNativeSize}
end

function M.adapt(spec)
  if type(spec) ~= 'table' then return nil, diagnostic('ERR_SHADER_SPEC', 'expected a program table') end
  local pixelSource = spec.pixel or spec.glsl or spec.fragment
  if type(pixelSource) ~= 'string' or pixelSource == '' then return nil, diagnostic('ERR_SHADER_MISSING', 'pixel shader is missing', nil, spec.path) end
  local pixel, err
  local vertex
  if spec.vertex then
    vertex, err = stage(spec.vertex, 'vertex', spec)
    if not vertex then return nil, err end
  end
  pixel, err = stage(pixelSource, 'pixel', spec)
  if not pixel then return nil, err end
  local uniforms = {}
  for key, value in pairs(pixel.uniforms) do uniforms[key] = value end
  if vertex then for key, value in pairs(vertex.uniforms) do uniforms[key] = value end end
  local defaultVertex = [[#pragma language glsl3
varying vec2 v_texCoord;
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  VaryingTexCoord.xy = VertexTexCoord.xy;
  v_texCoord = VertexTexCoord.xy;
  return vec4(VertexTexCoord.xy * 2.0 - 1.0, 0.0, 1.0);
}
]]
  return {
    pixel = pixel.source,
    vertex = vertex and vertex.source or defaultVertex,
    uniforms = uniforms,
    outputs = pixel.outputs,
    drawMode = vertex and vertex.pointLowering and 'point_quads' or (spec.vertex and 'custom' or 'fullscreen'),
    pointNativeSize = vertex and vertex.pointNativeSize or nil,
    pointQuad = vertex and vertex.pointLowering and {vertices = 6, instances = 'sourceVertexCount', corner = 'VertexPosition.xy[-0.5,0.5]', texcoord = 'VertexTexCoord.xy[0,1]'} or nil,
    provenance = {
      path = spec.path,
      inputHash = spec.hash or hash(pixelSource),
      generatedHash = hash(pixel.source),
      vertexInputHash = spec.vertexHash or (spec.vertex and hash(spec.vertex) or nil),
      vertexGeneratedHash = hash(vertex and vertex.source or defaultVertex),
      adapterVersion = M.version,
      defines = spec.defines or {},
      pixelLineMap = pixel.lineMap,
      vertexLineMap = vertex and vertex.lineMap or nil,
    },
  }
end
return M
