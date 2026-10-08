export function authoredAttributionTarget(filename, declaredEffects, catalogEffects) {
  const exact = catalogEffects.find(effect => effect.replace('/', '_') + '.json' === filename)
  return exact && declaredEffects.includes(exact) ? exact : null
}

export function rgbContrast(left, right) {
  if (!left?.length || left.length !== right?.length || left.length % 4) return null
  let changedRgbPixels = 0, maxRgbDelta = 0
  for (let i = 0; i < left.length; i += 4) {
    let delta = 0
    for (let channel = 0; channel < 3; channel++) delta = Math.max(delta, Math.abs(left[i + channel] - right[i + channel]))
    if (delta > 0) changedRgbPixels++
    maxRgbDelta = Math.max(maxRgbDelta, delta)
  }
  return {changedRgbPixels, maxRgbDelta}
}

export function effectEvidenceKind(target, contributingEffects, control) {
  if (!target?.target || !(target.observedPasses > 0) || !(target.outputRgbPixels > 0) ||
      target.readbackErrors !== 0 || !contributingEffects?.includes(target.target)) return null
  if (target.changedRgbPixels > 0) return 'rgb-transform'
  // loopEnd copies input unchanged; its observable operation is feedback storage.
  if (target.target !== 'render/loopEnd' || !(target.stateWriteComparisons > 0) ||
      !(target.stateChangedRgbPixels > 0) || !(target.stateOutputRgbPixels > 0) ||
      !(target.feedbackReadPasses > 0) || control?.matched !== true) return null
  for (const side of [control.reference, control.candidate])
    if (!(side?.changedRgbPixels > 0) || !(side.maxRgbDelta > 2)) return null
  return 'feedback-state-transfer'
}
