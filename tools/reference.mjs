import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const DEFAULT_PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const SOURCE_PREFIXES = ['shaders/src/', 'shaders/effects/', 'share/meshes/']
const SOURCE_FILES = new Set(['shaders/manifest.json', 'package.json', 'LICENSE', 'share/palettes.json'])
const archiveCache = new Map()

process.once('exit', () => {
  for (const cached of archiveCache.values()) rmSync(cached.cache, { recursive: true, force: true })
})

function git(root, args) {
  return execFileSync('git', args, { cwd: root, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 }).trim()
}

export function loadReferenceLock(projectRoot = DEFAULT_PROJECT_ROOT) {
  const lock = JSON.parse(readFileSync(join(projectRoot, 'parity', 'reference.json'), 'utf8'))
  if (!/^https:\/\/github\.com\/[\w-]+\/[\w-]+$/.test(lock.repository) || !/^[0-9a-f]{40}$/.test(lock.commit)) {
    throw new Error('Invalid reference lock: expected repository URL and full commit SHA')
  }
  return lock
}

export function listReferenceSourceFiles(root) {
  return git(root, ['ls-files', '--cached', '--full-name', '-z']).split('\0')
    .filter(path => path && (SOURCE_PREFIXES.some(prefix => path.startsWith(prefix)) || SOURCE_FILES.has(path)))
    .sort()
}

export function hashReferenceFiles(root, paths) {
  const hashes = {}
  const canonicalRoot = realpathSync(root)
  for (const path of paths) {
    if (path.startsWith('/') || path.split('/').includes('..')) throw new Error(`Invalid authority-relative path: ${path}`)
    const absolute = join(root, path)
    if (!existsSync(absolute)) throw new Error(`Missing locked source: ${path}`)
    if (lstatSync(absolute).isSymbolicLink()) throw new Error(`Symlink authority source is unsupported: ${path}`)
    const inside = relative(canonicalRoot, realpathSync(absolute))
    if (inside.startsWith('..') || inside.startsWith('/')) throw new Error(`Authority source escapes checkout: ${path}`)
    hashes[path] = createHash('sha256').update(readFileSync(absolute)).digest('hex')
  }
  return hashes
}

export function assertLockedReference(root, lock) {
  const revision = git(root, ['rev-parse', 'HEAD'])
  if (revision !== lock.commit) throw new Error(`Reference is at ${revision}, not locked commit ${lock.commit}`)
  const status = git(root, ['status', '--porcelain', '--untracked-files=all'])
  if (status) throw new Error(`Reference checkout is dirty at locked commit ${lock.commit}: ${status.split('\n')[0]}`)
  const files = listReferenceSourceFiles(root)
  const hashes = hashReferenceFiles(root, files)
  const digest = createHash('sha256')
  for (const path of files) digest.update(`${path}\0${hashes[path]}\n`)
  return { revision, dirty: false, fileCount: files.length, sourceSha256: digest.digest('hex'), files: hashes }
}

