local graphlib = require('noisemaker.runtime.graph')
local executor = require('noisemaker.runtime.executor')
local M = {}

local function fail(code, message, pass, detail)
  error({stage='capability',code=code,message=message,pass=pass,detail=detail}, 0)
end

local function target(resources, id)
  local name = type(id)=='string' and id:match('^global_(.+)$')
  if name then
    local surface = resources.surfaces[name]
    return surface and surface.write
  end
  return resources.textures[id]
end

local function requireVolume(g, pass, id)
  local types = type(g.getTextureTypes)=='function' and g.getTextureTypes() or {}
  if not types.volume then
    fail('ERR_VOLUME_UNAVAILABLE', 'Volume textures are unavailable', pass, id)
  end
end

-- Called once for the candidate renderer, after shader compilation and allocation.
-- Bind the real attachments, including the geometry depth buffer, without drawing
-- or sampling host inputs. The caller's graphics-state guard restores the host.
function M.check(graph, resources, programs)
  local g = love.graphics
  local limits = g.getSystemLimits()
  for _, key in ipairs(graphlib.keys(graph.textures)) do
    local spec=graph.textures[key]
    if spec.is3D then requireVolume(g,nil,key) end
  end
  for _, pass in ipairs(graph.passes) do
    local mode = pass.drawMode or 'fullscreen'
    local program = programs[pass.program..':'..mode]
    if not program then fail('ERR_PROGRAM_NOT_FOUND', 'Prepared program is missing', pass.id, pass.program) end
    if mode=='billboards' or program.adapted and program.adapted.drawMode=='point_quads' then
      if type(g.drawInstanced)~='function' then
        fail('ERR_INSTANCING_UNAVAILABLE', 'Instanced drawing is unavailable', pass.id)
      end
    end
    for name, uniform in pairs(program.uniforms or {}) do
      if uniform.type=='sampler3D' or uniform.type=='VolumeImage' then
        requireVolume(g,pass.id,name)
      end
    end
    local bindings = executor.outputsFor(pass)
    local attachments, seen = {}, {}
    for _, key in ipairs(graphlib.keys(bindings)) do
      local id = bindings[key]
      local canvas = target(resources,id)
      if not canvas then fail('ERR_RENDER_TARGET','Missing output texture '..tostring(id),pass.id,id) end
      if seen[canvas] then fail('ERR_MRT_ALIAS','A texture is bound to more than one color attachment',pass.id,id) end
      seen[canvas] = true
      if type(canvas.getTextureType)=='function' and canvas:getTextureType()~='2d' then
        fail('ERR_RENDER_TARGET_TYPE','Render output must be a 2D Canvas',pass.id,id)
      end
      attachments[#attachments+1] = canvas
    end
    if #attachments==0 then fail('ERR_RENDER_TARGET','Pass has no render targets',pass.id) end
    if #attachments>(limits.multicanvas or 1) then
      fail('ERR_MRT_LIMIT','Pass exceeds color attachment limit',pass.id,#attachments)
    end
    local w,h=attachments[1]:getDimensions()
    for i=2,#attachments do
      if attachments[i]:getWidth()~=w or attachments[i]:getHeight()~=h then
        fail('ERR_MRT_DIMENSIONS','MRT attachments have unequal dimensions',pass.id)
      end
    end
    for _, key in ipairs(graphlib.keys(pass.inputs)) do
      local id=pass.inputs[key]
      local spec=graph.textures and graph.textures[id]
      if spec and spec.is3D then requireVolume(g,pass.id,id) end
    end
    local blendOk,blendError=pcall(executor.selectBlend,g,pass.blend)
    if not blendOk then
      if type(blendError)=='table' then
        blendError.pass=pass.id;blendError.stage='capability';error(blendError,0)
      end
      fail('ERR_BLEND_UNAVAILABLE','Blend mode is unavailable',pass.id,tostring(blendError))
    end
    local list={}
    for i,canvas in ipairs(attachments) do list[i]=canvas end
    if mode=='triangles' then list.depth=true end
    local ok,err=pcall(g.setCanvas,list)
    if not ok then
      fail(mode=='triangles' and 'ERR_DEPTH_ATTACHMENT' or 'ERR_RENDER_TARGET_BIND',
        'Pass attachment configuration is unavailable',pass.id,tostring(err))
    end
    g.setCanvas()
  end
  return true
end

return M
