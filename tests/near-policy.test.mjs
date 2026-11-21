import test from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {join,resolve} from 'node:path'
import {isReviewed,reviewNearCase,validateNearPolicies} from '../tools/near-policy.mjs'

const root=resolve(import.meta.dirname,'..')
const hash=character=>character.repeat(64)
const protocol={width:257,height:129,time:0.25,frames:8,seedPolicy:'authored'}
const entry={authority:hash('a').slice(0,40),protocol,referenceSha256:hash('1'),candidateSha256:hash('2'),maxChannelDelta:3,minSsim:0.9999,mechanism:'m',review:'r'}
const withPairs={...entry,pairs:[{referenceSha256:hash('3'),candidateSha256:hash('2'),platform:'Windows 11, NVIDIA GeForce RTX 3060 Ti',review:'r2'}]}
const capture=(referenceSha256,candidateSha256,max=3,ssim=0.99998)=>({authority:entry.authority,protocol,referenceSha256,candidateSha256,max,ssim})
const reviewed=isReviewed

test('an entry without pairs reviews only its own reference and candidate pair',()=>{
 assert.ok(reviewed(reviewNearCase(entry,capture(hash('1'),hash('2')))))
 assert.ok(!reviewed(reviewNearCase(entry,capture(hash('3'),hash('2')))))
 assert.ok(!reviewed(reviewNearCase(entry,capture(hash('1'),hash('3')))))
 assert.equal(isReviewed(null),false)
 assert.equal(reviewNearCase(undefined,capture(hash('1'),hash('2'))),null)
})

test('a capture matching a listed pair is reviewed, and the entry pair still is',()=>{
 assert.ok(reviewed(reviewNearCase(withPairs,capture(hash('3'),hash('2')))))
 assert.ok(reviewed(reviewNearCase(withPairs,capture(hash('1'),hash('2')))))
})

test('a capture whose hashes come from different pairs, or no pair, is not reviewed',()=>{
 const crossed={...withPairs,pairs:[{...withPairs.pairs[0],candidateSha256:hash('4')}]}
 const checks=reviewNearCase(crossed,capture(hash('3'),hash('2')))
 assert.equal(checks.reference,true)
 assert.equal(checks.candidate,true)
 assert.equal(checks.pair,false)
 assert.ok(!reviewed(checks))
 assert.ok(!reviewed(reviewNearCase(withPairs,capture(hash('5'),hash('6')))))
})

test('listed pairs share the entry authority, protocol and bound',()=>{
 assert.equal(reviewNearCase(withPairs,capture(hash('3'),hash('2'),4)).bound,false)
 assert.equal(reviewNearCase(withPairs,capture(hash('3'),hash('2'),3,0.99)).bound,false)
 assert.equal(reviewNearCase(withPairs,{...capture(hash('3'),hash('2')),authority:hash('b').slice(0,40)}).authority,false)
 assert.equal(reviewNearCase(withPairs,{...capture(hash('3'),hash('2')),protocol:{...protocol,frames:1}}).protocol,false)
})

test('malformed pairs are refused when the policy file loads',()=>{
 const file=cases=>({version:1,cases})
 assert.doesNotThrow(()=>validateNearPolicies(file({x:entry})))
 assert.doesNotThrow(()=>validateNearPolicies(file({x:withPairs})))
 assert.throws(()=>validateNearPolicies(file({x:{...entry,pairs:{}}})),/Invalid near policy pairs for x/)
 assert.throws(()=>validateNearPolicies(file({x:{...entry,pairs:[{...withPairs.pairs[0],referenceSha256:'abc'}]}})),/Invalid near policy pair for x/)
 assert.throws(()=>validateNearPolicies(file({x:{...entry,pairs:[{...withPairs.pairs[0],review:''}]}})),/Invalid near policy pair for x/)
 assert.throws(()=>validateNearPolicies(file({x:{...entry,pairs:[{...withPairs.pairs[0],referenceSha256:[hash('3')]}]}})),/Invalid near policy pair for x/)
 assert.throws(()=>validateNearPolicies(file({x:{...entry,pairs:[{...withPairs.pairs[0],maxChannelDelta:99}]}})),/Invalid near policy pair for x/)
 assert.throws(()=>validateNearPolicies(file({x:{...entry,pairs:[null]}})),/Invalid near policy pair for x/)
 assert.throws(()=>validateNearPolicies(file({x:null})),/Invalid near policy for x/)
 assert.throws(()=>validateNearPolicies({version:2,cases:{}}),/Invalid parity\/near-policy\.json/)
})

test('the committed near-policy file loads and each entry reviews its own and its listed pairs',()=>{
 const policies=validateNearPolicies(JSON.parse(readFileSync(join(root,'parity/near-policy.json'),'utf8')))
 for(const [id,policy] of Object.entries(policies.cases)){
  for(const pair of [policy,...(policy.pairs||[])]){
   const checks=reviewNearCase(policy,{authority:policy.authority,protocol:policy.protocol,referenceSha256:pair.referenceSha256,
    candidateSha256:pair.candidateSha256,max:policy.maxChannelDelta,ssim:policy.minSsim})
   assert.ok(reviewed(checks),id)
  }
 }
})
