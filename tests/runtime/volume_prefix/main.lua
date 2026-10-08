local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local nm=require('noisemaker')
local renderer=require('noisemaker.runtime.renderer')
local resources=require('noisemaker.runtime.resources')
local function run()
 local graph={passes={{uniforms={volumeSize_chain_custom=128,volumeSize_node_alpha=128,volumeSize_chains_custom=128}}}}
 resources.clampGraphVolumes(graph,8192)
 local uniforms=graph.passes[1].uniforms
 assert(uniforms.volumeSize_chain_custom==64 and uniforms.volumeSize_node_alpha==64,
  'Volume-size family prefixes must clamp to the shared atlas limit')
 assert(uniforms.volumeSize_chains_custom==128,'Unrelated uniform names must remain unchanged')
 local effect={name='VolumePrefixProbe',namespace='user',func='volumePrefixProbe',
  globals={volumeSize_chain_custom={type='float',default=128,uniform='volumeSize_chain_custom'}},
  passes={{name='main',program='main',inputs={},outputs={fragColor='outputTex'}}},
  shaders={main={glsl='uniform float volumeSize_chain_custom;out vec4 fragColor;void main(){fragColor=vec4(volumeSize_chain_custom/512.0,0.0,0.0,1.0);}'}}}
 local registered,registrationErrors=nm.registerEffect(effect)
 assert(registered,require('noisemaker.json').encode(registrationErrors))
 local compiled,compileErrors=nm.compile('search user\nvolumePrefixProbe().write(o0)\nrender(o0)\n')
 assert(compiled,require('noisemaker.json').encode(compileErrors))
 local instance,diagnostics=renderer.new(compiled,{width=8,height=8})
 assert(instance,diagnostics and diagnostics[1].message)
 local expected=resources.clampVolumeSize(256,love.graphics.getSystemLimits().texturesize)
 assert(instance:setParameter(0,'volumeSize_chain_custom',256))
 assert(instance.graph.passes[1].uniforms.volumeSize_chain_custom==expected,
  'Portable volume-size prefix parameter must clamp before GPU binding')
 local frame,renderErrors=instance:render{}
 assert(frame,renderErrors and renderErrors[1].message)
 local pixels=frame:newImageData();local red=pixels:getPixel(4,4);pixels:release()
 assert(math.abs(red-expected/512)<.01,'Portable shader must receive the effective volume size')
 assert(instance:release())
 print('VOLUME-PREFIX Portable nonnumeric family names clamp; unrelated names remain unchanged')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
