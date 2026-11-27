import assert from 'node:assert/strict'
import {spawnSync} from 'node:child_process'
import {mkdtempSync,readFileSync,rmSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join,resolve} from 'node:path'

const root=resolve(import.meta.dirname,'..')
const authored=JSON.parse(readFileSync(join(root,'parity/upstream/synth_roll.json'),'utf8'))
const expected={clockCount:0,notes:authored.midiInputs.flatMap(input=>input.notes)}
assert.ok(expected.notes.length>0,'The source-owned roll fixture must provide MIDI notes')
const output=mkdtempSync(join(tmpdir(),'love-authored-midi-'))
try {
 // The existing dense MIDI control supplies informative effect evidence beside the authored fixture.
 const ids=['upstream-synth_roll','supplemental-synth_roll-midi']
 const run=spawnSync(process.execPath,['tools/parity.mjs','--tier','all','--ids',ids.join(','),'--out',output],
  {cwd:root,env:process.env,stdio:'inherit'})
 if(run.error)throw run.error
 assert.equal(run.status,0,'Authored MIDI pixel qualification must pass')
 const fixtures=JSON.parse(readFileSync(join(output,'cases.json'),'utf8')).cases
 assert.deepEqual(fixtures.map(fixture=>fixture.id),ids)
 assert.deepEqual(fixtures[0].capture.midi,expected,'The authored notes must enter the capture plan')
 for(const side of ['reference','candidate']) {
  const report=JSON.parse(readFileSync(join(output,side,side+'.json'),'utf8'))
  assert.deepEqual(report.cases.map(fixture=>fixture.id),ids)
  assert.deepEqual(report.cases[0].midiSnapshot,expected,side+' must consume every authored note in order')
 }
 console.log('AUTHORED-MIDI-PIXELS source notes consumed by both renderers')
} finally {rmSync(output,{recursive:true,force:true})}
