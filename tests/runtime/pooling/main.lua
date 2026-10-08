local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local function make()
 local function program(color)return {glsl='out vec4 fragColor;void main(){fragColor='..color..';}'} end
 return {passes={
  {id='a',program='red',inputs={},outputs={color='a'},uniforms={}},
  {id='readA',program='copy',inputs={src='a'},outputs={color='global_o0'},uniforms={}},
  {id='b',program='blue',inputs={},outputs={color='b'},uniforms={}},
  {id='readB',program='copy',inputs={src='b'},outputs={color='global_o0'},uniforms={}}},
  programs={red=program('vec4(1.,0.,0.,1.)'),blue=program('vec4(0.,0.,1.,1.)'),copy={glsl='in vec2 v_texCoord;uniform sampler2D src;out vec4 fragColor;void main(){fragColor=texture(src,v_texCoord);}'}},
  textures={a={width='screen',height='screen',format='rgba16f'},b={width='screen',height='screen',format='rgba16f'}},allocations={a='phys_0',b='phys_0'},renderSurface='o0'}
end
function love.load()
 local ok,err=xpcall(function()
  local renderer=require('noisemaker.runtime.renderer')
  local function prepared(graph,pooling)return assert(renderer.new(graph,{width=8,height=8,texturePooling=pooling}))end
  local standalone=prepared(make(),false);assert(standalone.resources.textures.a~=standalone.resources.textures.b);standalone:release()
  local pooled=prepared(make(),true)
  assert(pooled.resources.textures.a==pooled.resources.textures.b,'Eligible non-overlapping temporary targets must share storage')
  for frame=1,3 do local out=assert(pooled:render{});local data=out:newImageData();local red,green,blue,alpha=data:getPixel(3,4);assert(red==0 and green==0 and blue==1 and alpha==1);data:release()end
  assert(pooled:resize(9,7));assert(pooled.resources.textures.a==pooled.resources.textures.b);assert(pooled:render{})
  pooled.graph.passes[3].conditions={skipIf={{uniform='skip',equals=1}}};pooled.graph.passes[3].uniforms.skip=0
  assert(pooled:resize(9,7));assert(pooled.resources.textures.a~=pooled.resources.textures.b,'A changed pooling group must split previously shared storage')
  pooled.graph.passes[3].conditions=nil
  assert(pooled:resize(9,7));assert(pooled.resources.textures.a==pooled.resources.textures.b);assert(pooled:render{});pooled:release()
  local modifiers={
   function(g)g.textures.b.format='rgba32f'end,
   function(g)g.textures.b.filter='linear'end,
   function(g)g.textures.b.persistent=true end,
   function(g)g.textures.b.mipmaps=true end,
   function(g)g.passes[3].blend=true end,
   function(g)g.passes[3].conditions={skipIf={{uniform='skip',equals=1}}};g.passes[3].uniforms.skip=0 end,
   function(g)g.programs.blue.glsl='out vec4 fragColor;void main(){if(gl_FragCoord.x<2.)discard;fragColor=vec4(0.,0.,1.,1.);}'end,
   function(g)g.passes[4].inputs.extra='a'end,
  }
  for _,modify in ipairs(modifiers)do local graph=make();modify(graph);local r=prepared(graph,true);assert(r.resources.textures.a~=r.resources.textures.b,'Unsafe targets were pooled');assert(r:render{});r:release()end
  print('pooling: disjoint full-overwrite targets share storage; descriptor, lifetime, persistent, mipmap, blend, condition and discard exclusions passed')
 end,debug.traceback)
 love.graphics.setCanvas();if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)
end
