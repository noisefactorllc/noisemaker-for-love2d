local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local adapter=require('noisemaker.shaders.adapter')
local function run()
 local pixel='in vec4 vColor; out vec4 fragColor; void main(){fragColor=vColor;}'
 local vertex=[[out vec4 vColor;
void main(){
 int particle=gl_VertexID/6;
 int corner=gl_VertexID%6;
 vec2 uv=corner==0||corner==3||corner==5?vec2(0.0,corner==5?1.0:0.0):
         corner==1?vec2(1.0,0.0):vec2(1.0,1.0);
 vec2 center=particle==0?vec2(-0.5,0.0):vec2(0.5,0.0);
 gl_Position=vec4(center+(uv-0.5)*vec2(0.5,1.0),0.0,1.0);
 vColor=particle==0?vec4(1.0,0.0,0.0,0.5):vec4(0.0,1.0,0.0,0.75);
}]]
 local a=assert(adapter.adapt{pixel=pixel,vertex=vertex,drawMode='billboards'})
 local shader=love.graphics.newShader(a.pixel,a.vertex)
 local mesh=love.graphics.newMesh({{0,0,0,0},{0,0,0,0},{0,0,0,0},{0,0,0,0},{0,0,0,0},{0,0,0,0}},'triangles','static')
 local canvas=love.graphics.newCanvas(16,8,{format='rgba16f',dpiscale=1})
 love.graphics.push('all');love.graphics.setCanvas(canvas);love.graphics.clear(0,0,0,0)
 love.graphics.setBlendMode('replace','premultiplied');love.graphics.setColor(1,1,1,1)
 love.graphics.setShader(shader);love.graphics.drawInstanced(mesh,2);love.graphics.pop()
 local data=canvas:newImageData()
 local function near(a,b) return math.abs(a-b)<0.002 end
 local lr,lg,lb,la=data:getPixel(4,4)
 local rr,rg,rb,ra=data:getPixel(12,4)
 assert(near(lr,1) and near(lg,0) and near(la,.5),string.format('left %.4f %.4f %.4f %.4f',lr,lg,lb,la))
 assert(near(rr,0) and near(rg,1) and near(ra,.75),string.format('right %.4f %.4f %.4f %.4f',rr,rg,rb,ra))
 print('BILLBOARD-INDEX two instanced quads address particles 0 and 1 with preserved RGBA')
 data:release();canvas:release();mesh:release();shader:release()
end
function love.load() local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n') end;love.event.quit(ok and 0 or 1) end
