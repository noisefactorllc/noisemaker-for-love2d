import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { resolveReference } from '../tools/reference.mjs'
import test from 'node:test'

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const referenceRoot = (await resolveReference({ projectRoot })).root
const generatedRoot = join(projectRoot, 'noisemaker/catalog')
const run = (...args) => spawnSync(process.execPath, ['tools/import-catalog.mjs', ...args], {
  cwd: projectRoot,
  env: { ...process.env },
  encoding: 'utf8',
})

async function sourceDefinitions() {
  const base = join(referenceRoot, 'shaders/effects')
  const result = {}
  for (const namespace of readdirSync(base).sort()) {
    const nsDir = join(base, namespace)
    if (!statSync(nsDir).isDirectory()) continue
    for (const name of readdirSync(nsDir).sort()) {
      const path = join(nsDir, name, 'definition.js')
      if (!existsSync(path)) continue
      const exported = (await import(pathToFileURL(path).href)).default
      const instance = typeof exported === 'function' ? new exported() : exported
      result[`${namespace}/${name}`] = JSON.parse(JSON.stringify(instance))
    }
  }
  return result
}

test('generated catalog is fresh against the locked authority', () => {
  const result = run('--check')
  assert.equal(result.status, 0, result.stderr || result.stdout)
})

test('generated definitions preserve every upstream own data value', async () => {
  const actual = JSON.parse(readFileSync(join(generatedRoot, 'definitions.json'), 'utf8'))
  const expected = await sourceDefinitions()
  assert.deepEqual(actual, expected)
  assert.deepEqual(actual['synth/remap'].globals.zone0_tex.default, 'none')
})

test('inventory counts all shader stages and identifies feature owners', () => {
  const inventory = JSON.parse(readFileSync(join(generatedRoot, 'inventory.json'), 'utf8'))
  assert.deepEqual(inventory.counts.shaderExtensions, { frag: 8, glsl: 301, vert: 8 })
  assert.equal(inventory.counts.definitions, 210)
  assert.equal(inventory.sources.length, 317)
  assert.equal(inventory.effects['synth/remap'].features.uniformBlock, true)
  assert.equal(inventory.effects['filter/median'].features.halfPacking, true)
  assert.deepEqual(inventory.byFeature.halfPacking, ['filter/median'])
  assert.equal(inventory.effects['render/meshRender'].features.vertexId, true)
  assert.equal(inventory.effects['render/meshRender'].features.vertexTexelFetch, true)
  assert.equal(inventory.effects['points/lenia'].features.vertexPointSize, true)
  assert.equal(inventory.effects['synth3d/heightmap3d'].features.computePassType, true)
  assert.equal(inventory.effects['synth3d/heightmap3d'].features.computeConvention, false)
  assert.equal(inventory.effects['synth3d/heightmap3d'].features.nativeCompute, false)
  assert.equal(inventory.effects['synth/remap'].features.volumeTexture, false)
  assert.equal(inventory.portableRequirements.volumeTexture, true)
  assert.deepEqual(inventory.unownedSources, ['shaders/effects/filter/_shared/glsl/overlayBlend.glsl'])
})

test('freshness check rejects changed generated Lua without editing the catalog', () => {
  const temporaryRoot = mkdtempSync(join(tmpdir(), 'nm-catalog-check-'))
  try {
    for (const name of ['definitions.json', 'definitions.lua', 'inventory.json']) {
      copyFileSync(join(generatedRoot, name), join(temporaryRoot, name))
    }
    const path = join(temporaryRoot, 'definitions.lua')
    writeFileSync(path, `${readFileSync(path, 'utf8')}\n-- stale\n`)
    const result = run('--check', '--output-root', temporaryRoot)
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /definitions\.lua/)
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true })
  }
})

test('native compute, storage buffers, cube and integer samplers are rejected', async () => {
  const { shaderFeatures, rejectUnexpected } = await import('../tools/import-catalog.mjs')
  for (const [source, field] of [
    ['layout(local_size_x = 8) in; void main() {}', 'nativeCompute'],
    ['layout(std430) buffer Pixels { vec4 pixels[]; };', 'storageBuffer'],
    ['uniform samplerCube environment;', 'cubeSampler'],
    ['uniform isampler2D indices;', 'integerSampler'],
  ]) {
    const features = shaderFeatures(source, '.glsl')
    assert.equal(features[field], true, source)
    assert.throws(() => rejectUnexpected('synthetic/effect', features), new RegExp(field))
  }
  assert.equal(shaderFeatures('// uniform samplerCube example\nuniform sampler2D image;', '.glsl').cubeSampler, false)
  assert.equal(shaderFeatures('void main() { gl_Position = vec4(float(gl_VertexID)); gl_PointSize = 2.0; }', '.vert').vertexPointSize, true)
  assert.equal(shaderFeatures('uint bits = packHalf2x16(vec2(0.5));', '.glsl').halfPacking, true)
})

test('compute convention output mapping follows the WebGL2 reference', async () => {
  const { convertComputeConvention } = await import('../tools/import-catalog.mjs')
  assert.equal(convertComputeConvention({ type: 'compute', outputs: { color: 'surface' } }), null)
  assert.deepEqual(convertComputeConvention({ type: 'compute', storageTextures: { state: 'stateTex' } }).outputs, { state: 'stateTex' })
  assert.deepEqual(convertComputeConvention({ type: 'compute', storageTextures: { ignored: 'old' }, outputs: { outputBuffer: 'next', geo: 'normal' } }).outputs, { color: 'next', geo: 'normal' })
})

test('definition validation refuses values that JSON or Lua would silently change', async () => {
  const { requireData } = await import('../tools/import-catalog.mjs')
  assert.throws(() => requireData({ negativeZero: -0 }, 'fixture'), /negative zero/)
  assert.throws(() => requireData({ missing: undefined }, 'fixture'), /unsupported undefined/)
  const sparse = new Array(2)
  sparse[1] = 'value'
  assert.throws(() => requireData(sparse, 'fixture'), /sparse array/)
  const decorated = ['value']
  decorated.extra = true
  assert.throws(() => requireData(decorated, 'fixture'), /array properties/)
  const hiddenIndex = ['value']
  Object.defineProperty(hiddenIndex, '0', { enumerable: false })
  assert.throws(() => requireData(hiddenIndex, 'fixture'), /array properties/)
})
