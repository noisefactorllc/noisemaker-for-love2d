local compiler = require('noisemaker.compiler.init')
local renderer = require('noisemaker.runtime.renderer')
local registry = require('noisemaker.catalog.registry')

return {
  compile = compiler.compile,
  newRenderer = renderer.new,
  registerEffect = registry.registerEffect,
}
