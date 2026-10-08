import test from 'node:test'
import assert from 'node:assert/strict'
import {gradePixels} from '../tools/grade.mjs'
const image=()=>Buffer.from([0,20,30,0,250,200,5,255,10,100,200,128,255,255,255,255])
test('grading rejects wrong pixels even in flat goldens',()=>{
 assert.equal(gradePixels(Buffer.alloc(16),Buffer.alloc(16,255),2,2).bucket,'fail')
 assert.equal(gradePixels(Buffer.alloc(16),Buffer.alloc(16),2,2).uninformative,true)
})
test('grading is strict, alpha-sensitive and length checked',()=>{
 const a=image(),b=image();assert.equal(gradePixels(a,b,2,2).bucket,'exact');assert.equal(gradePixels(a,b,2,2).uninformative,false)
 b[3]=3;assert.notEqual(gradePixels(a,b,2,2).bucket,'strict')
 b[3]=2;assert.equal(gradePixels(a,b,2,2).bucket,'strict')
 assert.equal(gradePixels(a,b.subarray(0,12),2,2).bucket,'fail')
})
test('asymmetric marker rejects row inversion',()=>{
 const a=image(),b=Buffer.concat([a.subarray(8),a.subarray(0,8)])
 assert.equal(gradePixels(a,b,2,2).bucket,'fail')
})
