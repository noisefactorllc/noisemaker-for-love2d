import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { dirname, extname, join, relative, resolve, sep } from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { resolveReference } from './reference.mjs'

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const defaultOutputRoot = join(projectRoot, 'noisemaker/catalog')
const shaderExtensions = new Set(['.glsl', '.vert', '.frag'])
const nativeComputeExtensions = new Set(['.comp', '.compute'])
const outputNames = ['definitions.json', 'definitions.lua', 'inventory.json']

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function sourcePaths(root) {
  const base = join(root, 'shaders/effects')
  const paths = []
  function visit(dir) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name)
      if (entry.isDirectory()) visit(path)
      else if (entry.isFile()) paths.push(relative(root, path).split(sep).join('/'))
    }
  }
  visit(base)
  return paths.sort()
}

export function requireData(value, where, seen = new Set()) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error(`${where}: non-finite number cannot be imported`)
    if (Object.is(value, -0)) throw new Error(`${where}: negative zero cannot be represented in JSON`)
    return
  }
  if (typeof value !== 'object') throw new Error(`${where}: unsupported ${typeof value} in definition data`)
  if (seen.has(value)) throw new Error(`${where}: cyclic definition data`)
  if (!Array.isArray(value) && Object.getPrototypeOf(value) !== Object.prototype && Object.getPrototypeOf(value) !== null) {
    throw new Error(`${where}: unsupported ${value.constructor?.name || 'object'} in definition data`)
  }
  if (Object.getOwnPropertySymbols(value).length) throw new Error(`${where}: symbol keys cannot be imported`)
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index++) {
      if (!Object.hasOwn(value, index)) throw new Error(`${where}: sparse array cannot be imported`)
    }
    if (Object.getOwnPropertyNames(value).length !== value.length + 1 || Object.keys(value).length !== value.length) {
      throw new Error(`${where}: extra array properties cannot be imported`)
    }
  } else if (Object.getOwnPropertyNames(value).length !== Object.keys(value).length) {
    throw new Error(`${where}: non-enumerable properties cannot be imported`)
  }
  seen.add(value)
  for (const [key, child] of Object.entries(value)) requireData(child, `${where}.${key}`, seen)
  seen.delete(value)
}

function luaString(value) {
  let result = '"'
  for (const byte of Buffer.from(value, 'utf8')) {
    if (byte === 34 || byte === 92) result += `\\${String.fromCharCode(byte)}`
    else if (byte >= 32 && byte <= 126) result += String.fromCharCode(byte)
    else result += `\\${String(byte).padStart(3, '0')}`
  }
  return `${result}"`
}

function luaValue(value) {
  if (value === null) return '{ __nm_type = "null" }'
  if (typeof value === 'string') return luaString(value)
  if (typeof value === 'boolean') return String(value)
  if (typeof value === 'number') return Object.is(value, -0) ? '-0.0' : String(value)
  if (Array.isArray(value)) return `{ __nm_type = "array", items = { ${value.map(luaValue).join(', ')} } }`
  return `{ __nm_type = "object", entries = { ${Object.entries(value).map(([key, child]) => `{ ${luaString(key)}, ${luaValue(child)} }`).join(', ')} } }`
}

function stripComments(source) {
  return source.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, ' ')
}

