local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local nm=require('noisemaker')
local resources=require('noisemaker.runtime.resources')
assert(type(nm.compile)=='function' and type(nm.newRenderer)=='function' and type(nm.registerEffect)=='function')
local source='search synth\nsolid(color: #ff9933).write(o0)\nrender(o0)'
local graph,diagnostics=nm.compile(source)
assert(graph,diagnostics and diagnostics[1] and diagnostics[1].message)
assert(graph.renderSurface=='o0' and #graph.passes==2)
local bad,errors=nm.compile('search synth\nmissing().write(o0)\nrender(o0)')
assert(not bad and errors and errors[1].code=='S001')
assert(resources.clampVolumeSize(128,8192)==64)
assert(resources.clampVolumeSize(256,16384)==128)
local volumeGraph={passes={{uniforms={volumeSize=128,volumeSize_chain_0=128,volumeSize_node_1=128,other=128}}}}
resources.clampGraphVolumes(volumeGraph,8192)
assert(volumeGraph.passes[1].uniforms.volumeSize==64 and volumeGraph.passes[1].uniforms.volumeSize_chain_0==64)
assert(volumeGraph.passes[1].uniforms.volumeSize_node_1==64 and volumeGraph.passes[1].uniforms.other==128)
print('clean consumer CPU compile passed')
os.exit(0)
