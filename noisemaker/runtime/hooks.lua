-- Lifecycle and one-shot CPU overlays used by the locked effect catalog.
-- Worm paths are generated with the reference PCG and float32 flow field;
-- raster bytes remain binary until the host uploads them as a GPU texture.
-- Hairline rasterization adapts algorithms from Skia SkScan_Antihair.cpp and
-- SkScan_Hairline.cpp. Copyright 2006, 2011 The Android Open Source Project.
-- Skia source: https://skia.googlesource.com/skia/
-- Skia license: https://skia.googlesource.com/skia/+/refs/heads/main/LICENSE
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
-- 1. Redistributions of source code must retain the above copyright notice,
--    this list of conditions and the following disclaimer.
-- 2. Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
-- 3. Neither the name of the copyright holder nor the names of its
--    contributors may be used to endorse or promote products derived from
--    this software without specific prior written permission.
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.
local ffi=require('ffi')
local bit=require('bit')
local values=require('noisemaker.compiler.values')
local skiaFill=require('noisemaker.runtime.skia_fill')
local M={}
local TAU=math.pi*2
local UINT32=4294967296
local function uint32(x)
  return x % UINT32
end
local RNG={};RNG.__index=RNG
function M.seededRNG(seed)
  return setmetatable({state=uint32(uint32(math.modf(seed))*747796405+2891336453)},RNG)
end
function RNG:next()
  self.state=uint32(self.state*747796405+2891336453)
  local shift=bit.rshift(self.state,28)+4
  local word=uint32(bit.bxor(bit.rshift(self.state,shift),self.state)*277803737)
  return uint32(bit.bxor(bit.rshift(word,22),word))
end
function RNG:float() return self:next()/4294967295 end
function RNG:int(min,max) return min+self:next()%(max-min+1) end
function RNG:normal(mean,std)
  local u1=math.max(self:float(),1e-10)
  local u2=self:float()
  return (mean or 0)+(std or 1)*math.sqrt(-2*math.log(u1))*math.cos(TAU*u2)
end
local function flowField(width,height,frequency,rng)
  local gridWidth,gridHeight=math.ceil(frequency)+2,math.ceil(frequency)+2
  local grid=ffi.new('float[?]',gridWidth*gridHeight)
  for i=0,gridWidth*gridHeight-1 do grid[i]=rng:float() end
  local field=ffi.new('float[?]',width*height)
  for y=0,height-1 do
    for x=0,width-1 do
      local fx,fy=(x/width)*frequency,(y/height)*frequency
      local ix,iy=math.floor(fx),math.floor(fy)
      local dx,dy=fx-ix,fy-iy
      local sx,sy=dx*dx*(3-2*dx),dy*dy*(3-2*dy)
      local tl,tr=grid[iy*gridWidth+ix],grid[iy*gridWidth+ix+1]
      local bl,br=grid[(iy+1)*gridWidth+ix],grid[(iy+1)*gridWidth+ix+1]
      field[y*width+x]=(tl*(1-sx)+tr*sx)*(1-sy)+(bl*(1-sx)+br*sx)*sy
    end
  end
  return field
end
function M.traceWorms(opts,draw)
  local width,height=opts.width,opts.height
  local rng=M.seededRNG(opts.seed)
  local minDim,maxDim=math.min(width,height),math.max(width,height)
  local strideScale=maxDim/1024
  local field=flowField(width,height,opts.flowFreq,M.seededRNG(opts.seed*31337))
  local count=math.max(1,math.floor(maxDim*opts.density))
  local sharedRot=rng:float()*TAU
  local worms={}
  for i=1,count do
    worms[i]={x=rng:float()*width,y=rng:float()*height,
      stride=rng:normal(opts.stride,opts.strideDeviation)*strideScale,
      rot=opts.behavior=='obedient' and sharedRot or rng:float()*TAU,
      color=opts.colorFn(rng,i-1)}
  end
  local iterations=math.max(1,math.floor(math.sqrt(minDim)*opts.duration))
  for w=1,count do
    local worm=worms[w]
    local wx,wy=worm.x,worm.y
    for iter=0,iterations-1 do
      local t=iterations>1 and iter/(iterations-1) or 1
      local exposure=1-math.abs(1-t*2)
      local fx=math.floor(wx%width)
      local fy=math.floor(wy%height)
      local angle=field[fy*width+fx]*TAU*opts.kink
      angle=angle+(opts.behavior=='obedient' and sharedRot or worm.rot)
      local newX=wx+math.sin(angle)*worm.stride
      local newY=wy+math.cos(angle)*worm.stride
      draw(wx,wy,newX,newY,opts.lineWidth,worm.color,exposure,w-1,iter)
      wx,wy=newX,newY
    end
  end
