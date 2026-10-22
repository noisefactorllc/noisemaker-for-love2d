local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local renderer=require('noisemaker.runtime.renderer')
-- Upstream webgl2.js bindTextures (be8ed4cd): a declared sampler2D that pass.inputs does not list
-- reads the default texture, transparent black, including in a pass that has no inputs.
local function pixel(graph,binding)
 local r,diagnostics=renderer.new(graph,{width=5,height=3});assert(r,diagnostics and diagnostics[1].message)
 if binding then assert(r:setInput(binding[1],binding[2])) end
 local out,errors=r:render{};assert(out,errors and errors[1].message)
 local data=out:newImageData();local seen={data:getPixel(2,1)};data:release();r:release()
 return seen
end
local function near(seen,expected,label)
 for i=1,4 do assert(math.abs(seen[i]-expected[i])<.002,string.format('%s channel%d %.6f expected %.6f',label,i,seen[i],expected[i])) end
end
local function graph(inputs,source)
 return {passes={{id='p',program='p',inputs=inputs,outputs={color='global_o0'},uniforms={}}},programs={p={glsl=source}},textures={},allocations={},renderSurface='o0'}
end
local function run()
 near(pixel(graph({},'uniform sampler2D extraTex;out vec4 fragColor;void main(){vec4 t=texture(extraTex,vec2(0.5));fragColor=vec4(t.r,t.g,t.b+0.25,1.0-t.a);}')),
  {0,0,.25,1},'pass without inputs')
 local data=love.image.newImageData(4,4);data:mapPixel(function()return 1,.5,.25,1 end)
 local image=love.graphics.newImage(data,{linear=true});data:release()
 near(pixel(graph({src='hostTex'},'uniform sampler2D src;uniform sampler2D extraTex;out vec4 fragColor;void main(){vec4 a=texture(src,vec2(0.5));vec4 b=texture(extraTex,vec2(0.5));fragColor=vec4(a.r,b.r+b.g+b.b,1.0-b.a,a.a);}'),{'hostTex',image}),
  {1,0,1,1},'unlisted sampler beside a bound input')
 image:release()
 print('UNBOUND-SAMPLER an unlisted sampler2D reads transparent black with and without bound inputs')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
