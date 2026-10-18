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
  -- A DSL parameter name resolves to its catalog uniform, as upstream applyStepParameterValues
  -- writes spec.uniform || paramName. Each renamed parameter is set by its DSL name on its
  -- effect's coverage default program.
  local registry=require('noisemaker.catalog.registry')
  local listed={'classicNoisedeck/cellNoise:smooth','classicNoisedeck/cellRefract:amount','classicNoisedeck/cellRefract:smooth',
   'classicNoisedeck/kaleido:sides','filter/celShading:mix','filter/chromaticAberration:aberration','filter/directionalBlur:distance',
   'filter/dither:type','filter/dither:mix','filter/edge:mix','filter/feedback:mix','filter/flipMirror:mode','filter/historicPalette:index',
   'filter/lens:displacement','filter/octaveWarp:freq','filter/oilPaint:texture','filter/outline:shape','filter/palette:index',
   'filter/polar:mode','filter/prismaticAberration:aberration','filter/scale:x','filter/scale:y','filter/skew:skew','filter/skew:rotate',
   'filter/smooth:type','filter/strokes:length','filter/vignette:brightness','filter3d/palette3d:index','mixer/patternMix:type',
   'render/meshRender:scale','synth/cell:shape','synth/gradient:type','synth/mandelbrot:centerX','synth/mandelbrot:centerY',
   'synth/newton:centerX','synth/newton:centerY','synth/osc2d:freq','synth/pattern:type','synth/polygon:smooth','synth/roll:color',
   'synth/scope:color','synth/scope:thickness','synth/spectrum:color','synth/spectrum:thickness','synth3d/cell3d:variation',
   'synth3d/flythrough3d:type','synth3d/fractal3d:type'}
  assert(#listed==47)
  local function same(a,b)
   if type(a)~='table' or type(b)~='table' then return a==b end
   if #a~=#b then return false end
   for i=1,#a do if a[i]~=b[i] then return false end end
   return true
  end
  local function nextValue(spec,current)
   if type(current)=='table' then local v={};for i,c in ipairs(current) do v[i]=c>.5 and .125 or .875 end;return v end
   local candidates={spec.max,spec.min,current+1,current-1}
   for i=1,4 do
    local candidate=candidates[i]
    if type(candidate)=='number' and candidate~=current then return candidate end
   end
  end
  local covered,renamedCount={},0
  local effectKeys={}
  for _,entry in ipairs(require('noisemaker.catalog.definitions').entries) do effectKeys[#effectKeys+1]=entry[1] end
  table.sort(effectKeys)
  assert(#effectKeys>=200,'catalog enumeration found '..#effectKeys..' effects')
  for _,effectKey in ipairs(effectKeys) do
   local definition=assert(registry.getEffect(effectKey),'no catalog definition for '..effectKey)
   local renamed={}
   for _,name in ipairs(registry.keys(definition.globals or {})) do
    local spec=definition.globals[name]
    if type(spec.uniform)=='string' and spec.uniform~=name and not spec.define and spec.type~='surface' and spec.type~='volume' and spec.type~='geometry' then renamed[#renamed+1]=name end
   end
   if #renamed>0 then
    local file=assert(io.open(root..'/parity/coverage/'..effectKey:gsub('/','_')..'.dsl','rb'),'missing coverage default for '..effectKey)
    local source=file:read('*a');file:close()
    local graph=assert(nm.compile(source))
    local instance=assert(nm.newRenderer(graph,{width=16,height=16}))
    local step
    for _,pass in ipairs(instance.graph.passes) do if pass.effectKey==effectKey or pass.effectKey==effectKey:gsub('/','.') then step=pass.stepIndex;break end end
    assert(step,'no compiled step for '..effectKey)
    for _,name in ipairs(renamed) do
     local spec=definition.globals[name]
     local current
     for _,pass in ipairs(instance.graph.passes) do if pass.stepIndex==step and pass.uniforms and pass.uniforms[spec.uniform]~=nil then current=pass.uniforms[spec.uniform];break end end
     assert(current~=nil,effectKey..' step holds no uniform '..spec.uniform)
     local value=nextValue(spec,current)
     local changed,errors=instance:setParameter(step,name,value)
     assert(changed==true,effectKey..' '..name..': '..tostring(errors and errors[1].message))
     local held=0
     for _,pass in ipairs(instance.graph.passes) do if pass.stepIndex==step and pass.uniforms and pass.uniforms[spec.uniform]~=nil then
      assert(same(pass.uniforms[spec.uniform],value),effectKey..' '..name..' did not reach uniform '..spec.uniform);held=held+1
     end end
     assert(held>0)
     covered[effectKey..':'..name]=true;renamedCount=renamedCount+1
    end
    local unknown,unknownErrors=instance:setParameter(step,'noSuchParameter',1)
    assert(not unknown and unknownErrors[1].code=='ERR_PARAMETER','Unknown names must still be refused')
    assert(instance:render{time=0});instance:release()
   end
  end
  for _,key in ipairs(listed) do assert(covered[key],'renamed parameter not covered: '..key) end
  local scaled=assert(nm.newRenderer(assert(nm.compile('search synth, filter\nnoise(seed: 1).scale(x: 2).write(o0)\nrender(o0)')),{width=8,height=8}))
  local scalePass;for _,pass in ipairs(scaled.graph.passes) do if pass.stepIndex==1 then scalePass=pass end end
  assert(scaled:setParameter(1,'scaleX',3) and scalePass.uniforms.scaleX==3,'Uniform names must keep working')
  scaled:release()
  print('DSL-NAME-PARAMETERS '..renamedCount..' renamed catalog parameters accept their DSL names; '..#listed..' listed parameters covered')
  print('define-backed parameters compile transactionally and preserve working shader on failure')
 end,debug.traceback)
 love.graphics.setCanvas();if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)
end
