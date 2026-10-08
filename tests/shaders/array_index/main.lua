local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local adapter=require('noisemaker.shaders.adapter')
local function contains(source,needle) assert(source:find(needle,1,true),'Expected shader lowering: '..needle) end
local function run()
 local structural=[[
  uniform sampler2D textures[2];
  float large(float values[9],int i){return values[i];}
  float small(float values[4],int i){return values[i];}
  float nested(int i,int j){float outer[3];float inner[2];return outer[inner[j]>0.0?i:j];}
  float samplerAccess(int i){return texture(textures[i],vec2(0.0)).r;}
  out vec4 fragColor;
  void main(){float values[3];values[0]=0.125;values[1]=0.5;values[2]=0.875;fragColor=vec4(values[1]);}
 ]]
 local adapted,diagnostic=adapter.adapt{pixel=structural,path='test/array-index'}
 assert(adapted,diagnostic and diagnostic.detail)
 contains(adapted.pixel,'values[int(clamp(nmArrayIndexValue(i), 0.0, 8.0))]')
 contains(adapted.pixel,'values[int(clamp(nmArrayIndexValue(i), 0.0, 3.0))]')
 contains(adapted.pixel,'inner[int(clamp(nmArrayIndexValue(j), 0.0, 1.0))]')
 contains(adapted.pixel,'outer[int(clamp(nmArrayIndexValue(inner[')
 contains(adapted.pixel,'values[1]')
 contains(adapted.pixel,'textures[2]')
 contains(adapted.pixel,'textures[i]')
 local sizedByMacro=assert(adapter.adapt{pixel=[[
  #define N 3
  uniform int lookup;out vec4 fragColor;
  void main(){float values[N];values[0]=0.125;values[1]=0.5;values[2]=0.875;fragColor=vec4(values[lookup]);}
 ]]})
 contains(sizedByMacro.pixel,'values[int(clamp(nmArrayIndexValue(lookup), 0.0, 2.0))]')
 local sizedByComment=assert(adapter.adapt{pixel=[[
  #define N 3 // size
  uniform int lookup;out vec4 fragColor;
  void main(){float values[N];values[0]=0.125;values[1]=0.5;values[2]=0.875;fragColor=vec4(values[lookup]);}
 ]]})
 contains(sizedByComment.pixel,'values[int(clamp(nmArrayIndexValue(lookup), 0.0, 2.0))]')
 local sizedByParens=assert(adapter.adapt{pixel=[[
  #define N (3)
  uniform int lookup;out vec4 fragColor;
  void main(){float values[N];values[0]=0.125;values[1]=0.5;values[2]=0.875;fragColor=vec4(values[lookup]);}
 ]]})
 contains(sizedByParens.pixel,'values[int(clamp(nmArrayIndexValue(lookup), 0.0, 2.0))]')
 local externallySized=assert(adapter.adapt{pixel='uniform int lookup;out vec4 fragColor;void main(){float values[N];fragColor=vec4(values[lookup]);}',defines={N=3}})
 contains(externallySized.pixel,'values[int(clamp(nmArrayIndexValue(lookup), 0.0, 2.0))]')
 local conditionalSize=assert(adapter.adapt{pixel=[[
  #if defined(USE_THREE)
  #define N 3
  #else
  #define N 4
  #endif
  uniform int lookup;out vec4 fragColor;void main(){float values[N];fragColor=vec4(values[lookup]);}
 ]]})
 assert(not conditionalSize.pixel:find('values[int(clamp(',1,true),'Conditional macro size must not be guessed')
 local scopes=[[
  #define FIXED 1
  uniform int lookup;
  float values[2];
  float multiple(int i){float a[3], b[4];return a[i]+b[i];}
  float constants(){const int fixed=1;return values[-1]+values[1+1]+values[fixed]+values[FIXED];}
  float shadow(){vec4 values=vec4(0.125,0.25,0.5,0.875);return values[lookup];}
  float boolShadow(){bvec3 values=bvec3(false,false,true);return values[lookup]?0.875:0.125;}
  float matrixShadow(){mat2x3 values=mat2x3(1.0);return values[lookup][0];}
  struct Choice{float x;};
  float structShadow(){Choice values[3];return values[lookup].x;}
  struct Holder{float values[5];};
  float field(Holder holder){return holder.values[lookup];}
  out vec4 fragColor;void main(){fragColor=vec4(shadow());}
 ]]
 local scoped,scopeDiagnostic=adapter.adapt{pixel=scopes,path='test/array-scopes'}
 assert(scoped,scopeDiagnostic and scopeDiagnostic.detail)
 contains(scoped.pixel,'a[int(clamp(nmArrayIndexValue(i), 0.0, 2.0))]')
 contains(scoped.pixel,'b[int(clamp(nmArrayIndexValue(i), 0.0, 3.0))]')
 contains(scoped.pixel,'values[-1]')
 contains(scoped.pixel,'values[1+1]')
 contains(scoped.pixel,'values[fixed]')
 contains(scoped.pixel,'values[FIXED]')
 contains(scoped.pixel,'return values[lookup]')
 contains(scoped.pixel,'holder.values[lookup]')
 contains(scoped.pixel,'bvec3 values=bvec3(false,false,true);return values[lookup]')
 contains(scoped.pixel,'mat2x3 values=mat2x3(1.0);return values[lookup]')
 contains(scoped.pixel,'Choice values[3];return values[int(clamp(nmArrayIndexValue(lookup), 0.0, 2.0))]')
 local renamed,renameError=adapter.adapt{pixel=[[
  uniform int number;out vec4 fragColor;
  void main(){float values[3];values[0]=0.125;values[1]=0.5;values[2]=0.875;fragColor=vec4(values[number]);}
 ]],path='test/array-number-rename'}
 assert(renamed,renameError and renameError.detail)
 contains(renamed.pixel,'values[int(clamp(nmArrayIndexValue(nmNumberValue), 0.0, 2.0))]')
 local vertexIndexed,vertexError=adapter.adapt{
  pixel='out vec4 fragColor;void main(){fragColor=vec4(1.0);}',
  vertex='void main(){float values[3];values[0]=0.0;values[1]=0.5;values[2]=1.0;gl_PointSize=1.0;gl_Position=vec4(values[gl_VertexID],0.0,0.0,1.0);}',
  path='test/array-vertex-id',drawMode='points'}
 assert(vertexIndexed,vertexError and vertexError.detail)
 contains(vertexIndexed.vertex,'values[int(clamp(nmArrayIndexValue(gl_VertexID), 0.0, 2.0))]')
 local quadIndexed=assert(adapter.adapt{
  pixel='out vec4 fragColor;void main(){fragColor=vec4(1.0);}',
  vertex='void main(){float values[3];values[0]=0.0;values[1]=0.5;values[2]=1.0;gl_PointSize=1.0+float(gl_VertexID);gl_Position=vec4(values[gl_VertexID],0.0,0.0,1.0);}',
  path='test/array-instance-id',drawMode='points'})
 contains(quadIndexed.vertex,'values[int(clamp(nmArrayIndexValue(love_InstanceID), 0.0, 2.0))]')
 for repeats=1,32 do
  local accesses={}
  for i=1,repeats do accesses[i]='values[number]' end
  local many,manyError=adapter.adapt{pixel='uniform int number;out vec4 fragColor;void main(){float values[3];fragColor=vec4('..table.concat(accesses,'+')..');}',path='test/array-edit-ties-'..repeats}
  assert(many,manyError and manyError.detail)
  local _,lowered=many.pixel:gsub('values%[int%(clamp%(nmArrayIndexValue%(nmNumberValue%)%, 0%.0, 2%.0%)%)%]','')
  assert(lowered==repeats,'Every tied-offset index and rename must compose deterministically')
 end
 local colliding,collisionError=adapter.adapt{pixel=[[
  uniform int lookup;out vec4 fragColor;
  float nmArrayIndexValue(int index){return float(index)*0.5;}
  void main(){float values[3];values[0]=0.125;values[1]=0.5;values[2]=0.875;fragColor=vec4(values[lookup]);}
 ]],path='test/array-helper-collision'}
 assert(colliding,collisionError and collisionError.detail)
 contains(colliding.pixel,'nmArrayIndexValue_1(lookup)')
 local macroCollision,macroError=adapter.adapt{pixel=[[
  #define nmArrayIndexValue(x) ((x)+1)
  uniform int lookup;out vec4 fragColor;
  void main(){float values[3];fragColor=vec4(values[lookup]);}
 ]],path='test/array-helper-macro-collision'}
 assert(macroCollision,macroError and macroError.detail)
 contains(macroCollision.pixel,'nmArrayIndexValue_1(lookup)')
 local loopPixel=[[
  uniform int lookup;float values[9];out vec4 fragColor;
  void main(){
    values[8]=0.875;
    for(int values=0;values<1;values++){}
    float afterBraced=values[lookup];
    for(int values=0;values<1;values++) values+=0;
    fragColor=vec4(afterBraced+values[lookup]*0.0);
  }
 ]]
 local loopAdapted,loopError=adapter.adapt{pixel=loopPixel,path='test/array-for-scope'}
 assert(loopAdapted,loopError and loopError.detail)
 local _,loopReads=loopAdapted.pixel:gsub('values%[int%(clamp%(nmArrayIndexValue%(lookup%)%, 0%.0, 8%.0%)%)%]','')
 assert(loopReads==2,'For-loop initializer shadow must end after braced and unbraced bodies')
 local whilePixel=[[
  uniform int lookup;float values[9];out vec4 fragColor;
  void main(){
   values[8]=0.875;
   while(bool values=false){}
   float afterBraced=values[lookup];
   while(bool values=false) values=false;
   fragColor=vec4(afterBraced+values[lookup]*0.0);
  }
 ]]
 local whileAdapted,whileError=adapter.adapt{pixel=whilePixel,path='test/array-while-scope'}
 assert(whileAdapted,whileError and whileError.detail)
 local _,whileReads=whileAdapted.pixel:gsub('values%[int%(clamp%(nmArrayIndexValue%(lookup%)%, 0%.0, 8%.0%)%)%]','')
 assert(whileReads==2,'While-condition declaration shadow must end after braced and unbraced bodies')
 local pixel=[[
  uniform int lookup;
  out vec4 fragColor;
  float choose(){float values[3];values[0]=0.125;values[1]=0.5;values[2]=0.875;return values[lookup];}
  void main(){fragColor=vec4(choose());}
 ]]
 local result,diagnostics=adapter.adapt{pixel=pixel,path='test/array-index-pixels'}
 assert(result,diagnostics and diagnostics.detail)
 local g=love.graphics
 for _,kind in ipairs({'float','bool'}) do
  local invalid,invalidError=adapter.adapt{pixel='uniform '..kind..' invalidIndex;out vec4 fragColor;void main(){float values[3];fragColor=vec4(values[invalidIndex]);}',path='test/array-invalid-'..kind}
  assert(invalid,invalidError and invalidError.detail)
  local accepted,compiled=pcall(g.newShader,invalid.pixel,invalid.vertex)
  if accepted then compiled:release() end
  assert(not accepted,'Invalid '..kind..' fixed-array index must retain GLSL compiler rejection')
 end
 local shader=g.newShader(result.pixel,result.vertex)
 local macroSizedShader=g.newShader(sizedByMacro.pixel,sizedByMacro.vertex)
 local mesh=g.newMesh({{'VertexPosition','float',2},{'VertexTexCoord','float',2}},{{0,0,0,0},{16,0,2,0},{0,16,0,2}},'triangles','static')
 local canvas=g.newCanvas(8,8,{format='rgba8',dpiscale=1})
 g.push('all');g.origin();g.setBlendMode('replace','premultiplied');g.setColor(1,1,1,1)
 g.setCanvas(canvas);g.clear(0,0,0,0);g.setShader(macroSizedShader);macroSizedShader:send('lookup',9);g.draw(mesh);g.setCanvas()
 local macroPixels=canvas:newImageData();local macroRed=macroPixels:getPixel(4,4)
 assert(math.abs(macroRed-.875)<.01,'Macro-sized fixed-array read must clamp to the final element')
 macroPixels:release();macroSizedShader:release()
 for _,program in ipairs({sizedByComment,sizedByParens}) do
  local variant=g.newShader(program.pixel,program.vertex)
  g.setCanvas(canvas);g.clear(0,0,0,0);g.setShader(variant);variant:send('lookup',9);g.draw(mesh);g.setCanvas()
  local pixels=canvas:newImageData();local red=pixels:getPixel(4,4)
  assert(math.abs(red-.875)<.01,'Commented or parenthesized macro-sized array must clamp to the final element')
  pixels:release();variant:release()
 end
 local collisionShader=g.newShader(colliding.pixel,colliding.vertex)
 local macroShader=g.newShader(macroCollision.pixel,macroCollision.vertex)
 g.setCanvas(canvas);g.clear(0,0,0,0);g.setShader(collisionShader);collisionShader:send('lookup',1);g.draw(mesh);g.setCanvas()
 local collisionData=canvas:newImageData();local collisionRed=collisionData:getPixel(4,4)
 assert(math.abs(collisionRed-.5)<.01,'Collision-free injected helper must be used, not the authored function')
 collisionData:release();collisionShader:release();macroShader:release()
 local loopShader=g.newShader(loopAdapted.pixel,loopAdapted.vertex)
 g.setCanvas(canvas);g.clear(0,0,0,0);g.setShader(loopShader);loopShader:send('lookup',9);g.draw(mesh);g.setCanvas()
 local loopData=canvas:newImageData();local loopRed=loopData:getPixel(4,4)
 assert(math.abs(loopRed-.875)<.01,'For-loop scope must restore global array bounds after both body forms')
 loopData:release();loopShader:release()
 local whileShader=g.newShader(whileAdapted.pixel,whileAdapted.vertex)
 g.setCanvas(canvas);g.clear(0,0,0,0);g.setShader(whileShader);whileShader:send('lookup',9);g.draw(mesh);g.setCanvas()
 local whileData=canvas:newImageData();local whileRed=whileData:getPixel(4,4)
 assert(math.abs(whileRed-.875)<.01,'While-condition scope must restore global array bounds after both body forms')
 whileData:release();whileShader:release()
 for _,case in ipairs({{-4,.125},{1,.5},{9,.875}}) do
  g.setCanvas(canvas);g.clear(0,0,0,0);g.setShader(shader);shader:send('lookup',case[1]);g.draw(mesh);g.setCanvas()
  local data=canvas:newImageData();local r,gc,b,a=data:getPixel(4,4)
  assert(math.abs(r-case[2])<.01 and math.abs(gc-case[2])<.01 and math.abs(b-case[2])<.01 and math.abs(a-case[2])<.01,
   string.format('Index %d: got %.4f %.4f %.4f %.4f, expected %.4f',case[1],r,gc,b,a,case[2]))
  data:release()
 end
 local shadowPixel=[[
  uniform int lookup;
  float values[2];
  out vec4 fragColor;
  void main(){vec4 values=vec4(0.125,0.25,0.5,0.875);fragColor=vec4(values[lookup]);}
 ]]
 local shadowAdapted,shadowError=adapter.adapt{pixel=shadowPixel,path='test/array-shadow-pixels'}
 assert(shadowAdapted,shadowError and shadowError.detail)
 local shadowShader=g.newShader(shadowAdapted.pixel,shadowAdapted.vertex)
 g.setCanvas(canvas);g.clear(0,0,0,0);g.setShader(shadowShader);shadowShader:send('lookup',3);g.draw(mesh);g.setCanvas()
 local shadowData=canvas:newImageData();local shadowRed=shadowData:getPixel(4,4)
 assert(math.abs(shadowRed-.875)<.01,'Local vector shadow must retain vector index 3, not inherit global array bounds')
 shadowData:release();shadowShader:release()
 local sideEffectPixel=[[
  out vec4 fragColor;
  void main(){float values[3];values[0]=0.125;values[1]=0.5;values[2]=0.875;int i=1;float x=values[i++];fragColor=vec4(x,float(i)/4.0,0.0,1.0);}
 ]]
 local sideEffectAdapted,sideEffectError=adapter.adapt{pixel=sideEffectPixel,path='test/array-side-effect'}
 assert(sideEffectAdapted,sideEffectError and sideEffectError.detail)
 local sideEffectShader=g.newShader(sideEffectAdapted.pixel,sideEffectAdapted.vertex)
 g.setCanvas(canvas);g.clear(0,0,0,0);g.setShader(sideEffectShader);g.draw(mesh);g.setCanvas()
 local sideEffectData=canvas:newImageData();local sideRed,sideGreen=sideEffectData:getPixel(4,4)
 assert(math.abs(sideRed-.5)<.01 and math.abs(sideGreen-.5)<.01,'Dynamic index expression must be evaluated exactly once')
 sideEffectData:release();sideEffectShader:release()
 local nestedPixel=[[
  uniform int lookup;
  out vec4 fragColor;
  void main(){
    float inner[2];inner[0]=0.0;inner[1]=2.0;
    float outer[3];outer[0]=0.125;outer[1]=0.5;outer[2]=0.875;
    fragColor=vec4(outer[int(inner[lookup])]);
  }
 ]]
 local nestedAdapted,nestedError=adapter.adapt{pixel=nestedPixel,path='test/array-nested-pixels'}
 assert(nestedAdapted,nestedError and nestedError.detail)
 local nestedShader=g.newShader(nestedAdapted.pixel,nestedAdapted.vertex)
 g.setCanvas(canvas);g.clear(0,0,0,0);g.setShader(nestedShader);nestedShader:send('lookup',9);g.draw(mesh);g.setCanvas()
 local nestedData=canvas:newImageData();local nestedRed=nestedData:getPixel(4,4)
 assert(math.abs(nestedRed-.875)<.01,'Nested dynamic indexes must retain independent bounds')
 nestedData:release();nestedShader:release()
 local function verifyShadow(pixel,label)
  local program,errorValue=adapter.adapt{pixel=pixel,path='test/array-'..label}
  assert(program,errorValue and errorValue.detail)
  local variant=g.newShader(program.pixel,program.vertex)
  g.setCanvas(canvas);g.clear(0,0,0,0);g.setShader(variant);variant:send('lookup',2);g.draw(mesh);g.setCanvas()
  local pixels=canvas:newImageData();local red=pixels:getPixel(4,4)
  assert(math.abs(red-.875)<.01,label..' must mask outer array bounds')
  pixels:release();variant:release()
 end
 verifyShadow([[
  uniform int lookup;float values[2];out vec4 fragColor;
  void main(){bvec3 values=bvec3(false,false,true);fragColor=vec4(values[lookup]?0.875:0.125);}
 ]],'bool-vector-shadow')
 verifyShadow([[
  uniform int lookup;struct Choice{float x;};float values[2];out vec4 fragColor;
  void main(){Choice values[3];values[0].x=0.125;values[1].x=0.5;values[2].x=0.875;fragColor=vec4(values[lookup].x);}
 ]],'named-struct-shadow')
 g.pop();canvas:release();mesh:release();shader:release()
 print('ARRAY-INDEX GPU bounds, shadowing, nested indexes and constant indexes passed')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