export function shaderFeatures(source, extension) {
  const code = stripComments(source)
  return {
    uniformBlock: /\buniform\s+\w+\s*\{/.test(code),
    halfPacking: /\b(?:packHalf2x16|unpackHalf2x16)\s*\(/.test(code),
    vertexId: extension === '.vert' && /\bgl_VertexID\b/.test(code),
    vertexTexelFetch: extension === '.vert' && /\btexelFetch\s*\(/.test(code),
    vertexPointSize: extension === '.vert' && /\bgl_PointSize\b/.test(code),
    volumeTexture: /\bsampler3D\b/.test(code),
    cubeSampler: /\bsamplerCube(?:Array|Shadow)?\b/.test(code),
    integerSampler: /\b(?:i|u)sampler\w+\b/.test(code),
    nativeCompute: nativeComputeExtensions.has(extension) || /\b(?:gl_GlobalInvocationID|gl_LocalInvocationID|local_size_[xyz])\b/.test(code),
    storageBuffer: /\bbuffer\s+\w+\s*\{|\b(?:imageStore|imageLoad|[iu]?image[123]D)\b/.test(code),
  }
}

function lifecycleMethods(instance) {
  const methods = []
  let proto = Object.getPrototypeOf(instance)
  while (proto && proto.constructor?.name !== 'Effect' && proto !== Object.prototype) {
    for (const name of Object.getOwnPropertyNames(proto)) {
      if (name !== 'constructor' && typeof proto[name] === 'function' && !methods.includes(name)) methods.push(name)
    }
    proto = Object.getPrototypeOf(proto)
  }
  for (const name of ['_configOnInit', '_configOnUpdate', '_configOnDestroy', '_configAsyncInit']) {
    if (typeof instance[name] === 'function' && !methods.includes(name)) methods.push(name)
  }
  return methods.sort()
}

export function convertComputeConvention(pass) {
  if (!pass.storageTextures && !pass.outputs?.outputBuffer) return null
  let outputs = pass.storageTextures ? { ...pass.storageTextures } : {}
  if (pass.outputs) outputs = Object.fromEntries(Object.entries(pass.outputs).map(([key, value]) => [key === 'outputBuffer' ? 'color' : key, value]))
  if (Object.keys(outputs).length === 0) outputs = { color: 'outputTex' }
  return { type: 'render', originalType: 'compute', outputs }
}

function effectFeatures(definition) {
  const passes = Array.isArray(definition.passes) ? definition.passes : []
  return {
    uniformBlock: false,
    halfPacking: false,
    vertexId: false,
    vertexTexelFetch: false,
    vertexPointSize: false,
    computePassType: passes.some(pass => pass.type === 'compute'),
    computeConvention: passes.some(pass => convertComputeConvention(pass) !== null),
    nativeCompute: false,
    storageBuffer: false,
    volumeTexture: Boolean(definition.is3D || definition.textures3d),
    cubeSampler: false,
    integerSampler: false,
    mrt: passes.some(pass => Number(pass.drawBuffers || 0) > 1),
  }
}

export function rejectUnexpected(effectId, features) {
  for (const field of ['nativeCompute', 'storageBuffer', 'cubeSampler', 'integerSampler']) {
    if (features[field]) throw new Error(`${effectId}: unsupported catalog requirement ${field}`)
  }
}

async function buildCatalog(root, lock) {
  const paths = sourcePaths(root)
  const definitionPaths = paths.filter(path => path.endsWith('/definition.js'))
  const shaderPaths = paths.filter(path => shaderExtensions.has(extname(path)) || nativeComputeExtensions.has(extname(path)))
  const definitions = {}
  const effects = {}
  const sources = []
  const shaderCounts = { frag: 0, glsl: 0, vert: 0 }

  for (const path of definitionPaths) {
    const id = path.slice('shaders/effects/'.length, -'/definition.js'.length)
    if (id.split('/').length !== 2) throw new Error(`unexpected definition path: ${path}`)
    const exported = (await import(pathToFileURL(join(root, path)).href)).default
    if (!exported) throw new Error(`${id}: missing default definition export`)
    const instance = typeof exported === 'function' ? new exported() : exported
    if (!instance || typeof instance !== 'object') throw new Error(`${id}: invalid definition export`)
    if (Object.getOwnPropertySymbols(instance).length || Object.getOwnPropertyNames(instance).length !== Object.keys(instance).length) {
      throw new Error(`${id}: non-enumerable or symbol definition fields cannot be imported`)
    }
    const methods = lifecycleMethods(instance)
    // Runtime hooks are source-bound and explicitly identified; the importer
    // transfers own data only. A Lua runtime must port these methods separately.
    const data = Object.fromEntries(Object.entries(instance).filter(([, value]) => typeof value !== 'function'))
    for (const [key, value] of Object.entries(instance)) {
      if (typeof value === 'function' && !methods.includes(key)) methods.push(key)
    }
    requireData(data, id)
    definitions[id] = data
    effects[id] = {
      definition: { path, sha256: sha256(readFileSync(join(root, path))), methods: methods.sort() },
      sources: [],
      webgl2Conversions: (data.passes || []).flatMap((pass, index) => {
        const converted = convertComputeConvention(pass)
        return converted ? [{ passIndex: index, outputs: converted.outputs }] : []
      }),
      features: effectFeatures(data),
    }
  }

  for (const path of shaderPaths) {
    const id = path.slice('shaders/effects/'.length).split('/').slice(0, 2).join('/')
    const owner = effects[id] ? id : null
    const extension = extname(path)
    if (extension in { '.comp': true, '.compute': true }) throw new Error(`${path}: native compute shader source is unsupported`)
    const bytes = readFileSync(join(root, path))
    const features = shaderFeatures(bytes.toString('utf8'), extension)
    const effect = owner ? effects[owner] : null
    if (effect) {
      for (const [feature, present] of Object.entries(features)) if (present) effect.features[feature] = true
      effect.sources.push(path)
    } else if (Object.values(features).some(Boolean)) {
      throw new Error(`${path}: unowned shader has a catalog capability requirement`)
    }
    sources.push({ path, effect: owner, extension: extension.slice(1), bytes: bytes.length, sha256: sha256(bytes) })
    shaderCounts[extension.slice(1)]++
  }

  const byFeature = {}
  for (const [id, effect] of Object.entries(effects)) {
    rejectUnexpected(id, effect.features)
    for (const [feature, enabled] of Object.entries(effect.features)) {
      if (enabled) (byFeature[feature] ??= []).push(id)
    }
  }
  const computeTypePasses = Object.values(definitions).reduce((count, definition) => count + (definition.passes || []).filter(pass => pass.type === 'compute').length, 0)
  const webgl2ConversionPasses = Object.values(effects).reduce((count, effect) => count + effect.webgl2Conversions.length, 0)
  const inventory = {
    schema: 1,
    authority: { repository: lock.repository, commit: lock.commit },
    counts: { definitions: definitionPaths.length, sources: sources.length, shaderExtensions: shaderCounts, computeTypePasses, webgl2ConversionPasses },
    portableRequirements: { volumeTexture: true },
    unownedSources: sources.filter(source => source.effect === null).map(source => source.path),
    effects,
    byFeature,
    sources,
  }
  const definitionJson = `${JSON.stringify(definitions, null, 2)}\n`
  const upstreamLicense = readFileSync(join(root, 'LICENSE'), 'utf8').trimEnd().split('\n').map(line => line ? `-- ${line}` : '--').join('\n')
  const lua = `-- Generated from ${lock.commit}; run node tools/import-catalog.mjs to refresh.\n-- Objects retain key order as entries; arrays retain their type even when empty.\n${upstreamLicense}\nreturn ${luaValue(definitions)}\n`
  return {
    'definitions.json': definitionJson,
    'definitions.lua': lua,
    'inventory.json': `${JSON.stringify(inventory, null, 2)}\n`,
  }
}

async function main() {
  const args = process.argv.slice(2)
  let check = false
  let outputRoot = defaultOutputRoot
  let outputRootSeen = false
  for (let index = 0; index < args.length; index++) {
    if (args[index] === '--check' && !check) check = true
    else if (args[index] === '--output-root' && !outputRootSeen && args[index + 1] && !args[index + 1].startsWith('--')) {
      outputRoot = resolve(args[++index])
      outputRootSeen = true
    } else throw new Error('usage: node tools/import-catalog.mjs [--check] [--output-root DIR]')
  }
  const { root, lock } = await resolveReference({ projectRoot })
  const outputs = await buildCatalog(root, lock)
  if (!check) mkdirSync(outputRoot, { recursive: true })
  const stale = []
  for (const name of outputNames) {
    const path = join(outputRoot, name)
    if (check) {
      if (!existsSync(path) || readFileSync(path, 'utf8') !== outputs[name]) stale.push(name)
    } else writeFileSync(path, outputs[name])
  }
  if (stale.length) throw new Error(`stale catalog files: ${stale.join(', ')}`)
  console.log(`${check ? 'checked' : 'generated'} ${Object.keys(JSON.parse(outputs['definitions.json'])).length} effects and ${JSON.parse(outputs['inventory.json']).sources.length} shader sources`)
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    console.error(error.message)
    process.exitCode = 1
  })
}
