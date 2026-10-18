import test from 'node:test'
import assert from 'node:assert/strict'
import {spawnSync} from 'node:child_process'
import {chmodSync,existsSync,mkdtempSync,readFileSync,rmSync,writeFileSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join,resolve} from 'node:path'
import {parseParityArguments,selectParityCases} from '../tools/parity-args.mjs'

const root=resolve(import.meta.dirname,'..')
const cases=['coverage-synth_noise','coverage-synth_cell','programs-chain','timed-x-frame1'].map(id=>({id}))

test('case-ID arguments select only those cases',()=>{
 const args=parseParityArguments(['coverage-synth_noise','programs-chain'])
 assert.deepEqual(args.ids,['coverage-synth_noise','programs-chain'])
 assert.equal(args.tier,'all')
 const selected=selectParityCases(cases,args.ids)
 assert.deepEqual(selected.map(item=>item.id),['coverage-synth_noise','programs-chain'])
 assert.equal(selected.length,2)
})

test('an unknown case-ID argument is refused',()=>{
 assert.throws(()=>selectParityCases(cases,parseParityArguments(['coverage-no_such_case']).ids),/Unknown parity case coverage-no_such_case/)
 assert.throws(()=>selectParityCases(cases,parseParityArguments(['coverage-synth_noise','--bogus']).ids),/Unknown parity case --bogus/)
})

test('no arguments keep the full --tier all set',()=>{
 const args=parseParityArguments([])
 assert.deepEqual(args,{tier:'all',limit:Infinity,out:null,ids:null})
 assert.equal(selectParityCases(cases,args.ids),cases)
})

test('--ids, --tier, --limit and --out keep their behavior',()=>{
 assert.deepEqual(parseParityArguments(['--tier','coverage','--limit','3','--out','/tmp/x','--ids','coverage-synth_noise,coverage-synth_cell']),
  {tier:'coverage',limit:3,out:'/tmp/x',ids:['coverage-synth_noise','coverage-synth_cell']})
 assert.deepEqual(parseParityArguments(['--ids','coverage-synth_cell','programs-chain']).ids,['coverage-synth_cell','programs-chain'])
 assert.deepEqual(parseParityArguments(['--out','coverage-synth_noise']).ids,null)
 assert.throws(()=>parseParityArguments(['--tier']),/Missing value for --tier/)
 assert.throws(()=>selectParityCases(cases,parseParityArguments(['--ids','nope']).ids),/Unknown parity case nope/)
})

// parity.mjs exits on an unknown case-ID argument before it starts the native runner
// (and so before the reference browser, which starts after it). The stub LÖVE records any start.
function runWithStub(argv){
 const work=mkdtempSync(join(tmpdir(),'love-parity-args-'))
 try{
  const stub=join(work,'love'),marker=join(work,'love-started')
  writeFileSync(stub,'#!/bin/sh\necho "$@" >> "$STUB_LOVE_MARKER"\nexit 3\n');chmodSync(stub,0o755)
  const run=spawnSync(process.execPath,['tools/parity.mjs',...argv,'--out',join(work,'out')],{cwd:root,encoding:'utf8',
   env:{...process.env,LOVE_BIN:stub,STUB_LOVE_MARKER:marker}})
  return {status:run.status,stderr:run.stderr,loveStarted:existsSync(marker)?readFileSync(marker,'utf8'):null}
 }finally{rmSync(work,{recursive:true,force:true})}
}

test('parity-summary stops on an unknown case-ID argument before the native runner',()=>{
 const unknown=runWithStub(['coverage-no_such_case'])
 assert.notEqual(unknown.status,0)
 assert.match(unknown.stderr,/Unknown parity case coverage-no_such_case/)
 assert.equal(unknown.loveStarted,null)
 const known=runWithStub(['coverage-synth_noise'])
 assert.notEqual(known.status,0)
 assert.equal(known.loveStarted?.trim(),'parity/runner')
})
