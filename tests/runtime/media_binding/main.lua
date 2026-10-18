local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local nm=require('noisemaker')
-- README: "The media() effect uses the external binding imageTex: renderer:setInput('imageTex', hostTexture)".
-- The compiled media() step samples the step-scoped id imageTex_step_<N>; both bindings must reach it.
local program='search synth\nmedia().write(o0)\nrender(o0)\n'
local function asymmetric(w,h,tint)
 local data=love.image.newImageData(w,h)
 data:mapPixel(function(x,y)return x/(w-1),y/(h-1),tint,(x<4 and y<3) and 1 or .75 end)
 local image=love.graphics.newImage(data,{linear=true});data:release();return image
end
local function capture(bindings)
 local graph=assert(nm.compile(program))
 local renderer=assert(nm.newRenderer(graph,{width=31,height=23}))
 for _,binding in ipairs(bindings) do assert(renderer:setInput(binding[1],binding[2])) end
 local frame,errors=renderer:render{time=0};assert(frame,errors and errors[1].message)
 local pixels=frame:newImageData();local bytes=pixels:getString();pixels:release()
 return bytes,renderer,graph
end
local function run()
 local image,other=asymmetric(17,13,.25),asymmetric(17,13,.9)
 local none,noneRenderer,graph=capture({})
 assert(graph.mediaSteps and graph.mediaSteps[1] and graph.mediaSteps[1].textureId=='imageTex_step_0','media() step id is not imageTex_step_0')
 noneRenderer:release()
 local stepBound,stepRenderer=capture({{'imageTex_step_0',image}});stepRenderer:release()
 assert(stepBound~=none,'binding imageTex_step_0 did not change the output')
 local named,renderer=capture({{'imageTex',image}})
 assert(named==stepBound,'setInput(imageTex) output differs from setInput(imageTex_step_0) output')
 assert(named~=none,'setInput(imageTex) output equals the no-input output')
 assert(renderer:setInput('imageTex',nil))
 local frame=assert(renderer:render{time=0});local pixels=frame:newImageData();local cleared=pixels:getString();pixels:release()
 assert(cleared==none,'setInput(imageTex, nil) did not restore the no-input output')
 renderer:release()
 local otherStep,otherRenderer=capture({{'imageTex_step_0',other}});otherRenderer:release()
 local both,bothRenderer=capture({{'imageTex',image},{'imageTex_step_0',other}});bothRenderer:release()
 assert(both==otherStep and both~=stepBound,'an exact step binding must take precedence over imageTex')
 image:release();other:release()
 print('MEDIA-BINDING GPU setInput(imageTex) reaches the compiled media() step, clears, and yields to an exact step binding')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
