import test from 'node:test'
import assert from 'node:assert/strict'
import { authoredAttributionTarget, rgbContrast, effectEvidenceKind } from '../tools/attribution.mjs'

const catalog = ['render/meshLoader', 'render/meshRender', 'synth/media', 'filter/text']

test('an authored fixture attributes only its exact named effect', () => {
  const declared = ['render/meshLoader', 'render/meshRender']
  assert.equal(authoredAttributionTarget('render_meshRender.json', declared, catalog), 'render/meshRender')
  assert.notEqual(authoredAttributionTarget('render_meshRender.json', declared, catalog), 'render/meshLoader')
  assert.equal(authoredAttributionTarget('render_meshLoader.json', ['render/meshRender'], catalog), null)
  assert.equal(authoredAttributionTarget('meshRender.json', declared, catalog), null)
  assert.equal(authoredAttributionTarget('synth_media.json', ['synth/media'], catalog), 'synth/media')
})

const loopEvidence = {target:'render/loopEnd',observedPasses:2,changedRgbPixels:0,
  outputRgbPixels:20,readbackErrors:0,stateWriteComparisons:1,stateChangedRgbPixels:12,stateOutputRgbPixels:20,feedbackReadPasses:1}
const control = {matched:true,reference:{changedRgbPixels:4,maxRgbDelta:30},candidate:{changedRgbPixels:4,maxRgbDelta:30}}

test('feedback transfer requires a matched causal control and an observed state read and write', () => {
  assert.equal(effectEvidenceKind(loopEvidence,['render/loopEnd'],control),'feedback-state-transfer')
  for (const field of ['stateWriteComparisons','stateChangedRgbPixels','stateOutputRgbPixels','feedbackReadPasses'])
    assert.equal(effectEvidenceKind({...loopEvidence,[field]:0},['render/loopEnd'],control),null,field)
  assert.equal(effectEvidenceKind(loopEvidence,['render/loopEnd']),null)
  assert.equal(effectEvidenceKind(loopEvidence,['render/loopEnd'],{...control,matched:false}),null)
  for (const side of ['reference','candidate'])
    assert.equal(effectEvidenceKind(loopEvidence,['render/loopEnd'],{...control,[side]:{changedRgbPixels:4,maxRgbDelta:2}}),null,side)
  assert.equal(effectEvidenceKind({...loopEvidence,readbackErrors:1},['render/loopEnd'],control),null)
  assert.equal(effectEvidenceKind(loopEvidence,[],control),null)
  assert.equal(effectEvidenceKind({...loopEvidence,target:'filter/invert'},['filter/invert'],control),null)
})

test('ordinary effects still require a measured RGB transformation', () => {
  const evidence={target:'filter/invert',observedPasses:1,changedRgbPixels:2,outputRgbPixels:4,readbackErrors:0}
  assert.equal(effectEvidenceKind(evidence,['filter/invert']),'rgb-transform')
  assert.equal(effectEvidenceKind({...evidence,changedRgbPixels:0},['filter/invert']),null)
  assert.equal(effectEvidenceKind({...evidence,readbackErrors:1},['filter/invert']),null)
})

test('causal contrast ignores alpha-only changes and rejects different dimensions', () => {
  assert.deepEqual(rgbContrast(Buffer.from([1,2,3,0]),Buffer.from([1,2,3,255])),{changedRgbPixels:0,maxRgbDelta:0})
  assert.deepEqual(rgbContrast(Buffer.from([1,2,3,255]),Buffer.from([1,2,7,255])),{changedRgbPixels:1,maxRgbDelta:4})
  assert.equal(rgbContrast(Buffer.alloc(4),Buffer.alloc(8)),null)
  assert.equal(rgbContrast(Buffer.alloc(3),Buffer.alloc(3)),null)
})
