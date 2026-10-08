-- Analytic coverage for the round-capped line paths used by the CPU overlays.
-- Adapted from Skia's SkStroke, SkStrokerPriv, SkAnalyticEdge, and
-- SkScan_AAAPath. Copyright 2006, 2008, 2016 The Android Open Source Project.
-- Sources: https://hg.mozilla.org/releases/mozilla-release/file/FIREFOX_153_0_RELEASE/gfx/skia/skia/src/core/
-- Firefox's SkUserConfig.h defines SK_RASTERIZE_EVEN_ROUNDING for analytic edges.
-- License: https://skia.googlesource.com/skia/+/refs/heads/main/LICENSE
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

local ffi = require('ffi')
local M = {}
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local sqrt = math.sqrt

local function f32(value) return tonumber(ffi.cast('float', value)) end
local function trunc(value) return value < 0 and ceil(value) or floor(value) end
local function roundEven(value)
  local base = floor(value)
  local part = value - base
  if part > 0.5 or (part == 0.5 and base % 2 ~= 0) then return base + 1 end
  return base
end

-- SkAnalyticEdge's default accuracy is two extra bits over FDot6. Its line
-- endpoints therefore have 1/256 x precision; SnapY uses quarter pixels.
local function edgePoint(x, y)
  return roundEven(x * 256) / 256, floor(roundEven(y * 256) / 64 + 0.5) / 4
end

local FIXED = 65536
local function toFixed(value) return trunc(value * FIXED) end
-- SkAnalyticEdge.cpp's quick_inverse table is the integer quotient of
-- 2^22 / |FDot6|. Reconstructing that quotient avoids carrying 2,049 literals.
local function quickInverse(value)
  if value == 0 then return 0 end
  local result = floor(4194304 / math.abs(value))
  return value < 0 and -result or result
end
local function quickDiv(a, b)
  if math.abs(b) >= 8 and math.abs(b) < 1024 and math.abs(a) < 4096 then
    return floor(a * quickInverse(b) / 64)
  end
  return trunc(a * FIXED / b)
end
local function roundAlpha(height)
  return max(0, min(255, floor((255 * height + 32768) / FIXED)))
end
local function trapAlpha(a, b) return floor((a + b) / 512) end
local function triangleAlpha(a, b)
  return floor(floor(a / 2048) ^ 2 * floor(b / 2048) / 256) % 256
end
local function partialAlpha(alpha, full) return floor(alpha * full / 256) end
local function below(l, r, dy, full)
  local out = {}
  local R = ceil(r / FIXED)
  if R == 1 then
    out[1] = partialAlpha(trapAlpha(l, r), full)
  elseif R > 1 then
    local first, last = FIXED - l, r - (R - 1) * FIXED
    local lastH = floor(last * dy / FIXED)
    out[R] = floor(floor(last * lastH / FIXED) / 512)
    local alpha16 = lastH + floor(dy / 2)
    for i = R - 1, 2, -1 do out[i] = floor(alpha16 / 256) % 256; alpha16 = alpha16 + dy end
    out[1] = full - triangleAlpha(first, dy)
  end
  return out
end
local function above(l, r, dy, full)
  local out = {}
  local R = ceil(r / FIXED)
  if R == 1 then
    out[1] = partialAlpha(floor((2 * FIXED - l - r) / 512), full)
  elseif R > 1 then
    local first, last = FIXED - l, r - (R - 1) * FIXED
    local firstH = floor(first * dy / FIXED)
    out[1] = floor(floor(first * firstH / FIXED) / 512)
    local alpha16 = firstH + floor(dy / 2)
    for i = 2, R - 1 do out[i] = floor(alpha16 / 256) % 256; alpha16 = alpha16 + dy end
    out[R] = full - triangleAlpha(last, dy)
  end
  return out
end

