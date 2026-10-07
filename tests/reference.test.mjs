import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import test from 'node:test'

import {
  assertLockedReference,
  encodePortable,
  hashReferenceFiles,
  listReferenceSourceFiles,
  loadReferenceLock,
  resolveReference
} from '../tools/reference.mjs'
import { exportReference } from '../tools/export-reference.mjs'

const projectRoot = resolve(import.meta.dirname, '..')
const upstreamRoot = process.env.NM_REFERENCE_ROOT ? resolve(process.env.NM_REFERENCE_ROOT) : undefined

function git(root, ...args) {
  return execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim()
}

async function fixtureRepository(fn) {
  const root = mkdtempSync(join(tmpdir(), 'love-reference-test-'))
  try {
    git(root, 'init', '-b', 'main')
    git(root, 'config', 'user.email', 'test@example.invalid')
    git(root, 'config', 'user.name', 'Reference test')
    mkdirSync(join(root, 'shaders', 'src'), { recursive: true })
    mkdirSync(join(root, 'shaders', 'effects', 'synth', 'solid'), { recursive: true })
    writeFileSync(join(root, 'shaders', 'src', 'compiler.js'), 'export const revision = 1\n')
    writeFileSync(join(root, 'shaders', 'effects', 'synth', 'solid', 'main.frag'), 'void main() {}\n')
    git(root, 'add', '.')
    git(root, 'commit', '-m', 'fixture')
    return await fn(root, git(root, 'rev-parse', 'HEAD'))
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

test('wrong locked commit is refused before reading reference source', () => fixtureRepository((root) => {
  assert.throws(() => assertLockedReference(root, { commit: '0'.repeat(40) }), /locked commit/i)
}))

test('dirty tracked source is refused even at the locked commit', () => fixtureRepository((root, commit) => {
  writeFileSync(join(root, 'shaders', 'src', 'compiler.js'), 'export const revision = 2\n')
  assert.throws(() => assertLockedReference(root, { commit }), /dirty/i)
}))

test('source inventory uses authority-relative paths and content hashes', () => fixtureRepository((root, commit) => {
  const files = listReferenceSourceFiles(root)
  assert.deepEqual(files, ['shaders/effects/synth/solid/main.frag', 'shaders/src/compiler.js'])
  const hashes = hashReferenceFiles(root, files)
  assert.equal(hashes['shaders/src/compiler.js'], createHash('sha256').update('export const revision = 1\n').digest('hex'))
  assert.equal(assertLockedReference(root, { commit }).revision, commit)
}))

test('fallback materializes the locked tree without a working checkout', async () => {
  await fixtureRepository(async (root) => {
    writeFileSync(join(root, 'package.json'), '{"type":"module"}\n')
    writeFileSync(join(root, 'LICENSE'), 'MIT License\nFixture copyright\n')
    mkdirSync(join(root, 'share'))
    writeFileSync(join(root, 'share', 'palettes.json'), '{"fixture":[1,2,3]}\n')
    git(root, 'add', 'package.json', 'LICENSE', 'share/palettes.json')
    git(root, 'commit', '-m', 'package metadata')
    const commit = git(root, 'rev-parse', 'HEAD')
    const project = mkdtempSync(join(tmpdir(), 'love-reference-lock-'))
    mkdirSync(join(project, 'parity'))
    const repository = 'https://github.com/example/reference-fallback'
    writeFileSync(join(project, 'parity', 'reference.json'), JSON.stringify({ repository, commit }))
    const previous = [process.env.GIT_CONFIG_COUNT, process.env.GIT_CONFIG_KEY_0, process.env.GIT_CONFIG_VALUE_0]
    process.env.GIT_CONFIG_COUNT = '1'
    process.env.GIT_CONFIG_KEY_0 = `url.file://${root}.insteadOf`
    process.env.GIT_CONFIG_VALUE_0 = repository
    try {
      const resolved = await resolveReference({ projectRoot: project, referenceRoot: '' })
      assert.equal(resolved.sourceIdentity.revision, commit)
      assert.equal(resolved.sourceIdentity.sourceSha256, assertLockedReference(root, { commit }).sourceSha256)
      assert.equal(existsSync(join(resolved.root, '.git')), false)
      assert.equal(readFileSync(join(resolved.root, 'LICENSE'), 'utf8'), readFileSync(join(root, 'LICENSE'), 'utf8'))
      assert.ok(resolved.sourceIdentity.files.LICENSE)
      assert.equal(readFileSync(join(resolved.root, 'share', 'palettes.json'), 'utf8'), '{"fixture":[1,2,3]}\n')
      assert.ok(resolved.sourceIdentity.files['share/palettes.json'])
      assert.equal(existsSync(join(resolved.root, '..', 'authority.git')), false)
      const again = await resolveReference({ projectRoot: project, referenceRoot: '' })
      assert.equal(again.root, resolved.root)
      writeFileSync(join(resolved.root, 'shaders', 'src', 'compiler.js'), 'export const revision = 2\n')
      await assert.rejects(resolveReference({ projectRoot: project, referenceRoot: '' }), /cached reference source changed/i)
      rmSync(resolve(resolved.root, '..'), { recursive: true, force: true })
    } finally {
      for (const [key, value] of [['GIT_CONFIG_COUNT', previous[0]], ['GIT_CONFIG_KEY_0', previous[1]], ['GIT_CONFIG_VALUE_0', previous[2]]]) {
        if (value === undefined) delete process.env[key]
        else process.env[key] = value
      }
      rmSync(project, { recursive: true, force: true })
    }
  })
})

test('portable encoding preserves maps, missing, non-finite values, and insertion order', () => {
  const encoded = encodePortable(new Map([['first', undefined], ['second', NaN], ['third', null]]))
  assert.deepEqual(encoded, {
    $type: 'map',
    entries: [
      ['first', { $type: 'undefined' }],
      ['second', { $type: 'number', value: 'NaN' }],
      ['third', null]
    ]
  })
  class Unsupported { constructor() { this.value = 1 } }
  assert.throws(() => encodePortable(new Unsupported()), /Unsupported portable object/)
})

test('reference export is deterministic and includes independent compiler stages', async () => {
  const lock = loadReferenceLock(projectRoot)
  const { sourceIdentity } = await resolveReference({ projectRoot, referenceRoot: upstreamRoot })
  assert.equal(sourceIdentity.revision, lock.commit)
  assert.equal(sourceIdentity.dirty, false)
  const manifest = JSON.parse(readFileSync(join(projectRoot, 'tests', 'fixtures', 'manifest.json'), 'utf8'))
  const first = await exportReference({ projectRoot, referenceRoot: upstreamRoot, manifest })
  const second = await exportReference({ projectRoot, referenceRoot: upstreamRoot, manifest })
  assert.deepEqual(first, second)
  assert.equal(first.authority.revision, lock.commit)
  assert.equal(first.cases.length, manifest.cases.length)
  const solid = first.cases.find(item => item.id === 'solid-red')
  assert.equal(solid.status, 'compiled')
  assert.equal(solid.stages.lex[0].type, 'SEARCH')
  assert.ok(solid.stages.parse)
  assert.ok(solid.stages.validate.plans.length)
  assert.ok(solid.stages.expand.passes.length)
  assert.equal(solid.stages.graph.source, manifest.cases.find(item => item.id === 'solid-red').source)
  assert.equal(solid.stages.graph.allocations.$type, 'map')
  assert.deepEqual(solid.capture, {
    width: 257, height: 129, backend: 'webgl2', target: 'o0',
    frame: 0, frames: 1, time: 0, deltaTime: 1 / 60, seed: 1, reset: true, inputs: []
  })
  assert.ok(first.sourceInventory.some(file => file.path === 'shaders/effects/synth/solid/definition.js'))
  assert.ok(first.sourceInventory.some(file => file.path === 'share/palettes.json'))
  assert.equal(first.cases.find(item => item.id === 'unknown-effect').refusal.stage, 'validate')
  const unicode = first.cases.find(item => item.id === 'utf16-source')
  assert.equal(unicode.status, 'compiled')
  assert.equal(unicode.stages.lex.find(token => token.type === 'SEARCH').position.start, 6)
})

test('missing locked effect is an exporter failure, not a DSL refusal', async () => {
  const manifest = {
    version: 1,
    cases: [{ id: 'missing-source', effects: ['synth/nonexistent'], source: 'search synth\nsolid()', capture: null }]
  }
  await assert.rejects(exportReference({ projectRoot, referenceRoot: upstreamRoot, manifest }), /Effect absent from locked manifest/)
})

test('CLI rejects unknown arguments instead of silently exporting', () => {
  assert.throws(() => execFileSync('node', ['tools/export-reference.mjs', '--unknown'], {
    cwd: projectRoot,
    env: { ...process.env, ...(upstreamRoot ? { NM_REFERENCE_ROOT: upstreamRoot } : {}) },
    stdio: 'pipe'
  }), /Usage: node tools\/export-reference\.mjs/)
})
