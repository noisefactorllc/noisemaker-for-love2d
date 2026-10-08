local lexer = require('noisemaker.compiler.lexer')
local parser = require('noisemaker.compiler.parser')
local validator = require('noisemaker.compiler.validator')
local expander = require('noisemaker.compiler.expander')
local resources = require('noisemaker.compiler.resources')
local normalize = require('noisemaker.compiler.normalize')

local M = {}

local function fail(stage, err)
  if type(err)=='table' and err.diagnostic then return {err.diagnostic} end
  return {{stage=stage,severity='error',code=type(err)=='table' and err.code or 'ERR_'..stage:upper(),
    message=type(err)=='table' and err.message or tostring(err)}}
end

function M.compile(source,options)
  options=options or {}
  local ok,tokens=pcall(lexer.lex,source)
  if not ok then return nil,fail('lexer',tokens) end
  local ast
  ok,ast=pcall(parser.parse,tokens)
  if not ok then return nil,fail('parser',ast) end
  local validated
  ok,validated=pcall(validator.validate,ast)
  if not ok then return nil,fail('semantic',validated) end
  for _,item in ipairs(validated.diagnostics or {}) do
    if item.severity=='error' then return nil,validated.diagnostics end
  end
  local expansion
  ok,expansion=pcall(expander.expand,validated,options)
  if not ok then return nil,fail('expansion',expansion) end
  if expansion.errors and #expansion.errors>0 then
    local diagnostics={}
    for _,item in ipairs(expansion.errors) do
      diagnostics[#diagnostics+1]={stage='expansion',severity='error',code='ERR_EXPANSION_FAILED',message=item.message,step=item.step}
    end
    return nil,diagnostics
  end
  local graph={id=normalize.hashSource(source),source=source,passes=expansion.passes,programs=expansion.programs,
    allocations=resources.allocateResources(expansion.passes),
    textures=normalize.extractTextureSpecs(expansion.passes,options,expansion.textureSpecs),
    renderSurface=expansion.renderSurface,mediaSteps=expansion.mediaSteps}
  return graph,validated.diagnostics
end

M.lex=lexer.lex
M.parse=parser.parse
M.validate=validator.validate
M.expand=expander.expand
M.allocateResources=resources.allocateResources
M.hashSource=normalize.hashSource
return M