local function trapRow(row, width, ul, ur, ll, lr, ldy, rdy, full)
  if ul > ur then return end
  if ll > lr then
    local mid = (max(ul, ll) + min(ur, lr)) / 2
    ll, lr = mid, mid
  end
  if ul == ur and ll == lr then return end
  if ul > ll then ul, ll = ll, ul end
  if ur > lr then ur, lr = lr, ur end
  local function add(x, value)
    if x >= 0 and x < width and value > 0 then row[x] = min(255, (row[x] or 0) + value) end
  end
  local function single(x, value)
    if full == 255 then row[x] = value else add(x, partialAlpha(value, full)) end
  end
  local function general(a, b, c, d, ady, bdy)
    local L, R = floor(a / FIXED), ceil(d / FIXED)
    if R <= L then return end
    if R == L + 1 then single(L, trapAlpha(b - a, d - c)); return end
    local values = {}
    for x = L, R - 1 do values[x] = full end
    local uL, lL = floor(a / FIXED), ceil(c / FIXED)
    if uL + 2 == lL then
      local first = (uL + 1) * FIXED - a
      local second = c - a - first
      if values[uL] then values[uL] = max(0, values[uL] - (full - triangleAlpha(first, ady))) end
      if values[uL + 1] then values[uL + 1] = max(0, values[uL + 1] - triangleAlpha(second, ady)) end
    else
      local excluded = below(a - uL * FIXED, c - uL * FIXED, ady, full)
      for x = max(uL, L), min(lL - 1, R - 1) do
        values[x] = max(0, values[x] - (excluded[x - uL + 1] or 0))
      end
    end
    local uR, lR = floor(b / FIXED), ceil(d / FIXED)
    if uR + 2 == lR then
      local first = (uR + 1) * FIXED - b
      local second = d - b - first
      if values[R - 2] then values[R - 2] = max(0, values[R - 2] - triangleAlpha(first, bdy)) end
      if values[R - 1] then values[R - 1] = max(0, values[R - 1] - (full - triangleAlpha(second, bdy))) end
    else
      local excluded = above(b - uR * FIXED, d - uR * FIXED, bdy, full)
      for x = max(uR, L), min(lR - 1, R - 1) do
        values[x] = max(0, values[x] - (excluded[x - uR + 1] or 0))
      end
    end
    for x = L, R - 1 do add(x, values[x]) end
  end
  local joinLeft, joinRight = ceil(ll / FIXED) * FIXED, floor(ur / FIXED) * FIXED
  if joinLeft <= joinRight then
    if ul < joinLeft then
      local n = ceil((joinLeft - ul) / FIXED)
      if n == 1 then
        single(floor(ul / FIXED), trapAlpha(joinLeft - ul, joinLeft - ll))
      elseif n == 2 then
        local first = joinLeft - FIXED - ul
        local second = ll - ul - first
        add(floor(ul / FIXED), triangleAlpha(first, ldy))
        add(floor(ul / FIXED) + 1, full - triangleAlpha(second, ldy))
      else
        general(ul, joinLeft, ll, joinLeft, ldy, 2147483647)
      end
    end
    for x = joinLeft / FIXED, joinRight / FIXED - 1 do add(x, full) end
    if lr > joinRight then
      local n = ceil((lr - joinRight) / FIXED)
      if n == 1 then
        single(joinRight / FIXED, trapAlpha(ur - joinRight, lr - joinRight))
      elseif n == 2 then
        local first = joinRight + FIXED - ur
        local second = lr - ur - first
        add(joinRight / FIXED, full - triangleAlpha(first, rdy))
        add(joinRight / FIXED + 1, triangleAlpha(second, rdy))
      else
        general(joinRight, ur, joinRight, lr, 2147483647, rdy)
      end
    end
  else
    general(ul, ur, ll, lr, ldy, rdy)
  end
end

