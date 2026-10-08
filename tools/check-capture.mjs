#!/usr/bin/env node
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { renderReference } from './render-reference.mjs'
import { gradePixels } from './grade.mjs'

const root = resolve(import.meta.dirname, '..')
const capture = { backend: 'webgl2', width: 32, height: 24, surface: 'o0', frames: 1,
  frame: 0, time: 0, deltaTime: 0, seed: 9, reset: true, inputs: [] }
const source = 'search synth\nnoise(seed: 7).write(o0)\nrender(o0)'
const mncaSource = 'search synth\nnoise(seed: 1, scaleX: 50, scaleY: 50).write(o0)\nmnca(tex: o0).write(o1)\nrender(o1)'
const mncaCapture = { ...capture, width: 257, height: 129, surface: 'o1', seedPolicy: 'authored',
  deltaTime: 1 / 60, frames: 2 }
const coverageSource = name => readFileSync(join(root, 'parity/coverage', name + '.dsl'), 'utf8')
const rollCapture = { ...capture, width: 257, height: 129, time: .25, deltaTime: 1 / 60,
  frames: 8, advanceTime: true, seedPolicy: 'authored' }
const rollNotes = [{ channel: 1, key: 60, velocity: 127 }, { channel: 1, key: 64, velocity: 96 },
  { channel: 9, key: 72, velocity: 110 }]
