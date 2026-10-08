local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
function love.load()
 local ok,err=xpcall(function()
  local nm=require('noisemaker');local g=love.graphics
  local cyclic={};cyclic.self=cyclic
  for _,bad in ipairs({cyclic,{passes={1},programs={}},{['$type']='invalid'}}) do local result,diags=nm.newRenderer(bad,{width=5,height=3});assert(not result and diags[1].stage=='graph') end
  assert(not nm.newRenderer({},42))
  local renderer=assert(nm.newRenderer(assert(nm.compile('search synth\nsolid().write(o0)\nrender(o0)')),{width=5,height=3}))
  local originalImage,originalCanvas=g.newImage,g.newCanvas;local captured
  g.newImage=function(...)captured=originalImage(...);return captured end
  g.newCanvas=function()error('injected canvas failure')end
  local success=pcall(renderer._upload,renderer,'failure',string.rep(string.char(255),16),2,2,'rgba8',true,{})
  g.newImage,g.newCanvas=originalImage,originalCanvas
  assert(not success and captured)
  assert(not pcall(captured.getWidth,captured),'Upload must release Image when Canvas allocation fails')
  local dead=g.newCanvas(2,2);dead:release()
  for _,origin in ipairs({'top-left','bottom-left'}) do
   local called,value,diagnostics=pcall(renderer.setInput,renderer,'imageTex',dead,{origin=origin})
   assert(called and not value and diagnostics[1].code=='ERR_INPUT_RELEASED','Released inputs must return a diagnostic without mutation')
   assert(not renderer.external.imageTex and not renderer.externalSources.imageTex)
  end
  local source=g.newCanvas(2,2)
  assert(renderer:setInput('imageTex',source,{origin='bottom-left'}))
  local oldDraw=g.draw;local pending
  g.newCanvas=function(...)pending=originalCanvas(...);return pending end
  g.draw=function()error('injected input conversion failure')end
  local bound,inputErrors=renderer:setInput('imageTex',source)
  g.draw,g.newCanvas=oldDraw,originalCanvas
  assert(not bound and inputErrors[1].stage=='input')
  assert(renderer.external.imageTex==source and renderer.externalSources.imageTex.texture==source)
  assert(pending and not pcall(pending.getWidth,pending),'Failed input conversion leaked Canvas')
  assert(renderer:setInput('imageTex',nil));source:release()
  local output=assert(renderer:render{})
  g.setCanvas(output)
  local resized,resizeErrors=renderer:resize(7,5)
  assert(not resized and resizeErrors[1].code=='ERR_RESOURCE_IN_USE' and renderer.width==5 and g.getCanvas()==output)
  local released,releaseErrors=renderer:release();assert(not released and releaseErrors[1].code=='ERR_RESOURCE_IN_USE' and not renderer.released)
  g.setCanvas()
  local host=g.newCanvas(2,2);g.setCanvas(host);g.setColor(.2,.3,.4,.5)
  local copied,diagnostics=renderer:copyTo(output)
  assert(not copied and diagnostics[1].code=='ERR_COPY_TARGET')
  assert(g.getCanvas()==host and math.abs(g.getColor()-.2)<.001)
  g.setCanvas();host:release();renderer:release()
  print('failure cleanup and copy alias regression passed')
 end,debug.traceback)
 love.graphics.setCanvas();if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)
end
