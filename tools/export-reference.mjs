#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

import { encodePortable, resolveReference } from './reference.mjs'

const NORMALIZER_VERSION = 1
const DEFAULT_PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')

function loadModule(root, path) {
  return import(pathToFileURL(join(root, path)).href)
}

function stageError(error) {
  return encodePortable({
    code: error?.code ?? error?.name ?? 'ERR_REFERENCE',
    message: error?.message ?? String(error),
    diagnostics: error?.diagnostics,
    errors: error?.errors,
    diagnostic: error?.diagnostic
  })
}

function validateManifest(manifest) {
  if (manifest?.version !== 1 || !Array.isArray(manifest.cases)) throw new Error('Invalid fixture manifest version or cases')
  const seen = new Set()
  for (const fixture of manifest.cases) {
    if (!/^[a-z0-9][a-z0-9-]*$/.test(fixture.id) || seen.has(fixture.id)) throw new Error(`Invalid or duplicate fixture id: ${fixture.id}`)
    seen.add(fixture.id)
    if (typeof fixture.source !== 'string' || !Array.isArray(fixture.effects)) throw new Error(`Invalid fixture source/effects: ${fixture.id}`)
    for (const effect of fixture.effects) {
      if (!/^[a-zA-Z0-9_-]+\/[a-zA-Z0-9_-]+$/.test(effect)) throw new Error(`Invalid effect id in ${fixture.id}: ${effect}`)
    }
    if (fixture.capture) {
      const capture = fixture.capture
      if (capture.backend !== 'webgl2' || !Number.isInteger(capture.width) || !Number.isInteger(capture.height) || capture.width < 1 || capture.height < 1 ||
          !/^o[0-7]$/.test(capture.target) || !Number.isInteger(capture.frame) || capture.frame < 0 || !Number.isInteger(capture.frames) || capture.frames < 1 ||
          !Number.isFinite(capture.time) || !Number.isFinite(capture.deltaTime) || capture.deltaTime < 0 || !Number.isFinite(capture.seed) ||
          typeof capture.reset !== 'boolean' || !Array.isArray(capture.inputs)) {
        throw new Error(`Invalid WebGL2 capture specification: ${fixture.id}`)
      }
    }
  }
}

async function loadEffects(root, effectIds, reference) {
  const manifest = JSON.parse(readFileSync(join(root, 'shaders', 'effects', 'manifest.json'), 'utf8'))
  const { CanvasRenderer } = reference.canvas
  for (const effectId of effectIds) {
    const [namespace, name] = effectId.split('/')
    const entry = manifest[effectId]
    if (!entry) throw new Error(`Effect absent from locked manifest: ${effectId}`)
    const { default: exported } = await loadModule(root, `shaders/effects/${effectId}/definition.js`)
    const instance = typeof exported === 'function' ? new exported() : exported
    if (!instance.shaders) instance.shaders = {}
    for (const [program, glsl] of Object.entries(entry.glsl || {})) {
      const shader = instance.shaders[program] ?? (instance.shaders[program] = {})
      const base = join(root, 'shaders', 'effects', effectId, 'glsl', program)
      if (glsl === 'combined') shader.glsl = readFileSync(`${base}.glsl`, 'utf8')
      else {
        if (glsl.v) shader.vertex = readFileSync(`${base}.vert`, 'utf8')
        if (glsl.f) shader.fragment = readFileSync(`${base}.frag`, 'utf8')
      }
    }
    const effect = { namespace, name, instance }
    const choices = CanvasRenderer.prototype.registerEffectWithRuntime.call({}, effect)
    if (choices && Object.keys(choices).length) await reference.enums.mergeIntoEnums(choices)
    CanvasRenderer.prototype.registerStarterOpForEffect.call({}, effect)
  }
}

