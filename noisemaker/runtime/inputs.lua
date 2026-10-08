-- Host-fed audio and MIDI snapshots. Device capture and permissions stay with
-- the embedding application; this module gives them the reference lookup and
-- GPU-uniform layout used by Polymorphic automation.
local values=require('noisemaker.compiler.values')
local M={}
local Input={};Input.__index=Input
local function pick(tableValue,key)
  if type(tableValue)~='table' then return nil end
  return tableValue[key] or tableValue[tostring(key)]
end
local function indexed(tableValue,index)
  if type(tableValue)~='table' then return nil end
  if values.isArray(tableValue) or #tableValue>0 then return tableValue[index+1] end
  return tableValue[index] or tableValue[tostring(index)]
end
local function array(input,count,default)
  local out=values.array()
  for i=1,count do
    local value=type(input)=='table' and input[i] or nil
    out[i]=type(value)=='number' and value or default
  end
  return out
end
local Midi={};Midi.__index=Midi
local function midiState(snapshot,ports)
  return setmetatable({channels=snapshot.channels or {},clockCount=snapshot.clockCount or 0,
    ports=ports or snapshot.ports or {},mpeZones=snapshot.mpeZones or {}},Midi)
end
function Midi:getChannel(channel)
  return pick(self.channels,channel) or pick(self.channels,1) or {key=0,velocity=0,gate=0,time=0,keys={}}
