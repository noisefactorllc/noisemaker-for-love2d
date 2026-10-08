local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local nm=require('noisemaker')
local renderer=require('noisemaker.runtime.renderer')
local function source(w,h)
 local data=love.image.newImageData(w,h)
 data:mapPixel(function()return 1,1,1,1 end)
 local image=love.graphics.newImage(data,{linear=true});data:release();return image
end
local function checkSize(instance,x,y)
 local size=instance.graph.passes[1].uniforms.imageSize
 assert(size[1]==x and size[2]==y,'Authored imageSize was overwritten by texture binding')
 local frame,errors=instance:render{};assert(frame,errors and errors[1].message)
 local pixels=frame:newImageData();local red,green=pixels:getPixel(3,3);pixels:release()
 assert(math.abs(red-x/1024)<.01 and math.abs(green-y/1024)<.01,
  string.format('GPU imageSize %.4f %.4f, wanted %d,%d',red,green,x,y))
end
local function run()
 local graph={passes={{id='media',program='size',effectKey='synth/media',inputs={imageTex='imageTex'},outputs={fragColor='global_o0'},uniforms={imageSize={64,32}}}},
  programs={size={glsl='uniform vec2 imageSize;out vec4 fragColor;void main(){fragColor=vec4(imageSize/1024.0,0.0,1.0);}'}},
  textures={},allocations={},renderSurface='o0'}
 local instance,diagnostics=renderer.new(graph,{width=8,height=8});assert(instance,diagnostics and diagnostics[1].message)
 local first,second=source(17,13),source(31,7)
 checkSize(instance,64,32)
 assert(instance:setInput('imageTex',first,{origin='bottom-left'}));checkSize(instance,64,32)
 assert(instance:setInput('imageTex',second,{origin='bottom-left'}));checkSize(instance,64,32)
 assert(instance:setInput('imageTex',nil));checkSize(instance,64,32)
 assert(instance:release());first:release();second:release()
 local compiled,compileErrors=nm.compile('search synth\nmedia().write(o0)\nrender(o0)\n')
 assert(compiled,require('noisemaker.json').encode(compileErrors))
 local default,defaultError=renderer.new(compiled,{width=8,height=8});assert(default,defaultError and defaultError[1].message)
 local pass
 for _,item in ipairs(default.graph.passes) do if item.effectKey=='synth/media' or item.effectKey=='synth.media' then pass=item;break end end
 assert(pass and pass.uniforms.imageSize[1]==1024 and pass.uniforms.imageSize[2]==1024,'Catalog default imageSize changed')
 local image=source(17,13)
 assert(default:setInput('imageTex',image,{origin='bottom-left'}))
 assert(pass.uniforms.imageSize[1]==1024 and pass.uniforms.imageSize[2]==1024,'Default imageSize must preserve authored priority')
 assert(default:render{})
 assert(default:setInput('imageTex',nil))
 assert(pass.uniforms.imageSize[1]==1024 and pass.uniforms.imageSize[2]==1024,'Clearing input must preserve default imageSize')
 assert(default:release());image:release()
 print('MEDIA-SIZE GPU authored and catalog imageSize survive input binding, rebinding and clearing')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
