local root=love.filesystem.getSource()..'/../../..'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local nm=require('noisemaker')
-- Native counterpart of upstream shaders/tests/test_effect_orientation.mjs and
-- test_height_grid_orientation.mjs for the six effects whose orientation upstream fixed after
-- 8e583593: each reads the presented Canvas for an asymmetric input.
local size=128
local function frame(dsl,frames,media)
 local graph=assert(nm.compile(dsl))
 local renderer=assert(nm.newRenderer(graph,{width=size,height=size}))
 -- Upstream uploads the media image top row first without flipping (flipY: false), which is
 -- origin bottom-left here.
 if media then assert(renderer:setInput('imageTex',media,{origin='bottom-left'})) end
 local canvas
 for _=1,frames or 2 do canvas=assert(renderer:render{time=0}) end
 local data=canvas:newImageData()
 local pixels={}
 for y=0,size-1 do for x=0,size-1 do
  local r,g,b=data:getPixel(x,y)
  pixels[y*size+x]={math.floor(r*255+.5),math.floor(g*255+.5),math.floor(b*255+.5)}
 end end
 data:release();renderer:release()
 return pixels
end
local function at(view,x,y) return view[y*size+x] end
local function meanAbsDiff(a,b)
 local sum=0
 for i=0,size*size-1 do for c=1,3 do sum=sum+math.abs(a[i][c]-b[i][c]) end end
 return sum/(size*size*3)
end
local function remapped(view,sx,sy)
 local out={}
 for y=0,size-1 do for x=0,size-1 do out[y*size+x]=view[sy(y)*size+sx(x)] end end
 return out
end
local function litMean(view,x0,y0,x1,y1,f)
 local sum,lit=0,0
 for y=y0,y1-1 do for x=x0,x1-1 do
  local p=at(view,x,y)
  if p[1]+p[2]+p[3]>=24 then sum=sum+f(p[1],p[2],p[3]);lit=lit+1 end
 end end
 assert(lit>16,string.format('band %d,%d-%d,%d must contain lit pixels',x0,y0,x1,y1))
 return sum/lit
