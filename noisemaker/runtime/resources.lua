local graph=require('noisemaker.runtime.graph')
local M={}
local formats={rgba16float='rgba16f',rgba32float='rgba32f',rgba8unorm='rgba8',r16float='r16f',r32float='r32f'}
local function normalized(format) return formats[format] or format or 'rgba16f' end

local function fail(code,message)
  error({stage='resources',code=code,message=message},0)
end

local function dimensions(spec,width,height,uniforms)
  local w=graph.dimension(spec.width,width,uniforms)
  local h=graph.dimension(spec.height,height,uniforms)
  local d=spec.is3D and graph.dimension(spec.depth or spec.width,w,uniforms) or nil
  return w,h,d
end

local function create(width,height,depth,spec,owned)
  local g=love.graphics
  local format=normalized(spec.format)
  if not g.getCanvasFormats()[format] then fail('ERR_TEXTURE_FORMAT','Canvas format unavailable: '..format) end
  local limit=g.getSystemLimits().texturesize
  if width>limit or height>limit or depth and depth>limit then
    fail('ERR_TEXTURE_SIZE','Texture exceeds GPU limit')
  end
  local settings={format=format,readable=true,msaa=0,dpiscale=1}
  if spec.mipmaps then settings.mipmaps='manual' end
  if depth then settings.type='volume' end
  local texture=depth and g.newCanvas(width,height,depth,settings) or g.newCanvas(width,height,settings)
  owned[#owned+1]=texture
  local filter=spec.filter or 'nearest'
  if type(filter)=='table' then texture:setFilter(filter.min or 'nearest',filter.mag or 'nearest')
  else texture:setFilter(filter,filter) end
  local wrap=spec.wrap or 'clamp'
  if type(wrap)=='table' then texture:setWrap(wrap.x or 'clamp',wrap.y or 'clamp',wrap.z or 'clamp')
  else texture:setWrap(wrap,wrap,wrap) end
  if depth then
    for layer=1,depth do g.setCanvas({{texture,layer=layer}});g.clear(0,0,0,0) end
  else g.setCanvas(texture);g.clear(0,0,0,0) end
  g.setCanvas()
  return texture
end

local function descriptor(w,h,d,spec)
  local filter,wrap=spec.filter or 'nearest',spec.wrap or 'clamp'
  local min,mag=filter,filter
  if type(filter)=='table' then min,mag=filter.min or 'nearest',filter.mag or 'nearest' end
  local x,y,z=wrap,wrap,wrap
  if type(wrap)=='table' then x,y,z=wrap.x or 'clamp',wrap.y or 'clamp',wrap.z or 'clamp' end
  return table.concat({w,h,d or '2d',normalized(spec.format),spec.mipmaps and 'manual' or 'none',min,mag,x,y,z},':')
end

local function copy(source,target)
  local g=love.graphics
  g.setCanvas(target)
  g.setShader()
  g.setColor(1,1,1,1)
  g.setBlendMode('replace','premultiplied')
  g.draw(source,0,0,0,target:getWidth()/source:getWidth(),target:getHeight()/source:getHeight())
  g.setCanvas()
end

local function collectNames(graphValue)
  local names={}
  for _,pass in ipairs(graphValue.passes) do
    for _,bindings in ipairs({pass.inputs or {},pass.outputs or {},pass.storageTextures or {}}) do
      for _,key in ipairs(graph.keys(bindings)) do
        local id=bindings[key]
        if type(id)=='string' and id:sub(1,7)=='global_' then names[id:sub(8)]=true end
      end
    end
  end
  for _,id in ipairs(graph.keys(graphValue.textures)) do
    if id:sub(1,7)=='global_' then names[id:sub(8)]=true end
  end
  if graphValue.renderSurface then names[graphValue.renderSurface]=true end
  return names
end

function M.clampVolumeSize(value,maxTextureSize)
  if type(value)~='number' or not maxTextureSize or value*value<=maxTextureSize then return value end
  local clamped=16
  while (clamped*2)*(clamped*2)<=maxTextureSize and clamped*2<value do clamped=clamped*2 end
  return clamped
end

function M.isVolumeSizeUniform(key)
  return type(key)=='string' and (key=='volumeSize' or
    key:sub(1,#'volumeSize_chain_')=='volumeSize_chain_' or
    key:sub(1,#'volumeSize_node_')=='volumeSize_node_')
end

function M.clampGraphVolumes(graphValue,maxTextureSize)
  for _,pass in ipairs(graphValue.passes) do
    for _,key in ipairs(graph.keys(pass.uniforms)) do
      if M.isVolumeSizeUniform(key) then
        pass.uniforms[key]=M.clampVolumeSize(pass.uniforms[key],maxTextureSize)
      end
    end
  end
end

-- The upstream pool is opt-in. Restrict reuse to complete overwrites with
-- disjoint lifetimes; persistent and partially written targets remain private.
local function poolingPlan(graphValue,width,height,uniforms)
  local spans,unsafe={},{}
  local function touch(id,index,write)
    if type(id)~='string' then return end
    local span=spans[id]
    if not span then span={first=index,last=index,firstWrite=write};spans[id]=span end
    span.last=index
  end
  for index,pass in ipairs(graphValue.passes) do
    for _,key in ipairs(graph.keys(pass.inputs)) do touch(pass.inputs[key],index,false) end
    local spec=graphValue.programs[pass.program] or {}
    local source=spec.pixel or spec.glsl or spec.fragment or ''
    local conditions=pass.conditions or {}
    local partial=pass.drawMode or pass.blend or pass.viewport or spec.vertex
      or #(conditions.skipIf or {})>0 or #(conditions.runIf or {})>0
      or source:find('%f[%w_]discard%f[^%w_]')
    for _,outputs in ipairs({pass.outputs or {},pass.storageTextures or {}}) do
      for _,key in ipairs(graph.keys(outputs)) do
        local id=outputs[key];touch(id,index,true)
        if partial then unsafe[id]=true end
      end
    end
  end
  local groups,aliases={},{}
  for _,id in ipairs(graph.keys(graphValue.allocations)) do
    local physical=graphValue.allocations[id]
    if type(physical)=='string' and id:sub(1,7)~='global_' and graphValue.textures[id] then
      groups[physical]=groups[physical] or {};table.insert(groups[physical],id)
    end
  end
  for _,members in pairs(groups) do
    local eligible=#members>1;local signature
    for index,id in ipairs(members) do
      local spec,span=graphValue.textures[id],spans[id]
      if not span or not span.firstWrite or unsafe[id] or spec.persistent or spec.mipmaps or spec.is3D then eligible=false;break end
      local w,h,d=dimensions(spec,width,height,uniforms)
      local key=descriptor(w,h,d,spec)
      if signature and signature~=key then eligible=false;break end
      signature=key
      for prior=1,index-1 do
        local other=spans[members[prior]]
        if span.first<=other.last and other.first<=span.last then eligible=false end
      end
    end
    if eligible then for _,id in ipairs(members) do aliases[id]=members[1] end end
  end
  return aliases
end

function M.allocate(graphValue,width,height,uniforms,previous,texturePooling)
  local owned,created,reused,claimed={}, {}, {}, {}
  local textures,surfaces,descriptors={},{},{}
  local function acquire(old,w,h,d,spec)
    local key=descriptor(w,h,d,spec)
    if old and not claimed[old] and previous.descriptors and previous.descriptors[old]==key then
      owned[#owned+1]=old;reused[old]=true;claimed[old]=true;descriptors[old]=key;return old
    end
    local texture=create(w,h,d,spec,created)
    owned[#owned+1]=texture;descriptors[texture]=key
    if old and spec.persistent and not d then
      copy(old,texture)
      if spec.mipmaps then texture:generateMipmaps() end
    end
    return texture
  end
  local aliases=texturePooling and poolingPlan(graphValue,width,height,uniforms) or {}
  local pooled={}
  local ok,err=xpcall(function()
    for _,id in ipairs(graph.keys(graphValue.textures)) do
      local spec=graphValue.textures[id]
      if id:sub(1,7)~='global_' then
        local w,h,d=dimensions(spec,width,height,uniforms)
        local alias=aliases[id]
        local texture=alias and pooled[alias]
        if not texture then
          texture=acquire(previous and previous.textures[id],w,h,d,spec)
          if alias then pooled[alias]=texture end
        end
        textures[id]=texture
      end
    end
    for name in pairs(collectNames(graphValue)) do
      local spec=graphValue.textures['global_'..name] or {}
      local volume=name:match('^vol%d')
      local w,h,d=dimensions(spec,volume and 64 or width,volume and 4096 or height,uniforms)
      if d then fail('ERR_SURFACE_3D','Global surfaces use 2D volume atlases') end
      local old=previous and previous.surfaces[name]
      surfaces[name]={read=acquire(old and old.read,w,h,nil,spec),write=acquire(old and old.write,w,h,nil,spec)}
    end
    textures.__black=acquire(previous and previous.textures.__black,1,1,nil,{format='rgba8'})
    textures.__present=acquire(previous and previous.textures.__present,width,height,nil,{format='rgba16f'})
  end,function(e)return e end)
  if not ok then
    for i=#created,1,-1 do pcall(created[i].release,created[i]) end
    error(err,0)
  end
  return {owned=owned,textures=textures,surfaces=surfaces,reused=reused,descriptors=descriptors,aliases=aliases}
end

function M.release(previous,next)
  if not previous then return end
  local keep=next and next.reused or {}
  for i=#previous.owned,1,-1 do local texture=previous.owned[i];if not keep[texture] then pcall(texture.release,texture) end end
end

function M.abort(candidate)
  if not candidate then return end
  for i=#candidate.owned,1,-1 do
    local texture=candidate.owned[i]
    if not candidate.reused[texture] then pcall(texture.release,texture) end
  end
end

function M.generateMipmaps(graphValue,resources)
  for _,id in ipairs(graph.keys(graphValue.textures)) do
    local spec=graphValue.textures[id]
    if spec.mipmaps and not spec.is3D then
      local name=id:match('^global_(.+)$')
      if name then
        local surface=resources.surfaces[name]
        if surface then surface.read:generateMipmaps();surface.write:generateMipmaps() end
      else
        local texture=resources.textures[id]
        if texture then texture:generateMipmaps() end
      end
    end
  end
end

return M
