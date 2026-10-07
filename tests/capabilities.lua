package.path = './?.lua;./?/init.lua;' .. package.path
local capabilities = require('noisemaker.runtime.capabilities')

local function equal(actual, expected, label)
  assert(actual == expected, (label or 'value') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end

local events = {}
local fake = {
  graphics = {
    push = function(mode) equal(mode, 'all'); events[#events + 1] = 'push' end,
    pop = function() events[#events + 1] = 'pop' end,
  },
  getVersion = function() return 11, 5, 0, 'Mysterious Mysteries' end,
  system = { getOS = function() return 'OS X' end },
}

local report = capabilities.run(fake, {
  {name = 'success', run = function(scope)
    scope:own({release = function() events[#events + 1] = 'release' end})
    return {pixels = 2}
  end},
  {name = 'failure', run = function(scope)
    scope:own({release = function() events[#events + 1] = 'failure-release' end})
    error('pixel mismatch')
  end},
  {name = 'unsupported', run = function(scope) scope:unsupported('missing format') end},
})
equal(report.probes.success.status, 'pass')
equal(report.probes.failure.status, 'fail')
equal(report.probes.unsupported.status, 'unsupported')
equal(report.counts.pass, 1)
equal(report.counts.fail, 1)
equal(report.counts.unsupported, 1)
equal(table.concat(events, ','), 'push,pop,release,push,pop,failure-release,push,pop')
local json = capabilities.json(report)
assert(json:find('"failure"', 1, true))
assert(json:find('pixel mismatch', 1, true))
assert(not json:find('"status":"pass","reason":"missing format"', 1, true))
local released = false
local brokenPop = {graphics = {
  push = function() end,
  pop = function() error('pop failed') end,
}}
local restoration = capabilities.run(brokenPop, {{name = 'restore_error', run = function(scope)
  scope:own({release = function() released = true end})
  return {pixels = 1}
end}})
equal(restoration.probes.restore_error.status, 'fail')
assert(restoration.probes.restore_error.reason:find('graphics state restoration', 1, true))
assert(released, 'resource must be released even when graphics.pop fails')
assert(not restoration.ok)
print('capabilities CPU tests passed')