end
local function overlayOptions(effect,width,height,params,layer)
  local seed=params.seed
  if seed==nil or seed==0 then seed=1 end
  if effect=='filter/fibers' then
    local density=params.density~=nil and params.density or 0.5
    local layerSeed=seed*1000+layer*137
    return {width=width,height=height,seed=layerSeed,density=0.5+density*2,
      kink=5+layerSeed%5,stride=0.75,strideDeviation=0.125,duration=1,
      behavior='chaotic',flowFreq=4,lineWidth=math.max(1.5,width/384),
      colorFn=function(rng) return {r=math.floor(rng:float()*200+55),g=math.floor(rng:float()*200+55),b=math.floor(rng:float()*200+55),a=0.5} end}
  end
  if effect=='filter/scratches' then
    local density=params.density~=nil and params.density or 0.3
    local layerSeed=seed*1000+layer*251
    return {width=width,height=height,seed=layerSeed,density=0.1+density*0.4,
      kink=0.125+(layerSeed%50)/400,stride=0.75,strideDeviation=0.5,
      duration=2+layerSeed%3,behavior=layerSeed%2==0 and 'obedient' or 'unruly',
      flowFreq=2+layerSeed%3,lineWidth=math.max(0.5,width/1024),
      colorFn=function() return {r=255,g=255,b=255,a=1} end}
  end
  if effect=='filter/strayHair' then
    local density=params.density~=nil and params.density or 0.5
    local layerSeed=seed*1000+42
    return {width=width,height=height,seed=layerSeed,density=0.001+density*0.004,
      kink=5+layerSeed%45,stride=0.5,strideDeviation=0.25,duration=8+layerSeed%8,
      behavior='unruly',flowFreq=4,lineWidth=math.max(1,width/400),
      colorFn=function(rng) return {r=math.floor(rng:float()*30),g=math.floor(rng:float()*30),b=math.floor(rng:float()*30),a=0.666} end}
  end
  error('Unsupported async effect '..tostring(effect))
end
local function blendPixel(pixels,width,height,x,y,color,paintAlpha,coverage,wideFill)
  if x<0 or x>=width or y<0 or y>=height or paintAlpha<=0 or coverage<=0 then return end
  local base=(y*width+x)*4
  local sourceScale=coverage+1
  local sourceAlpha=math.floor(paintAlpha*sourceScale/256)
  local destinationScale
  if wideFill then
    -- SkARGB32 blitAntiH pre-scales its paint before Color32/src-over.
    destinationScale=256-sourceAlpha
  else
    -- Anti-hair blitAntiH2/V2 uses SkBlendARGB32. It combines the fractional
    -- source term and scaled destination before the final >> 8.
    local inverseProduct=65535-paintAlpha*sourceScale
    destinationScale=math.floor((inverseProduct+math.floor(inverseProduct/256))/256)
  end
  for channel=0,2 do
    local component=channel==0 and color.r or channel==1 and color.g or color.b
    local paintPremul=math.floor(component*paintAlpha/255+0.5)
    local destinationPremul=math.floor(pixels[base+channel]*255+0.5)
    local sourcePremul=wideFill and math.floor(paintPremul*sourceScale/256) or 0
    local combined=wideFill and sourcePremul+math.floor(destinationPremul*destinationScale/256)
      or math.floor((paintPremul*sourceScale+destinationPremul*destinationScale)/256)
    pixels[base+channel]=combined/255
  end
  local destinationAlpha=math.floor(pixels[base+3]*255+0.5)
  local combinedAlpha=wideFill and sourceAlpha+math.floor(destinationAlpha*destinationScale/256)
    or math.floor((paintAlpha*sourceScale+destinationAlpha*destinationScale)/256)
  pixels[base+3]=combinedAlpha/255