const cases = [
  { id: 'authored-seed', source, capture: { ...capture, seedPolicy: 'authored' } },
  { id: 'global-seed', source, capture },
  { id: 'pooled-seed', source, capture: { ...capture, seedPolicy: 'authored', texturePooling: true } },
  { id: 'alternate-surface', source: 'search synth\nnoise(seed: 7).write(o1)\nrender(o1)',
    capture: { ...capture, surface: 'o1', seedPolicy: 'authored' } },
  { id: 'overwritten-effect', source: 'search synth\nnoise(seed: 7).write(o0)\nsolid(color: #404040).write(o0)\nrender(o0)',
    attributionTarget: 'synth/noise', capture: { ...capture, seedPolicy: 'authored' } },
  { id: 'inert-effect', source: 'search synth, filter\nsolid(color: #404040).blur().write(o0)\nrender(o0)',
    attributionTarget: 'filter/blur', capture: { ...capture, seedPolicy: 'authored' } },
  { id: 'readable-input', source: 'search synth, filter\nnoise(seed: 7).invert().write(o0)\nrender(o0)',
    attributionTarget: 'filter/invert', capture: { ...capture, seedPolicy: 'authored' } },
  { id: 'failed-input-readback', source: 'search synth, filter\nnoise(seed: 7).invert().write(o0)\nrender(o0)',
    attributionTarget: 'filter/invert', capture: { ...capture, seedPolicy: 'authored' } },
  { id: 'incomplete-input-readback', source: 'search synth, filter\nnoise(seed: 7).invert().write(o0)\nrender(o0)',
    attributionTarget: 'filter/invert', capture: { ...capture, seedPolicy: 'authored' } },
  { id: 'default-cell-noise', source: coverageSource('classicNoisedeck_cellNoise'),
    attributionTarget: 'classicNoisedeck/cellNoise', capture: { ...capture, seedPolicy: 'authored' } },
  { id: 'default-shapes-3d', source: coverageSource('classicNoisedeck_shapes3d'),
    attributionTarget: 'classicNoisedeck/shapes3d', capture: { ...capture, seedPolicy: 'authored' } },
  { id: 'default-subdivide', source: coverageSource('synth_subdivide'),
    attributionTarget: 'synth/subdivide', capture: { ...capture, width: 257, height: 129, seedPolicy: 'authored' } },
  { id: 'roll-held-notes', source: coverageSource('synth_roll'), attributionTarget: 'synth/roll',
    capture: { ...rollCapture, midi: { notes: rollNotes, clockCount: 24 } } },
  { id: 'roll-empty-notes', source: coverageSource('synth_roll'), attributionTarget: 'synth/roll',
    capture: { ...rollCapture, midi: { notes: [], clockCount: 24 } } },
  { id: 'volume-x128', source: coverageSource('synth3d_reactionDiffusion3d__volumeSize_x128'),
    capture: { ...capture, seedPolicy: 'authored' } },
  { id: 'volume-x64', source: coverageSource('synth3d_reactionDiffusion3d__volumeSize_x64'),
    capture: { ...capture, seedPolicy: 'authored' } },
  { id: 'volume-x32', source: coverageSource('synth3d_fractal3d__volumeSize_x32'),
    capture: { ...capture, seedPolicy: 'authored' } },
  { id: 'mnca-time-zero-first', source: mncaSource,
    capture: { ...mncaCapture, time: 0, frames: 1, advanceTime: true } },
  { id: 'mnca-time-zero-second', source: mncaSource,
    capture: { ...mncaCapture, time: 0, advanceTime: true } },
  { id: 'mnca-time-constant-second', source: mncaSource,
    capture: { ...mncaCapture, time: .25, advanceTime: false } },
  { id: 'mnca-time-nonzero-second', source: mncaSource,
    capture: { ...mncaCapture, time: .25, advanceTime: true } }
]
const directory = mkdtempSync(join(tmpdir(), 'nm-love-capture-'))
try {
  const referenceDir = join(directory, 'reference')
  const candidateDir = join(directory, 'candidate')
  mkdirSync(referenceDir)
  mkdirSync(candidateDir)
  const nativeCapabilitiesPath = join(directory, 'native-capabilities.json')
  execFileSync(process.env.LOVE_BIN || 'love', ['parity/runner'], {
    cwd: root, env: { ...process.env, NM_PARITY_CAPS_OUTPUT: nativeCapabilitiesPath }, stdio: 'inherit'
  })
  const { maxTextureSize: nativeMaxTextureSize } = JSON.parse(readFileSync(nativeCapabilitiesPath, 'utf8'))
  if (!Number.isSafeInteger(nativeMaxTextureSize) || nativeMaxTextureSize < 1) throw Error('Invalid native capability probe')
  const reference = await renderReference({ cases, output: referenceDir,
    nativeMaxTextureSize, testInputReadbackFailureCaseId: 'failed-input-readback',
    testInputIncompleteFramebufferCaseId: 'incomplete-input-readback' })
  const manifest = join(directory, 'cases.json')
  writeFileSync(manifest, JSON.stringify({ version: 1, capabilities: reference.capabilities, cases }))
  execFileSync(process.env.LOVE_BIN || 'love', ['parity/runner'], {
    cwd: root, env: { ...process.env, NM_PARITY_INPUT: manifest, NM_PARITY_OUTPUT: candidateDir }, stdio: 'inherit'
  })
  const candidate = JSON.parse(readFileSync(join(candidateDir, 'candidate.json'), 'utf8'))
  const bytes = (side, id) => readFileSync(join(side, id + '.rgba'))
  let errors = 0
  const caps = reference.capabilities
  if (!Number.isSafeInteger(caps?.browserMaxTextureSize) || caps.browserMaxTextureSize < 1 ||
    caps.nativeMaxTextureSize !== nativeMaxTextureSize ||
    caps.commonMaxTextureSize !== Math.min(caps.browserMaxTextureSize, nativeMaxTextureSize) ||
    candidate.capabilities?.nativeMaxTextureSize !== nativeMaxTextureSize ||
    candidate.capabilities?.commonMaxTextureSize !== caps.commonMaxTextureSize ||
    cases.some(item => item.capture.commonMaxTextureSize !== caps.commonMaxTextureSize)) {
    console.error('CAPTURE-CONTRACT-FAIL texture limits were not negotiated from real devices',
      { reference: caps, candidate: candidate.capabilities })
    errors++
  }
  for (const fixture of cases) {
    const oracle = reference.cases.find(item => item.id === fixture.id)
    const native = candidate.cases.find(item => item.id === fixture.id)
    if (oracle?.status !== 'rendered' || native?.status !== 'rendered' ||
      oracle.captureSurface !== fixture.capture.surface || native.captureSurface !== fixture.capture.surface ||
      !oracle.surfaceId || !native.surfaceId) {
      console.error('CAPTURE-CONTRACT-FAIL ' + JSON.stringify({ id: fixture.id, oracle, native }))
      errors++
      continue
    }
    const grade = gradePixels(bytes(referenceDir, fixture.id), bytes(candidateDir, fixture.id),
      fixture.capture.width, fixture.capture.height)
    if (!['exact', 'strict'].includes(grade.bucket) ||
      (!fixture.attributionTarget && grade.uninformative)) errors++
    console.log('CAPTURE-CONTRACT-CASE ' + JSON.stringify({ id: fixture.id, grade, referenceSurfaceId: oracle.surfaceId, nativeSurfaceSlot: native.surfaceId }))
  }
  const overwritten = reference.cases.find(item => item.id === 'overwritten-effect')
  if (!overwritten?.targetEvidence?.observedPasses ||
    overwritten.contributingEffects?.includes('synth/noise')) {
    console.error('CAPTURE-CONTRACT-FAIL overwritten effect was credited', overwritten)
    errors++
  }
  const inert = reference.cases.find(item => item.id === 'inert-effect')
  if (!inert?.targetEvidence?.observedPasses || !inert.targetEvidence.comparablePasses ||
    inert.targetEvidence.changedRgbPixels !== 0 || inert.targetEvidence.readbackErrors !== 0) {
    console.error('CAPTURE-CONTRACT-FAIL inert effect had causal pixel evidence', inert)
    errors++
  }
  const clampVolume = (value, limit) => {
    if (value * value <= limit) return value
    let effective = 16
    while ((effective * 2) ** 2 <= limit && effective * 2 < value) effective *= 2
    return effective
  }
  const changeTuples = changes => (changes || []).map(item =>
    [item.passIndex, item.key, item.requested, item.effective])
  for (const [id, requested] of [['volume-x128', 128], ['volume-x64', 64], ['volume-x32', 32]]) {
    const oracle = reference.cases.find(item => item.id === id)
    const native = candidate.cases.find(item => item.id === id)
    const expected = clampVolume(requested, caps.commonMaxTextureSize)
    const oracleChanges = changeTuples(oracle?.volumeSizeChanges)
    const nativeChanges = changeTuples(native?.volumeSizeChanges)
    if (JSON.stringify(oracleChanges) !== JSON.stringify(nativeChanges) ||
      (requested !== expected && !oracleChanges.length) ||
      oracleChanges.some(([, key, value, effective]) =>
        !key.startsWith('volumeSize') || value !== requested || effective !== expected) ||
      (requested === expected && oracleChanges.length)) {
      console.error('CAPTURE-CONTRACT-FAIL volume clamp differs',
        { id, requested, expected, oracleChanges, nativeChanges })
      errors++
    }
  }
  const readable = reference.cases.find(item => item.id === 'readable-input')
  const failedReadback = reference.cases.find(item => item.id === 'failed-input-readback')
  const incompleteReadback = reference.cases.find(item => item.id === 'incomplete-input-readback')
  const validEvidence = evidence => evidence?.observedPasses > 0 && evidence.comparablePasses > 0 &&
    evidence.changedRgbPixels > 0 && evidence.outputRgbPixels > 0 && evidence.readbackErrors === 0
  if (!validEvidence(readable?.targetEvidence) ||
    failedReadback?.targetEvidence?.observedPasses !== readable.targetEvidence.observedPasses ||
    failedReadback.targetEvidence.readbackErrors < 1 || validEvidence(failedReadback.targetEvidence) ||
    !bytes(referenceDir, 'readable-input').equals(bytes(referenceDir, 'failed-input-readback')) ||
    incompleteReadback?.targetEvidence?.observedPasses !== readable.targetEvidence.observedPasses ||
    incompleteReadback.targetEvidence.readbackErrors < 1 || validEvidence(incompleteReadback.targetEvidence) ||
    !bytes(referenceDir, 'readable-input').equals(bytes(referenceDir, 'incomplete-input-readback'))) {
    console.error('CAPTURE-CONTRACT-FAIL failed input readback earned attribution evidence',
      { readable: readable?.targetEvidence, failed: failedReadback?.targetEvidence, incomplete: incompleteReadback?.targetEvidence })
    errors++
  }
  for (const id of ['default-cell-noise', 'default-shapes-3d', 'default-subdivide']) {
    const oracle = reference.cases.find(item => item.id === id)
    if (!validEvidence(oracle?.targetEvidence) || oracle.targetEvidence.defaultBaselinePasses !== 1) {
      console.error('CAPTURE-CONTRACT-FAIL transparent default input lacked causal evidence',
        { id, evidence: oracle?.targetEvidence })
      errors++
    }
  }
  const activeRoll = reference.cases.find(item => item.id === 'roll-held-notes')
  const emptyRoll = reference.cases.find(item => item.id === 'roll-empty-notes')
  const activeSnapshot = { clockCount: 24, notes: rollNotes }
  const emptySnapshot = { clockCount: 24, notes: [] }
  if (!validEvidence(activeRoll?.targetEvidence) || emptyRoll?.targetEvidence?.changedRgbPixels !== 0 ||
    JSON.stringify(activeRoll?.midiSnapshot) !== JSON.stringify(activeSnapshot) ||
    JSON.stringify(emptyRoll?.midiSnapshot) !== JSON.stringify(emptySnapshot) ||
    JSON.stringify(candidate.cases.find(item => item.id === 'roll-held-notes')?.midiSnapshot) !== JSON.stringify(activeSnapshot) ||
    JSON.stringify(candidate.cases.find(item => item.id === 'roll-empty-notes')?.midiSnapshot) !== JSON.stringify(emptySnapshot) ||
    bytes(referenceDir, 'roll-held-notes').equals(bytes(referenceDir, 'roll-empty-notes')) ||
    bytes(candidateDir, 'roll-held-notes').equals(bytes(candidateDir, 'roll-empty-notes'))) {
    console.error('CAPTURE-CONTRACT-FAIL held MIDI notes did not causally activate Roll',
      { active: activeRoll, empty: emptyRoll })
    errors++
  }
  for (const side of [referenceDir, candidateDir]) {
    if (bytes(side, 'authored-seed').equals(bytes(side, 'global-seed'))) {
      console.error('CAPTURE-CONTRACT-FAIL seed override had no visible effect')
      errors++
    }
    if (!bytes(side, 'authored-seed').equals(bytes(side, 'pooled-seed'))) {
      console.error('CAPTURE-CONTRACT-FAIL texture pooling changed output')
      errors++
    }
    if (!bytes(side, 'authored-seed').equals(bytes(side, 'alternate-surface'))) {
      console.error('CAPTURE-CONTRACT-FAIL equivalent o0/o1 surface output differs')
      errors++
    }
  }
  console.log('CAPTURE-CONTRACT ' + JSON.stringify({ reference: reference.authority.revision, cases: cases.length, errors }))
  if (errors) process.exitCode = 1
} finally {
  rmSync(directory, { recursive: true, force: true })
}
