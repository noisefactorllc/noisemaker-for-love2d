local M = {}

local digits = '0123456789abcdefghijklmnopqrstuvwxyz'
local function base36(value)
  if value == 0 then return '0' end
  local negative = value < 0
  if negative then value = -value end
  local parts = {}
  while value > 0 do
    local remainder = value % 36
    parts[#parts+1] = digits:sub(remainder+1,remainder+1)
    value = math.floor(value/36)
  end
  local result = ''
  for i=#parts,1,-1 do result=result..parts[i] end
  return negative and '-'..result or result
end

local function utf16units(source)
  local i = 1
  return function()
    if i > #source then return nil end
    local b1 = source:byte(i)
    local cp, width
    if b1 < 0x80 then cp=b1; width=1
    elseif b1 >= 0xc2 and b1 <= 0xdf then
      local b2=source:byte(i+1)
      assert(b2 and b2 >= 0x80 and b2 <= 0xbf,'invalid UTF-8 source')
      cp=(b1-0xc0)*64+b2-0x80; width=2
    elseif b1 >= 0xe0 and b1 <= 0xef then
      local b2,b3=source:byte(i+1,i+2)
      assert(b2 and b3 and b2>=0x80 and b2<=0xbf and b3>=0x80 and b3<=0xbf,'invalid UTF-8 source')
      cp=(b1-0xe0)*4096+(b2-0x80)*64+b3-0x80; width=3
      assert(cp>=0x800 and not (cp>=0xd800 and cp<=0xdfff),'invalid UTF-8 source')
    elseif b1 >= 0xf0 and b1 <= 0xf4 then
      local b2,b3,b4=source:byte(i+1,i+3)
      assert(b2 and b3 and b4 and b2>=0x80 and b2<=0xbf and b3>=0x80 and b3<=0xbf and b4>=0x80 and b4<=0xbf,'invalid UTF-8 source')
      cp=(b1-0xf0)*262144+(b2-0x80)*4096+(b3-0x80)*64+b4-0x80; width=4
      assert(cp>=0x10000 and cp<=0x10ffff,'invalid UTF-8 source')
    else error('invalid UTF-8 source') end
    i=i+width
    if cp <= 0xffff then return cp end
    local supplementary=cp-0x10000
    local high=0xd800+math.floor(supplementary/0x400)
    local low=0xdc00+supplementary%0x400
    local previous=i
    return high,low,previous
  end
end

function M.hashSource(source)
  return require('noisemaker.compiler.values').hashSource(source)
end

function M.extractTextureSpecs(passes, options, effectSpecs)
  local textures={}
  for id, effect in pairs(effectSpecs or {}) do
    local spec={width=effect.width or 'screen',height=effect.height or 'screen',format=effect.format or 'rgba16f',
      usage={'render','sample','copySrc','copyDst'}}
    if effect.is3D then
      spec.depth=effect.depth or effect.width or 64
      spec.is3D=true
      spec.usage={'storage','sample','copySrc','copyDst'}
      if effect.filter then spec.filter=effect.filter end
    else
      if effect.mipmaps~=nil then spec.mipmaps=effect.mipmaps end
      if effect.persistent~=nil then spec.persistent=effect.persistent end
    end
    textures[id]=spec
  end
  for _,pass in ipairs(passes or {}) do
    for _,id in pairs(pass.outputs or {}) do
      if type(id)=='string' and id:sub(1,7)~='global_' and not textures[id] then
        textures[id]={width='screen',height='screen',format='rgba16f',usage={'render','sample','copySrc','copyDst'}}
      end
    end
  end
  return textures
end

return M