async function compilerModules(root) {
  const [lang, expander, resources, compiler, canvas, enums, stdEnums] = await Promise.all([
    loadModule(root, 'shaders/src/lang/index.js'),
    loadModule(root, 'shaders/src/runtime/expander.js'),
    loadModule(root, 'shaders/src/runtime/resources.js'),
    loadModule(root, 'shaders/src/runtime/compiler.js'),
    loadModule(root, 'shaders/src/renderer/canvas.js'),
    loadModule(root, 'shaders/src/lang/enums.js'),
    loadModule(root, 'shaders/src/lang/std_enums.js')
  ])
  await enums.mergeIntoEnums(stdEnums.stdEnums)
  return { lang, expander, resources, compiler, canvas, enums }
}

async function exportCase(root, fixture, reference) {
  const result = { id: fixture.id, source: fixture.source, effects: [...fixture.effects], capture: fixture.capture ?? null, status: 'compiled', stages: {} }
  let stage = 'effect-loading'
  try {
    await loadEffects(root, fixture.effects, reference)
    stage = 'lex'
    const tokens = reference.lang.lex(fixture.source)
    result.stages.lex = encodePortable(tokens.map(token => ({ ...token, position: token.position ?? null })))
    stage = 'parse'
    const ast = reference.lang.parse(tokens)
    result.stages.parse = encodePortable(ast)
    stage = 'validate'
    const validated = reference.lang.validate(ast)
    result.stages.validate = encodePortable(validated)
    if (validated.diagnostics?.some(item => item.severity === 'error')) {
      result.status = 'refused'
      result.refusal = { stage, diagnostics: encodePortable(validated.diagnostics) }
      return result
    }
    stage = 'expand'
    const expansion = reference.expander.expand(validated)
    result.stages.expand = encodePortable(expansion)
    if (expansion.errors?.length) {
      result.status = 'refused'
      result.refusal = { stage, errors: encodePortable(expansion.errors) }
      return result
    }
    stage = 'allocate'
    result.stages.allocate = encodePortable(reference.resources.allocateResources(expansion.passes))
    stage = 'graph'
    const graph = reference.compiler.compileGraph(fixture.source)
    const { compiledAt: _compiledAt, ...semanticGraph } = graph
    result.stages.graph = encodePortable(semanticGraph)
    return result
  } catch (error) {
    if (stage === 'effect-loading' || !error?.diagnostic && !['ERR_COMPILATION_FAILED', 'ERR_EXPANSION_FAILED'].includes(error?.code) && !(error instanceof SyntaxError)) {
      throw new Error(`Reference export infrastructure failure in ${fixture.id} at ${stage}: ${error?.message ?? String(error)}`, { cause: error })
    }
    result.status = 'refused'
    result.refusal = { stage, error: stageError(error) }
    return result
  }
}

export async function exportReference({ projectRoot = DEFAULT_PROJECT_ROOT, referenceRoot, manifest } = {}) {
  const { root, lock, sourceIdentity } = await resolveReference({ projectRoot, referenceRoot })
  const fixtures = manifest ?? JSON.parse(readFileSync(join(projectRoot, 'tests', 'fixtures', 'manifest.json'), 'utf8'))
  validateManifest(fixtures)
  const reference = await compilerModules(root)
  const cases = []
  for (const fixture of fixtures.cases) cases.push(await exportCase(root, fixture, reference))
  return {
    schemaVersion: 1,
    normalizerVersion: NORMALIZER_VERSION,
    authority: { repository: lock.repository, revision: sourceIdentity.revision, dirty: sourceIdentity.dirty, sourceSha256: sourceIdentity.sourceSha256 },
    sourceInventory: Object.entries(sourceIdentity.files).map(([path, sha256]) => ({ path, sha256 })),
    cases
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  const outIndex = args.indexOf('--out')
  if ((outIndex === -1 && args.length !== 0) || (outIndex !== -1 && (!args[outIndex + 1] || outIndex !== 0 || args.length !== 2))) {
    throw new Error('Usage: node tools/export-reference.mjs [--out FILE]')
  }
  const output = `${JSON.stringify(await exportReference(), null, 2)}\n`
  if (outIndex === -1) process.stdout.write(output)
  else writeFileSync(resolve(args[outIndex + 1]), output)
}
