local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local nm=require('noisemaker')
local renderer=require('noisemaker.runtime.renderer')
local resources=require('noisemaker.runtime.resources')
local function run()
 local limit=love.graphics.getSystemLimits().texturesize
 local expected=resources.clampVolumeSize(128,limit)
 assert(resources.clampVolumeSize(128,8192)==64,'The shared atlas clamp must follow the source power-of-two rule')
 local source='search synth3d, render\ncell3d(volumeSize: x128).render3d().write(o0)\nrender(o0)\n'
 local graph,compileError=nm.compile(source)
 assert(graph,require('noisemaker.json').encode(compileError))
 local r,diagnostics=renderer.new(graph,{width=8,height=8})
 assert(r,diagnostics and diagnostics[1].message)
 local volume=r.resources.textures.node_0_volumeCache
 local geometry=r.resources.textures.node_0_geoBuffer
 assert(volume and geometry,'The authored 3D graph must allocate both volume atlases')
 assert(volume:getWidth()==expected and volume:getHeight()==expected*expected,
  'Native volume atlas does not match its own GPU texture limit')
 assert(geometry:getWidth()==expected and geometry:getHeight()==expected*expected,
  'Native geometry atlas does not match its own GPU texture limit')
 for _,pass in ipairs(r.graph.passes) do
  if pass.uniforms and pass.uniforms.volumeSize then
   assert(pass.uniforms.volumeSize==expected and pass.uniforms.volumeSize_chain_0==expected,
    'Native volume uniforms must match allocated atlas size')
  end
 end
 assert(r:release())
 if limit>=16384 then assert(expected==128,'Native high-capability GPU must retain the authored x128 volume') end
 print('VOLUME-LIMIT native max '..limit..' keeps effective volume '..expected..' atlas '..expected..'x'..expected*expected)
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
