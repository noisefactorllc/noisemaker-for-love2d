local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local nm=require('noisemaker')
local viewer=require('examples.viewer.session')
local json=require('noisemaker.json')
local resources=require('noisemaker.runtime.resources')
local source='search synth\nsolid(color: #ff9933).write(o0)\nrender(o0)'
local function read(path)
  local file=assert(io.open(root..'/'..path,'rb'))
  local content=file:read('*a');file:close();return content
end
local function check()
  local session=viewer.new(23,17)
  local canvas,diagnostics=session:replace(source,{time=0})
  assert(canvas,diagnostics and diagnostics[1] and diagnostics[1].message)
  local stable=session.renderer
  local invalid,errors=session:replace('search synth\nmissing().write(o0)\nrender(o0)')
  assert(not invalid and errors and session.renderer==stable and session.canvas==canvas)
  local definition=json.decode(read('parity/portable/portableRings.portable.json'))
  definition.shaders={rings={glsl='invalid shader source'}}
  local registered,registrationErrors=nm.registerEffect(definition)
  assert(registered,registrationErrors and registrationErrors[1] and registrationErrors[1].message)
  local shaderFailure,shaderErrors=session:replace(read('parity/portable/portableRings.dsl'))
  assert(not shaderFailure and shaderErrors and session.renderer==stable and session.canvas==canvas)
  local continued=session:render({time=1})
  assert(continued and continued:getWidth()==23 and continued:getHeight()==17)
  definition.shaders={rings={glsl=read('noisemaker/shaders/portable/rings.glsl')}}
  assert(nm.registerEffect(definition))
  local portableCanvas,portableErrors=session:replace(read('parity/portable/portableRings.dsl'),{time=1})
  assert(portableCanvas,portableErrors and portableErrors[1] and portableErrors[1].message)
  assert(session.renderer~=stable and stable.released)
  assert(session:resize(19,13))
  assert(session:render({time=2}))
  session:release()
  local dimensionGraph=assert(nm.compile(source))
  dimensionGraph.textures.node_0_out.width={screenDivide='zoom_chain_0',default=2}
  dimensionGraph.passes[1].uniforms.zoom_chain_0=2
  dimensionGraph.passes[1].scopedParams={zoom='zoom_chain_0'}
  local sized=assert(nm.newRenderer(dimensionGraph,{width=23,height=17}))
  assert(sized.resources.textures.node_0_out:getWidth()==12)
  assert(sized:setParameter(0,'zoom',4))
  assert(sized.resources.textures.node_0_out:getWidth()==6)
  sized:release()
  local scopedProgram={glsl='#version 300 es\nprecision highp float; in vec2 v_texCoord; out vec4 fragColor; void main(){fragColor=vec4(v_texCoord,0.0,1.0);}'}
  local scopedGraph={passes={
    {id='chain0',program='solid',inputs={},outputs={color='tex0'},uniforms={zoom=2,zoom_chain_0=2},scopedParams={zoom='zoom_chain_0'},stepIndex=0},
    {id='chain1',program='solid',inputs={},outputs={color='tex1'},uniforms={zoom=2,zoom_chain_1=2},scopedParams={zoom='zoom_chain_1'},stepIndex=1},
    {id='output',program='copy',inputs={src='tex0'},outputs={color='global_o0'},uniforms={}},
  },programs={solid=scopedProgram,copy={glsl='#version 300 es\nprecision highp float; in vec2 v_texCoord; uniform sampler2D src; out vec4 fragColor; void main(){fragColor=texture(src,v_texCoord);}'}},textures={
    tex0={width={screenDivide='zoom_chain_0',default=2},height='screen',format='rgba8'},
    tex1={width={screenDivide='zoom_chain_1',default=2},height='screen',format='rgba8'},
  },renderSurface='o0',allocations={}}
  local scoped=assert(nm.newRenderer(scopedGraph,{width=23,height=17}))
  assert(scoped.resources.textures.tex0:getWidth()==12 and scoped.resources.textures.tex1:getWidth()==12)
  assert(scoped:setParameter(0,'zoom',4))
  assert(scoped.resources.textures.tex0:getWidth()==6 and scoped.resources.textures.tex1:getWidth()==12)
  assert(scoped.graph.passes[2].uniforms.zoom_chain_1==2)
  scoped:release()
  local mediaGraph={passes={{id='media',program='solid',effectKey='synth.media',inputs={asset='mediaTex'},outputs={color='global_o0'},uniforms={}}},
    programs={solid={glsl='uniform vec2 imageSize;out vec4 fragColor;void main(){fragColor=vec4(imageSize/100.0,0.0,1.0);}'}},textures={},renderSurface='o0',allocations={}}
  local media=assert(nm.newRenderer(mediaGraph,{width=23,height=17}))
  local supplied=love.graphics.newCanvas(11,7)
  assert(media:setInput('mediaTex',supplied))
  assert(media.hooks.mediaWidth==11 and media.hooks.mediaHeight==7)
  local mediaPixels=assert(media:render{}):newImageData()
  local mediaWidth,mediaHeight=mediaPixels:getPixel(0,0)
  assert(math.abs(mediaWidth-.11)<.002 and math.abs(mediaHeight-.07)<.002,'Bound dimensions must reach pass uniforms')
  mediaPixels:release()
  assert(media:resize(31,29))
  assert(media.hooks.mediaWidth==11 and media.hooks.mediaHeight==7)
  assert(media:setInput('mediaTex',nil))
  assert(media.hooks.mediaWidth==1 and media.hooks.mediaHeight==1)
  media:release();supplied:release()
  local inputGraph={passes={{id='copy-input',program='copy',inputs={src='asset'},outputs={color='global_o0'},uniforms={}}},
    programs={copy={glsl='#version 300 es\nprecision highp float; in vec2 v_texCoord; uniform sampler2D src; out vec4 fragColor; void main(){fragColor=texture(src,v_texCoord);}'}},textures={},renderSurface='o0',allocations={}}
  local inputRenderer=assert(nm.newRenderer(inputGraph,{width=2,height=2}))
  local imageData=love.image.newImageData(2,2)
  for x=0,1 do imageData:setPixel(x,0,1,0,0,1);imageData:setPixel(x,1,0,0,1,1) end
  local image=love.graphics.newImage(imageData);imageData:release()
  local host=love.graphics.newCanvas(3,3)
  love.graphics.setCanvas(host);love.graphics.setColor(.2,.3,.4,.5)
  assert(inputRenderer:setInput('asset',image))
  assert(love.graphics.getCanvas()==host and math.abs(love.graphics.getColor()-.2)<.001)
  love.graphics.setCanvas()
  assert(inputRenderer.external.asset~=image)
  local oriented=assert(inputRenderer:render({time=0})):newImageData()
  local topR,_,topB=oriented:getPixel(0,0)
  local bottomR,_,bottomB=oriented:getPixel(0,1)
  assert(topR>.9 and topB<.1 and bottomB>.9 and bottomR<.1)
  oriented:release()
  local dynamic=love.graphics.newCanvas(2,2,{format='rgba8'})
  love.graphics.setCanvas(dynamic);love.graphics.clear(0,1,0,1);love.graphics.setCanvas()
  assert(inputRenderer:setInput('asset',dynamic))
  assert(inputRenderer:render({time=1}))
  love.graphics.setCanvas(dynamic);love.graphics.clear(1,1,0,1);love.graphics.setCanvas()
  local changed=assert(inputRenderer:render({time=2})):newImageData()
  local changedR,changedG,changedB=changed:getPixel(0,0)
  assert(changedR>.9 and changedG>.9 and changedB<.1)
  changed:release()
  local invalidOrigin,originDiagnostics=inputRenderer:setInput('asset',image,{origin='sideways'})
  assert(not invalidOrigin and originDiagnostics and inputRenderer.externalSources.asset.texture==dynamic)
  assert(inputRenderer:setInput('asset',image,{origin='bottom-left'}))
  assert(inputRenderer.external.asset==image and not inputRenderer.externalSources.asset.converted)
  assert(inputRenderer:setInput('asset',nil))
  inputRenderer:release()
  assert(image:getWidth()==2 and dynamic:getWidth()==2)
  image:release();dynamic:release();host:release()
  local persistentGraph=assert(nm.compile(source))
  persistentGraph.textures.global_o0={width='screen',height='screen',format='rgba8',persistent=true,mipmaps=true}
  local persistent=assert(nm.newRenderer(persistentGraph,{width=23,height=17}))
  local oldRead=persistent.resources.surfaces.o0.read
  love.graphics.setCanvas(oldRead);love.graphics.clear(.25,.5,.75,1);love.graphics.setCanvas()
  assert(persistent:resize(23,17))
  assert(persistent.resources.surfaces.o0.read==oldRead)
  assert(persistent:resize(31,29))
  local resizedRead=persistent.resources.surfaces.o0.read
  assert(resizedRead~=oldRead and resizedRead:getWidth()==31)
  local pixels=resizedRead:newImageData()
  local red,green,blue=pixels:getPixel(15,14)
  assert(math.abs(red-.25)<.03 and math.abs(green-.5)<.03 and math.abs(blue-.75)<.03)
  pixels:release()
  assert(persistent:render({time=0}))
  assert(persistent:reset())
  persistent:release()
  local volumeGraph={passes={},textures={volume={width=4,height=4,depth=3,is3D=true,format='rgba8'}},renderSurface=nil}
  local volumeResources=resources.allocate(volumeGraph,4,4,{},nil)
  assert(volumeResources.textures.volume:getDepth()==3)
  resources.release(volumeResources)
  local feedbackGraph={
    passes={
      {id='feedback',program='advance',inputs={src='global_ca_state'},outputs={color='global_ca_state'},uniforms={},['repeat']=3},
      {id='present',program='copy',inputs={src='global_ca_state'},outputs={color='global_o0'},uniforms={}},
    },
    programs={
      advance={glsl='#version 300 es\nprecision highp float; in vec2 v_texCoord; uniform sampler2D src; out vec4 fragColor; void main(){fragColor=texture(src,v_texCoord)+vec4(0.1,0.0,0.0,0.0);}'},
      copy={glsl='#version 300 es\nprecision highp float; in vec2 v_texCoord; uniform sampler2D src; out vec4 fragColor; void main(){fragColor=texture(src,v_texCoord);}'},
    },
    textures={global_ca_state={width=4,height=4,format='rgba16f'}},renderSurface='o0',allocations={}
  }
  local feedback=assert(nm.newRenderer(feedbackGraph,{width=4,height=4}))
  for frame,expected in ipairs({.3,.6}) do
    local output,renderErrors=feedback:render({time=frame/60})
    assert(output,renderErrors and renderErrors[1] and renderErrors[1].message)
    local data=output:newImageData()
    local red=data:getPixel(0,0)
    assert(math.abs(red-expected)<.025,tostring(red)..' ~= '..expected)
    data:release()
  end
  assert(feedback:reset())
  local cleared=assert(feedback:render({time=0}))
  local clearedPixels=cleared:newImageData()
  assert(math.abs(clearedPixels:getPixel(0,0)-.3)<.025)
  clearedPixels:release()
  feedback:release()
  local lifecycleBaseline,luaBaseline
  for i=1,100 do
    local graph,compileErrors=nm.compile(source)
    assert(graph,compileErrors and compileErrors[1] and compileErrors[1].message)
    local renderer,prepareErrors=nm.newRenderer(graph,{width=23,height=17})
    assert(renderer,prepareErrors and prepareErrors[1] and prepareErrors[1].message)
    local frame,renderErrors=renderer:render({time=i/60})
    assert(frame,renderErrors and renderErrors[1] and renderErrors[1].message)
    assert(frame:getWidth()==23 and frame:getHeight()==17)
    assert(renderer:resize(19,13))
    assert(renderer:render({time=i/60+1}))
    assert(renderer:reset())
    renderer:release()
    assert(not renderer:render({time=0}))
    collectgarbage('collect')
    local stats=love.graphics.getStats()
    if i==8 then lifecycleBaseline=stats;luaBaseline=collectgarbage('count') end
    if i>8 then
      for _,kind in ipairs({'canvases','images','shaders'}) do assert(stats[kind]==lifecycleBaseline[kind],'Leaked '..kind..' in lifecycle cycle '..i) end
      assert(stats.texturememory<=lifecycleBaseline.texturememory,'Texture memory grew after warm-up')
      assert(collectgarbage('count')<=luaBaseline+1024,'Lua memory exceeded 1 MiB growth bound after warm-up')
    end
  end
  print('clean consumer GPU hot replacement and 100 lifecycle cycles passed; GPU object counts and texture bytes returned to baseline, Lua growth below 1 MiB')
end
function love.load()
  local ok,errorMessage=xpcall(check,debug.traceback)
  if not ok then io.stderr:write(tostring(errorMessage)..'\n') end
  love.event.quit(ok and 0 or 1)
end