end
function Midi:getPortState(selector)
  selector=selector or {}
  if not selector.name and not selector.id then return self end
  local matches={}
  for _,port in ipairs(self.ports) do
    if port.connected~=false and ((selector.id and port.id==selector.id) or (not selector.id and port.name==selector.name)) then
      matches[#matches+1]=port
    end
  end
  if selector.id then
    if #matches~=1 then return nil end
  elseif #matches~=1 then return nil end
  return midiState(matches[1],{})
end
local function newestVoice(state,zone,members)
  if zone~=0 and zone~=1 then return nil end
  if members~=nil and (type(members)~='number' or members%1~=0 or members<1 or members>15) then return nil end
  local configured=zone==0 and state.mpeZones.lower or state.mpeZones.upper
  local count=members or configured or 15
  local first=zone==0 and 2 or 16-count
  local last=zone==0 and 1+count or 15
  local newest
  for channel=first,last do
    local ch=state:getChannel(channel)
    local held=ch.heldNotes or {}
    for _,note in pairs(held) do
      if type(note)=='table' and (not newest or (note.order or 0)>(newest.order or 0)) then
        newest={key=note.key,velocity=note.velocity,time=note.time,order=note.order,
          channel=ch,channelNumber=channel,gate=1}
      end
    end
  end
  return newest
end
function Midi:getZoneVoice(selector)
  selector=selector or {}
  local newest=newestVoice(self,selector.zone,selector.members)
  for _,port in ipairs(self.ports) do
    if port.connected~=false then
      local voice=newestVoice(midiState(port,{}),selector.zone,selector.members)
      if voice and (not newest or (voice.order or 0)>(newest.order or 0)) then newest=voice end
    end
  end
  return newest
end
function Midi:updateNoteGrid()
  local grid=values.array()
  for channel=1,16 do
    local channelState=pick(self.channels,channel)
    local keys=channelState and channelState.keys or {}
    for key=0,127 do
      local velocity=indexed(keys,key) or 0
      local offset=((channel-1)*128+key)*4
      grid[offset+1]=velocity>0 and velocity/127 or 0
      grid[offset+2]=velocity>0 and 1 or 0
      grid[offset+3]=0
      grid[offset+4]=0
    end
  end
  self.noteGrid=grid
  return grid
end
local Audio={};Audio.__index=Audio
local function audioState(snapshot)
  local result={low=snapshot.low or 0,mid=snapshot.mid or 0,high=snapshot.high or 0,
    vol=snapshot.vol or 0,raw=snapshot.raw or 0,rawReady=snapshot.rawReady==true,
    fft=array(snapshot.fft,16,0),spectrum=array(snapshot.spectrum,128,0),
    waveform=array(snapshot.waveform,128,0.5),devices=snapshot.devices or {},
    defaultChannels=snapshot.defaultChannels or {},defaultConnected=snapshot.defaultConnected~=false}
  return setmetatable(result,Audio)
end
function Audio:getDeviceChannelState(selector)
  selector=selector or {}
  if not selector.name and not selector.id and selector.channel==nil then return self end
  local channel=selector.channel
  if type(channel)~='number' or channel%1~=0 or channel<1 or channel>32 then return nil end
  if not selector.name and not selector.id then
    if not self.defaultConnected then return nil end
    return pick(self.defaultChannels,channel)
  end
  local matches={}
  for _,device in ipairs(self.devices) do
    if device.connected~=false and ((selector.id and device.id==selector.id) or (not selector.id and device.name==selector.name)) then
      matches[#matches+1]=device
    end
  end
  if #matches~=1 then return nil end
  return pick(matches[1].channels,channel)
end
function M.new(options)
  return setmetatable({options=options or {},external={midi=nil,audio=nil},
    silentSpectrum=array(nil,128,0),silentWaveform=array(nil,128,0.5)},Input)
end
function Input:update(frame)
  frame=frame or {}
  local uniforms={}
  local textures={}
  if frame.audio then
    local audio=audioState(frame.audio)
    self.external.audio=audio
    uniforms.audioWaveform=audio.waveform
    uniforms.audioSpectrum=audio.spectrum
  else
    self.external.audio=nil
    uniforms.audioWaveform=self.silentWaveform
    uniforms.audioSpectrum=self.silentSpectrum
  end
  if frame.midi then
    local midi=midiState(frame.midi)
    self.external.midi=midi
    uniforms.midiClockCount=midi.clockCount
    textures.midiNoteGrid={width=128,height=16,format='rgba32float',data=midi:updateNoteGrid()}
  else
    self.external.midi=nil
    uniforms.midiClockCount=0
    if self.options.needsMidiNoteGrid then
      textures.midiNoteGrid={width=128,height=16,format='rgba32float',data=array(nil,128*16*4,0)}
    end
  end
  return uniforms,textures,self.external
end
function Input:release() self.external={midi=nil,audio=nil} end
M.Midi=Midi
M.Audio=Audio
local palettes={
{offset={0.93,0.97,0.52},amp={0.76,0.88,0.37},freq={1,1,1},phase={0.21,0.41,0.56},mode=3},
{offset={0.5,0.5,0.5},amp={0.56851584,0.7740668,0.23485267},freq={1,1,1},phase={0.727029,0.08039695,0.10427457},mode=3},
{offset={0.5,0.5,0.5},amp={0.5,0.5,0.5},freq={1,1,1},phase={0.3,0.2,0.2},mode=3},
{offset={0.7,0.2,0.2},amp={0.45,0.2,0.1},freq={1,1,1},phase={0.5,0.4,0},mode=3},
{offset={0.2,0.31,0.98},amp={0.09,0.59,0.48},freq={1,1,1},phase={0.88,0.4,0.33},mode=3},
{offset={0.1,0.4,0.7},amp={0.5,0.5,0.5},freq={1,1,1},phase={0.1,0.1,0.1},mode=3},
{offset={0.5,0.5,0.5},amp={0.5,0.5,0.5},freq={1,1,1},phase={0,0.1,0.2},mode=3},
{offset={0.63290054,0.37883538,0.29405284},amp={0.7259015,0.7004237,0.9494409},freq={1,1,1},phase={0,0.1,0.2},mode=3},
{offset={0.74,0.37,0.73},amp={0.94,0.33,0.27},freq={1,1,1},phase={0.44,0.17,0.88},mode=3},
{offset={1,0.4,0.9},amp={1,0.7,1},freq={1,1,1},phase={0.4,0.5,0.6},mode=3},
{offset={0.59,0.53,0.94},amp={0.51,0.39,0.41},freq={1,1,1},phase={0.15,0.41,0.46},mode=3},
{offset={0,0,0.43},amp={0,0,0.51},freq={1,1,1},phase={0,0,0.36},mode=1},
{offset={0.79,0.45,0.35},amp={0.83,0.45,0.19},freq={1,1,1},phase={0.28,0.91,0.61},mode=3},
{offset={0.5,0.5,0.5},amp={0.5,0.5,0.5},freq={1,1,1},phase={0,0.2,0.25},mode=3},
{offset={0.22,0.48,0.62},amp={0.5,0.5,0.5},freq={1,1,1},phase={0.1,0.3,0.2},mode=3},
{offset={0.51,0.49,0.51},amp={0.02,0.92,0.76},freq={1,1,1},phase={0.71,0.23,0.66},mode=1},
{offset={0.5,0.5,0.5},amp={0.5,0.5,0.5},freq={2,2,2},phase={1,1,1},mode=3},
{offset={0.96,0.5,0.49},amp={0.79,0.56,0.22},freq={1,1,1},phase={0.15,0.98,0.87},mode=3},
{offset={0.35536355,0.12935615,0.17060602},amp={0.75804377,0.62868536,0.2227562},freq={1,1,1},phase={0,0.25,0.5},mode=3},
{offset={0.75,0.47,0.45},amp={0.79,0.5,0.23},freq={1,1,1},phase={0.08,0.84,0.16},mode=3},
{offset={0.1,0.22,0.27},amp={0.7,0.81,0.73},freq={1,1,1},phase={0.99,0.12,0.94},mode=3},
{offset={0.5,0.5,0.5},amp={0.5,0.5,0.5},freq={0,0,1},phase={0.5,0.5,0.5},mode=3},
{offset={0.5,0.5,0.5},amp={0.5,0.5,0.5},freq={0,1,1},phase={0.5,0.5,0.5},mode=3},
{offset={0.5,0.5,0.5},amp={0.5,0.5,0.5},freq={0,1,0},phase={0.5,0.5,0.5},mode=3},
{offset={0.5,0.5,0.5},amp={0.5,0.5,0.5},freq={1,0,1},phase={0.5,0.5,0.5},mode=3},
{offset={0.5,0.5,0.5},amp={0.5,0.5,0.5},freq={1,0,0},phase={0.5,0.5,0.5},mode=3},
{offset={0.5,0.5,0.5},amp={0.5,0.5,0.5},freq={1,1,0},phase={0.5,0.5,0.5},mode=3},
{offset={0.62,0.2,0.2},amp={0.74,0.33,0.09},freq={1,1,1},phase={0.2,0.1,0},mode=3},
{offset={0.72,0.07,0.62},amp={0.56,0.68,0.39},freq={1,1,1},phase={0.25,0.4,0.41},mode=3},
{offset={0,0.53,0.33},amp={0.78,0.39,0.07},freq={1,1,1},phase={0.94,0.92,0.9},mode=3},
{offset={0.2,0.64,0.62},amp={0.5,0.5,0.5},freq={1,1,1},phase={0.15,0.2,0.3},mode=3},
{offset={0.64,0.12,0.84},amp={0.5,0.5,0.5},freq={1,1,1},phase={0.1,0.25,0.15},mode=3},
{offset={0.47,0.27,0.27},amp={0.42,0.42,0.04},freq={1,1,1},phase={0.41,0.14,0.11},mode=3},
{offset={0.72,0.45,0.08},amp={0.65,0.4,0.11},freq={1,1,1},phase={0.71,0.8,0.84},mode=3},
{offset={0.22,0.56,0.17},amp={0.62,0.79,0.11},freq={1,1,1},phase={0.15,0.1,0.25},mode=3},
{offset={0.41,0.22,0.67},amp={0.5,0.5,0.5},freq={1,1,1},phase={0.2,0.25,0.2},mode=3},
{offset={0.5,0.5,0.5},amp={0.5,0.5,0.5},freq={1,1,1},phase={0.25,0.5,0.75},mode=3},
{offset={0.5224456,0.3864609,0.36020845},amp={0.6059281,0.17591387,0.17166573},freq={1,1,1},phase={0,0.25,0.5},mode=3},
{offset={0.5224456,0.3864609,0.36020845},amp={0.6059281,0.17591387,0.17166573},freq={2,2,2},phase={0,0.25,0.5},mode=3},
{offset={0.45,0.5,0.42},amp={0.42,0,0},freq={2,2,2},phase={0.63,1,1},mode=2},
{offset={0.83,0.6,0.63},amp={0.5,0.5,0.5},freq={1,1,1},phase={0.3,0.1,0},mode=3},
{offset={0.6,0.4,0.1},amp={0.5,0.5,0.5},freq={1,1,1},phase={0.3,0.2,0.1},mode=3},
{offset={0.27,0.79,0.78},amp={0.46,0.73,0.19},freq={1,1,1},phase={0.27,0.16,0.04},mode=2},
{offset={0.74,0.48,0.46},amp={0.67,0.25,0.27},freq={1,1,1},phase={0.07,0.79,0.39},mode=3},
{offset={0.56,0.69,0.32},amp={0.9,0.43,0.34},freq={1,1,1},phase={0.03,0.8,0.4},mode=3},
{offset={0.78,0.68,0.15},amp={0.73,0.36,0.52},freq={1,1,1},phase={0.74,0.93,0.28},mode=3},
{offset={0,0,0},amp={1,0,0.8},freq={1,1,1},phase={0,0.5,0.1},mode=3},
{offset={0,0,0.25},amp={1,0.25,0.5},freq={0.5,0.5,0.5},phase={0.5,0,0},mode=3},
{offset={0.26,0.57,0.03},amp={0.5,0.5,0.5},freq={1,1,1},phase={0,0.1,0.3},mode=3},
{offset={0.48,0.6,0.03},amp={0.28,0.08,0.65},freq={1,1,1},phase={0.1,0.15,0.3},mode=2},
{offset={0.31,0.21,0.27},amp={0.65,0.93,0.73},freq={1,1,1},phase={0.43,0.45,0.48},mode=3},
{offset={0,0.19,0.68},amp={0.9,0.76,0.63},freq={1,1,1},phase={0.43,0.23,0.32},mode=3},
{offset={0.41,0.03,0.16},amp={0.78,0.63,0.68},freq={1,1,1},phase={0.81,0.61,0.06},mode=3},
{offset={0.97,0.38,0.35},amp={0.97,0.74,0.23},freq={1,1,1},phase={0.34,0.41,0.44},mode=3},
{offset={0.56,0.35,0.14},amp={0.68,0.79,0.57},freq={1,1,1},phase={0.73,0.9,0.99},mode=3}
}
function M.expandPalette(index)
  if type(index)~='number' or index<=0 or index>#palettes then return nil end
  local entry=palettes[index]
  if not entry then error('Palette index must be an integer') end
  local function copy(a) local out={};for i,v in ipairs(a) do out[i]=v end;return out end
  return {paletteOffset=copy(entry.offset),paletteAmp=copy(entry.amp),paletteFreq=copy(entry.freq),palettePhase=copy(entry.phase),paletteMode=entry.mode}
end
return M
