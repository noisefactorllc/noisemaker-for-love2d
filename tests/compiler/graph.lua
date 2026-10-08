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
