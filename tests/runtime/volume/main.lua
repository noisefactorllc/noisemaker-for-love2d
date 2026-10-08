local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local renderer=require('noisemaker.runtime.renderer')
local function run()
 local g=love.graphics
 local volume=g.newCanvas(4,4,2,{type='volume',format='rgba16f',dpiscale=1,readable=true})
 g.push('all');g.setBlendMode('replace','premultiplied');g.setColor(1,1,1,1)
 g.setCanvas({{volume,layer=1}});g.clear(.2,.3,.4,.5)
 g.setCanvas({{volume,layer=2}});g.clear(.7,.6,.5,.4)
 g.setColor(1,0,0,1);g.rectangle('fill',0,0,4,1)
 g.pop()
 volume:setFilter('nearest','nearest')
 local graph={passes={{id='sample',program='sample',inputs={volumeTex='inputVolume'},outputs={color='global_o0'},uniforms={}}},programs={sample={glsl='uniform sampler3D volumeTex;out vec4 fragColor;void main(){fragColor=texture(volumeTex,vec3(.5,.5,.75));}'}},textures={},allocations={},renderSurface='o0'}
 local r,diagnostics=renderer.new(graph,{width=17,height=9});assert(r,diagnostics and diagnostics[1].message)
 assert(r:setInput('inputVolume',volume))
 local prior=r.external.inputVolume
 local flat=g.newCanvas(4,4)
 for _,origin in ipairs({'top-left','bottom-left'})do
  local accepted,inputErrors=r:setInput('inputVolume',flat,{origin=origin})
  assert(not accepted and inputErrors[1].code=='ERR_INPUT_TYPE' and r.external.inputVolume==prior,'Sampler mismatch must preserve the prior valid binding')
 end
 flat:release()
 local out,errors=r:render{};assert(out,errors and errors[1].message)
 local data=out:newImageData();local a,b,c,d=data:getPixel(0,0)
 assert(math.abs(a-.7)<.002 and math.abs(b-.6)<.002 and math.abs(c-.5)<.002 and math.abs(d-.4)<.002,string.format('volume %.6f %.6f %.6f %.6f',a,b,c,d))
 data:release()
 local copied=r.external.inputVolume:newImageData(2)
 local top=copied:getPixel(0,0);local bottom=copied:getPixel(0,3)
 assert(math.abs(top-.7)<.002 and bottom>.99,'Volume top-left input must flip each layer')
 copied:release()
 assert(not r:copyTo(out),'Self-copy must fail before changing graphics state')
 r:release();assert(volume:getWidth()==4);volume:release()
 print('VOLUME-PIXELS public volume Canvas sampler3D layer 2 preserved RGBA')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
