import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const required = [
  'solid', 'asymmetric_alpha_marker', 'float_target', 'mrt_two_outputs',
  'synth_remap_uniform_lowering', 'gl_VertexID_points', 'vertex_texelFetch',
  'volume_texture', 'state_restoration',
]
const all = [...required, 'half_packing', 'gl_PointSize'].sort()

export function validateCapabilityReport(report) {
  assert.equal(report?.schema, 'noisemaker-love-capabilities-v1')
  assert.equal(report.host?.love?.major, 11)
  assert.equal(report.host?.love?.minor, 5)
  assert.equal(report.host?.renderer?.vendor, 'Apple', 'the GPU lane must use an Apple GPU')
  assert.match(report.host?.renderer?.device ?? '', /^Apple M\d/, 'the GPU lane must use Apple Silicon')
  assert.deepEqual(Object.keys(report.probes ?? {}).sort(), all, 'every native probe must run')
  for (const name of required) {
    assert.equal(report.probes[name].status, 'pass', `required native probe ${name}: ${report.probes[name].reason ?? ''}`)
  }
  const half = report.probes.half_packing
  if (half.status !== 'pass') {
    assert.equal(half.status, 'unsupported', 'half packing may only lack the direct GLSL builtin')
    assert.match(half.reason ?? '', /packHalf2x16/, 'identify the missing direct half-packing builtin')
  }
  const point = report.probes.gl_PointSize
  if (point.status !== 'pass') {
    assert.equal(point.status, 'fail', 'only the measured shader point-size limitation is expected')
    assert.equal(point.reason,
      'PIXEL MISMATCH: gl_PointSize requested widths 1 and 7; observed 1 and 1')
  }
  const statuses = Object.values(report.probes).map(probe => probe.status)
  for (const status of ['pass', 'fail', 'unsupported']) {
    assert.equal(report.counts?.[status], statuses.filter(value => value === status).length)
  }
  assert.equal(report.ok, statuses.every(status => status === 'pass'))
  for (const name of ['noisemaker/runtime/capabilities.lua',
    'parity/capabilities/main.lua', 'parity/capabilities/conf.lua']) {
    assert.match(report.sourceHashes?.[name] ?? '', /^[0-9a-f]{64}$/, `source hash ${name}`)
  }
  return {
    device: report.host.renderer.device,
    requiredPassed: required.length,
    halfPacking: half.status,
    shaderPointSize: point.status,
  }
}

function main() {
  const love = process.env.LOVE_BIN
  assert.ok(love, 'LOVE_BIN must name the verified LÖVE 11.5 binary')
  const directory = mkdtempSync(path.join(os.tmpdir(), 'noisemaker-love-capabilities-'))
  try {
    const output = path.join(directory, 'result.jsonl')
    const result = spawnSync(love, ['parity/capabilities'], {
      cwd: root,
      env: { ...process.env, NM_CAPABILITIES_RESULT: output },
      encoding: 'utf8',
      timeout: 120000,
      maxBuffer: 4 * 1024 * 1024,
    })
    if (result.stdout) process.stdout.write(result.stdout)
    if (result.stderr) process.stderr.write(result.stderr)
    if (result.error) throw result.error
    const line = readFileSync(output, 'utf8').trim()
    assert.ok(line.startsWith('CAPABILITIES-RESULT '), 'native capability result is missing')
    const report = JSON.parse(line.slice('CAPABILITIES-RESULT '.length))
    assert.equal(result.status, report.ok ? 0 : 1, 'native probe exit and report disagree')
    const qualified = validateCapabilityReport(report)
    console.log('CAPABILITIES-QUALIFIED ' + JSON.stringify(qualified))
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main() } catch (error) {
    console.error('Capability qualification failed:', error.message)
    process.exitCode = 1
  }
}