end
local function rasterHairline(pixels,width,height,x1,y1,x2,y2,lineWidth,color,exposure)
  -- Skia's antialiased hairline path extends a round-capped unit stroke by pi/8.
  -- It then quantizes endpoints to 26.6, slope to 16.16 and coverage to 8 bits.
  local function f32(value) return tonumber(ffi.cast('float',value)) end
  x1,y1,x2,y2=f32(x1),f32(y1),f32(x2),f32(y2)
  local dx,dy=f32(x2-x1),f32(y2-y1)
  local len=f32(math.sqrt(f32(dx*dx+dy*dy)))
  if len==0 then dx,dy,len=1,0,1 end
  local outset=f32(math.pi/8)
  local ux,uy=f32(dx/len),f32(dy/len)
  x1,y1=f32(x1-f32(ux*outset)),f32(y1-f32(uy*outset))
  x2,y2=f32(x2+f32(ux*outset)),f32(y2+f32(uy*outset))
  x1,y1,x2,y2=math.modf(x1*64),math.modf(y1*64),math.modf(x2*64),math.modf(y2*64)
  -- AntiHairLineRgn first clips to the segment's expanded integer bounds.
  -- If those bounds cross the canvas, its smaller clip rectangle may leave a
  -- SkRectClipBlitter around the underlying paint blitter. That wrapper does
  -- not implement blitAntiH2/V2: its inherited methods dispatch via
  -- blitAntiH, which pre-scales the paint before the source-over operation.
  local boundsLeft=math.floor(math.min(x1,x2)/64)-1
  local boundsTop=math.floor(math.min(y1,y2)/64)-1
  local boundsRight=math.ceil(math.max(x1,x2)/64)+1
  local boundsBottom=math.ceil(math.max(y1,y2)/64)+1
  local clipped=boundsLeft<0 or boundsTop<0 or boundsRight>width or boundsBottom>height
  local clipLeft,clipTop=math.max(0,boundsLeft),math.max(0,boundsTop)
  local clipRight,clipBottom=math.min(width,boundsRight),math.min(height,boundsBottom)
  local horizontal=math.abs(x2-x1)>math.abs(y2-y1)
  if horizontal then
    if x1>x2 then x1,x2=x2,x1;y1,y2=y2,y1 end
  else
    if y1>y2 then x1,x2=x2,x1;y1,y2=y2,y1 end
    x1,y1,x2,y2=y1,x1,y2,x2
  end
  local span=x2-x1
  if span<=0 then return end
  local axial=y1==y2
  local slope=math.modf((y2-y1)*65536/span)
  local istart,istop=math.floor(x1/64),math.ceil(x2/64)
  local fstart=y1*1024+math.floor((slope*(32-(x1%64))+32)/64)
  local startCoverage,stopCoverage
  if istop-istart==1 then
    startCoverage,stopCoverage=span,0
  else
    startCoverage,stopCoverage=64-(x1%64),x2%64
  end
  local wrapped=false
  if clipped then
    local majorStart,majorStop=horizontal and clipLeft or clipTop,horizontal and clipRight or clipBottom
    if istart<majorStart then
      fstart=fstart+slope*(majorStart-istart)
      istart=majorStart
      startCoverage=64
      if istop-istart==1 then
        startCoverage=(x2-1)%64+1
        stopCoverage=0
      end
    end
    if istop>majorStop then
      istop=majorStop
      stopCoverage=0
    end
    if istart>=istop then return end
    local minorStart,minorStop=horizontal and clipTop or clipLeft,horizontal and clipBottom or clipRight
    local first,last=fstart,fstart+(istop-istart-1)*slope
    local low,high=math.min(first,last),math.max(first,last)
    local extentStart=math.floor((low-32768)/65536)-1
    local extentStop=math.ceil((high+32768)/65536)+1
    wrapped=minorStart>extentStart or minorStop<extentStop
  end
  local sourceAlpha=math.floor(color.a*exposure*255+0.5)
  local scaledAlpha=math.floor(sourceAlpha*math.floor(lineWidth*256)/256)
  for major=istart,istop-1 do
    local mod64=major==istart and startCoverage or (major==istop-1 and stopCoverage>0 and stopCoverage or 64)
    if mod64>0 then
      local fvalue=fstart+slope*(major-istart)+32768
      local minor=math.floor(fvalue/65536)
      local a=math.floor(fvalue/256)%256
      local upper=math.floor((255-a)*mod64/64)
      local lower=math.floor(a*mod64/64)
      if horizontal then
        blendPixel(pixels,width,height,major,minor-1,color,scaledAlpha,upper,wrapped or axial)
        blendPixel(pixels,width,height,major,minor,color,scaledAlpha,lower,wrapped or axial)
      else
        blendPixel(pixels,width,height,minor-1,major,color,scaledAlpha,upper,wrapped or axial)
        blendPixel(pixels,width,height,minor,major,color,scaledAlpha,lower,wrapped or axial)
      end
    end
  end
