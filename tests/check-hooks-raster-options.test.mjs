import test from 'node:test'
import assert from 'node:assert/strict'
import {spawnSync} from 'node:child_process'
import {existsSync,mkdtempSync,readFileSync,rmSync,writeFileSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join,resolve} from 'node:path'
import {pathToFileURL} from 'node:url'

// tools/check-hooks-raster.mjs launches its own reference browser. It must take the same
// browser plan as tools/render-reference.mjs. A stub Playwright (NM_PLAYWRIGHT_MODULE)
// records each launch to a file and stops the script there, so no real browser starts.
const root=resolve(import.meta.dirname,'..')
const work=mkdtempSync(join(tmpdir(),'love-hooks-raster-options-'))
const stub=join(work,'playwright-stub.mjs')
writeFileSync(stub,[
 "import {appendFileSync} from 'node:fs'",
 "const launcher=name=>({launch:async options=>{appendFileSync(process.env.NM_STUB_LAUNCH_LOG,JSON.stringify({name,options,stack:new Error().stack})+'\\n');throw Error('stub launch')}})",
 "export const firefox=launcher('firefox')",
 "export const chromium=launcher('chromium')",
].join('\n')+'\n')
test.after(()=>rmSync(work,{recursive:true,force:true}))

let runs=0
function runWith(env){
 const log=join(work,`launches-${runs++}.jsonl`)
 const base={...process.env}
 for(const key of ['NM_REFERENCE_BROWSER','NM_ANGLE_BACKEND','NM_REFERENCE_GL','NM_BROWSER_CHANNEL','NM_HOOK_FULL','NM_HOOK_DUMP'])delete base[key]
 const run=spawnSync(process.execPath,['tools/check-hooks-raster.mjs'],{cwd:root,encoding:'utf8',timeout:600000,
  env:{...base,NM_PLAYWRIGHT_MODULE:pathToFileURL(stub).href,NM_STUB_LAUNCH_LOG:log,...env}})
 const launches=existsSync(log)?readFileSync(log,'utf8').trim().split('\n').filter(Boolean).map(line=>JSON.parse(line)):[]
 return {status:run.status,stdout:run.stdout,stderr:run.stderr,launches}
}
// The overlay check's own launch, not renderReference's: its stack has no render-reference frame.
function assertOverlayLaunch(launch){
 assert.match(launch.stack,/check-hooks-raster\.mjs/)
 assert.doesNotMatch(launch.stack,/render-reference\.mjs/)
}

test('without NM_REFERENCE_GL, the overlay check launches Firefox with its existing preferences',()=>{
 const {status,stderr,launches}=runWith({})
 assert.notEqual(status,0)
 assert.match(stderr,/stub launch/)
 assert.equal(launches.length,1)
 assert.equal(launches[0].name,'firefox')
 assertOverlayLaunch(launches[0])
 assert.deepEqual(launches[0].options.firefoxUserPrefs,{'webgl.sanitize-unmasked-renderer':false})
})

test('NM_REFERENCE_GL=native gives the overlay check the same native-OpenGL Firefox',()=>{
 const {status,stderr,launches}=runWith({NM_REFERENCE_GL:'native'})
 assert.notEqual(status,0)
 assert.match(stderr,/stub launch/)
 assert.equal(launches.length,1)
 assert.equal(launches[0].name,'firefox')
 assertOverlayLaunch(launches[0])
 assert.deepEqual(launches[0].options.firefoxUserPrefs,{'webgl.sanitize-unmasked-renderer':false,'webgl.disable-angle':true})
})

test('NM_REFERENCE_GL with Chrome is refused before the overlay check starts a browser',()=>{
 const {status,stdout,stderr,launches}=runWith({NM_REFERENCE_BROWSER:'chrome',NM_REFERENCE_GL:'native'})
 assert.notEqual(status,0)
 assert.match(stderr,/NM_REFERENCE_GL applies only to Firefox/)
 assert.equal(launches.length,0)
 // Refused at startup: the overlay comparison never ran.
 assert.doesNotMatch(stdout,/HOOKS-VISIBLE-RASTER-DIFFERENTIAL/)
})
