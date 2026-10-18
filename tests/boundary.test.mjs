import test from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {join,resolve} from 'node:path'
import {boundaryCases,boundedNumericParameters,numberLiteral,withCallArgument} from '../tools/boundary.mjs'

const root=resolve(import.meta.dirname,'..')
const definitions=JSON.parse(readFileSync(join(root,'noisemaker/catalog/definitions.json'),'utf8'))

test('the boundary family has a min and a max case for each bounded numeric catalog parameter',()=>{
 const expected=[]
 for(const [effect,definition] of Object.entries(definitions))for(const [name,spec] of Object.entries(definition.globals||{})){
  if(['float','int'].includes(spec.type)&&!spec.choices&&Number.isFinite(spec.min)&&Number.isFinite(spec.max))expected.push(effect+':'+name)
 }
 assert.ok(expected.length>0)
 assert.deepEqual(boundedNumericParameters(definitions).map(item=>item.effect+':'+item.name).sort(),expected.sort())
 const cases=boundaryCases(root,definitions)
 assert.equal(cases.length,2*expected.length)
 assert.equal(new Set(cases.map(item=>item.id)).size,cases.length)
 for(const item of cases){
  const spec=definitions[item.effect].globals[item.parameter]
  assert.equal(item.value,item.bound==='min'?spec.min:spec.max)
  assert.ok(item.source.includes(`${item.parameter}: ${numberLiteral(item.value)}`),item.id)
 }
})

test('boundary values replace or add one keyword argument on the first call',()=>{
 assert.equal(withCallArgument('noise(seed: 1).blur(radius: 4).write(o0)','blur','radius','0'),'noise(seed: 1).blur(radius: 0).write(o0)')
 assert.equal(withCallArgument('noise(seed: 1).blur().write(o0)','blur','radius','0.5'),'noise(seed: 1).blur(radius: 0.5).write(o0)')
 assert.equal(withCallArgument('solid().write(o0)','blur','radius','1'),null)
 assert.equal(numberLiteral(1e-7),'0.0000001')
 assert.equal(numberLiteral(-200),'-200')
})
