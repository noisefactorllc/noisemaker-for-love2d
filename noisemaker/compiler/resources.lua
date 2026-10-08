local registry = require('noisemaker.catalog.registry')
local M = {}

local function values(object)
  local result = {}
  for _, key in ipairs(registry.keys(object)) do result[#result + 1] = object[key] end
  return result
end

function M.analyzeLiveness(passes)
  local lifetime = {}
  local function touch(id, index)
    if type(id) ~= 'string' or id:sub(1, 7) == 'global_' then return end
    local span = lifetime[id]
    if not span then lifetime[id] = {start = index, ['end'] = index}
    else
      if index < span.start then span.start = index end
      if index > span['end'] then span['end'] = index end
    end
  end
  for i, pass in ipairs(passes) do
    for _, id in ipairs(values(pass.inputs)) do touch(id, i - 1) end
    for _, id in ipairs(values(pass.outputs)) do touch(id, i - 1) end
  end
  return lifetime
end

function M.allocateResources(passes)
  local lifetime = M.analyzeLiveness(passes)
  local allocations, free, physicalCount = {}, {}, 0
  for i, pass in ipairs(passes) do
    local index = i - 1
    for _, id in ipairs(values(pass.outputs)) do
      if type(id) == 'string' and id:sub(1, 7) ~= 'global_' and not allocations[id] then
        local freeIndex
        for j, slot in ipairs(free) do
          if slot.availableAfter < index then freeIndex = j; break end
        end
        if freeIndex then
          allocations[id] = table.remove(free, freeIndex).id
        else
          allocations[id] = 'phys_' .. physicalCount
          physicalCount = physicalCount + 1
        end
      end
    end
    local seen = {}
    for _, id in ipairs(values(pass.inputs)) do
      if type(id) == 'string' and id:sub(1, 7) ~= 'global_' and not seen[id] then
        seen[id] = true
        local span = lifetime[id]
        if span and span['end'] == index and allocations[id] then
          free[#free + 1] = {id = allocations[id], availableAfter = index}
        end
      end
    end
  end
  return allocations
end

return M
