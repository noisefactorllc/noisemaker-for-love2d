local json = require('noisemaker.json')
local graph = require('noisemaker.runtime.graph')
local decoded = json.decode('{"a":[],"b":{},"c":null,"s":"\\ud83d\\ude00","n":-1.25e2}')
assert(decoded.n == -125 and decoded.s == '\240\159\152\128')
assert(json.encode(decoded):find('"a":%[%]'))
assert(json.encode(decoded):find('"b":{}'))
assert(json.encode(decoded):find('"c":null'))
for _, s in ipairs({'[1,]', '{"x":01}', 'true false', '"\\uZZZZ"', '{"a":1,"a":2}', '1e', '"\n"'}) do
 assert(not pcall(json.decode,s), 'accepted malformed JSON: ' .. s)
end
local portable = json.decode('{"$type":"map","entries":[["b",2],["a",1]]}')
assert(graph.decode(portable).b == 2)
assert(graph.dimension({param='s',power=2,default=4096},256,{s=16}) == 256)
assert(graph.dimension({param='s',power=2,default=4096},256,{}) == 4096)
assert(graph.dimension({screenDivide='z'},257,{z=2}) == 129)
assert(graph.dimension('50%',257,{}) == 128)
assert(graph.dimension({scale=0.1,clamp={min=32}},256,{}) == 32)
local valid={passes={{id='p',program='solid',inputs={},outputs={color='t'},uniforms={}}},programs={solid={glsl='void main() {}'}},textures={t={width='screen',height='screen',format='rgba16f'}},allocations={},renderSurface='o0'}
assert(graph.validate(valid))
valid.passes[1].unknownExecutionField=true
local ok,diags=graph.validate(valid)
assert(not ok and diags[1].code == 'ERR_GRAPH_FIELD')
print('runtime JSON and graph CPU tests passed')
