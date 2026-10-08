local graphlib = require('noisemaker.runtime.graph')
local values = require('noisemaker.compiler.values')
local adapter = require('noisemaker.shaders.adapter')
local M = {}
local unpack = unpack or table.unpack
local function keys(t) return graphlib.keys(t or {}) end
local function actual(x) return x ~= nil and x ~= values.NULL and x ~= values.UNDEFINED end
local function global(id) return type(id) == 'string' and id:match('^global_(.+)$') end
local function fail(code, message, fields)
  local diagnostic = fields or {}
  diagnostic.code, diagnostic.message = code, message
  error(diagnostic, 0)
end
local function own(renderer, resource)
  renderer.owned[#renderer.owned + 1] = resource
  return resource
end
local function outputsFor(pass)
  local out = values.object()
  if pass.storageTextures then
    for _, key in ipairs(keys(pass.storageTextures)) do values.set(out, key, pass.storageTextures[key]) end
  end
  if pass.outputs then
    if pass.storageTextures or pass.outputs.outputBuffer then out = values.object() end
    for _, key in ipairs(keys(pass.outputs)) do
      values.set(out, key == 'outputBuffer' and 'color' or key, pass.outputs[key])
    end
  end
  return out
end
M.outputsFor = outputsFor
local function jsNumber(value)
  local kind = type(value)
  if kind == 'number' then return value end
  if kind == 'boolean' then return value and 1 or 0 end
  if kind == 'string' then
    local stripped = value:match('^%s*(.-)%s*$')
    if stripped == '' then return 0 end
    if stripped == 'Infinity' or stripped == '+Infinity' then return math.huge end
    if stripped == '-Infinity' then return -math.huge end
    return tonumber(stripped) or (0 / 0)
  end
  return 0 / 0
end
local function jsInt(value)
  local number = jsNumber(value)
  if number ~= number or number == math.huge or number == -math.huge then return 0 end
  number = number < 0 and math.ceil(number) or math.floor(number)
  number = number % 4294967296
  if number >= 2147483648 then number = number - 4294967296 end
  return number
end
local function send(shader, name, value, spec)
  if not actual(value) or not shader:hasUniform(name) then return end
  local ty = spec and spec.type or ''
  if ty:find('sampler', 1, true) or ty == 'Image' then shader:send(name, value); return end
  if ty == 'float' then
    if type(value) == 'table' and (values.isArray(value) or #value > 0) then
      local array = {}
      for i = 1, #value do array[i] = jsNumber(value[i]) end
      shader:send(name, unpack(array))
    else shader:send(name, jsNumber(value)) end
  elseif ty == 'int' then shader:send(name, jsInt(value))
  elseif ty == 'bool' then shader:send(name, jsInt(value) ~= 0)
  elseif ty == 'vec2' or ty == 'vec3' or ty == 'vec4' then
    local n = tonumber(ty:sub(-1))
    local isArray = type(value) == 'table' and (values.isArray(value) or #value > 0)
    local vector = {}
    for i = 1, n do
      local component
      if isArray then component = value[i] else component = value end
      if component == nil then component = i == 4 and 1 or 0 end
      vector[i] = jsNumber(component)
    end
    shader:send(name, vector)
  elseif ty == 'mat3' or ty == 'mat4' then
    if type(value) == 'table' and (values.isArray(value) or #value > 0) then shader:send(name, 'column', value) end
  end
  -- The WebGL2 authority does not dispatch other uniform types (ivec*, uvec*, uint).
end
M.send = send
local function remapData(renderer, info, uniforms, globals)
  local layout = info.spec.uniformLayout
  if not layout then fail('ERR_UNIFORM_LAYOUT', 'Remap shader requires uniformLayout', {program=info.spec.path}) end
  local holder = info.remapData
  if not holder then
    local imageData = own(renderer, love.image.newImageData(275, 1, 'rgba32f'))
    local image = own(renderer, love.graphics.newImage(imageData, {mipmaps=false}))
    image:setFilter('nearest', 'nearest')
    holder = {data=imageData, image=image}
    info.remapData = holder
  end
  local slots = {}
  for i = 1, 275 do slots[i] = {0, 0, 0, 0} end
  for name, entry in pairs(layout) do
    local slot = entry.slot
    if type(slot) == 'number' and slot >= 0 and slot < 275 then
      local value = uniforms[name]
      if not actual(value) then value = globals[name] end
      if name == 'width' and not actual(value) and type(globals.resolution) == 'table' then value = globals.resolution[1] end
      if name == 'height' and not actual(value) and type(globals.resolution) == 'table' then value = globals.resolution[2] end
      if name == 'channels' and not actual(value) then value = 4 end
      if actual(value) then
        if type(value) == 'boolean' then value = value and 1 or 0 end
        local components = entry.components
        for i = 1, #components do
          local component = components:sub(i, i)
          local column = ({x=1,y=2,z=3,w=4})[component]
          if column then
            local scalar = type(value) == 'table' and value[i] or (i == 1 and value or nil)
            if type(scalar) == 'boolean' then scalar = scalar and 1 or 0 end
            if type(scalar) == 'number' then slots[slot+1][column] = scalar end
          end
        end
      end
    end
  end
  for i = 1, 275 do holder.data:setPixel(i-1, 0, unpack(slots[i])) end
  holder.image:replacePixels(holder.data)
  return holder.image
end
local function countTexture(renderer, id, reads, triangles)
  if type(id) ~= 'string' then return nil end
  local name = global(id)
  if not triangles and name then return reads[name] end
  local function direct(key)
    local upload = renderer.uploads[key]
    return upload and upload.texture or renderer.external[key] or renderer.resources.textures[key]
  end
  local texture = direct(id)
  if triangles and not texture then
    local unscoped = id:gsub('_chain_%d+$', '')
    if unscoped ~= id then texture = direct(unscoped) end
    if not texture and name then texture = reads[name] end
  end
  return texture
end
local function resolveCount(renderer, pass, uniforms, globals, reads, attachment, mode)
  local count = pass.count
  if count == nil or count == false or count == 0 or count == '' or count ~= count then
    count = mode == 'triangles' and 3 or 1000
  end
  if mode == 'triangles' and pass.countUniform then
    local value = uniforms[pass.countUniform]
    if not actual(value) then value = globals[pass.countUniform] end
    if type(value) == 'number' and value > 0 then count = value end
  elseif type(count) == 'string' and
    ((mode == 'triangles' and (count == 'auto' or count == 'input')) or
     (mode ~= 'triangles' and (count == 'auto' or count == 'screen' or count == 'input'))) then
    local texture
    if count == 'input' then
      local inputs = pass.inputs or {}
      local id
      if mode == 'triangles' then id = inputs.meshPositions or inputs.inputTex
      elseif mode == 'billboards' then id = inputs.xyzTex
      else id = inputs.xyzTex or inputs.inputTex end
      if id then texture = countTexture(renderer, id, reads, mode == 'triangles')
      elseif mode == 'billboards' then texture = attachment end
    else
      texture = attachment
    end
    if texture then count = texture:getWidth() * texture:getHeight()
    else count = mode == 'triangles' and 3 or renderer.width * renderer.height end
  end
  if type(count) ~= 'number' or count ~= count or count < 1 or count == math.huge then fail('ERR_DRAW_COUNT', 'Invalid vertex or particle count', {pass=pass.id}) end
  return math.floor(count)
end
M.resolveCount = resolveCount
local function prepareAttachments(renderer, pass, writes)
  local outputBindings = outputsFor(pass)
  local attachments, outputNames = {}, {}
  for _, key in ipairs(keys(outputBindings)) do
    local id = outputBindings[key]
    local name = global(id)
    local target = name and writes[name] or renderer.resources.textures[id]
    if not target then fail('ERR_RENDER_TARGET', 'Missing output texture '..id, {pass=pass.id}) end
    attachments[#attachments+1] = target
    outputNames[#outputNames+1] = name or false
  end
  if #attachments == 0 then fail('ERR_RENDER_TARGET', 'Pass has no render targets', {pass=pass.id}) end
  if #attachments > love.graphics.getSystemLimits().multicanvas then
    fail('ERR_MRT_LIMIT', 'Pass exceeds color attachment limit', {pass=pass.id})
  end
  local w, h = attachments[1]:getDimensions()
  for _, target in ipairs(attachments) do
    if target:getWidth() ~= w or target:getHeight() ~= h then
      fail('ERR_MRT_DIMENSIONS', 'MRT attachments have unequal dimensions', {pass=pass.id})
    end
  end
  return attachments, outputNames, w, h
end
local function bindInputs(renderer, pass, info, shader, uniforms, globals, reads, attachments)
  for _, name in ipairs(keys(pass.inputs)) do
    local texture = renderer:_input(pass.inputs[name], reads)
    for _, target in ipairs(attachments) do
      if texture == target then fail('ERR_TEXTURE_HAZARD', 'Pass samples its active render target', {pass=pass.id,texture=pass.inputs[name]}) end
    end
    send(shader, name, texture, info.uniforms[name])
  end
  if info.uniforms.nmRemapDataTexture then
    send(shader, 'nmRemapDataTexture', remapData(renderer, info, uniforms, globals), info.uniforms.nmRemapDataTexture)
  end
  for name, spec in pairs(info.uniforms) do
    if not (pass.inputs and pass.inputs[name]) and name ~= 'nmRemapDataTexture' then
      local value = uniforms[name]
      if not actual(value) then value = globals[name] end
      send(shader, name, value, spec)
    end
  end
end
local function setTargets(g, targets, depth)
  if depth then
    local withDepth = {}
    for i, target in ipairs(targets) do withDepth[i] = target end
    withDepth.depth = true
    g.setCanvas(withDepth)
    g.clear(false, false, 1)
    g.setDepthMode('less', true)
    g.setMeshCullMode('back')
    -- LÖVE reverses requested winding while a Canvas is active; 'cw' yields GL_CCW.
    g.setFrontFaceWinding('cw')
  else
    g.setCanvas(targets)
    g.setDepthMode()
    g.setMeshCullMode('none')
  end
end
local function selectBlend(g, blend)
  if not blend then g.setBlendMode('replace', 'premultiplied'); return end
  if blend == true then g.setBlendMode('add', 'premultiplied'); return end
  if type(blend) ~= 'table' or #blend < 2 then fail('ERR_BLEND_FACTOR', 'Invalid blend descriptor') end
  local src, dst = tostring(blend[1]):upper(), tostring(blend[2]):upper()
  if src == 'ONE' and dst == 'ONE_MINUS_SRC_ALPHA' then g.setBlendMode('alpha', 'premultiplied')
  elseif src == 'ONE' and dst == 'ONE' then g.setBlendMode('add', 'premultiplied')
  elseif src == 'SRC_ALPHA' and dst == 'ONE_MINUS_SRC_ALPHA' then g.setBlendMode('alpha', 'alphamultiply')
  else fail('ERR_BLEND_FACTOR', 'Blend factors require explicit lowering: '..src..', '..dst) end
end
M.selectBlend = selectBlend
local function alphaCaptureMode(blend)
  if blend == true then return 'add' end
  if type(blend) ~= 'table' then return nil end
  local src, dst = tostring(blend[1]):upper(), tostring(blend[2]):upper()
  if src == 'ONE' and dst == 'ONE' then return 'add' end
  if src == 'SRC_ALPHA' and dst == 'ONE_MINUS_SRC_ALPHA' then return 'src-alpha' end
  return nil
end
local function prepareBlendShaders(renderer, info, captureMode)
  renderer.blendShaders = renderer.blendShaders or {}
  local common = renderer.blendShaders
  local function make(name, source)
    if common[name] then return common[name] end
    local adapted, diagnostic = adapter.adapt{pixel=source, path='runtime/blend/'..name}
    if not adapted then error(diagnostic, 0) end
    common[name] = own(renderer, love.graphics.newShader(adapted.pixel, adapted.vertex))
    return common[name]
  end
  local initialize = make('initialize', 'in vec2 v_texCoord; uniform sampler2D sourceTex; out vec4 fragColor; void main(){fragColor=vec4(texture(sourceTex,v_texCoord).a,0.0,0.0,1.0);}')
  local merge = make('merge', 'in vec2 v_texCoord; uniform sampler2D colorTex; uniform sampler2D alphaTex; out vec4 fragColor; void main(){vec4 c=texture(colorTex,v_texCoord);fragColor=vec4(c.rgb,texture(alphaTex,v_texCoord).r);}')
  local copy = make('copy', 'in vec2 v_texCoord; uniform sampler2D sourceTex; out vec4 fragColor; void main(){fragColor=texture(sourceTex,v_texCoord);}')
  info.alphaShaders = info.alphaShaders or {}
  local capture = info.alphaShaders[captureMode]
  if not capture then
    local spec = {}
    for key, value in pairs(info.spec) do spec[key] = value end
    spec.captureAlpha = captureMode
    local adapted, diagnostic = adapter.adapt(spec)
    if not adapted then error(diagnostic, 0) end
    capture = own(renderer, love.graphics.newShader(adapted.pixel, adapted.vertex))
    info.alphaShaders[captureMode] = capture
  end
  return initialize, merge, copy, capture
end
local function blendScratch(renderer, target)
  local resources = renderer.resources
  resources.blendScratch = resources.blendScratch or {}
  local cached = resources.blendScratch[target]
  if cached then return cached end
  local w, h = target:getDimensions()
  local settings = {format=target:getFormat(),readable=true,msaa=0,dpiscale=1}
  local alpha = love.graphics.newCanvas(w, h, settings)
  resources.owned[#resources.owned+1] = alpha
  local merged = love.graphics.newCanvas(w, h, settings)
  resources.owned[#resources.owned+1] = merged
  cached = {alpha=alpha,merged=merged}
  resources.blendScratch[target] = cached
  return cached
end
local function drawGeometry(g, mesh, count, mode, meshMode)
  if mode == 'billboards' or meshMode == 'point_quads' then g.drawInstanced(mesh, count)
  else g.draw(mesh) end
end
local function prepareAlpha(renderer, attachments, w, h, initialize)
  local g = love.graphics
  local buffers = {}
  local mesh = renderer:_mesh(w, h, 1, 'fullscreen')
  for i, target in ipairs(attachments) do
    local pair = blendScratch(renderer, target)
    buffers[i] = pair.alpha
    g.setCanvas(pair.alpha)
    g.setDepthMode()
    g.setMeshCullMode('none')
    g.setBlendMode('replace', 'premultiplied')
    g.setShader(initialize)
    initialize:send('sourceTex', target)
    g.draw(mesh)
  end
  return buffers, mesh
end
local function finishAlpha(renderer, attachments, buffers, mesh, merge, copy)
  local g = love.graphics
  for i, target in ipairs(attachments) do
    local pair = blendScratch(renderer, target)
    g.setCanvas(pair.merged)
    g.setDepthMode()
    g.setMeshCullMode('none')
    g.setBlendMode('replace', 'premultiplied')
    g.setShader(merge)
    merge:send('colorTex', target)
    merge:send('alphaTex', buffers[i])
    g.draw(mesh)
    g.setCanvas(target)
    g.setShader(copy)
    copy:send('sourceTex', pair.merged)
    g.draw(mesh)
  end
end
function M.execute(renderer, pass, uniforms, globals, reads, writes)
  local g = love.graphics
  g.push('all')
  local ok, err = xpcall(function()
    local info = renderer.programs[pass.program..':'..(pass.drawMode or 'fullscreen')]
    local shader = info.shader
    local attachments, names, w, h = prepareAttachments(renderer, pass, writes)
    local mode = pass.drawMode or 'fullscreen'
    local captureMode = alphaCaptureMode(pass.blend)
    local alphaBuffers, fullMesh, merge, copy, capture
    if captureMode then
      local initialize
      initialize, merge, copy, capture = prepareBlendShaders(renderer, info, captureMode)
      alphaBuffers, fullMesh = prepareAlpha(renderer, attachments, w, h, initialize)
    end
    bindInputs(renderer, pass, info, shader, uniforms, globals, reads, attachments)
    setTargets(g, attachments, mode == 'triangles')
    g.setShader(shader)
    selectBlend(g, pass.blend)
    local count = resolveCount(renderer, pass, uniforms, globals, reads, attachments[1], mode)
    local meshMode = info.adapted.drawMode == 'point_quads' and 'point_quads' or mode
    local mesh = renderer:_mesh(w, h, count, meshMode)
    if mode == 'points' and info.adapted.pointNativeSize then g.setPointSize(info.adapted.pointNativeSize) end
    drawGeometry(g, mesh, count, mode, meshMode)
    if captureMode then
      bindInputs(renderer, pass, info, capture, uniforms, globals, reads, alphaBuffers)
      setTargets(g, alphaBuffers, mode == 'triangles')
      g.setShader(capture)
      selectBlend(g, pass.blend)
      drawGeometry(g, mesh, count, mode, meshMode)
      finishAlpha(renderer, attachments, alphaBuffers, fullMesh, merge, copy)
    end
    for _, name in ipairs(names) do if name then reads[name], writes[name] = writes[name], reads[name] end end
  end, function(e) return e end)
  local restored, restoreError = pcall(g.pop)
  if not restored then fail('ERR_STATE_RESTORE', tostring(restoreError), {pass=pass.id}) end
  if not ok then error(err, 0) end
  return true
end
return M