end
local keep=function(n) return n end
local reverse=function(n) return size-1-n end
local keepLow=function(n) return n<size/2 and n or size-1-n end
local keepHigh=function(n) return n>=size/2 and n or size-1-n end
local uvMap='testPattern(pattern: uvMap)'
local checks,failures=0,{}
local function check(fn) local ok,err=pcall(fn);checks=checks+1;if not ok then failures[#failures+1]=tostring(err) end end
local function run()
 local authored=frame('search synth\n'..uvMap..'.write(o0)\nrender(o0)')
 -- Base case: testPattern() numbers its 4x4 checkerboard 0-15 from the top-left, and each digit
 -- is drawn from a 3x5 bitmap whose top row is its highest group of bits.
 check(function()
  local view=frame('search synth\ntestPattern().write(o0)\nrender(o0)')
  local glyph={0x7B6F,0x2492,0x73E7,0x72CF,0x5BC9,0x79CF,0x79EF,0x7249,0x7BEF,0x7BCF}
  local cell=size/4
  for number=0,9 do
   local cellX,cellRow=number%4,math.floor(number/4)
   local cellFromBottom=3-cellRow
   local white=(cellX+cellFromBottom)%2==0
   local read,expected={},{}
   for row=0,4 do
    local readRow,expectedRow={},{}
    for column=0,2 do
     local x=math.floor(cellX*cell+(0.425+(column+.5)*0.05)*cell)
     local y=size-1-math.floor(cellFromBottom*cell+(0.325+(4-row+.5)*0.07)*cell)
     local lit=at(view,x,y)[1]>128
     readRow[#readRow+1]=(lit~=white) and '#' or '.'
     expectedRow[#expectedRow+1]=bit.band(bit.rshift(glyph[number+1],(4-row)*3+(2-column)),1)==1 and '#' or '.'
    end
    read[#read+1]=table.concat(readRow);expected[#expected+1]=table.concat(expectedRow)
   end
   assert(table.concat(read,' ')==table.concat(expected,' '),string.format('synth/testPattern: cell %d must show %d upright at row %d column %d (read %s, expected %s)',
    number,number,cellRow,cellX,table.concat(read,' '),table.concat(expected,' ')))
  end
 end)
 -- A mirror mode keeps the named half as authored and reflects it onto the other half; the
 -- presented rows run top first, so "up to down" keeps rows 0-63.
 local modes={
  {'none','none',keep,keep},{'all','all',reverse,reverse},{'horizontal','horizontal',reverse,keep},
  {'vertical','vertical',keep,reverse},{'mirrorLtoR','leftToRight',keepLow,keep},
  {'mirrorRtoL','rightToLeft',keepHigh,keep},{'mirrorUtoD','upToDown',keep,keepLow},
  {'mirrorDtoU','downToUp',keep,keepHigh},{'mirrorLtoRUtoD','lrUd',keepLow,keepLow},
  {'mirrorLtoRDtoU','lrDu',keepLow,keepHigh},{'mirrorRtoLUtoD','rlUd',keepHigh,keepLow},
  {'mirrorRtoLDtoU','rlDu',keepHigh,keepHigh}}
 for _,mode in ipairs(modes) do
  for _,case in ipairs({{'filter/flipMirror',mode[1],'search filter, synth\n'..uvMap..'.flipMirror(mode: '..mode[1]..')'},
    {'classicNoisedeck/effects',mode[2],'search classicNoisedeck, synth\n'..uvMap..'.effects(flip: '..mode[2]..')'}}) do
   check(function()
    local view=frame(case[3]..'.write(o0)\nrender(o0)')
    local diff=meanAbsDiff(view,remapped(authored,mode[3],mode[4]))
    assert(diff<=2,string.format('%s %s: the frame must be the authored image under the named flip (mean difference %.2f)',case[1],case[2],diff))
   end)
  end
 end
 -- glyphMap draws each glyph from its bitmap, whose row 0 is the top row. A dim grey input
 -- selects the period (row 5); a light grey input selects '@' or 'M'.
 local glyphs={{'period','#181818',{{'.....','.....','.....','.....','.....','..#..','.....'}}},
  {'@ and M','#e6e6e6',{{'.###.','#...#','#.###','#.#.#','#.##.','#....','.###.'},{'#...#','##.##','#.#.#','#.#.#','#...#','#...#','.....'}}}}
 for _,glyph in ipairs(glyphs) do
  check(function()
  local view=frame('search filter, synth\nsolid(color: '..glyph[2]..').glyphMap(cellSize: 32, colorMode: mono).write(o0)\nrender(o0)')
  for cy=0,3 do for cx=0,3 do
   local rows={}
   for r=0,6 do
    local row={}
    for c=0,4 do row[#row+1]=at(view,math.floor(cx*32+(c+.5)*32/5),math.floor(cy*32+(r+.5)*32/7))[1]>128 and '#' or '.' end
    rows[#rows+1]=table.concat(row)
   end
   local matched=false
   for _,bitmap in ipairs(glyph[3]) do
    local same=true;for r=1,7 do if bitmap[r]~=rows[r] then same=false end end
    matched=matched or same
   end
   assert(matched,string.format('filter/glyphMap %s: cell %d,%d must read the bitmap top row first (read %s)',glyph[1],cx,cy,table.concat(rows,' ')))
  end end
  end)
 end
 -- heightGrid seen from directly above shows its diffuse image as authored.
 local corners={topLeft={44,44},topRight={84,44},bottomLeft={44,84}}
 local function sample(view)
  local out={}
  for name,corner in pairs(corners) do
   local sum,lit={0,0,0},0
   for y=corner[2]-3,corner[2]+3 do for x=corner[1]-3,corner[1]+3 do
    local p=at(view,x,y)
    if p[1]+p[2]+p[3]>0 then for c=1,3 do sum[c]=sum[c]+p[c] end;lit=lit+1 end
   end end
   assert(lit>0,name..': the sample window must contain lit pixels')
   out[name]={sum[1]/lit,sum[2]/lit,sum[3]/lit}
  end
  return out
 end
 local across=function(s) return s.topRight[1]-s.topLeft[1] end
 local down=function(s) return s.bottomLeft[2]-s.topLeft[2] end
 local image=sample(frame('search synth\n'..uvMap..'.write(o0)\nrender(o0)',4))
 assert(math.abs(across(image))>48 and math.abs(down(image))>48,'the uvMap reference must vary along both axes')
 check(function()
 local grid=sample(frame('search synth, points, render\n'..uvMap..'.write(o1)\nsolid(color: #ffffff).pointsEmit(stateSize: x128).heightGrid(heightScale: 0, diffuseTex: read(o1)).pointsRender(viewMode: perspective, rotateX: 1.5708, density: 100, intensity: 0, inputIntensity: 0).write(o0)\nrender(o0)',4))
 local function sign(v) return v>0 and 1 or v<0 and -1 or 0 end
 assert(sign(across(grid))==sign(across(image)) and math.abs(across(grid))>32,string.format('points/heightGrid: seen from above, image right must be screen right (red %.0f -> %.0f)',grid.topLeft[1],grid.topRight[1]))
 assert(sign(down(grid))==sign(down(image)) and math.abs(down(grid))>32,string.format('points/heightGrid: seen from above, image top must be screen top (green %.0f -> %.0f, authored %.0f -> %.0f)',grid.topLeft[2],grid.bottomLeft[2],image.topLeft[2],image.bottomLeft[2]))
 end)
 -- The volume renderers show a volume as authored. The media image is red everywhere, green on
 -- its right half and blue on its top half (rows 0-63).
 local cubeData=love.image.newImageData(size,size)
 cubeData:mapPixel(function(x,y) return 1,x>=size/2 and 1 or 0,y<size/2 and 1 or 0,1 end)
 local cube=love.graphics.newImage(cubeData,{linear=true});cubeData:release()
 for _,case in ipairs({{'render/render3d','render3d()','from the front'},{'render/renderLit3d','renderLit3d()','from the front'},
   {'render/renderLit3d','renderLit3d(cameraPosition: [0, 1, 0])','from directly above'}}) do
  check(function()
  local view=frame('search synth3d, render, synth\nheightmap3d(heightTex: solid(color: #ffffff), tex: media(imageSize: ['..size..', '..size..']), volumeSize: x64, heightScale: 1)\n  .'..case[2]..'.write(o0)\nrender(o0)',2,cube)
  local greener=function(r,g) return g-r end
  local acrossVolume=litMean(view,size*5/8,0,size,size,greener)-litMean(view,0,0,size*3/8,size,greener)
  assert(acrossVolume>32,string.format('%s %s: image right must be screen right (green minus red, right minus left: %.0f)',case[1],case[3],acrossVolume))
  if case[3]=='from directly above' then
   local bluer=function(r,g,b) return b-r end
   local downVolume=litMean(view,0,0,size,size*3/8,bluer)-litMean(view,0,size*5/8,size,size,bluer)
   assert(downVolume>32,string.format('%s %s: image top must be screen top (blue minus red, top minus bottom: %.0f)',case[1],case[3],downVolume))
  end
  end)
 end
 cube:release()
 for _,failure in ipairs(failures) do print('EFFECT-ORIENTATION-FAIL '..failure) end
 assert(#failures==0,#failures..' of '..checks..' orientation checks failed')
 print('EFFECT-ORIENTATION '..checks..' checks: flipMirror and classicNoisedeck/effects keep the named half in 12 modes each; glyphMap glyphs, heightGrid, render3d and renderLit3d show the input as authored')
end
function love.load()local ok,err=xpcall(run,debug.traceback);if not ok then io.stderr:write(tostring(err),'\n')end;love.event.quit(ok and 0 or 1)end
