-- Path handling must accept both separators. On Windows, require() joins the parts
-- of a module name with '\', and Node passes file paths with '\'.
local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\]tests[/\\]paths%.lua$')
assert(root, 'cannot locate the repository root from the test chunk name')
local function read(path)
  local file = assert(io.open(path, 'rb'))
  local data = file:read('*a')
  file:close()
  return data
end

-- The shader catalog finds its package root from its own chunk name.
local catalogSource = read(root .. '/noisemaker/shaders/catalog.lua')
for _, chunk in ipairs({
  root .. '/noisemaker/shaders/catalog.lua',
  root .. '/noisemaker\\shaders\\catalog.lua',
}) do
  local catalog = assert(load(catalogSource, '@' .. chunk))()
  local first
  for key in pairs(catalog.manifest.programs) do
    if not first or key < first then first = key end
  end
  local effect, program = first:match('^(.*)/([^/]+)$')
  local entry, err = catalog.get(effect, program)
  assert(entry, 'catalog.get(' .. first .. ') failed for chunk ' .. chunk .. ': ' ..
    tostring(err and err.code) .. ' ' .. tostring(err and err.path))
  assert(type(entry.fragment) == 'string' and #entry.fragment > 0, 'empty shader source for ' .. first)
end

-- The parity runner resolves capture inputs next to its manifest.
local paths = dofile(root .. '/parity/runner/paths.lua')
assert(paths.parent('/work/out/cases.json') == '/work/out')
assert(paths.parent('C:\\work\\out\\cases.json') == 'C:\\work\\out')
assert(paths.parent('C:/work/out\\cases.json') == 'C:/work/out')
assert(paths.parent('C:\\work\\out/cases.json') == 'C:\\work\\out')
assert(paths.parent('cases.json') == '.')
print('path separator checks passed')