-- SkAnalyticQuadraticEdge converts each stroked-cap conic to a quadratic
-- (the 0.25 tolerance needs no conic subdivision at these radii), then uses
-- biased fixed-point forward differences. Return the snapped edge vertices.
local function quadraticVertices(p0, p1, p2)
  local x0, y0 = roundEven(p0[1] * 256), roundEven(p0[2] * 256)
  local x1, y1 = roundEven(p1[1] * 256), roundEven(p1[2] * 256)
  local x2, y2 = roundEven(p2[1] * 256), roundEven(p2[2] * 256)
  local reverse = y0 > y2
  if reverse then x0, x2 = x2, x0; y0, y2 = y2, y0 end
  local function point(x, y) return {x / 65536, floor(y / 16384 + 0.5) / 4} end
  if floor((y0 + 32) / 64) == floor((y2 + 32) / 64) then
    local a = {edgePoint(p0[1], p0[2])}
    local b = {edgePoint(p2[1], p2[2])}
    return {a, b}
  end
  local ddx = floor((2 * x1 - x0 - x2) / 4)
  local ddy = floor((2 * y1 - y0 - y2) / 4)
  local ax, ay = math.abs(ddx), math.abs(ddy)
  local distance = max(ax, ay) + floor(min(ax, ay) / 2)
  distance = floor((distance + 16) / 32)
  local shift = 1
  if distance > 0 then
    shift = max(1, floor((floor(math.log(distance) / math.log(2)) + 1) / 2))
  end
  shift = min(6, shift)
  local count = 2 ^ shift
  local A = (x0 - 2 * x1 + x2) * 512
  local B = (x1 - x0) * 1024
  local x = x0 * 256
  local dx = floor((B + floor(A / 2 ^ shift)) / 4)
  local ddxFixed = floor(floor(A / 2 ^ (shift - 1)) / 4)
  A = (y0 - 2 * y1 + y2) * 512
  B = (y1 - y0) * 1024
  local y = y0 * 256
  local dy = floor((B + floor(A / 2 ^ shift)) / 4)
  local ddyFixed = floor(floor(A / 2 ^ (shift - 1)) / 4)
  local sx, sy = x, floor((y + 8192) / 16384) * 16384
  -- setQuadratic() snaps fQy before forward differencing. Starting the
  -- differences at the unsnapped input changes which quarter-row a cap hits.
  y = sy
  local vertices = {point(sx, sy)}
  for i = 1, count do
    local nx, ny
    if i < count then
      nx = x + floor(dx / 2 ^ (shift - 1))
      ny = y + floor(dy / 2 ^ (shift - 1))
    else
      nx, ny = x2 * 256, y2 * 256
    end
    local snappedY, snappedX
    if i < count and math.abs(floor(dy / 2 ^ (shift - 1))) >= 2 * FIXED
       and math.abs(dy) * 64 > math.abs(dx) then
      snappedY = min(floor((y2 * 256 + 8192) / 16384) * 16384,
                     floor((ny + 32768) / FIXED) * FIXED)
      local deltaY = floor((ny - sy) / 1024)
      local slope = deltaY ~= 0 and quickDiv(floor((nx - sx) / 1024), deltaY) or 2147483647
      snappedX = nx - floor(slope * (ny - snappedY) / FIXED)
    else
      snappedY = min(floor((y2 * 256 + 8192) / 16384) * 16384,
                     floor((ny + 8192) / 16384) * 16384)
      snappedX = nx
    end
    if snappedY ~= sy then
      vertices[#vertices + 1] = point(snappedX, snappedY)
      sx, sy = snappedX, snappedY
    end
    x, y = nx, ny
    dx, dy = dx + ddxFixed, dy + ddyFixed
  end
  if reverse then
    local ordered = {}
    for i = #vertices, 1, -1 do ordered[#ordered + 1] = vertices[i] end
    return ordered
  end
  return vertices
end

function M.rasterSegment(width, height, x1, y1, x2, y2, lineWidth, emit)
  if lineWidth <= 0 then return end
  x1, y1, x2, y2 = f32(x1), f32(y1), f32(x2), f32(y2)
  if y1 == y2 then
    y1 = floor(y1 * 4 + 0.5) / 4
    y2 = y1
  end
  local dx, dy = f32(x2 - x1), f32(y2 - y1)
  local length = sqrt(dx * dx + dy * dy)
  local ux, uy = 1, 0
  if length > 0 then ux, uy = f32(dx / length), f32(dy / length) end
  local radius = f32(lineWidth * 0.5)
  -- SkStroke::set_normal_unitnormal rotates the tangent counterclockwise in
  -- Skia's screen coordinates: (dx, dy) becomes (dy, -dx).
  local nx, ny = f32(uy * radius), f32(-ux * radius)
  local tx, ty = f32(ux * radius), f32(uy * radius)
  local function p(x, y) return {f32(x), f32(y)} end
  local startBottom, endBottom = p(x1 + nx, y1 + ny), p(x2 + nx, y2 + ny)
  local endOuter, endTop = p(x2 + tx, y2 + ty), p(x2 - nx, y2 - ny)
  local startTop, startOuter = p(x1 - nx, y1 - ny), p(x1 - tx, y1 - ty)
  -- RoundCapper first stores projectedCenter as a SkPoint (float32), then
  -- adds/subtracts normal to form each conic control. That intermediate
  -- rounding also affects SkPathPriv's convexity decision for short lines.
  local endControl1 = p(endOuter[1] + nx, endOuter[2] + ny)
  local endControl2 = p(endOuter[1] - nx, endOuter[2] - ny)
  local startControl1 = p(startOuter[1] - nx, startOuter[2] - ny)
  local startControl2 = p(startOuter[1] + nx, startOuter[2] + ny)
  -- SkPathPriv::ComputeConvexity sees the conic controls as path points. A
  -- stroked two-point path is not necessarily convex after float rounding.
  local function isConvex()
    local points = {startBottom,endBottom,endControl1,endOuter,endControl2,endTop,
                    startTop,startControl1,startOuter,startControl2}
    local signsX, signsY, lastX, lastY = 0, 0, nil, nil
    local first = points[1]
    local previous = first
    for i = 2, #points + 1 do
      local point = points[i] or first
      local dx,dy = f32(point[1]-previous[1]),f32(point[2]-previous[2])
      if dx ~= 0 or dy ~= 0 then
        local sx,sy = dx < 0,dy < 0
        if sx ~= lastX then signsX=signsX+1 end
        if sy ~= lastY then signsY=signsY+1 end
        lastX,lastY=sx,sy
        if signsX > 3 or signsY > 3 then return false end
      end
      previous=point
    end
    local lastVec,firstVec,expected,reversals=nil,nil,nil,0
    previous=first
    for i=2,#points+1 do
      local point=points[i] or first
      local vx,vy=f32(point[1]-previous[1]),f32(point[2]-previous[2])
      if vx~=0 or vy~=0 then
        if not lastVec then lastVec={vx,vy};firstVec=lastVec
        else
          local cross=f32(f32(lastVec[1]*vy)-f32(lastVec[2]*vx))
          if cross==0 then
            if f32(f32(lastVec[1]*vx)+f32(lastVec[2]*vy))<0 then
              reversals=reversals+1
              if reversals>=3 then return false end
              lastVec={vx,vy}
            end
          else
            local direction=cross>0
            if expected~=nil and expected~=direction then return false end
            expected=direction;lastVec={vx,vy}
          end
        end
      end
      previous=point
    end
    if lastVec and firstVec then
      local cross=f32(f32(lastVec[1]*firstVec[2])-f32(lastVec[2]*firstVec[1]))
      if cross~=0 and expected~=nil and expected~=(cross>0) then return false end
    end
    return true
  end
  local convex=isConvex()
  local pathPoints = {startBottom, endBottom, endOuter, endTop, startTop,
                      startOuter, endControl1, endControl2,
                      startControl1, startControl2}
  local boundL,boundR=width,0
  for i=1,#pathPoints do
    boundL=min(boundL,pathPoints[i][1])
    boundR=max(boundR,pathPoints[i][1])
  end
  boundL=max(0,floor(boundL))*FIXED
  boundR=min(width,ceil(boundR))*FIXED
  local clipPath = false
  for i = 1, #pathPoints do
    local point = pathPoints[i]
    if point[1] < 0 or point[1] > width or point[2] < 0 or point[2] > height then
      clipPath = true
      break
    end
  end
  local poly = {}
  local curveSerial = 0
  local function append(point)
    if #poly == 0 or poly[#poly][1] ~= point[1] or poly[#poly][2] ~= point[2] then
      poly[#poly + 1] = point
    end
  end
  local function appendBoundary(x, y)
    local ax, ay = edgePoint(x, y)
    append({ax, ay})
  end
  local function appendQuadUnclipped(a, b, c)
    local function appendOne(u, v, w)
      curveSerial = curveSerial + 1
      local vertices = quadraticVertices(u, v, w)
      for i = 1, #vertices do
        if i > 1 then vertices[i][3] = curveSerial end
        append(vertices[i])
      end
    end
    if (a[2] - b[2]) * (c[2] - b[2]) > 0 then
      local divisor = a[2] - 2 * b[2] + c[2]
      local t = f32((a[2] - b[2]) / divisor)
      if t > 0 and t < 1 then
        local ab = p(a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)
        local bc = p(b[1] + (c[1] - b[1]) * t, b[2] + (c[2] - b[2]) * t)
        local middle = p(ab[1] + (bc[1] - ab[1]) * t,
                         ab[2] + (bc[2] - ab[2]) * t)
        ab[2], bc[2] = middle[2], middle[2]
        appendOne(a, ab, middle)
        appendOne(middle, bc, c)
        return
      end
    end
    appendOne(a, b, c)
  end
  local function lerpPoint(a, b, t)
    return p(a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)
  end
  local function splitQuad(a, b, c, t)
    local ab, bc = lerpPoint(a, b, t), lerpPoint(b, c, t)
    local middle = lerpPoint(ab, bc, t)
    return {a, ab, middle}, {middle, bc, c}
  end
  local function appendQuad(a, b, c)
    if not clipPath then appendQuadUnclipped(a, b, c); return end
    -- SkEdgeClipper chops a quadratic at Y, then X extrema before clipping it. A
    -- control point outside the canvas therefore changes the AA edge even
    -- when the visible curve itself lies completely within the canvas.
    local pieces = {{a, b, c}}
    local function chopExtrema(input, coordinate)
      local output = {}
      for i = 1, #input do
        local piece = input[i]
        local p0, p1, p2 = piece[1][coordinate], piece[2][coordinate],
                           piece[3][coordinate]
        if (p0 - p1) * (p2 - p1) > 0 then
          local t = f32((p0 - p1) / (p0 - 2 * p1 + p2))
          if t > 0 and t < 1 then
            local first, second = splitQuad(piece[1], piece[2], piece[3], t)
            first[2][coordinate] = first[3][coordinate]
            second[2][coordinate] = second[1][coordinate]
            output[#output + 1], output[#output + 2] = first, second
          else output[#output + 1] = piece end
        else output[#output + 1] = piece end
      end
      return output
    end
    pieces = chopExtrema(pieces, 2)
    local function clipInY(piece, bound, insideGreater)
      local first, last = piece[1], piece[3]
      local firstInside = insideGreater and first[2] >= bound or
                          not insideGreater and first[2] <= bound
      local lastInside = insideGreater and last[2] >= bound or
                         not insideGreater and last[2] <= bound
      if firstInside and lastInside then return piece end
      if not firstInside and not lastInside then return nil end
      local lo, hi = 0, 1
      for _ = 1, 24 do
        local mid = (lo + hi) * 0.5
        local mt = (1 - mid) * (1 - mid) * first[2] +
                   2 * (1 - mid) * mid * piece[2][2] + mid * mid * last[2]
        if (mt < bound) == (first[2] < last[2]) then lo = mid else hi = mid end
      end
      local before, after = splitQuad(piece[1], piece[2], piece[3], (lo + hi) * 0.5)
      if firstInside then
        before[3][2] = bound
        if insideGreater then before[2][2] = max(before[2][2], bound)
        else before[2][2] = min(before[2][2], bound) end
        return before
      else
        after[1][2] = bound
        if insideGreater then after[2][2] = max(after[2][2], bound)
        else after[2][2] = min(after[2][2], bound) end
        return after
      end
    end
    local clippedY = {}
    for i = 1, #pieces do
      local piece = clipInY(pieces[i], 0, true)
      if piece then piece = clipInY(piece, height, false) end
      if piece then clippedY[#clippedY + 1] = piece end
    end
    pieces = chopExtrema(clippedY, 1)
    local function appendClipped(piece, bound, insideGreater)
      local first, last = piece[1], piece[3]
      local firstInside = insideGreater and first[1] >= bound or
                          not insideGreater and first[1] <= bound
      local lastInside = insideGreater and last[1] >= bound or
                         not insideGreater and last[1] <= bound
      if not firstInside and not lastInside then
        appendBoundary(bound, first[2])
        appendBoundary(bound, last[2])
        return
      end
      if firstInside and lastInside then
        appendQuadUnclipped(piece[1], piece[2], piece[3])
        return
      end
      local lo, hi = 0, 1
      for _ = 1, 24 do
        local mid = (lo + hi) * 0.5
        local mt = (1 - mid) * (1 - mid) * first[1] +
                   2 * (1 - mid) * mid * piece[2][1] + mid * mid * last[1]
        if (mt < bound) == (first[1] < last[1]) then lo = mid else hi = mid end
      end
      local before, after = splitQuad(piece[1], piece[2], piece[3], (lo + hi) * 0.5)
      before[3][1], after[1][1] = bound, bound
      if firstInside then
        appendQuadUnclipped(before[1], before[2], before[3])
        appendBoundary(bound, after[3][2])
      else
        appendBoundary(bound, before[1][2])
        appendQuadUnclipped(after[1], after[2], after[3])
      end
    end
    for i = 1, #pieces do
      local piece = pieces[i]
      if piece[1][1] < 0 or piece[3][1] < 0 then
        appendClipped(piece, 0, true)
      elseif piece[1][1] > width or piece[3][1] > width then
        appendClipped(piece, width, false)
      else
        appendQuadUnclipped(piece[1], piece[2], piece[3])
      end
    end
  end
  local function appendLine(a, b)
    if not clipPath then
      local ax, ay = edgePoint(a[1], a[2]); append({ax, ay})
      ax, ay = edgePoint(b[1], b[2]); append({ax, ay})
      return
    end
    local first, last = {a[1], a[2]}, {b[1], b[2]}
    if max(first[2], last[2]) <= 0 or min(first[2], last[2]) >= height then return end
    local function clipY(point, other, bound)
      local t = (bound - point[2]) / (other[2] - point[2])
      return {f32(point[1] + t * (other[1] - point[1])), bound}
    end
    if first[2] < 0 then first = clipY(first, last, 0)
    elseif first[2] > height then first = clipY(first, last, height) end
    if last[2] < 0 then last = clipY(last, first, 0)
    elseif last[2] > height then last = clipY(last, first, height) end
    local function appendRaw(point)
      local ax, ay = edgePoint(point[1], point[2])
      append({ax, ay})
    end
    local function clipX(point, other, bound)
      local t = (bound - point[1]) / (other[1] - point[1])
      return {bound, f32(point[2] + t * (other[2] - point[2]))}
    end
    local firstBound = first[1] < 0 and 0 or first[1] > width and width
    local lastBound = last[1] < 0 and 0 or last[1] > width and width
    if firstBound then
      appendRaw({firstBound, first[2]})
      if not lastBound or firstBound ~= lastBound then
        appendRaw(clipX(first, last, firstBound))
      end
    else appendRaw(first) end
    if lastBound then
      if not firstBound or firstBound ~= lastBound then
        appendRaw(clipX(last, first, lastBound))
      end
      appendRaw({lastBound, last[2]})
    else appendRaw(last) end
  end
  appendLine(startBottom, endBottom)
  appendQuad(endBottom, endControl1, endOuter)
  appendQuad(endOuter, endControl2, endTop)
  appendLine(endTop, startTop)
  appendQuad(startTop, startControl1, startOuter)
  appendQuad(startOuter, startControl2, startBottom)
  local top = max(0, floor(min(y1, y2) - radius - 1))
  local bottom = min(height - 1, ceil(max(y1, y2) + radius + 1))
  local events = {}
  for y = top, bottom + 1 do events[#events + 1] = y end
  for i = 1, #poly do
    local y = poly[i][2]
    if y > top and y < bottom + 1 then events[#events + 1] = y end
  end
  table.sort(events)
  -- aaa_walk_edges advances by a quarter row first when the next edge or
  -- integer boundary lies three quarter rows away (the low quarter bit is
  -- tested before the half bit). A single three-quarter trapezoid takes the
  -- convex fast path instead and produces different coverage.
  local scanEvents = {}
  for i = 1, #events - 1 do
    local a, b = events[i], events[i + 1]
    scanEvents[#scanEvents + 1] = a
    if b - a == 0.75 then scanEvents[#scanEvents + 1] = a + 0.25 end
  end
  scanEvents[#scanEvents + 1] = events[#events]
  events = scanEvents
  local edges = {}
  local previous = poly[#poly]
  for i = 1, #poly do
    local current = poly[i]
    if current[2] ~= previous[2] then
      local low, high = previous, current
      if low[2] > high[2] then low, high = high, low end
      local x0, y0, x1f, y1f = toFixed(low[1]), toFixed(low[2]), toFixed(high[1]), toFixed(high[2])
      local dotDx = floor((x1f - x0) / 1024)
      local dotDy = floor((y1f - y0) / 1024)
      -- setLine() rejects edges whose height vanishes after FDot6 rounding.
      if dotDy ~= 0 then
        local slope = quickDiv(dotDx, dotDy)
        -- setLine tests the 16.16 slope directly. updateLine, used for each
        -- quadratic segment, first converts it to FDot6 for this lookup.
        local absSlope = math.abs(current[3] and floor(slope / 1024) or slope)
        local inv = (dotDx == 0 or slope == 0) and 2147483647
          or (absSlope < 1024 and quickInverse(absSlope) or math.abs(quickDiv(dotDy, dotDx)))
        edges[#edges + 1] = {x0=x0, y0=y0, x1=x1f, y1=y1f, slope=slope, inv=inv,
                             curveId=current[3]}
      end
    end
    previous = current
  end
  -- SkScan_AAAPath::insert_new_edges schedules an extra quarter row when
  -- newly adjacent edges would reverse X order over the next full pixel.
  -- A vertex-only event list would merge those two trapezoids and change the
  -- coarse partial-triangle coverage by several alpha levels.
  local crossingEvents = {}
  for i = 1, #events - 1 do
    local y, nextY = events[i], events[i + 1]
    if nextY > y + 0.25 then
      local fixedY = toFixed(y)
      local active = {}
      for j = 1, #edges do
        local edge = edges[j]
        if edge.y0 <= fixedY and edge.y1 > fixedY then
          local x = edge.x0 + floor(edge.slope * (fixedY - edge.y0) / FIXED)
          active[#active + 1] = {edge = edge, x = x}
        end
      end
      table.sort(active, function(a, b) return a.x < b.x end)
      for j = 1, #active - 1 do
        local left, right = active[j], active[j + 1]
        if (left.edge.y0 == fixedY or right.edge.y0 == fixedY) and
           left.x + left.edge.slope > right.x + right.edge.slope then
          crossingEvents[#crossingEvents + 1] = y + 0.25
          break
        end
      end
    end
  end
  for i = 1, #crossingEvents do events[#events + 1] = crossingEvents[i] end
  table.sort(events)
  -- A quadratic's next edge starts from the X reached by rasterizing its
  -- previous edge, not the ideal forward-difference vertex. This is Skia's
  -- keepContinuous() step; the small fixed-point change can alter quick_div.
  local curves = {}
  for i = 1, #edges do
    local edge = edges[i]
    if edge.curveId then
      local group = curves[edge.curveId]
      if not group then group = {}; curves[edge.curveId] = group end
      group[#group + 1] = edge
    end
  end
  for _, group in pairs(curves) do
    table.sort(group, function(a, b) return a.y0 < b.y0 end)
    for i = 2, #group do group[i].previousCurve = group[i - 1] end
  end
  local rows = {}
  local function edgeX(edge, y)
    return edge.x0 + floor(edge.slope * (toFixed(y) - edge.y0) / FIXED)
  end
  if convex then
    -- aaa_walk_convex_edges rounds X to sixteenths. At a smooth transition it
    -- extends the current edge to the next integer Y; its mask bounds clip
    -- the extrapolated side. Constant-X pairs take the rectangle fast path.
    local ordered={}
    for i=1,#edges do ordered[i]=edges[i] end
    table.sort(ordered,function(a,b)
      if a.y0~=b.y0 then return a.y0<b.y0 end
      if a.x0~=b.x0 then return a.x0<b.x0 end
      return a.slope<b.slope
    end)
    local y=ordered[1] and max(toFixed(top),ordered[1].y0) or toFixed(bottom+1)
    while y<toFixed(bottom+1) do
      local active={}
      for i=1,#ordered do
        local e=ordered[i]
        if e.y0<=y and e.y1>y then active[#active+1]=e end
      end
      if #active<2 then
        local nextY=toFixed(bottom+1)
        for i=1,#ordered do if ordered[i].y0>y then nextY=min(nextY,ordered[i].y0) end end
        if nextY<=y then break end
        y=nextY
      else
        table.sort(active,function(a,b)
          local ax,bx=edgeX(a,y/FIXED),edgeX(b,y/FIXED)
          if ax~=bx then return ax<bx end
          return a.slope<b.slope
        end)
        local left,right=active[1],active[#active]
        local limit=min(left.y1,right.y1)
        local upcoming={}
        for i=1,#ordered do
          local e=ordered[i]
          if e.y0>=limit and e.y0<limit+FIXED then upcoming[#upcoming+1]=e end
        end
        table.sort(upcoming,function(a,b)return a.x0<b.x0 end)
        if #upcoming>=2 and math.abs(left.y1-right.y1)<=FIXED and
           math.abs(left.slope-upcoming[1].slope)<=FIXED and
           math.abs(right.slope-upcoming[#upcoming].slope)<=FIXED and
           upcoming[1].y1-upcoming[1].y0>=FIXED and
           upcoming[#upcoming].y1-upcoming[#upcoming].y0>=FIXED then
          limit=ceil(limit/FIXED)*FIXED
        end
        limit=min(limit,toFixed(bottom+1))
        if limit<=y then break end
        local here=y
        while here<limit do
          local nextY=min(limit,(floor(here/FIXED)+1)*FIXED)
          local rowY=floor(here/FIXED)
          if rowY>=0 and rowY<height then
            if not rows[rowY] then rows[rowY]={} end
            if left.slope==0 and right.slope==0 then
              local lx,rx=edgeX(left,here/FIXED),edgeX(right,here/FIXED)
              for x=max(0,floor(lx/FIXED)),min(width-1,ceil(rx/FIXED)-1) do
                local covered=max(0,min(rx,(x+1)*FIXED)-max(lx,x*FIXED))
                local alpha=roundAlpha(floor(covered*(nextY-here)/FIXED))
                if nextY-here==FIXED then rows[rowY][x]=alpha
                else rows[rowY][x]=min(255,(rows[rowY][x] or 0)+alpha) end
              end
            else
              local function snapX(v)return floor((v+2048)/4096)*4096 end
              trapRow(rows[rowY],width,
                snapX(max(boundL,edgeX(left,here/FIXED))),snapX(min(boundR,edgeX(right,here/FIXED))),
                snapX(max(boundL,edgeX(left,nextY/FIXED))),snapX(min(boundR,edgeX(right,nextY/FIXED))),
                left.inv,right.inv,roundAlpha(nextY-here))
            end
          end
          here=nextY
        end
        y=limit
      end
    end
  else
  local function edgeStateX(edge, target)
    if edge.cursorY == nil then
      local predecessor = edge.previousCurve
      if predecessor and predecessor.cursorY == edge.y0 then
        edge.x0 = predecessor.cursorX
        local dotDx = floor((edge.x1 - edge.x0) / 1024)
        local dotDy = floor((edge.y1 - edge.y0) / 1024)
        edge.slope = quickDiv(dotDx, dotDy)
        local absSlope = math.abs(floor(edge.slope / 1024))
        edge.inv = (dotDx == 0 or edge.slope == 0) and 2147483647
          or (absSlope < 1024 and quickInverse(absSlope) or math.abs(quickDiv(dotDy, dotDx)))
      end
      edge.cursorY, edge.cursorX = edge.y0, edge.x0
    end
    local fixedTarget = toFixed(target)
    local delta = fixedTarget - edge.cursorY
    if delta ~= 0 then
      if delta == FIXED then edge.cursorX = edge.cursorX + edge.slope
      elseif delta == FIXED / 2 then edge.cursorX = edge.cursorX + floor(edge.slope / 2)
      elseif delta == FIXED / 4 then edge.cursorX = edge.cursorX + floor(edge.slope / 4)
      else edge.cursorX = edge.x0 + floor(edge.slope * (fixedTarget - edge.y0) / FIXED) end
      edge.cursorY = fixedTarget
    end
    return edge.cursorX
  end
  for i = 1, #events - 1 do
    local a, b = events[i], events[i + 1]
    if b > a then
      local mid = toFixed((a + b) * 0.5)
      local active = {}
      for j = 1, #edges do
        local edge = edges[j]
        if mid >= edge.y0 and mid < edge.y1 then
          active[#active + 1] = edge
        end
      end
      if #active >= 2 then
        table.sort(active, function(e1, e2) return edgeX(e1, (a + b) * 0.5) < edgeX(e2, (a + b) * 0.5) end)
        local left, right = active[1], active[#active]
        local y = floor((a + b) * 0.5)
        if not rows[y] then rows[y] = {} end
        -- aaa_walk_edges clips both positions of each boundary edge before
        -- rasterizing the row. An edge may cross the clip between these Ys.
        trapRow(rows[y], width,
          max(boundL, edgeStateX(left, a)), min(boundR, edgeStateX(right, a)),
          max(boundL, edgeStateX(left, b)), min(boundR, edgeStateX(right, b)),
          left.inv, right.inv, roundAlpha(toFixed(b - a)))
      end
    end
  end
  end
  for y = top, bottom do
    local row = rows[y]
    if row then
      for x, alpha in pairs(row) do
        if x >= 0 and x < width and alpha > 0 then emit(x, y, alpha) end
      end
    end
  end
end

return M
