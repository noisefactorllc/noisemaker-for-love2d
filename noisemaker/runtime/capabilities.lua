-- Isolated LÖVE 11.x GPU capability evidence. No result is a parity claim.
local M = {}

local function escape(s)
  return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c)
    local codes = {['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
    return codes[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function encode(value)
  local kind = type(value)
  if kind == 'nil' then return 'null' end
  if kind == 'boolean' then return value and 'true' or 'false' end
  if kind == 'number' then
    if value ~= value or value == math.huge or value == -math.huge then return 'null' end
    return tostring(value)
  end
  if kind == 'string' then return escape(value) end
  if kind ~= 'table' then return escape(tostring(value)) end
  local n, count, array = 0, 0, true
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then array = false
    elseif key > n then n = key end
  end
  if array and n == count and n > 0 then
    local parts = {}
    for i = 1, n do parts[i] = encode(value[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  local keys, parts = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for i, key in ipairs(keys) do parts[i] = escape(key) .. ':' .. encode(value[key]) end
  return '{' .. table.concat(parts, ',') .. '}'
end
M.json = encode

local function query(fn, ...)
  if type(fn) ~= 'function' then return nil end
  local ok, result = pcall(fn, ...)
  if ok then return result end
  return nil
end

local function identity(api)
  local major, minor, revision, codename
  if api.getVersion then
    local ok
    ok, major, minor, revision, codename = pcall(api.getVersion)
    if not ok then major, minor, revision, codename = nil, nil, nil, nil end
  end
  local g = api.graphics or {}
  local renderer = {}
  if g.getRendererInfo then
    local ok, name, version, vendor, device = pcall(g.getRendererInfo)
    if ok then renderer = {name = name, version = version, vendor = vendor, device = device} end
  end
  return {
    love = {major = major, minor = minor, revision = revision, codename = codename},
    os = api.system and query(api.system.getOS) or nil,
    jit = jit and {version = jit.version, arch = jit.arch, os = jit.os} or nil,
    renderer = renderer,
    gammaCorrect = query(g.isGammaCorrect),
    supported = query(g.getSupported) or {},
    canvasFormats = query(g.getCanvasFormats) or {},
    imageFormats = query(g.getImageFormats) or {},
    textureTypes = query(g.getTextureTypes) or {},
    limits = query(g.getSystemLimits) or {},
  }
end

local function neutral(g)
  if not g.setCanvas then return end
  g.setCanvas()
  g.origin()
  g.setScissor()
  g.setShader()
  g.setColor(1, 1, 1, 1)
  g.setBlendMode('replace', 'premultiplied')
  g.setColorMask(true, true, true, true)
  g.setDepthMode('always', false)
  g.setMeshCullMode('none')
  g.setPointSize(1)
end

local function runCase(api, case, host)
  local g = api.graphics
  local owned = {}
  local scope = {formats = host and host.canvasFormats, imageFormats = host and host.imageFormats, types = host and host.textureTypes, limits = host and host.limits}
  function scope:own(object)
    owned[#owned + 1] = object
    return object
  end
  function scope:unsupported(reason) error('UNSUPPORTED: ' .. reason, 0) end
  function scope:check(condition, reason)
    if not condition then error('PIXEL MISMATCH: ' .. reason, 0) end
  end
  function scope:canvas(w, h, settings)
    local ok, value = pcall(g.newCanvas, w, h, settings or {format = 'rgba8', dpiscale = 1})
    if not ok then self:unsupported('canvas allocation: ' .. tostring(value)) end
    return self:own(value)
  end
  function scope:shader(pixel, vertex)
    local ok, value = pcall(g.newShader, pixel, vertex)
    if not ok then self:unsupported('shader compilation: ' .. tostring(value)) end
    return self:own(value)
  end
  function scope:pixels(canvas)
    g.setCanvas()
    local ok, value = pcall(canvas.newImageData, canvas)
    if not ok then error('readback: ' .. tostring(value), 0) end
    return self:own(value)
  end
  local pushed, result, reason = false, nil, nil
  local ok, err = xpcall(function()
    g.push('all')
    pushed = true
    neutral(g)
    result = case.run(scope, api)
  end, function(e) return tostring(e) end)
  if not ok then reason = err end
  local restoreOk, restoreErr = true, nil
  if pushed then restoreOk, restoreErr = pcall(g.pop) end
  local cleanupErrors = {}
  for i = #owned, 1, -1 do
    local object = owned[i]
    if object.release then
      local releaseOk, releaseErr = pcall(object.release, object)
      if not releaseOk then cleanupErrors[#cleanupErrors + 1] = tostring(releaseErr) end
    end
  end
  if not restoreOk then reason = 'graphics state restoration: ' .. tostring(restoreErr) end
  if #cleanupErrors > 0 then reason = (reason and reason .. '; ' or '') .. 'resource release: ' .. table.concat(cleanupErrors, '; ') end
  if reason then
    local unsupported = reason:sub(1, 13) == 'UNSUPPORTED: '
    return {status = unsupported and 'unsupported' or 'fail', reason = reason:gsub('^UNSUPPORTED: ', '')}
  end
  return {status = 'pass', evidence = result or {}}
end

local function pixel(data, x, y, expected, tolerance)
  local r, g, b, a = data:getPixel(x, y)
  local got = {r, g, b, a}
  for i = 1, 4 do
    if math.abs(got[i] - expected[i]) > (tolerance or 0.012) then
      error(string.format('PIXEL MISMATCH at %d,%d channel %d: %.6f expected %.6f', x, y, i, got[i], expected[i]), 0)
    end
  end
end

local function near(data, x, y, expected, tolerance)
  for dy = -1, 1 do
    for dx = -1, 1 do
      local ok = pcall(pixel, data, x + dx, y + dy, expected, tolerance)
      if ok then return end
    end
  end
  error(string.format('PIXEL MISMATCH near %d,%d', x, y), 0)
end

local pixelColor = [[
#pragma language glsl3
vec4 effect(vec4 color, Image texture, vec2 tc, vec2 sc) { return vec4(0.2, 0.4, 0.7, 0.8); }
]]

local function solid(s, api)
  local g = api.graphics
  local c = s:canvas(8, 8)
  g.setCanvas(c)
  g.clear(0, 0, 0, 0)
  g.setShader(s:shader(pixelColor))
  g.rectangle('fill', 0, 0, 8, 8)
  local d = s:pixels(c)
  pixel(d, 4, 4, {0.2, 0.4, 0.7, 0.8})
  return {checkedPixels = 1, dimensions = {8, 8}, blend = 'replace,premultiplied'}
end

local function marker(s, api)
  local g = api.graphics
  local c = s:canvas(257, 129)
  g.setCanvas(c)
  g.clear(0, 0, 0, 0)
  local corners = {
    {0, 0, {1, 0, 0, 0.25}}, {253, 0, {0, 1, 0, 0.5}},
    {0, 125, {0, 0, 1, 0.75}}, {253, 125, {1, 1, 0, 1}},
  }
  for _, item in ipairs(corners) do
    g.setColor(unpack(item[3]))
    g.rectangle('fill', item[1], item[2], 4, 4)
  end
  for x = 32, 224, 32 do
    g.setColor(x / 256, 0, 1 - x / 256, x / 256)
    g.rectangle('fill', x, 63, 1, 1)
  end
  local d = s:pixels(c)
  for _, item in ipairs(corners) do pixel(d, item[1] + 1, item[2] + 1, item[3]) end
  pixel(d, 128, 63, {0.5, 0, 0.5, 0.5})
  pixel(d, 128, 32, {0, 0, 0, 0})
  return {checkedPixels = 6, dimensions = {257, 129}, alpha = true, blend = 'replace,premultiplied'}
end

local function floatTarget(s, api)
  local g = api.graphics
  if s.formats and not s.formats.rgba16f then s:unsupported('rgba16f Canvas format unavailable') end
  local c = s:canvas(4, 4, {format = 'rgba16f', dpiscale = 1})
  local shader = s:shader([[
#pragma language glsl3
vec4 effect(vec4 color, Image texture, vec2 tc, vec2 sc) { return vec4(1.25, -0.25, 0.5, 0.75); }
]])
  g.setCanvas(c)
  g.clear(0, 0, 0, 0)
  g.setShader(shader)
  g.rectangle('fill', 0, 0, 4, 4)
  pixel(s:pixels(c), 2, 2, {1.25, -0.25, 0.5, 0.75}, 0.003)
  return {checkedPixels = 1, format = 'rgba16f'}
end

local function mrt(s, api)
  local g = api.graphics
  if s.limits and (s.limits.multicanvas or 0) < 2 then s:unsupported('fewer than two Canvas attachments') end
  local a, b = s:canvas(4, 4), s:canvas(4, 4)
  local shader = s:shader([[
#pragma language glsl3
void effect() {
  love_Canvases[0] = vec4(1.0, 0.0, 0.0, 0.25);
  love_Canvases[1] = vec4(0.0, 0.0, 1.0, 0.75);
}
]])
  g.setCanvas(a, b)
  g.clear(0, 0, 0, 0)
  g.setShader(shader)
  g.rectangle('fill', 0, 0, 4, 4)
  pixel(s:pixels(a), 2, 2, {1, 0, 0, 0.25})
  pixel(s:pixels(b), 2, 2, {0, 0, 1, 0.75})
  return {checkedPixels = 2, attachments = 2}
end

local function halfPacking(s, api)
  local g = api.graphics
  if s.formats and not s.formats.rgba16f then s:unsupported('rgba16f Canvas format unavailable') end
  local c = s:canvas(4, 4, {format = 'rgba16f', dpiscale = 1})
  g.setCanvas(c)
  g.setShader(s:shader([[
#pragma language glsl3
vec4 effect(vec4 color, Image texture, vec2 tc, vec2 sc) {
  uint packed = packHalf2x16(vec2(0.25, -0.5));
  vec2 decoded = unpackHalf2x16(packed);
  return vec4(float(packed & 65535u) / 65535.0, float(packed >> 16) / 65535.0, decoded);
}
]]))
  g.rectangle('fill', 0, 0, 4, 4)
  pixel(s:pixels(c), 2, 2, {13312 / 65535, 47104 / 65535, 0.25, -0.5}, 0.003)
  return {checkedPixels = 1, vectors = {{0.25, -0.5}}, format = 'rgba16f'}
end

local function remapLowering(s, api)
  local g = api.graphics
  if s.imageFormats and not s.imageFormats.rgba32f then s:unsupported('rgba32f Image format unavailable') end
  if s.formats and not s.formats.rgba16f then s:unsupported('rgba16f Canvas format unavailable') end
  local data = s:own(api.image.newImageData(275, 1, 'rgba32f'))
  data:setPixel(0, 0, 0.1, 0.2, 0.3, 0.4)
  data:setPixel(274, 0, 0.25, 0.3, 0.35, 0.4)
  local texture = s:own(g.newImage(data))
  texture:setFilter('nearest', 'nearest')
  local c = s:canvas(4, 4, {format = 'rgba16f', dpiscale = 1})
  local shader = s:shader([[
#pragma language glsl3
uniform Image remapDataTexture;
uniform int lastSlot;
vec4 remapData(int slot) { return texelFetch(remapDataTexture, ivec2(slot, 0), 0); }
vec4 effect(vec4 color, Image texture, vec2 tc, vec2 sc) {
  return remapData(0) + remapData(lastSlot);
}
]])
  shader:send('remapDataTexture', texture)
  shader:send('lastSlot', 274)
  g.setCanvas(c)
  g.setShader(shader)
  g.rectangle('fill', 0, 0, 4, 4)
  pixel(s:pixels(c), 2, 2, {0.35, 0.5, 0.65, 0.8}, 0.003)
  return {checkedPixels = 1, source = 'synth/remap RemapUniforms.data[275]', lowering = 'rgba32f texelFetch', slots = 275}
end

local pointFragment = [[
#pragma language glsl3
varying vec4 probeColor;
vec4 effect(vec4 color, Image texture, vec2 tc, vec2 sc) { return probeColor; }
]]
local function points(s, api)
  local g = api.graphics
  local c = s:canvas(32, 32)
  g.setCanvas(c)
  g.clear(0, 0, 0, 0)
  local shader = s:shader(pointFragment, [[
#pragma language glsl3
varying vec4 probeColor;
vec4 position(mat4 tp, vec4 vp) {
  int id = gl_VertexID;
  probeColor = id == 0 ? vec4(1,0,0,1) : (id == 1 ? vec4(0,1,0,1) : vec4(0,0,1,1));
  return tp * vec4(5.0 + float(id) * 10.0, 16.0, 0.0, 1.0);
}
]])
  g.setShader(shader)
  g.setPointSize(3)
  g.points({{0, 0}, {0, 0}, {0, 0}})
  local d = s:pixels(c)
  near(d, 5, 16, {1, 0, 0, 1})
  near(d, 15, 16, {0, 1, 0, 1})
  near(d, 25, 16, {0, 0, 1, 1})
  return {checkedPoints = 3, primitive = 'points', index = 'gl_VertexID'}
end

local function vertexFetch(s, api)
  local g = api.graphics
  local data = s:own(api.image.newImageData(3, 1, 'rgba8'))
  data:setPixel(0, 0, 1, 0, 0, 1)
  data:setPixel(1, 0, 0, 1, 0, 1)
  data:setPixel(2, 0, 0, 0, 1, 1)
  local texture = s:own(g.newImage(data))
  texture:setFilter('nearest', 'nearest')
  local c = s:canvas(32, 32)
  local shader = s:shader(pointFragment, [[
#pragma language glsl3
uniform Image stateTexture;
varying vec4 probeColor;
vec4 position(mat4 tp, vec4 vp) {
  int id = gl_VertexID;
  probeColor = texelFetch(stateTexture, ivec2(id, 0), 0);
  return tp * vec4(5.0 + float(id) * 10.0, 16.0, 0.0, 1.0);
}
]])
  shader:send('stateTexture', texture)
  g.setCanvas(c)
  g.clear(0, 0, 0, 0)
  g.setShader(shader)
  g.setPointSize(3)
  g.points({{0, 0}, {0, 0}, {0, 0}})
  local d = s:pixels(c)
  near(d, 5, 16, {1, 0, 0, 1})
  near(d, 15, 16, {0, 1, 0, 1})
  near(d, 25, 16, {0, 0, 1, 1})
  return {checkedPoints = 3, stage = 'vertex', operation = 'texelFetch'}
end

local function pointSize(s, api)
  local g = api.graphics
  if s.limits and (s.limits.pointsize or 0) < 7 then s:unsupported('maximum point size below 7') end
  local c = s:canvas(32, 32)
  local shader = s:shader(pointFragment, [[
#pragma language glsl3
varying vec4 probeColor;
vec4 position(mat4 tp, vec4 vp) {
  gl_PointSize = gl_VertexID == 0 ? 1.0 : 7.0;
  probeColor = vec4(1,1,1,1);
  return tp * vec4(gl_VertexID == 0 ? 8.0 : 24.0, 16.0, 0.0, 1.0);
}
]])
  g.setCanvas(c)
  g.clear(0, 0, 0, 0)
  g.setShader(shader)
  g.setPointSize(1)
  g.points({{0, 0}, {0, 0}})
  local d = s:pixels(c)
  near(d, 8, 16, {1, 1, 1, 1})
  near(d, 24, 16, {1, 1, 1, 1})
  local function widthAt(cx)
    local largest = 0
    for y = 15, 17 do
      local width = 0
      for x = cx - 4, cx + 4 do
        local _, _, _, alpha = d:getPixel(x, y)
        if alpha > 0.9 then width = width + 1 end
      end
      if width > largest then largest = width end
    end
    return largest
  end
  local narrow, wide = widthAt(8), widthAt(24)
  s:check(narrow <= 2 and wide >= 5,
    string.format('gl_PointSize requested widths 1 and 7; observed %d and %d', narrow, wide))
  return {checkedPoints = 2, requestedWidths = {1, 7}, observedWidths = {narrow, wide}, operation = 'gl_PointSize'}
end

local function volume(s, api)
  local g = api.graphics
  if s.types and not s.types.volume then s:unsupported('volume texture type unavailable') end
  local ok, volumeCanvas = pcall(g.newCanvas, 2, 2, 2, {type = 'volume', format = 'rgba8', dpiscale = 1})
  if not ok then s:unsupported('volume Canvas allocation: ' .. tostring(volumeCanvas)) end
  s:own(volumeCanvas)
  volumeCanvas:setFilter('nearest', 'nearest')
  g.setCanvas(volumeCanvas, 1)
  g.clear(1, 0, 0, 1)
  g.setCanvas(volumeCanvas, 2)
  g.clear(0, 1, 0, 1)
  local c = s:canvas(4, 4)
  local shader = s:shader([[
#pragma language glsl3
uniform VolumeImage volumeTexture;
vec4 effect(vec4 color, Image sourceTexture, vec2 tc, vec2 sc) {
  float z = sc.x < 2.0 ? 0.25 : 0.75;
  return Texel(volumeTexture, vec3(0.5, 0.5, z));
}
]])
  shader:send('volumeTexture', volumeCanvas)
  g.setCanvas(c)
  g.setShader(shader)
  g.rectangle('fill', 0, 0, 4, 4)
  local d = s:pixels(c)
  pixel(d, 0, 2, {1, 0, 0, 1})
  pixel(d, 3, 2, {0, 1, 0, 1})
  return {checkedPixels = 2, slices = 2, type = 'volume'}
end

local function stateSnapshot(g)
  local canvas = g.getCanvas()
  local shader = g.getShader()
  local r, gr, b, a = g.getColor()
  local sx, sy, sw, sh = g.getScissor()
  local blend, alpha = g.getBlendMode()
  local depth, writeDepth = g.getDepthMode()
  local maskR, maskG, maskB, maskA = g.getColorMask()
  local tx, ty = g.transformPoint(0, 0)
  local ux, uy = g.transformPoint(1, 1)
  return {
    canvas, shader, r, gr, b, a, sx, sy, sw, sh,
    blend, alpha, depth, writeDepth, g.getMeshCullMode(),
    maskR, maskG, maskB, maskA, g.getPointSize(), tx, ty, ux, uy,
  }
end

local function assertState(actual, expected, phase)
  for i = 1, 24 do
    if actual[i] ~= expected[i] then
      error('GRAPHICS STATE MISMATCH after ' .. phase .. ' at field ' .. i .. ': ' .. tostring(actual[i]) .. ' expected ' .. tostring(expected[i]), 0)
    end
  end
end

local function stateRestoration(s, api)
  local g = api.graphics
  local hostCanvas = s:canvas(16, 16)
  local hostShader = s:shader([[
#pragma language glsl3
vec4 effect(vec4 color, Image sourceTexture, vec2 tc, vec2 sc) { return vec4(0.6, 0.2, 0.4, 1.0); }
]])
  g.setCanvas(hostCanvas)
  g.translate(2, 3)
  g.scale(1.25, 0.75)
  g.setScissor(1, 2, 8, 9)
  g.setColor(0.8, 0.3, 0.7, 0.6)
  g.setBlendMode('add', 'premultiplied')
  g.setDepthMode('less', true)
  g.setMeshCullMode('back')
  g.setColorMask(true, false, true, false)
  g.setPointSize(5)
  g.setShader(hostShader)
  local before = stateSnapshot(g)
  local success = runCase(api, {name = 'nested_success', run = function(n)
    local c = n:canvas(4, 4)
    g.setCanvas(c)
    g.setColor(1, 1, 1, 1)
    g.rectangle('fill', 0, 0, 4, 4)
    return {drawn = true}
  end})
  s:check(success.status == 'pass', 'nested success case: ' .. tostring(success.reason))
  assertState(stateSnapshot(g), before, 'successful draw')
  local failure = runCase(api, {name = 'nested_failure', run = function(n)
    n:own({release = function() end})
    g.setCanvas()
    g.setShader()
    g.translate(17, 19)
    error('deliberate probe failure')
  end})
  s:check(failure.status == 'fail' and failure.reason:find('deliberate probe failure', 1, true), 'deliberate failure was not recorded')
  assertState(stateSnapshot(g), before, 'deliberate failure')
  local compileFailure = runCase(api, {name = 'nested_shader_failure', run = function(n)
    local temporary = n:canvas(4, 4)
    g.setCanvas(temporary)
    g.setColor(0.1, 0.2, 0.3, 0.4)
    n:shader([[
#pragma language glsl3
vec4 effect(vec4 color, Image sourceTexture, vec2 tc, vec2 sc) {
  return vec4(UNDEFINED_SHADER_SYMBOL);
}
]])
  end})
  s:check(compileFailure.status == 'unsupported' and
    compileFailure.reason:find('shader compilation', 1, true),
    'broken shader compile was not recorded as unsupported: ' .. tostring(compileFailure.reason))
  assertState(stateSnapshot(g), before, 'broken shader compilation')
  return {checked = {'canvas', 'shader', 'color', 'scissor', 'blend', 'depth', 'cull', 'colorMask', 'pointSize', 'transform'}, paths = {'success', 'Lua error', 'shader compilation error'}}
end

M.cases = {
  {name = 'solid', run = solid},
  {name = 'asymmetric_alpha_marker', run = marker},
  {name = 'float_target', run = floatTarget},
  {name = 'mrt_two_outputs', run = mrt},
  {name = 'half_packing', run = halfPacking},
  {name = 'synth_remap_uniform_lowering', run = remapLowering},
  {name = 'gl_VertexID_points', run = points},
  {name = 'vertex_texelFetch', run = vertexFetch},
  {name = 'gl_PointSize', run = pointSize},
  {name = 'volume_texture', run = volume},
  {name = 'state_restoration', run = stateRestoration},
}

function M.run(api, cases)
  api = api or love
  local report = {schema = 'noisemaker-love-capabilities-v1', host = identity(api), counts = {pass = 0, fail = 0, unsupported = 0}, probes = {}}
  for _, case in ipairs(cases or M.cases) do
    local result = runCase(api, case, report.host)
    report.probes[case.name] = result
    report.counts[result.status] = report.counts[result.status] + 1
  end
  report.ok = report.counts.fail == 0 and report.counts.unsupported == 0 and report.counts.pass == #(cases or M.cases)
  return report
end

return M