export async function resolveReference({ projectRoot = DEFAULT_PROJECT_ROOT, referenceRoot = process.env.NM_REFERENCE_ROOT } = {}) {
  const lock = loadReferenceLock(projectRoot)
  let root = referenceRoot && resolve(referenceRoot)
  let sourceIdentity
  if (!root) {
    const cacheKey = `${lock.repository}\0${lock.commit}`
    const cached = archiveCache.get(cacheKey)
    if (cached && existsSync(cached.root)) {
      try {
        const actual = hashReferenceFiles(cached.root, Object.keys(cached.sourceIdentity.files))
        for (const [path, expected] of Object.entries(cached.sourceIdentity.files)) {
          if (actual[path] !== expected) throw new Error(`content mismatch: ${path}`)
        }
      } catch (error) {
        throw new Error(`Cached reference source changed: ${error.message}`, { cause: error })
      }
      return { root: cached.root, lock, sourceIdentity: structuredClone(cached.sourceIdentity) }
    }
    const cache = mkdtempSync(join(tmpdir(), 'noisemaker-locked-reference-'))
    const bare = join(cache, 'authority.git')
    root = join(cache, 'source')
    try {
      mkdirSync(root)
      execFileSync('git', ['clone', '--quiet', '--bare', lock.repository, bare], { stdio: 'pipe' })
      const revision = git(bare, ['rev-parse', lock.commit])
      if (revision !== lock.commit) throw new Error(`Locked commit unavailable: ${lock.commit}`)
      const treePaths = git(bare, ['ls-tree', '-r', '--name-only', '-z', lock.commit]).split('\0').filter(Boolean)
      const archivePaths = ['LICENSE', 'package.json', 'shaders/src', 'shaders/effects', 'share/palettes.json', 'share/meshes']
        .filter(path => treePaths.some(file => file === path || file.startsWith(path + '/')))
      const treeEntries = git(bare, ['ls-tree', '-r', '-z', lock.commit, '--', ...archivePaths]).split('\0')
      if (treeEntries.some(entry => entry.startsWith('120000 '))) throw new Error('Locked source archive contains a symlink')
      const archive = execFileSync('git', [`--git-dir=${bare}`, 'archive', lock.commit, ...archivePaths], { maxBuffer: 128 * 1024 * 1024 })
      execFileSync('tar', ['-xf', '-', '-C', root], { input: archive, env: { ...process.env, LC_ALL: 'C' } })
      const files = treePaths.filter(path => SOURCE_PREFIXES.some(prefix => path.startsWith(prefix)) || SOURCE_FILES.has(path)).sort()
      const hashes = hashReferenceFiles(root, files)
      const digest = createHash('sha256')
      for (const path of files) digest.update(`${path}\0${hashes[path]}\n`)
      sourceIdentity = { revision, dirty: false, fileCount: files.length, sourceSha256: digest.digest('hex'), files: hashes }
      rmSync(bare, { recursive: true, force: true })
      archiveCache.set(cacheKey, { cache, root, sourceIdentity })
    } catch (error) {
      rmSync(cache, { recursive: true, force: true })
      throw error
    }
  } else {
    sourceIdentity = assertLockedReference(root, lock)
    const checkout = root
    const cacheKey = `${checkout}\0${lock.repository}\0${lock.commit}`
    const cached = archiveCache.get(cacheKey)
    if (cached && existsSync(cached.root)) {
      const hashes = hashReferenceFiles(cached.root, Object.keys(sourceIdentity.files))
      if (JSON.stringify(hashes) !== JSON.stringify(sourceIdentity.files)) throw new Error('Cached reference source changed')
      return {root:cached.root,lock,sourceIdentity}
    }
    const cache = mkdtempSync(join(tmpdir(), 'noisemaker-locked-reference-'))
    root = join(cache, 'source')
    try {
      mkdirSync(root)
      const archive = execFileSync('git', ['-C',checkout,'archive',lock.commit,...Object.keys(sourceIdentity.files)], {maxBuffer:128*1024*1024})
      execFileSync('tar',['-xf','-','-C',root],{input:archive,env:{...process.env,LC_ALL:'C'}})
      const hashes = hashReferenceFiles(root,Object.keys(sourceIdentity.files))
      if (JSON.stringify(hashes)!==JSON.stringify(sourceIdentity.files)) throw new Error('Locked archive differs from clean source identity')
      archiveCache.set(cacheKey,{cache,root,sourceIdentity})
    } catch (error) {
      rmSync(cache,{recursive:true,force:true})
      throw error
    }
  }
  return { root, lock, sourceIdentity }
}

export function encodePortable(value, seen = new WeakSet()) {
  if (value === undefined) return { $type: 'undefined' }
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value
  if (typeof value === 'number') {
    if (Number.isNaN(value)) return { $type: 'number', value: 'NaN' }
    if (value === Infinity) return { $type: 'number', value: 'Infinity' }
    if (value === -Infinity) return { $type: 'number', value: '-Infinity' }
    if (Object.is(value, -0)) return { $type: 'number', value: '-0' }
    return value
  }
  if (typeof value === 'bigint') return { $type: 'bigint', value: String(value) }
  if (typeof value === 'function') return { $type: 'function', source: String(value) }
  if (typeof value !== 'object') throw new Error(`Unsupported portable value: ${typeof value}`)
  if (seen.has(value)) throw new Error('Circular reference value cannot be exported')
  seen.add(value)
  let encoded
  if (Array.isArray(value)) encoded = value.map(item => encodePortable(item, seen))
  else if (value instanceof Map) encoded = { $type: 'map', entries: [...value].map(([key, item]) => [encodePortable(key, seen), encodePortable(item, seen)]) }
  else if (value instanceof Set) encoded = { $type: 'set', values: [...value].map(item => encodePortable(item, seen)) }
  else if (value instanceof Date) encoded = { $type: 'date', value: value.toISOString() }
  else if (value instanceof RegExp) encoded = { $type: 'regexp', source: value.source, flags: value.flags }
  else {
    const prototype = Object.getPrototypeOf(value)
    if (prototype !== Object.prototype && prototype !== null) throw new Error(`Unsupported portable object: ${value.constructor?.name ?? 'unknown'}`)
    encoded = Object.fromEntries(Object.entries(value).map(([key, item]) => [key, encodePortable(item, seen)]))
  }
  seen.delete(value)
  return encoded
}