end
local function rasterSegment(pixels,width,height,x1,y1,x2,y2,lineWidth,color,exposure)
  if lineWidth<=1 then return rasterHairline(pixels,width,height,x1,y1,x2,y2,lineWidth,color,exposure) end
  local sourceAlpha=math.floor(color.a*exposure*255+0.5)
  if sourceAlpha<=0 then return end
  skiaFill.rasterSegment(width,height,x1,y1,x2,y2,lineWidth,function(x,y,coverageByte)
    blendPixel(pixels,width,height,x,y,color,sourceAlpha,coverageByte,true)
  end)
end
function M.renderOverlay(effect,width,height,params)
  assert(type(width)=='number' and width>0 and width%1==0 and type(height)=='number' and height>0 and height%1==0)
  params=params or {}
  local pixels=ffi.new('float[?]',width*height*4)
  local layers=effect=='filter/strayHair' and 1 or 4
  local segments=0
  for layer=0,layers-1 do
    local opts=overlayOptions(effect,width,height,params,layer)
    M.traceWorms(opts,function(x1,y1,x2,y2,lineWidth,color,exposure)
      rasterSegment(pixels,width,height,x1,y1,x2,y2,lineWidth,color,exposure)
      segments=segments+1
    end)
  end
  local bytes=ffi.new('uint8_t[?]',width*height*4)
  for pixel=0,width*height-1 do
    local base=pixel*4
    local a=math.max(0,math.min(1,pixels[base+3]))
    if a>0 then
      for channel=0,2 do
        bytes[base+channel]=math.floor(math.max(0,math.min(1,pixels[base+channel]/a))*255+0.5)
      end
    end
    bytes[base+3]=math.floor(a*255+0.5)
  end
  return ffi.string(bytes,width*height*4),segments
