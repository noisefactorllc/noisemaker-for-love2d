local values=require('noisemaker.compiler.values')
local registry=require('noisemaker.catalog.registry')
local M={}
local NULL=values.NULL

local function set(items)
  local result={}
  for _,item in ipairs(items) do result[item]=true end
  return result
end
local globalTypes=set{'float','int','boolean','vec2','vec3','vec4','mat3','color','surface','volume','geometry','member','palette','button','string'}
local uiControls=set{'slider','checkbox','dropdown','color','button','vector3','vec3'}
local uiKeys=set{'label','control','category','hidden','hint','format','buttonLabel','enabledBy','multiline','resetOnChange'}
local enabledOps=set{'eq','neq','lt','gt','gte','lte','in','notIn'}
local globalKeys=set{'type','default','uniform','define','choices','enum','min','max','step','zero','randMin','randMax','randChance','randChoices','colorModeUniform','ui'}
local passKeys=set{'name','program','type','entryPoint','drawMode','drawBuffers','count','countUniform','repeat','blend','workgroups','storageBuffers','storageTextures','viewport','conditions','defines','uniforms','inputs','outputs','clear','samplerTypes'}
local samplerTypes=set{'default','nearest','repeat','mipmap'}
local textureKeys=set{'width','height','depth','format','is3D','filter','mipmaps','persistent'}
local dimKeys=set{'param','power','multiply','default','paramDefault','screenDivide','scale','clamp','inputOverride'}
local formats=set{'rgba16f','rgba16float','rgba8','rgba8unorm','rgba32f','rgba32float','r8','r8unorm','r16f','r16float','r32f','r32float'}
local drawModes=set{'points','triangles','billboards'}
local passTypes=set{'render','compute'}
local topKeys=set{'name','namespace','func','description','tags','globals','passes','textures','textures3d','shaders','uniformLayout','uniformLayouts','paramAliases','openCategories','defaultProgram','hidden','deprecatedBy','externalTexture','externalMesh','builtinMeshes','outputTex3d','outputGeo','state','uniforms','onInit','onUpdate','onDestroy','asyncInit'}
local pipelineInputs=set{'inputTex','inputTex3d','inputGeo','inputXyz','inputVel','inputRgba','noise','midiNoteGrid','feedback','selfTex','outputTex','none'}
local pipelineOutputs=set{'outputTex','outputTex3d','outputXyz','outputVel','outputRgba'}
local dimensionWords=set{'screen','auto','input','resolution'}
local tags=set{'color','distort','edges','geometric','lens','noise','transform','util','sim','3d','audio','agents','antialiasing','artist','blend','blur','fractal','geometry','glitch','image','mesh','midi','palette','pattern','pixel','text','tiling','video'}

