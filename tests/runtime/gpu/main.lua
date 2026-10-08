local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local function near(a,b) assert(math.abs(a-b)<0.002,tostring(a)..' ~= '..tostring(b)) end
local function program(body) return {glsl='#version 300 es\nprecision highp float;\nin vec2 v_texCoord;\nout vec4 fragColor;\n'..body} end
local function graph()
 return {passes={{id='p0',program='p',inputs={},outputs={color='local0'},uniforms={alpha=.5}},{id='p1',program='copy',inputs={src='local0'},outputs={color='global_o0'},uniforms={}}},programs={p=program('uniform float alpha; void main(){fragColor=vec4(v_texCoord,0.25,alpha);}'),copy=program('uniform sampler2D src; void main(){fragColor=texture(src,v_texCoord);}')},textures={local0={width='screen',height='screen',format='rgba16f'}},allocations={},renderSurface='o0'}
end
function love.load()
 local ok,err=xpcall(function()
  local renderer=require('noisemaker.runtime.renderer')
  local g=love.graphics
  local host=g.newCanvas(7,9)
  g.setCanvas(host);g.setColor(.2,.3,.4,.5);g.translate(3,5);g.setScissor(1,2,3,4)
  local r,diags=renderer.new(graph(),{width=17,height=9});assert(r,diags and diags[1].message)
  assert(g.getCanvas()==host);near(g.getColor(),.2)
  local out,d=r:render{time=.25};assert(out,d and d[1].message)
  assert(g.getCanvas()==host);near(g.getColor(),.2);assert(select(1,g.getScissor())==1)
  local data=out:newImageData();local a,b,c,alpha=data:getPixel(0,0)
  near(a,.5/17);near(b,1-.5/9);near(c,.25);near(alpha,.5);data:release()
  assert(r:setParameter(0,'alpha',.25));out=assert(r:render{});data=out:newImageData();near(select(4,data:getPixel(0,0)),.25);data:release()
  assert(r:resize(19,11));out=assert(r:render{});assert(out:getWidth()==19 and out:getHeight()==11)
  local ownedBefore=#r.owned
  for i=1,12 do assert(r:resize(19+i,11+i));assert(r:render{}) end
  assert(#r.owned<=ownedBefore,'Repeated resize must retire obsolete fullscreen meshes')
  local prior=r.resources.textures.local0
  r.graph.textures.local0.filter='linear'
  r.graph.textures.local0.mipmaps=true
  assert(r:resize(r.width,r.height))
  assert(r.resources.textures.local0~=prior,'Reconfiguration must compare sampler and mipmap descriptors before texture reuse')
  assert(r.resources.textures.local0:getFilter()=='linear')
  assert(r:reset());r:release();assert(not r:render{})
  local bad=graph();bad.programs.p.glsl='invalid shader';local invalid,errors=renderer.new(bad,{width=17,height=9});assert(not invalid and errors[1].stage=='shader');assert(g.getCanvas()==host)
  g.setCanvas();host:release()
  print('runtime GPU state, multipass, alpha, parameters, resize, reset and release passed')
 end,debug.traceback)
 love.graphics.setCanvas()
 if not ok then io.stderr:write(tostring(err),'\n') end
 love.event.quit(ok and 0 or 1)
end
