local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local renderer=require('noisemaker.runtime.renderer')
local executor=require('noisemaker.runtime.executor')
local function near(a,b) return math.abs(a-b)<.002 end
local function check(graph,w,h,samples,label)
 local r,diagnostics=renderer.new(graph,{width=w,height=h});assert(r,diagnostics and diagnostics[1].message)
 local out,errors=r:render{};assert(out,errors and errors[1].message)
 local data=out:newImageData()
 for _,sample in ipairs(samples) do
  local x,y,want=sample[1],sample[2],sample[3]
  local red,green,blue,alpha=data:getPixel(x,y)
  assert(near(red,want[1]) and near(green,want[2]) and near(blue,want[3]) and near(alpha,want[4]),string.format('%s %d,%d got %.4f %.4f %.4f %.4f',label,x,y,red,green,blue,alpha))
 end
 data:release();r:release()
end
local function run()
 local billboardVertex=[[out vec4 vColor;
void main(){
 int particle=gl_VertexID/6;int corner=gl_VertexID%6;
 vec2 uv=corner==0||corner==3||corner==5?vec2(0.0,corner==5?1.0:0.0):corner==1?vec2(1.0,0.0):vec2(1.0,1.0);
 vec2 center=particle==0?vec2(-0.5,0.0):vec2(0.5,0.0);
 gl_Position=vec4(center+(uv-0.5)*vec2(0.5,1.0),0,1);
 vColor=particle==0?vec4(1,0,0,.5):vec4(0,1,0,.75);
}]]
 local pixel='in vec4 vColor;out vec4 fragColor;void main(){fragColor=vColor;}'
 local bill={passes={{id='bill',program='bill',drawMode='billboards',count='input',inputs={xyzTex='state'},outputs={color='global_o0'},uniforms={}}},programs={bill={vertex=billboardVertex,fragment=pixel}},textures={state={width=2,height=1,format='rgba16f'}},allocations={},renderSurface='o0'}
 check(bill,16,8,{{4,4,{1,0,0,.5}},{12,4,{0,1,0,.75}}},'billboards')
 local triangleVertex=[[out vec4 vColor;
void main(){
 int triangle=gl_VertexID/3;int corner=gl_VertexID%3;
 vec2 p=corner==0?vec2(-.75,-.75):corner==1?vec2(.75,-.75):vec2(0,.75);
 gl_Position=vec4(p,triangle==0?.2:.5,1);
 vColor=triangle==0?vec4(1,0,0,.6):vec4(0,1,0,.8);
}]]
 local tri={passes={{id='tri',program='tri',drawMode='triangles',count=6,inputs={},outputs={color='global_o0'},uniforms={}}},programs={tri={vertex=triangleVertex,fragment=pixel}},textures={},allocations={},renderSurface='o0'}
 check(tri,17,9,{{8,4,{1,0,0,.6}}},'depth triangles')
 local state=love.graphics.newCanvas(2,1)
 local fallback=love.graphics.newCanvas(1,1)
 local attachment=love.graphics.newCanvas(5,3)
 local fake={width=16,height=8,resources={textures={state=state}},uploads={},external={},_input=function(self,id) return self.resources.textures[id] or fallback end}
 local count=executor.resolveCount
 assert(count(fake,{count='input',inputs={xyzTex='missing'}},{},{},{},attachment,'points')==128,'Missing point input must use drawing-buffer dimensions')
 assert(count(fake,{count='input',inputs={xyzTex='state'}},{},{},{},attachment,'points')==2,'Point input must use actual texture dimensions')
 assert(count(fake,{count='input',inputs={inputTex='state'}},{},{},{},attachment,'billboards')==15,'Billboards without xyzTex use output dimensions')
 assert(count(fake,{count='input',inputs={meshPositions='missing'}},{},{},{},attachment,'triangles')==3,'Missing triangle input must fall back to one triangle')
 assert(count(fake,{count=2,countUniform='override',inputs={}},{override=7},{},{},attachment,'points')==2,'countUniform applies to triangles only')
 assert(not pcall(count,fake,{count=math.huge},{},{},{},attachment,'points'),'Infinite draw count must fail before allocation')
 assert(not pcall(count,fake,{count=3,countUniform='override'},{override=math.huge},{},{},attachment,'triangles'),'Infinite countUniform must fail before allocation')
 state:release();fallback:release();attachment:release()
 local pointVertex=[[out vec4 vColor;
 void main(){int id=gl_VertexID;gl_Position=vec4(id==0?-.5:.5,0,0,1);vColor=id==0?vec4(1,0,0,1):vec4(0,1,0,1);}]]
 local nm=require('noisemaker')
 local portable={name='Point No Size',namespace='user',func='pointNoSize',globals={},
  passes={{name='main',program='point',drawMode='points',count=2,inputs={},outputs={fragColor='outputTex'}}},
  shaders={point={vertex=pointVertex,fragment=pixel}}}
 local registered,registrationError=nm.registerEffect(portable);assert(registered,registrationError and registrationError[1].message)
 local pointGraph,compileError=nm.compile('search user\npointNoSize().write(o0)\nrender(o0)\n')
 assert(pointGraph,require('noisemaker.json').encode(compileError))
 local oldPointSize=love.graphics.getPointSize()
 love.graphics.setPointSize(7)
 local pointRenderer,pointError=renderer.new(pointGraph,{width=16,height=8});assert(pointRenderer,pointError and pointError[1].message)
 local pointOutput,pointRenderError=pointRenderer:render{};assert(pointOutput,pointRenderError and pointRenderError[1].message)
 local pointData=pointOutput:newImageData();local red,green=0,0
 for y=0,7 do for x=0,15 do local r,g=pointData:getPixel(x,y);if r>.5 then red=red+1 end;if g>.5 then green=green+1 end end end
 assert(red==1 and green==1,'A point shader without gl_PointSize must draw exactly one pixel per vertex despite host point size')
 assert(love.graphics.getPointSize()==7,'Renderer must restore host point size')
 love.graphics.setPointSize(oldPointSize)
 pointData:release();pointRenderer:release()
 local edgeVertex=[[
 void main(){
  int id=gl_VertexID;
  vec2 p=id==0?vec2(0.32676589488983154,0.674048662185669):vec2(0.32493460178375244,0.674433708190918);
  gl_Position=vec4(p*2.0-1.0,0.0,1.0);
  gl_PointSize=1.0;
 }]]
 local edge={passes={{id='edge',program='edge',drawMode='points',count=2,inputs={},outputs={color='global_o0'},uniforms={},blend=true}},
  programs={edge={vertex=edgeVertex,fragment='out vec4 fragColor;void main(){fragColor=vec4(.25,0,0,.25);}'}},textures={},allocations={},renderSurface='o0'}
 check(edge,257,129,{{83,41,{.25,0,0,.25}},{83,42,{.25,0,0,.25}},{84,42,{0,0,0,0}}},'one-pixel point boundary')
 print('GEOMETRY-PIXELS source draw counts, Portable points, billboards and depth-tested triangles')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
