local catalog = require('noisemaker.catalog.definitions')
local count = 0
local function validate(value)
  if type(value) ~= 'table' then
    assert(type(value) == 'string' or type(value) == 'number' or type(value) == 'boolean')
    return
  end
  if value.__nm_type == 'null' then return end
  if value.__nm_type == 'array' then
    assert(type(value.items) == 'table')
    for _, child in ipairs(value.items) do validate(child) end
  elseif value.__nm_type == 'object' then
    assert(type(value.entries) == 'table')
    local seen = {}
    for _, entry in ipairs(value.entries) do
      assert(#entry == 2 and type(entry[1]) == 'string')
      assert(not seen[entry[1]], 'duplicate object key: ' .. entry[1])
      seen[entry[1]] = true
      validate(entry[2])
    end
  else error('unknown catalog value tag: ' .. tostring(value.__nm_type)) end
end
local function get(object, key)
  assert(object.__nm_type == 'object')
  for _, entry in ipairs(object.entries) do
    if entry[1] == key then return entry[2] end
  end
  error('missing catalog key: ' .. key)
end
validate(catalog)
for _, entry in ipairs(catalog.entries) do
  assert(entry[1]:match('^[^/]+/[^/]+$'))
  assert(type(get(entry[2], 'name')) == 'string')
  count = count + 1
end
assert(count > 0)
local solid = get(catalog, 'synth/solid')
assert(get(solid, 'namespace') == 'synth')
assert(get(solid, 'func') == 'solid')
assert(#get(solid, 'state').entries == 0)
local color = get(get(get(solid, 'globals'), 'color'), 'default')
assert(color.__nm_type == 'array' and #color.items == 3)
assert(color.items[1] == 0.5 and color.items[2] == 0.5 and color.items[3] == 0.5)
assert(get(get(get(solid, 'globals'), 'alpha'), 'default') == 1)
print('catalog Lua load and value checks passed: ' .. count .. ' effects')