local function isArray(value)
  return type(value)=='table' and value~=NULL and (values.isArray(value) or #value>0)
end
local function object(value)
  return type(value)=='table' and value~=NULL and not isArray(value)
end
local function finite(value)
  return type(value)=='number' and value==value and value~=math.huge and value~=-math.huge
end
local function integer(value)
  return finite(value) and value==math.floor(value)
end
local function keys(value)
  return registry.keys(value)
end
local function add(errors,message)
  errors[#errors+1]=message
end
local function checkKeys(value,allowed,errors,label)
  for _,key in ipairs(keys(value)) do if not allowed[key] then add(errors,label .. ": unknown field '" .. key .. "'") end end
end
local function nonempty(value)
  return type(value)=='string' and #value>0
end

local function stdEnum(path)
  if not nonempty(path) then return nil end
  local a,b=path:match('^([^.]+)%.([^.]+)$')
  if a=='palette' then return require('noisemaker.catalog.palettes').names[b] end
  local enum={channel={r=0,g=1,b=2,a=3},color={mono=0,rgb=1,hsv=2},
    oscType={sine=0,linear=1,sawtooth=2,sawtoothInv=3,square=4,noise1d=5,noise2d=6},
    oscKind={sine=0,tri=1,saw=2,sawInv=3,square=4,noise=5,noise1d=5,noise2d=6},
    midiMode={noteChange=0,gateNote=1,gateVelocity=2,triggerNote=3,velocity=4,cc=5,cc14=6,nrpn=7,pitchBend=8,pressure=9,polyPressure=10},
    midiZone={lower=0,upper=1},audioBand={low=0,mid=1,high=2,vol=3,raw=4}}
  if b then return enum[a] and enum[a][b] end
  if path=='palette' then return require('noisemaker.catalog.palettes').names end
  return enum[path]
end

local function dimSpec(spec,errors,label)
  if finite(spec) then
    if spec<=0 then add(errors,label .. ': dimension must be a positive finite number, keyword, percentage, or dimension expression') end
    return
  end
  if type(spec)=='string' then
    if dimensionWords[spec] then return end
    local percent=spec:match('^([%d%.]+)%%$')
    if percent then
      if not tonumber(percent) or tonumber(percent)<=0 then add(errors,label .. ": invalid percentage '" .. spec .. "'") end
      return
    end
    add(errors,label .. ": invalid dimension '" .. spec .. "'")
    return
  end
  if object(spec) then
    checkKeys(spec,dimKeys,errors,label)
    if spec.param~=nil then
      if not nonempty(spec.param) then add(errors,label .. ': "param" must be a non-empty string') end
      for _,field in ipairs({'power','multiply','default','paramDefault'}) do
        if spec[field]~=nil and not finite(spec[field]) then add(errors,label .. ': "'..field..'" must be a finite number') end
      end
      if spec.inputOverride~=nil and not nonempty(spec.inputOverride) then add(errors,label .. ': "inputOverride" must be a non-empty string') end
      return
    end
    if spec.screenDivide~=nil then
      if not nonempty(spec.screenDivide) then add(errors,label .. ': "screenDivide" must be a non-empty string') end
      if spec.default~=nil and not finite(spec.default) then add(errors,label .. ': "default" must be a finite number') end
      return
    end
    if spec.scale~=nil then
      if not finite(spec.scale) then add(errors,label .. ': "scale" must be a finite number') end
      if spec.clamp~=nil then
        if not object(spec.clamp) then add(errors,label .. ': "clamp" must be an object')
        else
          for _,field in ipairs({'min','max'}) do
            if spec.clamp[field]~=nil and not finite(spec.clamp[field]) then add(errors,label .. ': "clamp.'..field..'" must be a finite number') end
          end
          checkKeys(spec.clamp,set{'min','max'},errors,label..'.clamp')
        end
      end
      return
    end
    add(errors,label .. ': dimension object must reference "param", "screenDivide", or "scale"')
    return
  end
  add(errors,label .. ': invalid dimension specification')
end

local function defaultValue(spec,errors,label)
  local typeName,value=spec.type,spec.default
  if typeName=='float' or typeName=='palette' or typeName=='button' then
    if not finite(value) then add(errors,label .. ': "default" must be a finite number') end
  elseif typeName=='int' then
    if not integer(value) then add(errors,label .. ': "default" must be a finite integer') end
  elseif typeName=='boolean' then
    if type(value)~='boolean' then add(errors,label .. ': "default" must be a boolean') end
  elseif typeName=='vec2' or typeName=='vec3' or typeName=='vec4' or typeName=='mat3' then
    local dims=typeName=='vec2' and 2 or typeName=='vec3' and 3 or typeName=='vec4' and 4 or 9
    local valid=isArray(value) and #value==dims
    if valid then for _,number in ipairs(value) do if not finite(number) then valid=false end end end
    if not valid then add(errors,label .. ': "default" must be an array of '..dims..' finite numbers') end
  elseif typeName=='color' then
    if isArray(value) then
      local valid=#value==3
      for _,number in ipairs(value) do if not finite(number) then valid=false end end
      if not valid then add(errors,label .. ': "default" must be a 3-component color array') end
    elseif type(value)~='string' or not value:match('^#%x%x%x%x%x%x$') then
      add(errors,label .. ": \"default\" must be a 3-component color array or '#rrggbb' string")
    end
  elseif typeName=='string' then
    if type(value)~='string' then add(errors,label .. ': "default" must be a string') end
  elseif typeName=='surface' or typeName=='volume' or typeName=='geometry' or typeName=='member' then
    if type(value)~='string' then add(errors,label .. ': "default" must be a string')
    elseif typeName=='member' and type(stdEnum(value))~='number' then
      add(errors,label .. ": \"default\" '" .. value .. "' does not resolve to a std enum value")
    end
  end
end

local function rangeBounds(spec,errors,label)
  local dims=({vec2=2,vec3=3,color=3,vec4=4,mat3=9})[spec.type] or 1
  local bound={}
  for _,field in ipairs({'min','max'}) do
    local value=spec[field]
    if value~=nil then
      if finite(value) then bound[field]={value}
      elseif isArray(value) then
        local valid=#value==dims
        for _,number in ipairs(value) do if not finite(number) then valid=false end end
        if valid then bound[field]=value
        else add(errors,label .. ': "'..field..'" must be an array of '..dims.." finite numbers for type '"..tostring(spec.type or 'unknown').."'") end
      else add(errors,label .. ': "'..field..'" must be a finite number or an array of '..dims..' finite numbers') end
    end
  end
  if bound.min and bound.max then
    if (#bound.min==1)~=(#bound.max==1) then add(errors,label .. ': "min" and "max" must both be scalars or both be arrays')
    else
      for i=1,#bound.min do if bound.min[i]>bound.max[i] then add(errors,label .. ': "min" must not exceed "max"'); break end end
    end
    local default=spec.default
    if finite(default) and #bound.min==1 and #bound.max==1 and (default<bound.min[1] or default>bound.max[1]) then
      add(errors,label .. ': default '..default..' is outside the declared range ['..bound.min[1]..', '..bound.max[1]..']')
    elseif isArray(default) then
      for i,value in ipairs(default) do
        local minimum=#bound.min==1 and bound.min[1] or bound.min[i]
        local maximum=#bound.max==1 and bound.max[1] or bound.max[i]
        if finite(value) and minimum and maximum and (value<minimum or value>maximum) then
          add(errors,label .. ': default ['..table.concat(default,', ')..'] is outside the declared range'); break
        end
      end
    end
  end
end

local function enabledBy(cond,errors,label,context)
  if type(cond)=='string' then
    if not context.globalKeys[cond] then add(errors,label .. ": enabledBy references unknown global '" .. cond .. "'") end
    return
  end
  if not object(cond) then add(errors,label .. ': "enabledBy" must be a global name or condition object'); return end
  if cond['not']~=nil then
    checkKeys(cond,set{'not'},errors,label)
    enabledBy(cond['not'],errors,label,context)
    return
  end
  if cond['and']~=nil or cond['or']~=nil then
    checkKeys(cond,set{'and','or'},errors,label)
    for _,branch in ipairs({'and','or'}) do
      if cond[branch]~=nil then
        if not isArray(cond[branch]) then add(errors,label .. ': "enabledBy.'..branch..'" must be an array')
        else for _,item in ipairs(cond[branch]) do enabledBy(item,errors,label,context) end end
      end
    end
    return
  end
  local allowed=set{'param'}
  for op in pairs(enabledOps) do allowed[op]=true end
  checkKeys(cond,allowed,errors,label)
  if not nonempty(cond.param) then add(errors,label .. ': "enabledBy" requires a "param" string'); return end
  if not context.globalKeys[cond.param] then add(errors,label .. ": enabledBy references unknown global '" .. cond.param .. "'") end
  local hasOp=false
  for op in pairs(enabledOps) do if cond[op]~=nil then hasOp=true end end
  if not hasOp then add(errors,label .. ': "enabledBy" requires one of eq/neq/lt/gt/in/notIn') end
  for _,op in ipairs({'in','notIn'}) do
    if cond[op]~=nil and not isArray(cond[op]) then add(errors,label .. ': "enabledBy.'..op..'" must be an array') end
  end
end

local function ui(uiValue,errors,label,context)
  if not object(uiValue) then add(errors,label .. ': must be an object'); return end
  checkKeys(uiValue,uiKeys,errors,label)
  if uiValue.label~=nil and not nonempty(uiValue.label) then add(errors,label .. ': "label" must be a non-empty string') end
  if uiValue.control~=nil and uiValue.control~=false and not uiControls[uiValue.control] then
    add(errors,label .. ": unknown control '" .. tostring(uiValue.control) .. "'")
  end
  if uiValue.category~=nil and not nonempty(uiValue.category) then add(errors,label .. ': "category" must be a non-empty string') end
  for _,field in ipairs({'hidden','multiline','resetOnChange'}) do
    if uiValue[field]~=nil and type(uiValue[field])~='boolean' then add(errors,label .. ': "'..field..'" must be a boolean') end
  end
  for _,field in ipairs({'hint','format','buttonLabel'}) do
    if uiValue[field]~=nil and not nonempty(uiValue[field]) then add(errors,label .. ': "'..field..'" must be a non-empty string') end
  end
  if uiValue.enabledBy~=nil then enabledBy(uiValue.enabledBy,errors,label,context) end
end

local function globals(globalsValue,errors,context)
  if globalsValue==nil or globalsValue==NULL then return end
  if not object(globalsValue) then add(errors,'"globals" must be an object'); return end
  local owners={}
  for _,key in ipairs(keys(globalsValue)) do
    local spec=globalsValue[key]
    local label="Global '"..key.."'"
    if not object(spec) then add(errors,label .. ': must be an object')
    else
      checkKeys(spec,globalKeys,errors,label)
      if not spec.type then add(errors,label .. ': Missing "type"')
      elseif type(spec.type)~='string' or not globalTypes[spec.type] then add(errors,label .. ": Unknown type '" .. tostring(spec.type) .. "'") end
      if spec.default~=nil then defaultValue(spec,errors,label) end
      if spec.min~=nil or spec.max~=nil then rangeBounds(spec,errors,label) end
      for _,field in ipairs({'step','zero','randMin','randMax','randChance'}) do
        if spec[field]~=nil and not finite(spec[field]) then add(errors,label .. ': "'..field..'" must be a finite number') end
      end
      if spec.randChoices~=nil then
        local valid=isArray(spec.randChoices)
        if valid then for _,choice in ipairs(spec.randChoices) do if not finite(choice) then valid=false end end end
        if not valid then add(errors,label .. ': "randChoices" must be an array of finite numbers') end
      end
      if spec.uniform~=nil then
        if not nonempty(spec.uniform) then add(errors,label .. ': "uniform" must be a non-empty string')
        elseif owners[spec.uniform] then add(errors,label .. ": uniform '"..spec.uniform.."' conflicts with global '"..owners[spec.uniform].."'")
        else owners[spec.uniform]=key end
      end
      for _,field in ipairs({'define','colorModeUniform'}) do
        if spec[field]~=nil and not nonempty(spec[field]) then add(errors,label .. ': "'..field..'" must be a non-empty string') end
      end
      if spec.choices~=nil then
        if not object(spec.choices) then add(errors,label .. ': "choices" must be an object mapping names to values')
        else
          local numeric={}
          for _,name in ipairs(keys(spec.choices)) do
            local choice=spec.choices[name]
            if choice~=NULL then
              if spec.type=='string' then
                if type(choice)~='string' then add(errors,label .. ": choices['"..name.."'] must be a string for type 'string'") end
              elseif not finite(choice) then add(errors,label .. ": choices['"..name.."'] must be a number or null")
              else numeric[#numeric+1]=choice end
            end
          end
          if #numeric>0 and finite(spec.default) then
            local found=false
            for _,choice in ipairs(numeric) do if choice==spec.default then found=true end end
            if not found then add(errors,label .. ': default '..spec.default..' is not among the declared choice values') end
          end
        end
      end
      if spec.enum~=nil then
        if not nonempty(spec.enum) then add(errors,label .. ': "enum" must be a non-empty string')
        elseif type(stdEnum(spec.enum))~='table' then add(errors,label .. ": enum '"..spec.enum.."' does not resolve to a std enum table") end
      end
      if spec.ui~=nil then ui(spec.ui,errors,label..'.ui',context) end
    end
  end
end

local function textures(map,errors,containerName)
  if map==nil then return end
  if not object(map) then add(errors,'"'..containerName..'" must be an object'); return end
  for _,name in ipairs(keys(map)) do
    local spec=map[name]
    local label="Texture '"..name.."'"
    if not object(spec) then add(errors,label .. ': must be an object')
    else
      checkKeys(spec,textureKeys,errors,label)
      for _,axis in ipairs({'width','height'}) do
        if spec[axis]~=nil then dimSpec(spec[axis],errors,label..'.'..axis) end
      end
      if spec.depth~=nil and (not finite(spec.depth) or spec.depth<=0) then add(errors,label .. ': "depth" must be a positive finite number') end
      if spec.format~=nil and (type(spec.format)~='string' or not formats[spec.format]) then
        add(errors,label .. ": unknown format '"..tostring(spec.format).."'")
      end
      if spec.is3D~=nil and type(spec.is3D)~='boolean' then add(errors,label .. ': "is3D" must be a boolean') end
      if spec.filter~=nil then
        if containerName~='textures3d' then add(errors,label .. ': "filter" is only supported on 3D texture specs ("textures3d")')
        elseif spec.filter~='nearest' and spec.filter~='linear' then add(errors,label .. ": unknown filter '"..tostring(spec.filter).."' (expected 'nearest' or 'linear')") end
      end
      for _,field in ipairs({'mipmaps','persistent'}) do
        if spec[field]~=nil then
          if containerName=='textures3d' then add(errors,label .. ': "'..field..'" is only supported on 2D texture specs ("textures")')
          elseif type(spec[field])~='boolean' then add(errors,label .. ': "'..field..'" must be a boolean') end
        end
      end
    end
  end
end

local componentOrder={x=1,y=2,z=3,w=4}
local function layoutEntry(entry,errors,label)
  if not object(entry) then add(errors,label .. ': layout entry must be an object'); return end
  checkKeys(entry,set{'name','slot','components'},errors,label)
  if not nonempty(entry.name) then add(errors,label .. ': missing "name" string') end
  if not integer(entry.slot) or entry.slot<0 then add(errors,label .. ': "slot" must be a non-negative integer') end
  if not nonempty(entry.components) or #entry.components>4 or entry.components:find('[^xyzw]') then
    add(errors,label .. ': "components" must be 1-4 characters from xyzw')
    return
  end
  local previous=0
  for i=1,#entry.components do
    local current=componentOrder[entry.components:sub(i,i)]
    if current<=previous then add(errors,label .. ": \"components\" '"..entry.components.."' must be in ascending xyzw order"); break end
    previous=current
  end
end

local function layoutConflicts(entries,errors,label)
  for i=1,#entries do
    local a=entries[i]
    for j=i+1,#entries do
      local b=entries[j]
      if a.slot==b.slot and type(a.components)=='string' and type(b.components)=='string' then
        local overlap=false
        for char in a.components:gmatch('.') do if b.components:find(char,1,true) then overlap=true end end
        if a.components==b.components then
          add(errors,label .. ": duplicate layout entries '"..a.name.."' and '"..b.name.."' claim slot "..a.slot.." components '"..a.components.."'")
        elseif overlap then
          add(errors,label .. ': layout conflict at slot '..a.slot..": '"..a.name.."' ("..a.components..") overlaps '"..b.name.."' ("..b.components..")")
        end
      end
    end
  end
end

local function uniformLayout(layout,errors,label)
  if isArray(layout) then
    local entries={}
    for i,entry in ipairs(layout) do
      layoutEntry(entry,errors,label..'['..(i-1)..']')
      if object(entry) and integer(entry.slot) then entries[#entries+1]=entry end
    end
    layoutConflicts(entries,errors,label)
    return
  end
  if not object(layout) then add(errors,label .. ': must be an object or array layout'); return end
  if layout.type=='byte' then
    if not isArray(layout.layout) then add(errors,label .. ': byte layout requires a "layout" array'); return end
    checkKeys(layout,set{'type','layout'},errors,label)
    local entries={}
    for i,entry in ipairs(layout.layout) do
      local entryLabel=label..'.layout['..(i-1)..']'
      if not object(entry) then add(errors,entryLabel .. ': entry must be an object')
      else
        checkKeys(entry,set{'name','offset','size','type','components'},errors,entryLabel)
        if not nonempty(entry.name) then add(errors,entryLabel .. ': missing "name" string') end
        if not integer(entry.offset) or entry.offset<0 then add(errors,entryLabel .. ': "offset" must be a non-negative integer') end
        if not integer(entry.size) or entry.size<=0 then add(errors,entryLabel .. ': "size" must be a positive integer') end
        if not nonempty(entry.type) then add(errors,entryLabel .. ': missing "type" string') end
        if nonempty(entry.name) and integer(entry.offset) and entry.offset>=0 and integer(entry.size) and entry.size>0 then entries[#entries+1]=entry end
      end
    end
    for i=1,#entries do
      local a=entries[i]
      for j=i+1,#entries do
        local b=entries[j]
        if a.name==b.name then add(errors,label .. ": duplicate byte-layout entries '"..a.name.."' (offsets "..a.offset..' and '..b.offset..')')
        elseif a.offset<b.offset+b.size and b.offset<a.offset+a.size then
          add(errors,label .. ": byte layout conflict: '"..a.name.."' (offset "..a.offset..', size '..a.size..") overlaps '"..b.name.."' (offset "..b.offset..', size '..b.size..')')
        end
      end
    end
    return
  end
  local entries={}
  for _,name in ipairs(keys(layout)) do
    local spec=layout[name]
    local entryLabel=label.."['"..name.."']"
    if not object(spec) then add(errors,entryLabel .. ': layout entry must be an object')
    else
      local entry={name=name,slot=spec.slot,components=spec.components}
      for key,value in pairs(spec) do entry[key]=value end
      layoutEntry(entry,errors,entryLabel)
      if integer(spec.slot) then entries[#entries+1]=entry end
    end
  end
  layoutConflicts(entries,errors,label)
end

local function validatePass(source,pass,index,errors,context)
  local label='Pass '..index
  if not object(pass) then add(errors,label .. ': must be an object'); return end
  if not nonempty(pass.program) then add(errors,label .. ': Missing "program" string') end
  checkKeys(pass,passKeys,errors,label)
  for _,field in ipairs({'name','entryPoint'}) do
    if pass[field]~=nil and not nonempty(pass[field]) then add(errors,label .. ': "'..field..'" must be a non-empty string') end
  end
  if pass.type~=nil and not passTypes[pass.type] then add(errors,label .. ": unknown pass type '"..tostring(pass.type).."'") end
  if pass.drawMode~=nil and not drawModes[pass.drawMode] then add(errors,label .. ": unknown drawMode '"..tostring(pass.drawMode).."'") end
  if pass.drawBuffers~=nil and (not integer(pass.drawBuffers) or pass.drawBuffers<1) then add(errors,label .. ': "drawBuffers" must be a positive integer') end
  if pass.count~=nil then
    if type(pass.count)=='string' then
      if not set{'auto','screen','input'}[pass.count] then add(errors,label .. ": unknown count '"..pass.count.."'") end
    elseif not integer(pass.count) or pass.count<1 then add(errors,label .. ': "count" must be a positive integer, \'auto\', \'screen\', or \'input\'') end
  end
  if pass.countUniform~=nil then
    if not nonempty(pass.countUniform) then add(errors,label .. ': "countUniform" must be a non-empty string')
    elseif not context.globalKeys[pass.countUniform] and not context.uniformNames[pass.countUniform] then
      add(errors,label .. ": countUniform '"..pass.countUniform.."' does not reference a declared global") end
  end
  if pass['repeat']~=nil then
    if type(pass['repeat'])=='string' then if #pass['repeat']==0 then add(errors,label .. ': "repeat" string must name a uniform') end
    elseif not integer(pass['repeat']) or pass['repeat']<1 then add(errors,label .. ': "repeat" must be a positive integer or a uniform name string') end
  end
  if pass.blend~=nil then
    local valid=type(pass.blend)=='boolean' or isArray(pass.blend) and #pass.blend==2 and nonempty(pass.blend[1]) and nonempty(pass.blend[2])
    if not valid then add(errors,label .. ': "blend" must be a boolean or [src, dst] factor strings') end
  end
  if pass.clear~=nil and type(pass.clear)~='boolean' then add(errors,label .. ': "clear" must be a boolean') end
  if pass.samplerTypes~=nil then
    if not object(pass.samplerTypes) then add(errors,label .. ': "samplerTypes" must be an object mapping sampler names to sampler types')
    else
      for _,name in ipairs(keys(pass.samplerTypes)) do
        if not samplerTypes[pass.samplerTypes[name]] then add(errors,label .. ": samplerTypes '"..name.."' must be one of default, nearest, repeat, mipmap") end
      end
    end
  end
  if pass.workgroups~=nil then
    local valid=isArray(pass.workgroups) and #pass.workgroups>=1 and #pass.workgroups<=3
    if valid then for _,value in ipairs(pass.workgroups) do if not finite(value) and not nonempty(value) then valid=false end end end
    if not valid then add(errors,label .. ': "workgroups" must be an array of 1-3 numbers or uniform names') end
  end
  for _,field in ipairs({'storageBuffers','storageTextures'}) do
    if pass[field]~=nil and not object(pass[field]) then add(errors,label .. ': "'..field..'" must be an object') end
  end
  if pass.viewport~=nil then
    if not object(pass.viewport) then add(errors,label .. ': "viewport" must be an object')
    else
      for _,field in ipairs(keys(pass.viewport)) do
        if field=='width' or field=='height' then dimSpec(pass.viewport[field],errors,label..'.viewport.'..field)
        elseif field=='x' or field=='y' or field=='w' or field=='h' then
          if not finite(pass.viewport[field]) then add(errors,label..'.viewport.'..field..' must be a finite number') end
        else add(errors,label..".viewport: unknown field '"..field.."'") end
      end
    end
  end
  if pass.conditions~=nil then
    if not object(pass.conditions) then add(errors,label .. ': "conditions" must be an object')
    else
      checkKeys(pass.conditions,set{'runIf','skipIf'},errors,label..'.conditions')
      for _,mode in ipairs({'runIf','skipIf'}) do
        local list=pass.conditions[mode]
        if list~=nil then
          if not isArray(list) then add(errors,label..'.conditions.'..mode..' must be an array')
          else
            for _,condition in ipairs(list) do
              if not object(condition) then add(errors,label..'.conditions.'..mode..': condition must be an object')
              else
                checkKeys(condition,set{'uniform','equals'},errors,label..'.conditions.'..mode)
                if not nonempty(condition.uniform) then add(errors,label..'.conditions.'..mode..': "uniform" must be a non-empty string')
                elseif not context.globalKeys[condition.uniform] and not context.uniformNames[condition.uniform] then
                  add(errors,label..'.conditions.'..mode..": uniform '"..condition.uniform.."' does not reference a declared global") end
                if condition.equals==nil then add(errors,label..'.conditions.'..mode..': condition requires an "equals" value') end
              end
            end
          end
        end
      end
    end
  end
  for _,field in ipairs({'uniforms','defines'}) do
    if pass[field]~=nil then
      if not object(pass[field]) then add(errors,label .. ': "'..field..'" must be an object')
      else
        for _,key in ipairs(keys(pass[field])) do
          local value=pass[field][key]
          if field=='uniforms' and not finite(value) and not nonempty(value) then
            add(errors,label .. ": uniforms['"..key.."'] must be a finite number or a non-empty string")
          elseif field=='defines' and type(value)~='string' and not finite(value) then
            add(errors,label .. ": defines['"..key.."'] must be a string or finite number")
          end
        end
      end
    end
  end
  local declared={}
  for _,name in ipairs(keys(source.textures or {})) do declared[name]=true end
  for _,name in ipairs(keys(source.textures3d or {})) do declared[name]=true end
  if pass.inputs~=nil then
    if not object(pass.inputs) then add(errors,label .. ': "inputs" must be an object')
    else
      for _,uniform in ipairs(keys(pass.inputs)) do
        local ref=pass.inputs[uniform]
        if not nonempty(ref) then add(errors,label .. ": inputs['"..uniform.."'] must be a non-empty texture reference string")
        elseif not pipelineInputs[ref] and not ref:match('^o[0-7]$') and not ref:match('^global_') and
          not declared[ref] and not context.globalKeys[ref] and ref~=source.externalTexture then
          add(errors,label .. ": inputs['"..uniform.."'] references unsupported texture '"..ref.."'")
        end
      end
    end
  end
  if pass.outputs~=nil then
    if not object(pass.outputs) then add(errors,label .. ': "outputs" must be an object')
    else
      for _,attachment in ipairs(keys(pass.outputs)) do
        local ref=pass.outputs[attachment]
        if not nonempty(ref) then add(errors,label .. ": outputs['"..attachment.."'] must be a non-empty texture reference string")
        elseif not pipelineOutputs[ref] and not ref:match('^global_') and not declared[ref] then
          add(errors,label .. ": outputs['"..attachment.."'] references unsupported output '"..ref.."'")
        end
      end
    end
  end
end

function M.validateEffectDefinition(def)
  local errors={}
  if def==nil or def==NULL then return {'Effect definition is null or undefined'} end
  if isArray(def) then return {'Effect definition must be a plain object or Effect instance, not an array'} end
  if not object(def) then
    return {'Effect definition must be a plain object or Effect instance, not '..type(def)}
  end
  local context={globalKeys={},uniformNames={}}
  if object(def.globals) then
    for _,name in ipairs(keys(def.globals)) do
      context.globalKeys[name]=true
      local spec=def.globals[name]
      if object(spec) and nonempty(spec.uniform) then context.uniformNames[spec.uniform]=true end
    end
  end
  if not nonempty(def.name) then add(errors,'Missing or invalid "name" property') end
  for _,field in ipairs({'namespace','func','deprecatedBy','externalTexture','externalMesh','outputTex3d','outputGeo'}) do
    if def[field]~=nil and not nonempty(def[field]) then add(errors,'"'..field..'" must be a non-empty string') end
  end
  if def.description~=nil and type(def.description)~='string' then add(errors,'"description" must be a string') end
  if def.tags~=nil then
    if not isArray(def.tags) then add(errors,'"tags" must be an array of tag strings')
    else
      for _,tag in ipairs(def.tags) do
        if not nonempty(tag) then add(errors,'"tags" must contain non-empty strings')
        elseif not tags[tag] then add(errors,"Unknown tag '"..tag.."'") end
      end
    end
  end
  if def.openCategories~=nil then
    local valid=isArray(def.openCategories)
    if valid then for _,category in ipairs(def.openCategories) do if type(category)~='string' then valid=false end end end
    if not valid then add(errors,'"openCategories" must be an array of strings') end
  end
  if def.defaultProgram~=nil and type(def.defaultProgram)~='string' then add(errors,'"defaultProgram" must be a string') end
  if def.hidden~=nil and type(def.hidden)~='boolean' then add(errors,'"hidden" must be a boolean') end
  if def.builtinMeshes~=nil then
    if not object(def.builtinMeshes) then add(errors,'"builtinMeshes" must be an object')
    else for _,name in ipairs(keys(def.builtinMeshes)) do
      if not nonempty(def.builtinMeshes[name]) then add(errors,"builtinMeshes['"..name.."'] must be a non-empty string") end
    end end
  end
  for _,hook in ipairs({'onInit','onUpdate','onDestroy','asyncInit'}) do
    if def[hook]~=nil and type(def[hook])~='function' then add(errors,'"'..hook..'" must be a function') end
  end
  globals(def.globals,errors,context)
  if not isArray(def.passes) or #def.passes==0 then add(errors,'Missing or empty "passes" array')
  else for index,pass in ipairs(def.passes) do validatePass(def,pass,index-1,errors,context) end end
  textures(def.textures,errors,'textures')
  textures(def.textures3d,errors,'textures3d')
  if def.shaders~=nil then
    if not object(def.shaders) then add(errors,'"shaders" must be an object mapping program names to shader maps')
    else for _,program in ipairs(keys(def.shaders)) do
      if not object(def.shaders[program]) then add(errors,"shaders['"..program.."'] must be an object") end
    end end
  end
  if def.uniformLayout~=nil then uniformLayout(def.uniformLayout,errors,'uniformLayout') end
  if def.uniformLayouts~=nil then
    if not object(def.uniformLayouts) then add(errors,'"uniformLayouts" must be an object mapping program names to layouts')
    else for _,name in ipairs(keys(def.uniformLayouts)) do
      uniformLayout(def.uniformLayouts[name],errors,"uniformLayouts['"..name.."']")
    end end
  end
  if def.paramAliases~=nil then
    if not object(def.paramAliases) then add(errors,'"paramAliases" must be an object mapping aliases to global names')
    else for _,name in ipairs(keys(def.paramAliases)) do
      local target=def.paramAliases[name]
      if not nonempty(target) then add(errors,"paramAliases['"..name.."'] must be a non-empty string")
      elseif not context.globalKeys[target] then add(errors,"paramAliases['"..name.."'] references unknown global '"..target.."'") end
    end end
  end
  checkKeys(def,topKeys,errors,'Definition')
  for i,message in ipairs(errors) do
    if message:sub(1,10)=='Definition' then errors[i]=message:gsub('^Definition: unknown field','Unknown definition field') end
  end
  return errors
end

return M
