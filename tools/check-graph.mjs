#!/usr/bin/env node
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { isDeepStrictEqual } from 'node:util'
import { exportReference } from './export-reference.mjs'

const projectRoot = resolve(import.meta.dirname, '..')
const coverageIndex = process.argv.indexOf('--coverage')
const variantIndex = process.argv.indexOf('--variants')
let manifest
if (coverageIndex >= 0 || variantIndex >= 0) {
  const supplied = process.argv[(variantIndex >= 0 ? variantIndex : coverageIndex) + 1]
  const limit = supplied == null ? Infinity : Number(supplied)
  if (limit !== Infinity && (!Number.isInteger(limit) || limit < 1)) throw new Error('Usage: --coverage POSITIVE_COUNT')
  const definitions = JSON.parse(readFileSync(join(projectRoot, 'noisemaker/catalog/definitions.json'), 'utf8'))
  const directory = join(projectRoot, 'parity/coverage')
  const files = readdirSync(directory).filter(name => name.endsWith('.dsl')).sort()
  const cases = []
  const ids = Object.keys(definitions)
  const selected = variantIndex >= 0 ? files : ids.map(id => {
    const prefix = id.replace('/', '_')
    const file = files.find(file => file === `${prefix}.dsl`)
    if (!file) throw new Error(`Missing default coverage for ${id}`)
    return file
  }).filter(Boolean)
  for (const name of selected) {
    const source = readFileSync(join(directory, name), 'utf8')
    const called = new Set([...source.matchAll(/\b([A-Za-z][A-Za-z0-9_]*)\s*\(/g)].map(match => match[1]))
    const effects = ids.filter(candidate => called.has(definitions[candidate].func))
    cases.push({ id: `coverage-${cases.length}`, source, effects })
    if (cases.length >= limit) break
  }
  manifest = { version: 1, cases }
}
if (process.argv.includes('--upstream')) {
  manifest = {version:1,cases:readdirSync(join(projectRoot,'parity/upstream')).filter(name=>name.endsWith('.json')).sort().map(name=>{
    const fixture=JSON.parse(readFileSync(join(projectRoot,'parity/upstream',name),'utf8'))
    return {id:'upstream-'+name.slice(0,-5).replaceAll('_','-').toLowerCase(),source:fixture.dsl,effects:fixture.effects}
  })}
}
if (process.argv.includes('--corpus')) {
  const definitions=JSON.parse(readFileSync(join(projectRoot,'noisemaker/catalog/definitions.json')))
  manifest={version:1,cases:['programs','curated','timed'].flatMap(family=>readdirSync(join(projectRoot,'parity',family)).filter(name=>name.endsWith('.dsl')).sort().map(name=>{
    const source=readFileSync(join(projectRoot,'parity',family,name),'utf8')
    const called=new Set([...source.matchAll(/\b([A-Za-z][A-Za-z0-9_]*)\s*\(/g)].map(match=>match[1]))
    return {id:family+'-'+name.slice(0,-4).replaceAll('_','-').toLowerCase(),source,effects:Object.keys(definitions).filter(id=>called.has(definitions[id].func))}
  }))}
}
const reference = await exportReference({ projectRoot, referenceRoot: process.env.NM_REFERENCE_ROOT, manifest })
const directory = mkdtempSync(join(tmpdir(), 'nm-love-graph-'))

function unmap(value) {
  if (Array.isArray(value)) return value.map(unmap)
  if (!value || typeof value !== 'object') return value
  if (value.$type === 'map') return Object.fromEntries(value.entries.map(([key, item]) => [key, unmap(item)]))
  const result = {}
  for (const [key, item] of Object.entries(value)) result[key] = unmap(item)
  return result
}

function firstDiff(expected, actual, path = '', probeValue = false) {
  if (probeValue && typeof expected === 'number' && typeof actual === 'number' && Math.abs(expected-actual)<=1e-12*Math.max(1,Math.abs(expected),Math.abs(actual))) return null
  if (expected?.$type==='functionProbe' || actual?.$type==='functionProbe') {
    if(expected?.$type!==actual?.$type)return `${path}: function probe type differs`
    if(expected.evaluations.length!==actual.evaluations.length)return `${path}: function probe count differs`
    for(let index=0;index<expected.evaluations.length;index++){
      const left=expected.evaluations[index],right=actual.evaluations[index]
      if(left.status==='threw'||right.status==='threw')return `${path}/evaluations/${index}: callback threw (${left.error||'reference returned'} / ${right.error||'native returned'})`
      const difference=firstDiff(left.value,right.value,`${path}/evaluations/${index}/value`,true)
      if(difference)return difference
    }
    return null
  }
  if (isDeepStrictEqual(expected, actual)) return null
  if (typeof expected === 'string' && typeof actual === 'string') {
    let at = 0
    while (at < Math.min(expected.length, actual.length) && expected[at] === actual[at]) at++
    return `${path}: string offset ${at}, lengths ${expected.length}/${actual.length}, ${JSON.stringify(expected.slice(at, at + 80))} != ${JSON.stringify(actual.slice(at, at + 80))}`
  }
  if (expected && actual && typeof expected === 'object' && typeof actual === 'object') {
    for (const key of new Set([...Object.keys(expected), ...Object.keys(actual)])) {
      if (Object.hasOwn(expected, key) !== Object.hasOwn(actual, key)) return `${path}/${key}: property presence differs`
      const difference = firstDiff(expected[key], actual[key], `${path}/${key}`,probeValue)
      if (difference) return difference
    }
    return null
  }
  return `${path}: ${JSON.stringify(expected)?.slice(0, 200)} != ${JSON.stringify(actual)?.slice(0, 200)}`
}

try {
  const input = join(directory, 'input.json')
  const output = join(directory, 'output.json')
  writeFileSync(input, JSON.stringify(reference.cases.map(({ source }) => ({ source, probeStates: reference.functionProbeStates }))))
  execFileSync(process.env.LOVE_BIN ?? 'love', ['tests/compiler'], {
    cwd: projectRoot, env: { ...process.env, NM_GRAPH_INPUT: input, NM_GRAPH_OUTPUT: output }, stdio: 'inherit'
  })
  const candidate = JSON.parse(readFileSync(output, 'utf8'))
  if (candidate.length !== reference.cases.length) throw new Error(`Candidate produced ${candidate.length} of ${reference.cases.length} cases`)
  let mismatches = 0
  for (let index = 0; index < reference.cases.length; index++) {
    const test = reference.cases[index]
    const actual = candidate[index]
    if (test.status !== actual.status) {
      console.error(`MISMATCH ${test.id}/status: ${test.status} != ${actual.status}; native stage ${actual.stage}, ${JSON.stringify(actual.diagnostics?.[0] ?? actual.error)?.slice(0,300)}`)
      mismatches++
      continue
    }
    if (test.status === 'refused') {
      if (test.refusal.stage !== actual.stage) {
        console.error(`MISMATCH ${test.id}/refusal: ${test.refusal.stage} != ${actual.stage}`)
        mismatches++
      } else if (test.refusal.stage === 'validate' || test.refusal.stage === 'expand') {
        const field = test.refusal.stage === 'validate' ? 'diagnostics' : 'errors'
        const difference = firstDiff(unmap(test.refusal[field]), actual[field], `${test.id}/refusal/${field}`)
        if (difference) { console.error(`MISMATCH ${difference}`); mismatches++ }
      }
      continue
    }
    for (const stage of ['validate', 'expand', 'graph']) {
      const expected = unmap(test.stages[stage])
      const seen = actual[stage]
      const difference = firstDiff(expected, seen, `${test.id}/${stage}`)
      if (difference) { console.error(`MISMATCH ${difference}`); mismatches++ }
    }
  }
  console.log(`GRAPH-DIFFERENTIAL ${JSON.stringify({ reference: reference.authority.revision, cases: reference.cases.length, mismatches })}`)
  if (mismatches) process.exitCode = 1
} finally {
  rmSync(directory, { recursive: true, force: true })
}
