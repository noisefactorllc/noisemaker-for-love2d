local source = love.filesystem.getSource()
local root = source .. '/../../..'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
local manifest = require('noisemaker.shaders.source.manifest')
local catalog = require('noisemaker.shaders.catalog')
local adapter = require('noisemaker.shaders.adapter')
local json = require('noisemaker.runtime.capabilities').json
local definitions = require('noisemaker.catalog.definitions')
local function unwrap(value)
  if type(value) ~= 'table' then return value end
  if value.__nm_type == 'array' then
    local result = {}
    for i, item in ipairs(value.items) do result[i] = unwrap(item) end
    return result
  end
  if value.__nm_type == 'object' then
    local result = {}
    for _, entry in ipairs(value.entries) do result[entry[1]] = unwrap(entry[2]) end
    return result
  end
  return nil
end
local definitionByEffect = unwrap(definitions)
local function defineVariants(effect, program)
  local def = definitionByEffect[effect]
  local base = {}
  local parameters = {}
  for _, parameter in pairs(def and def.globals or {}) do
    if type(parameter.define) == 'string' and parameter.default ~= nil then
      base[parameter.define] = parameter.default
      parameters[#parameters+1] = parameter
    end
  end
  local variants, seen = {}, {}
  local function add(candidate)
    local parts, keys = {}, {}
    for key in pairs(candidate) do keys[#keys+1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do parts[#parts+1] = key .. '=' .. tostring(candidate[key]) end
    local identity = table.concat(parts, ';')
    if seen[identity] then return end
    seen[identity] = true
    variants[#variants+1] = candidate
  end
  local matchingPass = false
  for _, pass in ipairs(def and def.passes or {}) do
    if pass.program == program then
      matchingPass = true
      local combined = {}
      for key, value in pairs(base) do combined[key] = value end
      for key, value in pairs(pass.defines or {}) do combined[key] = value end
      add(combined)
    end
  end
  if not matchingPass then add(base) end
  for _, parameter in ipairs(parameters) do
    local choices = {}
    for _, value in pairs(parameter.choices or {}) do choices[#choices+1] = value end
    for _, value in ipairs(parameter.randChoices or {}) do choices[#choices+1] = value end
    for _, value in ipairs(choices) do
      if type(value) == 'number' or type(value) == 'boolean' or type(value) == 'string' then
        local candidate = {}
        for key, item in pairs(base) do candidate[key] = item end
        candidate[parameter.define] = value
        add(candidate)
      end
    end
  end
  return variants
end
function love.load()
  local report = {schema='noisemaker-love-shader-sweep-v1', sourceCount=manifest.sourceCount, programCount=manifest.programCount, pass=0, variantCount=0, variantPass=0, adaptFail=0, compileFail=0, failures={}}
  local keys = {}
  for key in pairs(manifest.programs) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local entry = manifest.programs[key]
    local sourceFiles, readError = catalog.get(entry.effect, entry.program)
    if not sourceFiles then
      report.adaptFail = report.adaptFail + 1
      report.failures[#report.failures + 1] = {program=key, stage='read', error=tostring(readError and readError.code)}
    else
      local pixel = sourceFiles.fragment
      local validProgram = true
      for _, defines in ipairs(defineVariants(entry.effect, entry.program)) do
        report.variantCount = report.variantCount + 1
        local result, diagnostic = adapter.adapt{pixel=pixel, vertex=sourceFiles.vertex, defines=defines, path=sourceFiles.paths.glsl or sourceFiles.paths.frag, hash=sourceFiles.hashes.glsl or sourceFiles.hashes.frag, vertexHash=sourceFiles.hashes.vert}
        if not result then
          validProgram = false
          report.adaptFail = report.adaptFail + 1
          report.failures[#report.failures + 1] = {program=key, defines=defines, stage='adapt', error=diagnostic.detail or diagnostic.code}
        else
          local ok, shader = pcall(love.graphics.newShader, result.pixel, result.vertex)
          if not ok then
            validProgram = false
            report.compileFail = report.compileFail + 1
            report.failures[#report.failures + 1] = {program=key, defines=defines, stage='compile', error=tostring(shader):sub(1,700)}
          else report.variantPass = report.variantPass + 1; shader:release() end
        end
      end
      if validProgram then report.pass = report.pass + 1 end
    end
  end
  report.ok = report.pass == report.programCount
  local line = 'SHADER-SWEEP ' .. json(report)
  print(line)
  local path = os.getenv('NM_SHADER_SWEEP_RESULT')
  if path and path ~= '' then local file=assert(io.open(path,'wb'));file:write(line,'\n');file:close() end
  os.exit(report.ok and 0 or 1)
end