end
local Manager={};Manager.__index=Manager
local overlayEffects={['filter/fibers']=true,['filter/scratches']=true,['filter/strayHair']=true}
function M.new(graph,context)
  assert(type(graph)=='table' and type(context)=='table')
  local nodes,order={},{}
  local hasMedia=false
  for _,pass in ipairs(graph.passes or {}) do
    local effectKey=type(pass.effectKey)=='string' and pass.effectKey:gsub('%.','/') or pass.effectKey
    if effectKey=='synth/media' then hasMedia=true end
    if overlayEffects[effectKey] and pass.nodeId and not nodes[pass.nodeId] then
      local defaultDensity=effectKey=='filter/scratches' and 0.3 or 0.5
      local params={seed=1,density=defaultDensity,alpha=effectKey=='filter/scratches' and 0.75 or 0.5}
      -- Upstream initial asyncInit receives pipeline.globalUniforms, not pass
      -- uniforms. DSL values alone do not change the one-shot overlay.
      for _,key in ipairs{'seed','density','alpha'} do
        local global=context.globalUniforms and context.globalUniforms[key]
        local override=context.paramOverrides and context.paramOverrides[pass.nodeId]
        if global~=nil then params[key]=global end
        if override and override[key]~=nil then params[key]=override[key] end
      end
      nodes[pass.nodeId]={nodeId=pass.nodeId,effectKey=effectKey,stepIndex=pass.stepIndex,params=params}
      order[#order+1]=pass.nodeId
    end
  end
  local inherited={}
  for id,params in pairs(context.paramOverrides or {}) do
    local copy={}
    for name,value in pairs(params) do copy[name]=value end
    inherited[id]=copy
  end
  return setmetatable({graph=graph,context=context,nodes=nodes,order=order,hasMedia=hasMedia,
    mediaInitialized=false,mediaWidth=1,mediaHeight=1,released=false,overrides=inherited},Manager)
end
function Manager:_draw(node)
  if type(self.context.upload)~='function' then error('Overlay upload callback required') end
  local width,height=self.context.width,self.context.height
  local data=M.renderOverlay(node.effectKey,width,height,node.params)
  self.context.upload(node.nodeId..'_overlayTex',data,width,height,'rgba8')
end
function Manager:initialize()
  if self.released then error('Hooks manager released') end
  if self.hasMedia and not self.mediaInitialized then
    self.mediaWidth,self.mediaHeight=1,1
    self.mediaInitialized=true
  end
  for _,id in ipairs(self.order) do self:_draw(self.nodes[id]) end
  return true
end
function Manager:update(time,delta)
  if self.released then error('Hooks manager released') end
  local out={}
  if self.hasMedia then
    out['synth/media']={imageSize={self.mediaWidth or 1,self.mediaHeight or 1}}
  end
  return out
end
function Manager:parameter(stepIndex,name,value)
  if self.released then error('Hooks manager released') end
  if name~='seed' and name~='density' and name~='alpha' then return false end
  local changed=false
  for _,id in ipairs(self.order) do
    local node=self.nodes[id]
    if node.stepIndex==stepIndex and node.params[name]~=value then
      node.params[name]=value
      self.overrides[id]=self.overrides[id] or {}
      self.overrides[id][name]=value
      if name~='alpha' then self:_draw(node) end
      changed=true
    end
  end
  return changed
end
function Manager:parameterOverrides()
  local out={}
  for id,params in pairs(self.overrides) do
    local copy={}
    for name,value in pairs(params) do copy[name]=value end
    out[id]=copy
  end
  return out
end
function Manager:prepareParameter(stepIndex,name,value,uploadCallback)
  if self.released then error('Hooks manager released') end
  if name~='seed' and name~='density' and name~='alpha' then return nil end
  local relevant=false
  for _,id in ipairs(self.order) do
    local node=self.nodes[id]
    if node.stepIndex==stepIndex and node.params[name]~=value then
      relevant=true
      break
    end
  end
  if not relevant then return nil end
  local context={}
  for key,current in pairs(self.context) do context[key]=current end
  if uploadCallback then context.upload=uploadCallback end
  context.paramOverrides=self:parameterOverrides()
  local candidate=M.new(self.graph,context)
  for _,id in ipairs(self.order) do
    local original=self.nodes[id]
    local nextNode=candidate.nodes[id]
    for key,current in pairs(original.params) do nextNode.params[key]=current end
  end
  candidate.mediaInitialized=self.mediaInitialized
  candidate.mediaWidth=self.mediaWidth
  candidate.mediaHeight=self.mediaHeight
  candidate:parameter(stepIndex,name,value)
  return candidate
end
function Manager:setMediaDimensions(effectKey,width,height)
  if (effectKey~='synth/media' and effectKey~='synth.media') or not self.hasMedia then return false end
  assert(type(width)=='number' and width>0 and type(height)=='number' and height>0)
  self.mediaWidth,self.mediaHeight=width,height
  return true
end
function Manager:resize(width,height)
  if self.released then error('Hooks manager released') end
  self.context.width,self.context.height=width,height
  for _,id in ipairs(self.order) do self:_draw(self.nodes[id]) end
end
function Manager:release()
  self.released=true
  self.nodes={};self.order={}
end
return M
