local registry = require('noisemaker.catalog.registry')
local values = require('noisemaker.compiler.values')
local M = {}
local NULL = values.NULL
local UNDEFINED = values.UNDEFINED

local BLIT_FRAGMENT = [[#version 300 es
            precision highp float;
            in vec2 v_texCoord;
            uniform sampler2D src;
            out vec4 fragColor;
            void main() {
                fragColor = texture(src, v_texCoord);
            }]]
local BLIT_WGSL = '\n' .. [[
            struct FragmentInput {
                @builtin(position) position: vec4<f32>,
                @location(0) uv: vec2<f32>,
            }

            @group(0) @binding(0) var src: texture_2d<f32>;
            @group(0) @binding(1) var srcSampler: sampler;

            @fragment
            fn main(in: FragmentInput) -> @location(0) vec4<f32> {
                let uv = vec2<f32>(in.uv.x, 1.0 - in.uv.y);
                return textureSample(src, srcSampler, uv);
            }
        ]]

local function clone(value)
  if type(value) ~= 'table' or value == NULL or value == UNDEFINED then return value end
  local result = {}
  for k, v in pairs(value) do result[k] = clone(v) end
  return result
end

local function assign(target, source)
  for k, v in pairs(source or {}) do target[k] = clone(v) end
  return target
end

