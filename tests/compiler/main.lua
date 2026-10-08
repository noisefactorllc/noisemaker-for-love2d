local source = love.filesystem.getSource()
local root = source .. '/../..'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
if os.getenv('NM_FRONTEND_INPUT') then
  dofile(root .. '/tests/compiler/frontend.lua')
  os.exit(0)
end
if os.getenv('NM_GRAPH_INPUT') then
  dofile(root .. '/tests/compiler/graph_runner.lua')
  os.exit(0)
end
if os.getenv('NM_PORTABLE_INPUT') then
  dofile(root .. '/tests/compiler/portable_runner.lua')
  os.exit(0)
end
local ok, err = xpcall(function()
  assert(jit and jit.version, 'compiler tests require LuaJIT')
  dofile(root .. '/tests/compiler/graph.lua')
  local compiler = require('noisemaker.compiler.init')
  local program = 'search synth\nsolid(color: #ff0000).write(o0)\nrender(o0)'
  local graph, diagnostics = compiler.compile(program)
  assert(graph, diagnostics and diagnostics[1] and diagnostics[1].message)
  assert(graph.renderSurface == 'o0')
  assert(graph.passes[1].outputs.color == 'node_0_out')
  assert(graph.passes[2].outputs.color == 'global_o0')
  assert(graph.allocations.node_0_out == 'phys_0')
  assert(graph.programs.node_0_solid.glsl:find('uniform',1,true))
  assert(compiler.hashSource(program) == graph.id)
  local bad, errors = compiler.compile('search synth\nmissing().write(o0)\nrender(o0)')
  assert(not bad and errors and errors[1].code == 'S001')
  local json=require('noisemaker.json')
  local registry=require('noisemaker.catalog.registry')
  local portableRoot=root .. '/parity/portable/'
  local function read(path)
    local file=assert(io.open(path,'rb'))
    local bytes=file:read('*a'); file:close(); return bytes
  end
  for _,item in ipairs({
    {name='portableRings',shaders={rings='rings.glsl'}},
    {name='portableEdgeGlow',shaders={edges='edgeGlow-edges.glsl',combine='edgeGlow-combine.glsl'}}
  }) do
    local definition=json.decode(read(portableRoot .. item.name .. '.portable.json'))
    definition.shaders={}
    for programName,fileName in pairs(item.shaders) do
      definition.shaders[programName]={glsl=read(root .. '/noisemaker/shaders/portable/' .. fileName)}
    end
    local registered,registrationDiagnostics=registry.registerEffect(definition)
    assert(registered,registrationDiagnostics and registrationDiagnostics[1] and registrationDiagnostics[1].message)
    local portableGraph,portableDiagnostics=compiler.compile(read(portableRoot .. item.name .. '.dsl'))
    assert(portableGraph,portableDiagnostics and portableDiagnostics[1] and portableDiagnostics[1].message)
    assert(#portableGraph.passes >= 2)
    assert(portableGraph.renderSurface=='o0')
  end
  print('native compiler graph checks passed')
end, debug.traceback)
if not ok then io.stderr:write(tostring(err) .. '\n') end
os.exit(ok and 0 or 1)
