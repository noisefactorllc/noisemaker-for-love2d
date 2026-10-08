local registry = require('noisemaker.catalog.registry')
local resources = require('noisemaker.compiler.resources')

assert(registry.getEffect('synth.solid') == registry.getEffect('synth/solid'))
assert(registry.getEffect('synth.solid').globals.alpha.default == 1)

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
