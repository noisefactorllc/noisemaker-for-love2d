import assert from 'node:assert/strict'
import test from 'node:test'
import { validateCapabilityReport } from '../tools/qualify-capabilities.mjs'

const required = [
  'solid', 'asymmetric_alpha_marker', 'float_target', 'mrt_two_outputs',
  'synth_remap_uniform_lowering', 'gl_VertexID_points', 'vertex_texelFetch',
  'volume_texture', 'state_restoration',
]
const sourceHashes = Object.fromEntries([
  'noisemaker/runtime/capabilities.lua',
  'parity/capabilities/main.lua',
  'parity/capabilities/conf.lua',
].map(name => [name, 'a'.repeat(64)]))

function report() {
  const probes = Object.fromEntries(required.map(name => [name, { status: 'pass' }]))
  probes.half_packing = {
    status: 'unsupported',
    reason: "shader compilation: 'packHalf2x16': no matching overloaded function found",
  }
  probes.gl_PointSize = {
    status: 'fail',
    reason: 'PIXEL MISMATCH: gl_PointSize requested widths 1 and 7; observed 1 and 1',
  }
  return {
    schema: 'noisemaker-love-capabilities-v1',
    host: { love: { major: 11, minor: 5 }, renderer: { vendor: 'Apple', device: 'Apple M4' } },
    probes, counts: { pass: 9, fail: 1, unsupported: 1 }, ok: false, sourceHashes,
  }
}

test('the measured M4 direct-API limits remain visible while fallbacks qualify', () => {
  assert.deepEqual(validateCapabilityReport(report()), {
    device: 'Apple M4', requiredPassed: 9, halfPacking: 'unsupported', shaderPointSize: 'fail',
  })
})

test('a host with all direct capabilities also qualifies', () => {
  const value = report()
  value.probes.half_packing = { status: 'pass' }
  value.probes.gl_PointSize = { status: 'pass' }
  value.counts = { pass: 11, fail: 0, unsupported: 0 }
  value.ok = true
  assert.equal(validateCapabilityReport(value).requiredPassed, 9)
})

test('a software or unrecognized renderer cannot enter the GPU lane', () => {
  const value = report()
  value.host.renderer = { vendor: 'Google', device: 'SwiftShader' }
  assert.throws(() => validateCapabilityReport(value), /Apple GPU/)
})

test('required pixel probes and other point-size failures remain blocking', () => {
  const value = report()
  value.probes.mrt_two_outputs = { status: 'fail', reason: 'wrong attachment' }
  value.counts = { pass: 8, fail: 2, unsupported: 1 }
  assert.throws(() => validateCapabilityReport(value), /mrt_two_outputs/)
  const changed = report()
  changed.probes.gl_PointSize.reason = 'PIXEL MISMATCH: gl_PointSize requested widths 1 and 7; observed 3 and 3'
  assert.throws(() => validateCapabilityReport(changed), /observed 1 and 1/)
})

test('an unrelated half-packing failure and missing source proof remain blocking', () => {
  const value = report()
  value.probes.half_packing = { status: 'fail', reason: 'wrong pixels' }
  value.counts = { pass: 9, fail: 2, unsupported: 0 }
  assert.throws(() => validateCapabilityReport(value), /direct GLSL builtin/)
  const changed = report()
  delete changed.sourceHashes['noisemaker/runtime/capabilities.lua']
  assert.throws(() => validateCapabilityReport(changed), /source hash/)
})
