local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local nm=require('noisemaker')
local function must(value,err) assert(value,err and err[1] and err[1].message);return value end
local function run()
 local vertex=[[out vec4 shade;
 void main(){int tri=gl_VertexID/3;int corner=gl_VertexID%3;
 vec2 p=corner==0?vec2(-.4,-.75):corner==1?vec2(.4,-.75):vec2(0,.75);
 p.x+=tri==0?-.5:.5;gl_Position=vec4(p,0,1);shade=tri==0?vec4(1,0,0,1):vec4(0,1,0,1);}
 ]]
 must(nm.registerEffect({name='Mesh Cache',namespace='user',func='meshCache',
  globals={vertices={type='int',default=3,min=3,max=192,uniform='vertices'}},
  passes={{name='main',program='mesh',drawMode='triangles',count=3,countUniform='vertices',
    uniforms={vertices='vertices'},inputs={},outputs={fragColor='outputTex'}}},
  shaders={mesh={vertex=vertex,fragment='in vec4 shade;out vec4 fragColor;void main(){fragColor=shade;}'}}}))
 local graph=must(nm.compile('search user\nmeshCache().write(o0)\nrender(o0)'))
 local r=must(nm.newRenderer(graph,{width=32,height=16}))
 local function draw(count)
  must(r:setParameter(0,'vertices',count));must(r:reset())
  local frame=must(r:render{})
  local pixels=frame:newImageData()
  local red=pixels:getPixel(8,8);local _,green=pixels:getPixel(24,8)
  assert(red>.9 and (count==3 and green<.01 or count>3 and green>.9),string.format('Draw range count %d: red %.5f green %.5f',count,red,green))
  pixels:release()
 end
 draw(3);draw(6);draw(3)
 for count=9,192,3 do draw(count) end
 local highMesh
 local count=0;for key,mesh in pairs(r.meshes) do if key:sub(1,5)~='full:' then count=count+1;highMesh=mesh end end
 assert(count==1,'Animated geometry retained obsolete mesh buffers: '..count)
 local capacity=highMesh:getVertexCount()
 for i=1,20 do draw(i%2==0 and 3 or 6) end
 local cached=0;for key,mesh in pairs(r.meshes) do if key:sub(1,5)~='full:' then cached=cached+1;assert(mesh==highMesh,'Smaller draws should reuse the allocated mesh') end end
 assert(cached==1 and highMesh:getVertexCount()==capacity)
 local bill=r:_mesh(32,16,1,'billboards')
 assert(bill==r:_mesh(32,16,1000,'billboards'),'Instanced billboard corner mesh must be count-independent')
 local points=r:_mesh(32,16,1,'point_quads')
 assert(points==r:_mesh(32,16,1000,'point_quads'),'Instanced point corner mesh must be count-independent')
 must(r:release())
 for _,mesh in ipairs({highMesh,bill,points}) do assert(not pcall(mesh.getVertexCount,mesh),'Owned mesh survived renderer release') end
 print('MESH-CACHE animated vertex counts preserve pixels and reuse bounded buffers; instanced corners are shared')
end
function love.load() local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n') end;love.event.quit(ok and 0 or 1) end
