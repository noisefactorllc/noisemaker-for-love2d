import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync } from 'node:fs'
import { dirname, extname, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { resolveReference } from './reference.mjs'

const project = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const inventory = JSON.parse(readFileSync(join(project, 'noisemaker/catalog/inventory.json'), 'utf8'))
const destination = join(project, 'noisemaker/shaders/source')
const check = process.argv.includes('--check')
if (process.argv.slice(2).some(arg => arg !== '--check')) throw new Error('Usage: node tools/import-shaders.mjs [--check]')
const reference = check ? null : (await resolveReference({projectRoot:project,referenceRoot:process.env.NM_REFERENCE_ROOT})).root
const digest = bytes => createHash('sha256').update(bytes).digest('hex')
const quote = value => JSON.stringify(value).replace(/[\u0080-\uffff]/g, ch => [...Buffer.from(ch)].map(byte => `\\${String(byte).padStart(3, '0')}`).join(''))
const entries = {}
const wanted = new Set()
for (const item of inventory.sources) {
  if (!item.path.startsWith('shaders/effects/') || !/\.(glsl|vert|frag)$/.test(item.path)) throw new Error(`Invalid inventory source ${item.path}`)
  const suffix = item.path.slice('shaders/effects/'.length)
  if (suffix.split('/').includes('..')) throw new Error(`Invalid source path ${suffix}`)
  const target = join(destination, suffix)
  wanted.add(target)
  if (check) {
    if (!existsSync(target)) throw new Error(`Generated shader missing: ${target}`)
    const bytes = readFileSync(target)
    if (bytes.length !== item.bytes || digest(bytes) !== item.sha256) throw new Error(`Generated shader differs: ${target}`)
  } else {
    const bytes = readFileSync(join(reference, item.path))
    if (bytes.length !== item.bytes || digest(bytes) !== item.sha256) throw new Error(`Locked source mismatch: ${item.path}`)
    mkdirSync(dirname(target), { recursive: true })
    if (!existsSync(target) || !readFileSync(target).equals(bytes)) writeFileSync(target, bytes)
  }
  const parts = suffix.split('/')
  const extension = extname(parts.at(-1)).slice(1)
  const program = parts.at(-1).slice(0, -(extension.length + 1))
  const effect = parts.slice(0, -2).join('/')
  const key = `${effect}/${program}`
  entries[key] ??= {effect, program, files: {}}
  if (entries[key].files[extension]) throw new Error(`Duplicate shader stage: ${key}.${extension}`)
  entries[key].files[extension] = {path: `noisemaker/shaders/source/${suffix}`, sha256: item.sha256, bytes: item.bytes}
}
const sorted = Object.fromEntries(Object.entries(entries).sort(([a], [b]) => a.localeCompare(b, 'en')))
const manifest = {schema: 1, authority: inventory.authority, sourceCount: inventory.sources.length, programCount: Object.keys(sorted).length, programs: sorted}
const json = JSON.stringify(manifest, null, 2) + '\n'
function luaValue(value) {
  if (value === null) return 'nil'
  if (typeof value === 'string') return quote(value)
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  if (Array.isArray(value)) return `{${value.map(luaValue).join(',')}}`
  return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b, 'en')).map(([key, child]) => `[${quote(key)}]=${luaValue(child)}`).join(',')}}`
}
const luaSource = 'return ' + luaValue(manifest) + '\n'
for (const [name, contents] of [['manifest.json', json], ['manifest.lua', luaSource]]) {
  const target = join(destination, name)
  wanted.add(target)
  if (check) {
    if (!existsSync(target) || readFileSync(target, 'utf8') !== contents) throw new Error(`Generated manifest differs: ${target}`)
  } else {
    mkdirSync(dirname(target), { recursive: true })
    if (!existsSync(target) || readFileSync(target, 'utf8') !== contents) writeFileSync(target, contents)
  }
}
if (check) {
  function visit(dir) {
    if (!existsSync(dir)) return
    for (const item of readdirSync(dir, {withFileTypes:true})) {
      const path = join(dir, item.name)
      if (item.isDirectory()) visit(path)
      else if (!wanted.has(path)) throw new Error(`Stale generated shader: ${relative(destination, path).split(sep).join('/')}`)
    }
  }
  visit(destination)
}
console.log(`import-shaders: ${inventory.sources.length} byte-identical sources, ${Object.keys(sorted).length} programs${check ? ' verified' : ' written'}`)
