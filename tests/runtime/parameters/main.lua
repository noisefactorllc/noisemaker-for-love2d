local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
function love.load()
 local ok,err=xpcall(function()
  local nm=require('noisemaker')
  assert(nm.registerEffect{name='Live variant',namespace='user',func='liveVariant',globals={mode={type='int',default=0,define='MODE',min=0,max=2}},passes={{program='main',inputs={},outputs={color='outputTex'}}},shaders={main={glsl=[[#version 300 es
precision highp float;
out vec4 fragColor;
void main(){
#if MODE == 0
fragColor=vec4(1,0,0,1);
#elif MODE == 1
fragColor=vec4(0,0,1,1);
#else
invalid_shader_source
#endif
}
]]}}})
  local graph=assert(nm.compile('search user\nliveVariant().write(o0)\nrender(o0)'))
  local renderer=assert(nm.newRenderer(graph,{width=7,height=5}))
  local first=assert(renderer:render{}):newImageData();assert(first:getPixel(0,0)>.9);first:release()
  assert(renderer:setParameter(0,'mode',1))
  local next=assert(renderer:render{}):newImageData();assert(select(3,next:getPixel(0,0))>.9);next:release()
  local changed,diagnostics=renderer:setParameter(0,'mode',2);assert(not changed and diagnostics[1].stage=='shader')
  local retained=assert(renderer:render{}):newImageData();assert(select(3,retained:getPixel(0,0))>.9);retained:release()
  assert(not renderer:setParameter(nil,nil,1));renderer:release()
  local mixedGraph=assert(nm.compile('search user, filter\nliveVariant().fibers().write(o0)\nrender(o0)'))
  local mixed=assert(nm.newRenderer(mixedGraph,{width=8,height=8}))
  assert(mixed:setParameter(1,'density',.75))
  local manager=mixed.inputManager
  local state=mixed.resources.surfaces.o0.read
  love.graphics.setCanvas(state);love.graphics.clear(.25,.5,.75,1);love.graphics.setCanvas()
  assert(mixed:setParameter(0,'mode',1))
  assert(mixed.hooks.nodes.node_1.params.density==.75,'Define update lost overlay parameter')
  assert(mixed.inputManager==manager and mixed.resources.surfaces.o0.read==state,'Define update lost runtime state')
  local preserved=state:newImageData();assert(math.abs(preserved:getPixel(0,0)-.25)<.002);preserved:release()
  local bad,badDiags=mixed:setParameter(1,'alpha',{bad=1});assert(not bad and badDiags[1].code=='ERR_UNIFORM_VALUE')
  local oldHooks,oldDensity,oldUpload=mixed.hooks,mixed.graph.passes[2].uniforms.density,mixed.uploads.node_1_overlayTex.texture
  local upload=mixed._upload;mixed._upload=function()error('injected overlay upload failure')end
  local accepted,rejected=mixed:setParameter(1,'density',.2);mixed._upload=upload
  assert(not accepted and rejected[1].stage=='parameter')
  assert(mixed.hooks==oldHooks and mixed.graph.passes[2].uniforms.density==oldDensity and mixed.uploads.node_1_overlayTex.texture==oldUpload,'Rejected hook update changed active state')
  assert(mixed:render{});mixed:release()
  local paletteGraph={passes={{id='palette',program='palette',inputs={},outputs={color='global_o0'},uniforms={palette=1},stepIndex=0}},programs={palette={glsl='uniform float palette;out vec4 fragColor;void main(){fragColor=vec4(palette/10.0,0.0,0.0,1.0);}'}},textures={},renderSurface='o0'}
  local paletteRenderer=assert(nm.newRenderer(paletteGraph,{width=2,height=2}))
  local returned,paletteChanged,paletteErrors=pcall(paletteRenderer.setParameter,paletteRenderer,0,'palette',1.5)
  assert(returned and not paletteChanged and paletteErrors[1].code=='ERR_UNIFORM_VALUE','Invalid palette must return a diagnostic without throwing')
  assert(paletteRenderer.graph.passes[1].uniforms.palette==1 and paletteRenderer.uniforms.palette==1,'Invalid palette partially changed active state')
  local oldPalette=assert(paletteRenderer:render{}):newImageData();assert(math.abs(oldPalette:getPixel(0,0)-.1)<.003);oldPalette:release()
  assert(paletteRenderer:setParameter(0,'palette',2))
  local newPalette=assert(paletteRenderer:render{}):newImageData();assert(math.abs(newPalette:getPixel(0,0)-.2)<.003);newPalette:release();paletteRenderer:release()
  local temporal=assert(nm.newRenderer({passes={{id='clock',program='clock',inputs={},outputs={color='global_o0'},uniforms={}}},programs={clock={glsl='uniform float frame;uniform float deltaTime;out vec4 fragColor;void main(){fragColor=vec4(frame/10.0,deltaTime,0.0,1.0);}'}},textures={},renderSurface='o0'},{width=7,height=5}))
  assert(temporal:render{time=1});assert(temporal:render{time=2});assert(temporal:resize(9,7))
  local clock=assert(temporal:render{time=3}):newImageData();local frame,delta=clock:getPixel(0,0)
  assert(math.abs(frame-.2)<.002 and math.abs(delta-1)<.002,'Resize must preserve temporal counters');clock:release()
  assert(temporal:reset());local reset=assert(temporal:render{time=4}):newImageData();local f,d=reset:getPixel(0,0);assert(f==0 and d==0);reset:release();temporal:release()
  print('define-backed parameters compile transactionally and preserve working shader on failure')
 end,debug.traceback)
 love.graphics.setCanvas();if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)
end