local function starts(value, prefix)
  return type(value) == 'string' and value:sub(1, #prefix) == prefix
end

local function surface(value)
  return type(value) == 'string' and value:match('^(o[0-7])$') or
    type(value) == 'string' and value:match('^(vol[0-7])$') or
    type(value) == 'string' and value:match('^(geo[0-7])$') or
    type(value) == 'string' and value:match('^(xyz[0-7])$') or
    type(value) == 'string' and value:match('^(vel[0-7])$') or
    type(value) == 'string' and value:match('^(rgba[0-7])$')
end

local textureArgKinds = {temp=true,output=true,source=true,feedback=true,vol=true,geo=true,xyz=true,vel=true,rgba=true,pipeline=true}
local particleTextures={global_xyz=true,global_vel=true,global_rgba=true,global_points_trail=true,global_life_data=true}
local function textureArg(value)
  return type(value) == 'table' and textureArgKinds[value.kind] == true
end

local function ordered(object)
  return registry.keys(object or {})
end

local function argumentValue(arg)
  if type(arg)=='table' and arg ~= NULL and arg.value ~= nil then return arg.value end
  return arg
end

local function firstDefined(...)
  for i=1,select('#',...) do
    local value=select(i,...)
    if value~=nil then return value end
  end
  return nil
end

local function ensureBlit(programs)
  if programs.blit then return end
  programs.blit = {fragment=BLIT_FRAGMENT,wgsl=BLIT_WGSL,fragmentEntryPoint='main'}
end

local function enumValue(path)
  if type(path) ~= 'string' then return path end
  local namespace,func,param,choice = path:match('^([^.]+)%.([^.]+)%.([^.]+)%.([^.]+)$')
  local effect = namespace and registry.getEffect(namespace .. '.' .. func)
  local definition = effect and effect.globals and effect.globals[param]
  local paletteName=path:match('^palette%.([^.]+)$')
  if paletteName then return require('noisemaker.catalog.palettes').names[paletteName] or path end
  return definition and definition.choices and definition.choices[choice] or path
end

local function resolveGlobal(name)
  if name == 'none' then return 'none' end
  if starts(name,'global_') then return name end
  if surface(name) then return 'global_' .. name end
  return name
end

function M.expand(compilation, options)
  options = options or {}
  local passes, errors, programs, textureSpecs, textureMap = {}, {}, {}, {}, {}
  local mediaSteps, mediaStepIds = {}, {}
  local writtenVolumes, readVolumes, exportedTextures = {}, {}, {}
  local lastWrittenSurface
  local function addBlit(id, input, output, nodeId, stepIndex)
    passes[#passes+1] = {id=id,program='blit',type='render',inputs={src=input},outputs={color=output},uniforms={}}
    local pass = passes[#passes]
    if nodeId then pass.nodeId=nodeId; pass.stepIndex=stepIndex end
    ensureBlit(programs)
  end
  for planIndex, plan in ipairs(compilation.plans or {}) do
    local current = {input=nil,input3d=nil,geo=nil,xyz=nil,vel=nil,rgba=nil}
    local lastInlineWriteTarget, particleId
    local pipelineUniforms = {}
    local chainId = 'chain_' .. (planIndex-1)
    local volumeSizeParam = 'volumeSize_' .. chainId
    local function scopeParticle(name)
      if particleId and particleTextures[name] then return name .. '_' .. particleId end
      return name
    end
    local function scopeChain(name)
      local particle = scopeParticle(name)
      if particle ~= name then return particle end
      if starts(name,'global_') then return name .. '_' .. chainId end
      return name
    end
    local function passthrough(nodeId)
      local names = {input='out',input3d='out3d',geo='outGeo',xyz='outXyz',vel='outVel',rgba='outRgba'}
      for key, suffix in pairs(names) do if current[key] then textureMap[nodeId .. '_' .. suffix] = current[key] end end
    end
    for stepIndex, step in ipairs(plan.chain or {}) do
      local nodeId = 'node_' .. step.temp
      if step.builtin and step.op == '_read' then
        local tex = step.args and step.args.tex
        if tex and tex.kind == 'output' then current.input = 'global_' .. tex.name end
        textureMap[nodeId .. '_out'] = current.input
      elseif step.builtin and step.op == '_read3d' then
        local tex3d, geo = step.args and step.args.tex3d, step.args and step.args.geo
        if tex3d then current.input3d = tex3d.kind == 'vol' and 'global_' .. tex3d.name or tex3d.name end
        if geo then current.geo = 'global_' .. geo.name end
        if current.input3d then
          readVolumes[volumeSizeParam] = {surface=current.input3d,writer=writtenVolumes[current.input3d]}
          pipelineUniforms.volumeSize = (writtenVolumes[current.input3d] or {}).value or 64
          pipelineUniforms[volumeSizeParam] = pipelineUniforms.volumeSize
          textureMap[nodeId .. '_out3d'] = current.input3d
        end
        if current.geo then textureMap[nodeId .. '_outGeo'] = current.geo end
      elseif step.builtin and step.op == '_write' then
        local tex = step.args and step.args.tex
        if tex and current.input then
          if tex.name ~= 'none' then
            local target = 'global_' .. tex.name
            if current.input ~= target then
              addBlit(nodeId .. '_write_blit',current.input,target,nodeId,step.temp)
              lastWrittenSurface = tex.name
              lastInlineWriteTarget = {kind=tex.kind,name=tex.name}
            end
          end
          textureMap[nodeId .. '_out'] = current.input
        end
      elseif step.builtin and step.op == '_write3d' then
        local tex3d, geo = step.args and step.args.tex3d, step.args and step.args.geo
        if tex3d and tex3d.name ~= 'none' and current.input3d then
          local target = 'global_' .. tex3d.name
          exportedTextures[target] = current.input3d
          if textureSpecs[current.input3d] then textureSpecs[target]=clone(textureSpecs[current.input3d]) end
          if pipelineUniforms.volumeSize ~= nil then writtenVolumes[target]={param=volumeSizeParam,value=pipelineUniforms.volumeSize} end
          if current.input3d ~= target then addBlit(nodeId .. '_write3d_vol_blit',current.input3d,target,nodeId,step.temp) end
        end
        if geo and geo.name ~= 'none' and current.geo then
          local target = 'global_' .. geo.name
          exportedTextures[target] = current.geo
          if textureSpecs[current.geo] then textureSpecs[target]=clone(textureSpecs[current.geo]) end
          if current.geo ~= target then addBlit(nodeId .. '_write3d_geo_blit',current.geo,target,nodeId,step.temp) end
        end
        passthrough(nodeId)
      elseif step.builtin and (step.op == '_subchain_begin' or step.op == '_subchain_end') then
        passthrough(nodeId)
      elseif step.args and step.args._skip == true then
        lastInlineWriteTarget = nil
        passthrough(nodeId)
      else
        lastInlineWriteTarget = nil
        local effectName = step.op
        local effect = registry.getEffect(effectName)
        if not effect then errors[#errors+1]={message="Effect '" .. tostring(effectName) .. "' not found",step=step}
        else
          local createParticles = effect.textures and effect.textures.global_xyz
          if createParticles then particleId=nodeId; current.xyz=nil; current.vel=nil; current.rgba=nil end
          local defines,defineOrder = {},{}
          local globalNames=ordered(effect.globals)
          table.sort(globalNames)
          for _, name in ipairs(globalNames) do
            local def = effect.globals[name]
            if def and def.define then
              local arg = step.args and step.args[name]
              local value
              if arg ~= nil and arg ~= NULL then value=argumentValue(arg) end
              if value == nil then value=def.default end
              if def.type == 'member' then value = enumValue(value) end
              if value ~= nil and value ~= NULL then defines[def.define] = value; defineOrder[#defineOrder+1]=def.define end
            end
          end
          local suffix = ''
          for _, name in ipairs(defineOrder) do suffix = suffix .. '__' .. name .. '_' .. tostring(defines[name]) end
          local shaders = (options.shaderOverrides or {})[step.temp] or effect.shaders
          if not shaders then
            local ok, catalog = pcall(require,'noisemaker.shaders.catalog')
            if ok and catalog.get then
              shaders = {}
              local effectId = (effect.namespace or effectName:match('^([^.]+)%.')) .. '/' .. effect.func
              for _, pass in ipairs(effect.passes or {}) do
                if pass.program and not shaders[pass.program] then
                  local source = catalog.get(effectId,pass.program)
                  if source then
                    local upstream = {}
                    if source.glsl then upstream.glsl=source.glsl end
                    if source.vert then upstream.vertex=source.vert end
                    if source.frag then upstream.fragment=source.frag end
                    shaders[pass.program] = upstream
                  end
                end
              end
            end
          end
          for _, programName in ipairs(ordered(shaders)) do
            local key = nodeId .. '_' .. programName .. suffix
            local program = clone(shaders[programName])
            local layout = effect.uniformLayouts and effect.uniformLayouts[programName] or effect.uniformLayout
            program.uniformLayout=layout and clone(layout) or UNDEFINED
            program.defines=clone(defines)
            programs[key]=program
          end
          local scopedParams = {}
          for _, texName in ipairs(ordered(effect.textures)) do
            local spec = effect.textures[texName]
            local particle = particleTextures[texName] and particleId
            local global = starts(texName,'global_')
            local id = global and (particle and texName .. '_' .. particleId or texName .. '_' .. chainId) or nodeId .. '_' .. texName
            local resolved = clone(spec)
            for _, axis in ipairs({'width','height'}) do
              local dim = resolved[axis]
              if type(dim)=='table' and dim ~= NULL then
                local field = dim.param and 'param' or dim.screenDivide and 'screenDivide'
                if field then
                  local original = dim[field]
                  local scope = particle or chainId
                  if original == 'stateSize' and particleId and not global then scope=particleId end
                  local scoped = original == 'volumeSize' and volumeSizeParam or original .. '_' .. scope
                  dim[field] = scoped
                  scopedParams[original] = scoped
                end
              end
            end
            textureSpecs[id]=resolved
          end
          for _, texName in ipairs(ordered(effect.textures3d)) do
            local id = starts(texName,'global_') and scopeChain(texName) or nodeId .. '_' .. texName
            local spec=clone(effect.textures3d[texName]); spec.is3D=true; textureSpecs[id]=spec
          end
          if step.from ~= nil and step.from ~= NULL then current.input=textureMap['node_' .. step.from .. '_out'] end
          for _, argName in ipairs(ordered(effect.globals)) do
            local def=effect.globals[argName]
            if def.uniform and def.default ~= nil and pipelineUniforms[def.uniform] == nil then
              pipelineUniforms[def.uniform] = def.type == 'member' and enumValue(def.default) or clone(def.default)
            end
            if def.type == 'surface' and def.colorModeUniform and (not step.args or step.args[argName] == nil) then
              pipelineUniforms[def.colorModeUniform] = def.default == 'none' and 0 or 1
            end
          end
          local colorControlled = {}
          for argName,arg in pairs(step.args or {}) do
            local globalDef=effect.globals and effect.globals[argName]
            if textureArg(arg) and globalDef and globalDef.colorModeUniform then
              pipelineUniforms[globalDef.colorModeUniform] = arg.name == 'none' and 0 or 1
              colorControlled[globalDef.colorModeUniform]=true
            end
          end
          for argName,arg in pairs(step.args or {}) do
            if not textureArg(arg) then
              local globalDef=effect.globals and effect.globals[argName]
              local uniform=globalDef and globalDef.uniform or argName
              if not colorControlled[uniform] and not (uniform=='volumeSize' and current.input3d and pipelineUniforms.volumeSize ~= nil) then
                pipelineUniforms[uniform]=clone(argumentValue(arg))
              end
            end
          end
          local conditional={}
          for _, passDef in ipairs(effect.passes or {}) do
            for _, mode in ipairs({'runIf','skipIf'}) do
              for _, condition in ipairs(passDef.conditions and passDef.conditions[mode] or {}) do conditional[condition.uniform]=true end
            end
          end
          for passNumber, passDef in ipairs(effect.passes or {}) do
            local programName=nodeId .. '_' .. tostring(passDef.program) .. suffix
            if passDef.defines then
              local passSuffix=''
              local passDefineNames=ordered(passDef.defines)
              table.sort(passDefineNames)
              for _, name in ipairs(passDefineNames) do passSuffix=passSuffix .. '__' .. name .. '_' .. tostring(passDef.defines[name]) end
              local base=programs[programName]
              programName=programName .. passSuffix
              if base and not programs[programName] then
                programs[programName]=clone(base)
                programs[programName].defines=assign(clone(defines),passDef.defines)
              end
            end
            local pass={id=nodeId .. '_pass_' .. (passNumber-1),program=programName,
              inputs=registry.orderedObject(),outputs=registry.orderedObject(),uniforms={},
              effectKey=effectName,effectFunc=effect.func or effectName,effectNamespace=effect.namespace or NULL,nodeId=nodeId,stepIndex=step.temp}
            for _, field in ipairs({'entryPoint','drawMode','drawBuffers','count','countUniform','repeat','blend','conditions',
              'workgroups','storageBuffers','storageTextures','name','type','clear','viewport','samplerTypes'}) do
              if passDef[field] ~= nil then pass[field]=clone(passDef[field]) else pass[field]=UNDEFINED end
            end
            if current.input3d and pipelineUniforms.volumeSize ~= nil then pass.inheritsVolumeSize=true end
            pass.uniforms=clone(pipelineUniforms)
            if effect.globals then
              pass.uniformSpecs={}
              for _, argName in ipairs(ordered(effect.globals)) do
                local def=effect.globals[argName]
                if def.uniform and def.default ~= nil and pass.uniforms[def.uniform]==nil then
                  local value=def.type=='member' and enumValue(def.default) or clone(def.default)
                  pass.uniforms[def.uniform]=value; pipelineUniforms[def.uniform]=value
                end
                local uniform=def.uniform or argName
                if (def.type=='float' or def.type=='int') and not def.choices then
                  pass.uniformSpecs[uniform]={min=def.min or 0,max=def.max or 100}
                elseif def.type=='int' and def.choices and conditional[uniform] then
                  local spec={type='int'}
                  if type(def.min)=='number' and type(def.max)=='number' then spec.min=def.min; spec.max=def.max end
                  pass.uniformSpecs[uniform]=spec
                end
              end
            end
            for argName,arg in pairs(step.args or {}) do
              if not textureArg(arg) then
                local globalDef=effect.globals and effect.globals[argName]
                local uniform=globalDef and globalDef.uniform or argName
                local controlled=false
                for _, def in pairs(effect.globals or {}) do if def.colorModeUniform==uniform then controlled=true end end
                if not controlled and not (uniform=='volumeSize' and current.input3d and pipelineUniforms.volumeSize ~= nil) then
                  local value=clone(argumentValue(arg))
                  pass.uniforms[uniform]=value; pipelineUniforms[uniform]=value
                end
              end
            end
            for uniform, globalRef in pairs(passDef.uniforms or {}) do
              if type(globalRef)=='number' then pass.uniforms[uniform]=globalRef
              else
                if globalRef ~= uniform then pass.uniformAliases=pass.uniformAliases or {}; pass.uniformAliases[uniform]=globalRef end
                local def=effect.globals and effect.globals[globalRef]
                local value=firstDefined(pipelineUniforms[uniform],pipelineUniforms[globalRef],def and def.default)
                if value ~= nil then pass.uniforms[uniform]=def and def.type=='member' and enumValue(value) or clone(value) end
              end
            end
            for argName,globalDef in pairs(effect.globals or {}) do
              if globalDef.type=='palette' then
                local uniform=globalDef.uniform or argName
                local index=pass.uniforms[uniform]
                local palette=type(index)=='number' and require('noisemaker.catalog.palettes')[index] or nil
                if palette then
                  for name,value in pairs(palette) do
                    if pass.uniforms[name]~=nil then
                      pass.uniforms[name]=clone(value)
                      pipelineUniforms[name]=clone(value)
                    end
                  end
                end
              end
            end
            for _, uniform in ipairs(ordered(passDef.inputs)) do
              local texRef=passDef.inputs[uniform]
              local bound
              if texRef=='inputTex' or texRef:match('^o[0-7]') then bound=current.input or texRef
              elseif texRef=='inputTex3d' then bound=current.input3d or texRef
              elseif texRef=='inputGeo' then bound=current.geo or texRef
              elseif texRef=='inputXyz' then bound=current.xyz or texRef
              elseif texRef=='inputVel' then bound=current.vel or texRef
              elseif texRef=='inputRgba' then bound=current.rgba or texRef
              elseif texRef=='noise' then bound='global_noise'
              elseif texRef=='midiNoteGrid' then bound='midiNoteGrid'
              elseif texRef=='feedback' or texRef=='selfTex' then
                bound=plan.write and plan.write~=NULL and 'global_' .. plan.write.name or current.input or 'global_inputTex'
              elseif effect.externalTexture and texRef==effect.externalTexture then
                bound=texRef .. '_step_' .. step.temp
                if not mediaStepIds[bound] then mediaStepIds[bound]=true; mediaSteps[#mediaSteps+1]={textureId=bound,uniform=uniform,stepIndex=step.temp,effect=effectName} end
              elseif step.args and step.args[texRef] ~= nil then
                local arg=step.args[texRef]
                if arg ~= NULL then
                  if type(arg)=='table' and arg.kind=='temp' then bound=textureMap['node_' .. arg.index .. '_out']
                  elseif type(arg)=='table' and arg.kind=='pipeline' and (arg.name=='inputTex' or arg.name=='inputColor') then bound=current.input or arg.name
                  elseif textureArg(arg) then bound=arg.name=='none' and 'none' or 'global_' .. arg.name
                  elseif type(arg)=='string' then bound=resolveGlobal(arg) end
                end
              elseif effect.globals and effect.globals[texRef] and effect.globals[texRef].default ~= nil then
                local default=effect.globals[texRef].default
                if default=='none' then bound='none'
                elseif default=='inputTex' or default=='inputColor' then bound=current.input or default
                elseif surface(default) then bound='global_' .. default
                elseif starts(default,'global_') then bound=scopeChain(default)
                else bound=default end
              elseif starts(texRef,'global_') then bound=scopeChain(texRef)
              elseif texRef=='outputTex' then bound=nodeId .. '_out'
              else bound=nodeId .. '_' .. texRef end
              if bound ~= nil then registry.set(pass.inputs,uniform,bound) end
            end
            for _, attachment in ipairs(ordered(passDef.outputs)) do
              local texRef=passDef.outputs[attachment]
              local id
              if texRef=='outputTex' then
                local lastStep=stepIndex==#plan.chain and passNumber==#effect.passes
                if lastStep and plan.write and plan.write~=NULL then
                  id='global_' .. plan.write.name; lastWrittenSurface=plan.write.name
                else id=nodeId .. '_out' end
                textureMap[nodeId .. '_out']=id
              elseif texRef=='outputTex3d' then id=nodeId .. '_out3d'; textureMap[id]=id
              elseif texRef=='outputXyz' then id=nodeId .. '_outXyz'; textureMap[id]=id
              elseif texRef=='outputVel' then id=nodeId .. '_outVel'; textureMap[id]=id
              elseif texRef=='outputRgba' then id=nodeId .. '_outRgba'; textureMap[id]=id
              elseif texRef=='inputTex3d' then id=current.input3d or nodeId .. '_inputTex3d'
              elseif texRef=='inputGeo' then id=current.geo or nodeId .. '_inputGeo'
              elseif texRef=='inputXyz' then id=current.xyz or nodeId .. '_inputXyz'
              elseif texRef=='inputVel' then id=current.vel or nodeId .. '_inputVel'
              elseif texRef=='inputRgba' then id=current.rgba or nodeId .. '_inputRgba'
              elseif starts(texRef,'global_') then id=scopeChain(texRef)
              elseif starts(texRef,'feedback_') then id=texRef
              else id=nodeId .. '_' .. texRef end
              registry.set(pass.outputs,attachment,id)
            end
            for original,scoped in pairs(scopedParams) do
              if pass.uniforms[original] ~= nil then pass.uniforms[scoped]=pass.uniforms[original]; pipelineUniforms[scoped]=pass.uniforms[original] end
            end
            if next(scopedParams) then pass.scopedParams=clone(scopedParams) end
            passes[#passes+1]=pass
          end
          current.input=textureMap[nodeId .. '_out']
          if effect.outputTex and not current.input then
            if effect.outputTex=='inputTex' then current.input=step.from~=NULL and textureMap['node_' .. step.from .. '_out'] or nil
            else current.input=starts(effect.outputTex,'global_') and scopeChain(effect.outputTex) or nodeId .. '_' .. effect.outputTex end
            textureMap[nodeId .. '_out']=current.input
          end
          for key,suffix in pairs({input3d='out3d',xyz='outXyz',vel='outVel',rgba='outRgba'}) do
            current[key]=textureMap[nodeId .. '_' .. suffix] or current[key]
          end
          local outputs={input3d={'outputTex3d','out3d','inputTex3d'},geo={'outputGeo','outGeo','inputGeo'},
            xyz={'outputXyz','outXyz','inputXyz'},vel={'outputVel','outVel','inputVel'},rgba={'outputRgba','outRgba','inputRgba'}}
          for key,meta in pairs(outputs) do
            local named=effect[meta[1]]
            if named and not textureMap[nodeId .. '_' .. meta[2]] then
              if named~=meta[3] then current[key]=starts(named,'global_') and scopeChain(named) or nodeId .. '_' .. named end
              if current[key] then textureMap[nodeId .. '_' .. meta[2]]=current[key] end
            end
          end
        end
      end
    end
    if plan.write and plan.write~=NULL and current.input then
      local outName=plan.write.name or plan.write
      lastWrittenSurface=outName
      local already=lastInlineWriteTarget and lastInlineWriteTarget.kind=='output' and lastInlineWriteTarget.name==outName
      if not already then
        local target='global_' .. outName
        if current.input~=target then addBlit('final_blit_' .. outName,current.input,target) end
      end
    end
  end
  for id, source in pairs(exportedTextures) do if textureSpecs[source] then textureSpecs[id]=clone(textureSpecs[source]) end end
  for param, read in pairs(readVolumes) do
    local writer=read.writer or writtenVolumes[read.surface]
    if writer and writer.param~=param then
      for _, spec in pairs(textureSpecs) do
        for _, axis in ipairs({'width','height','depth'}) do
          if type(spec[axis])=='table' and spec[axis].param==param then spec[axis].param=writer.param end
        end
      end
      for _, pass in ipairs(passes) do
        if pass.uniforms[param]~=nil then
          pass.uniforms[param]=nil; pass.uniforms[writer.param]=writer.value; pass.uniforms.volumeSize=writer.value
          if pass.scopedParams and pass.scopedParams.volumeSize==param then pass.scopedParams.volumeSize=writer.param end
        end
      end
    end
  end
  local renderSurface=compilation.render and compilation.render~=NULL and compilation.render or lastWrittenSurface
  if not renderSurface then
    errors[#errors+1]={message='No render surface specified and no write() found - add render(oN) or write(oN)'}
    renderSurface=NULL
  end
  return {passes=passes,errors=errors,programs=programs,textureSpecs=textureSpecs,renderSurface=renderSurface,mediaSteps=mediaSteps}
end

return M
