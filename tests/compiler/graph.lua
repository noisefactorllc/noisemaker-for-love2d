local registry = require('noisemaker.catalog.registry')
local resources = require('noisemaker.compiler.resources')
do
  local compiler = require('noisemaker.compiler.init')
  local globals = require('noisemaker.compiler.values').object()
  for _, name in ipairs({'r','g','b','alpha'}) do
    require('noisemaker.compiler.values').set(globals,name,{type='float',default=1,uniform=name})
  end
  assert(registry.registerEffect({name='RGB contract',namespace='user',func='rgbContract',globals=globals,
    passes={{program='main',outputs={color='outputTex'}}},shaders={main={glsl='out vec4 fragColor;void main(){fragColor=vec4(1.0);}'}}}))
  local ast = compiler.parse(compiler.lex('search user\nlet c = rgbContract(#804020)\nc(r: 0.25).write(o0) render(o0)'))
  local result = compiler.validate(ast)
  assert(#result.diagnostics==0)
  local args = result.plans[1].chain[1].args
  assert(args.r==.25 and args.g==64/255 and args.b==32/255 and args.alpha==1,'let-bound RGB color splat')
end

assert(registry.getEffect('synth.solid') == registry.getEffect('synth/solid'))
assert(registry.getEffect('synth.solid').globals.alpha.default == 1)

-- Color constructors preserve the supplied components like their array literals, and a
-- malformed constructor gives S002 with the parameter's default (upstream GAP-086).
do
  local compiler = require('noisemaker.compiler.init')
  local function colorArg(source, op)
    local result = compiler.validate(compiler.parse(compiler.lex('search synth, filter\n' .. source .. '.write(o0)\nrender(o0)')))
    local codes = {}
    for _, d in ipairs(result.diagnostics) do codes[#codes + 1] = d.code end
    for _, entry in ipairs(result.plans[1].chain) do
      if entry.op == op then return entry.args.color, codes end
    end
    error('missing step ' .. op)
  end
  local function same(actual, expected, label)
    assert(#actual == #expected, label)
    for i = 1, #expected do assert(actual[i] == expected[i], label) end
  end
  for _, case in ipairs({
    {call = 'solid(color: %s)', op = 'synth.solid', fallback = {0.5, 0.5, 0.5}},
    {call = 'solid().tint(color: %s)', op = 'filter.tint', fallback = {1, 1, 1}},
  }) do
    for _, form in ipairs({'vec3(0.3, 0.2, 0.25)', '[0.3, 0.2, 0.25]'}) do
      local value, codes = colorArg(case.call:format(form), case.op)
      same(value, {0.3, 0.2, 0.25}, form); same(codes, {}, form)
    end
    for _, form in ipairs({'vec4(0.3, 0.2, 0.25, 0.4)', '[0.3, 0.2, 0.25, 0.4]'}) do
      local value, codes = colorArg(case.call:format(form), case.op)
      same(value, {0.3, 0.2, 0.25, 0.4}, form); same(codes, {}, form)
    end
    for _, form in ipairs({'vec2(0.3, 0.2)', 'vec3(0.3, 0.2)', 'vec3(0.3, 0.2, 0.25, 0.4)',
      'vec4(0.3, 0.2, 0.25)', 'vec4(0.3, 0.2, 0.25, 0.4, 1)'}) do
      local value, codes = colorArg(case.call:format(form), case.op)
      same(value, case.fallback, form); same(codes, {'S002'}, form)
    end
    -- The parser refuses mixed positional and keyword arguments (P007), so a
    -- kwargs-bearing constructor cannot reach the validator's constructor branch.
    for _, form in ipairs({'vec3(0.3, 0.2, 0.25, bogus: 1)', 'vec4(0.3, 0.2, 0.25, 0.4, bogus: 1)'}) do
      assert(not pcall(colorArg, case.call:format(form), case.op), form)
    end
  end
  print('compiler color constructor checks passed')
end

local passes = {
  {outputs = {color = 'a'}},
  {inputs = {first = 'a', second = 'a'}, outputs = {color = 'b'}},
  {inputs = {src = 'b'}, outputs = {color = 'global_o0'}},
  {outputs = {color = 'c'}}
}
local lifetime = resources.analyzeLiveness(passes)
assert(lifetime.a.start == 0 and lifetime.a['end'] == 1)
assert(lifetime.b.start == 1 and lifetime.b['end'] == 2)
local allocations = resources.allocateResources(passes)
assert(allocations.a == 'phys_0')
assert(allocations.b == 'phys_1')
assert(allocations.c == 'phys_0')
assert(allocations.global_o0 == nil)
do
  local aliasPasses = {
    {nodeId='node_0', outputs={color='node_0_out'}},
    {nodeId='node_1', inputs={color='node_1_inputColor'}, outputs={color='node_1_out'}},
    {nodeId='node_2', inputs={color='node_2_inputTex'}, outputs={color='node_2_out'}},
  }
  local spans = resources.analyzeLiveness(aliasPasses)
  assert(spans.node_0_out['end'] == 1 and spans.node_1_out['end'] == 2)
  assert(not spans.node_1_inputColor and not spans.node_2_inputTex)
  local slots = resources.allocateResources(aliasPasses)
  assert(slots.node_2_out == slots.node_0_out and slots.node_1_out ~= slots.node_0_out)
  aliasPasses[1].outputs.upload = 'node_1_inputColor'
  spans = resources.analyzeLiveness(aliasPasses)
  assert(spans.node_0_out['end'] == 0 and spans.node_1_inputColor['end'] == 1)
end
local portable={name='Portable',namespace='user',func='portable',globals={gain={type='float',default=0.5,min=0,max=1,uniform='gain'}},
  passes={{program='main',inputs={},outputs={color='outputTex'}}},
  shaders={main={glsl='#version 300 es\nprecision highp float;\nout vec4 fragColor;\nvoid main(){fragColor=vec4(1.0);}'}}}
local registered, diagnostics=registry.registerEffect(portable)
assert(registered, diagnostics and diagnostics[1] and diagnostics[1].message)
assert(registry.getEffect('user.portable')==portable)
local missingShader={name='Missing',namespace='user',func='missing',passes={{program='main',outputs={color='outputTex'}}}}
local rejected,shaderDiagnostics=registry.registerEffect(missingShader)
assert(not rejected and shaderDiagnostics[1].code=='ERR_PORTABLE_GLSL_REQUIRED')
assert(registry.getEffect('user.missing')==nil)
local invalid={name='Bad',namespace='user',func='bad',passes={{program='main',outputs={color='outputTex'},nonsense=true}},
  shaders={main={glsl='void main(){}'}}}
local invalidResult,invalidDiagnostics=registry.registerEffect(invalid)
assert(not invalidResult and invalidDiagnostics[1].message:find("unknown field 'nonsense'",1,true))

local expressions=require('noisemaker.compiler.expressions')
assert(expressions.evaluate('state.enabled === false ? 7 : 2',{enabled=false})==7)
assert(expressions.evaluate('typeof enabled',{enabled=false})=='boolean')
assert(expressions.evaluate('state.items[0] === false',{items={false}})==true)

local starterOverride={name='Starter override',namespace='user',func='starterOverride',starter=true,
  passes={{program='main',inputs={src='inputTex'},outputs={color='outputTex'}}},shaders=portable.shaders}
local starterResult,starterDiagnostics=registry.registerEffect(starterOverride)
assert(starterResult,starterDiagnostics and starterDiagnostics[1] and starterDiagnostics[1].message)
assert(require('noisemaker.compiler.init').compile('search user\nstarterOverride().write(o0)\nrender(o0)'))
local nonstarterOverride={name='Nonstarter override',namespace='user',func='nonstarterOverride',starter=false,
  passes=portable.passes,shaders=portable.shaders}
assert(registry.registerEffect(nonstarterOverride))
local nonstarterGraph,nonstarterDiagnostics=require('noisemaker.compiler.init').compile('search user\nnonstarterOverride().write(o0)\nrender(o0)')
assert(not nonstarterGraph and nonstarterDiagnostics[1].code=='S005')
local invalidStarter={name='Invalid starter',namespace='user',func='invalidStarter',starter='yes',
  passes=portable.passes,shaders=portable.shaders}
local badStarterResult,badStarterDiagnostics=registry.registerEffect(invalidStarter)
assert(not badStarterResult and badStarterDiagnostics[1].code=='ERR_PORTABLE_DEFINITION')

local invalidFunction={name='Invalid function',namespace='user',func='bad-name',passes=portable.passes,shaders=portable.shaders}
local badFunctionResult,badFunctionDiagnostics=registry.registerEffect(invalidFunction)
assert(not badFunctionResult and badFunctionDiagnostics[1].code=='ERR_PORTABLE_FUNCTION')
assert(registry.getEffect('user.bad-name')==nil)
-- A func that `search user` cannot call is reserved, as upstream registerPortableEffect rejects it.
for _,reserved in ipairs({'o1','s2','vol0','osc','midi','audio','read','read3d','from','if','render','write'}) do
  local reservedResult,reservedDiagnostics=registry.registerEffect({name='Reserved',namespace='user',func=reserved,passes=portable.passes,shaders=portable.shaders})
  assert(not reservedResult and reservedDiagnostics[1].code=='ERR_PORTABLE_FUNCTION' and reservedDiagnostics[1].message=='reserved func '..reserved,reserved)
  assert(registry.getEffect('user.'..reserved)==nil,reserved)
end
local aliased={name='Aliased',namespace='user',func='aliased',globals=portable.globals,paramAliases={level='gain'},passes=portable.passes,shaders=portable.shaders}
local aliasedResult,aliasedDiagnostics=registry.registerEffect(aliased)
assert(not aliasedResult and aliasedDiagnostics[1].message=='paramAliases is no longer supported')
assert(registry.getEffect('user.aliased')==nil)
print('compiler graph registry and allocation checks passed')

-- Compilation must not reorder the catalog's positional argument schema.
do
 local compiler=require('noisemaker.compiler.init')
 local source='search synth, mixer\nsolid(color: #ff0000).alphaMask(tex: solid(color: #808080), baseTex: solid(color: #0000ff)).write(o0)\nrender(o0)'
 for iteration=1,3 do
  local graph=assert(compiler.compile(source))
  assert(math.abs(graph.passes[2].uniforms.color[1]-128/255)<1e-12,'Nested argument order changed across compiles')
  assert(graph.passes[3].uniforms.color[3]==1 and graph.passes[3].uniforms.color[1]==0)
 end
end
