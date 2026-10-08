local nm = require('noisemaker')

local M = {}
local Session = {}
Session.__index = Session

function M.new(width, height)
  return setmetatable({width=width,height=height,renderer=nil,canvas=nil,source=nil,diagnostics=nil},Session)
end

function Session:replace(source, frame)
  local graph, diagnostics = nm.compile(source)
  if not graph then self.diagnostics=diagnostics; return nil,diagnostics end
  local candidate
  candidate, diagnostics = nm.newRenderer(graph,{width=self.width,height=self.height})
  if not candidate then self.diagnostics=diagnostics; return nil,diagnostics end
  local canvas
  canvas, diagnostics = candidate:render(frame or {time=0})
  if not canvas then candidate:release(); self.diagnostics=diagnostics; return nil,diagnostics end
  local previous=self.renderer
  self.renderer=candidate
  self.canvas=canvas
  self.source=source
  self.diagnostics=nil
  if previous then previous:release() end
  return canvas
end

function Session:render(frame)
  if not self.renderer then return nil,self.diagnostics end
  local canvas, diagnostics=self.renderer:render(frame)
  if canvas then self.canvas=canvas;self.diagnostics=nil
  else self.diagnostics=diagnostics end
  return canvas,diagnostics
end

function Session:resize(width,height)
  if self.renderer then
    local ok,diagnostics=self.renderer:resize(width,height)
    if not ok then self.diagnostics=diagnostics;return nil,diagnostics end
    self.canvas=nil
  end
  self.width=width;self.height=height
  return true
end

function Session:release()
  if self.renderer then self.renderer:release();self.renderer=nil end
  self.canvas=nil
  return true
end

return M
