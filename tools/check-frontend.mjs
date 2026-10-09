import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, readdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { isDeepStrictEqual } from 'node:util'
import { resolveReference } from './reference.mjs'

const projectRoot = resolve(import.meta.dirname, '..')
const { root, sourceIdentity } = await resolveReference({ projectRoot, referenceRoot: process.env.NM_REFERENCE_ROOT })
const { lex } = await import(pathToFileURL(join(root, 'shaders/src/lang/lexer.js')).href)
const { parse } = await import(pathToFileURL(join(root, 'shaders/src/lang/parser.js')).href)
const corpusRoot = join(projectRoot, 'parity')
const cases = []
function collect(dir, limit = Infinity) {
  let count = 0
  for (const entry of readdirSync(join(corpusRoot, dir), { withFileTypes: true })) {
    if (entry.isFile() && entry.name.endsWith('.dsl') && count < limit) {
      cases.push({ name: `${dir}/${entry.name}`, source: readFileSync(join(corpusRoot, dir, entry.name), 'utf8') })
      count++
    }
  }
}
for (const dir of ['programs', 'curated', 'timed', 'portable', 'coverage']) {
  try { collect(dir) } catch (error) { if (error.code !== 'ENOENT') throw error }
}
for (const [name, source, options] of [
  ['empty', ''],
  ['unicode-column', 'search synth\n//😀\nnoise().write(o0)\nrender(o0)'],
  ['bad-astral', 'search synth\n😀'],
  ['out-of-range', 'search synth\nnoise().write(o8)'],
  ['array', 'search synth\nnoise(scale: [1,2,3]).write(o0) render(o0)'],
  ['subchain-strict', 'search synth\nnoise().subchain(name: "x" id: "y") { .blur() }.write(o0) render(o0)', { subchainArguments: 'strict' }],
  ['subchain-warning', 'search synth\nnoise().subchain(name: "x" id: "y") { .blur() }.write(o0) render(o0)'],
  ['midi-audio', 'search synth\nnoise(speed: midi(1, min: 0.1), seed: audio(audioBand.low, channel: 1, name: "mic")).write(o0) render(o0)'],
  ['triple-string', 'search synth\nnoise(label: """a\nb""").write(o0) render(o0)'],
]) cases.push({ name, source, options })
const expressions = [
  ['3', {}], ['Math.sin(time) * 4 + 5', {time: 0.25}], ['seed + 1', {seed: 9}],
  ['time % 10', {time: 23.5}], ['frame % 2 > 0', {frame: 3}],
  ['mouse.x', {mouse: {x: 0.75}}], ['resolution[0] / 2', {resolution: [257, 129]}],
  ['time > 1 ? 1 : 0', {time: 2}], ['Math.floor(time)', {time: 1.75}],
  ['state.time', {time: 1.25}], ['time > 1 && frame < 10', {time: 2, frame: 8}],
  ['!b1', {b1: false}], ['typeof time', {time: 2}], ['void 0', {}],
  ['state.b1 === false ? 7 : 2', {b1: false}], ['typeof b1', {b1: false}],
  ['state.items[0] === false', {items: [false]}],
  ['state.b1 === true ? 7 : 2', {b1: true}], ['typeof b1', {b1: true}],
  ['state.b1 === undefined ? 7 : 2', {}], ['typeof b1', {}],
  ['state.b1 === 0 ? 7 : 2', {b1: 0}], ['typeof b1', {b1: 0}],
  ["state.b1 === '' ? 7 : 2", {b1: ''}], ['typeof b1', {b1: ''}],
  ['state.items[0] === true', {items: [true]}],
  ['state.items[0] === undefined', {items: []}],
  ['state.items[0] === 0', {items: [0]}],
  ["state.items[0] === ''", {items: ['']}],
  ['time ** 2', {time: 2.5}], ['(time ?? frame) || seed', {time: null, frame: 0, seed: 5}],
  ['(-time) ** 2', {time: 3}], ['time /* block */ + 1', {time: 2}],
]
for (const [expression, state] of expressions) cases.push({name: `expression/${expression}`, expression, state})
const jsonClone = value => JSON.parse(JSON.stringify(value))
const reference = cases.map(({ source, options, expression, state }) => {
  if (expression) {
    try { const value = new Function('state', `with(state){ return ${expression}; }`)(state); return {ok: true, value: value === undefined ? {$type: 'undefined'} : jsonClone(value)} }
    catch (error) { return {ok: false, error: String(error)} }
  }
  let tokens
  try { tokens = lex(source) } catch (error) {
    return { ok: false, stage: 'lexer', error: jsonClone(error.diagnostic ?? { message: String(error) }) }
  }
  const publicTokens = tokens.map(token => ({ type: token.type, lexeme: token.lexeme, line: token.line, col: token.col, position: token.position }))
  try {
    return { ok: true, tokens: publicTokens, ast: jsonClone(parse(tokens, options ?? {})) }
  } catch (error) {
    return { ok: false, stage: 'parser', tokens: publicTokens, error: jsonClone(error.diagnostic ?? { message: String(error) }) }
  }
})
const temp = mkdtempSync(join(tmpdir(), 'nm-love-frontend-'))
try {
  const input = join(temp, 'input.json')
  const output = join(temp, 'output.json')
  writeFileSync(input, JSON.stringify(cases.map(({ source, options, expression, state }) => ({ source, options, expression, state }))))
  execFileSync(process.env.LOVE_BIN ?? 'love', ['tests/compiler'], {
    cwd: projectRoot, env: { ...process.env, NM_FRONTEND_INPUT: input, NM_FRONTEND_OUTPUT: output }, stdio: 'inherit'
  })
  const actual = JSON.parse(readFileSync(output, 'utf8'))
  if (actual.length !== cases.length) throw new Error(`Candidate produced ${actual.length} of ${cases.length} cases`)
  function diffPath(a, b, path = '') {
    if (isDeepStrictEqual(a, b)) return null
    if (a && b && typeof a === 'object' && typeof b === 'object') {
      for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) {
        const nested = diffPath(a[key], b[key], `${path}/${key}`)
        if (nested) return nested
      }
    }
    return `${path}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`
  }
  let errors = 0
  for (let i = 0; i < cases.length; i++) {
    if (!isDeepStrictEqual(actual[i], reference[i])) {
      console.error(`MISMATCH ${cases[i].name}`)
      console.error(diffPath(reference[i], actual[i]).slice(0, 1000)); if (cases[i].expression) console.error(JSON.stringify(actual[i]))
      errors++
      if (errors >= 12) break
    }
  }
  console.log(`FRONTEND-DIFFERENTIAL ${JSON.stringify({ reference: sourceIdentity.revision, cases: cases.length, errors })}`)
  if (errors) process.exitCode = 1
} finally { rmSync(temp, { recursive: true, force: true }) }
