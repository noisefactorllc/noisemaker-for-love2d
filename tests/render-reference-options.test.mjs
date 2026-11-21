import test from 'node:test'
import assert from 'node:assert/strict'
import {mkdtempSync,rmSync,writeFileSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import {pathToFileURL} from 'node:url'
import * as referenceTool from '../tools/render-reference.mjs'

// A stub Playwright (through NM_PLAYWRIGHT_MODULE) records each launch and stops there, so
// these checks see the exact options the reference browser would get, without a browser.
const work=mkdtempSync(join(tmpdir(),'love-reference-options-'))
const stub=join(work,'playwright-stub.mjs')
writeFileSync(stub,[
 "const launcher=name=>({launch:async options=>{globalThis.nmStubLaunches.push({name,options});throw Error('stub launch')}})",
 "export const firefox=launcher('firefox')",
 "export const chromium=launcher('chromium')",
].join('\n')+'\n')
test.after(()=>rmSync(work,{recursive:true,force:true}))

const keys=['NM_PLAYWRIGHT_MODULE','NM_REFERENCE_BROWSER','NM_ANGLE_BACKEND','NM_REFERENCE_GL','NM_BROWSER_CHANNEL']
async function launchWith(env){
 const previous=keys.map(key=>process.env[key])
 for(const key of keys)delete process.env[key]
 Object.assign(process.env,{NM_PLAYWRIGHT_MODULE:pathToFileURL(stub).href},env)
 globalThis.nmStubLaunches=[]
 try{
  let error=null
  try{await referenceTool.renderReference({cases:[],output:mkdtempSync(join(work,'out-'))})}catch(caught){error=caught}
  return {launches:globalThis.nmStubLaunches,error}
 }finally{
  keys.forEach((key,index)=>{if(previous[index]===undefined)delete process.env[key];else process.env[key]=previous[index]})
 }
}

test('without NM_REFERENCE_GL, Firefox launches with its existing preferences',async()=>{
 const {launches,error}=await launchWith({})
 assert.match(error?.message??'',/stub launch/)
 assert.equal(launches.length,1)
 assert.equal(launches[0].name,'firefox')
 assert.deepEqual(launches[0].options.firefoxUserPrefs,{'webgl.sanitize-unmasked-renderer':false})
})

test('NM_REFERENCE_GL=native renders the Firefox reference without ANGLE',async()=>{
 const {launches,error}=await launchWith({NM_REFERENCE_GL:'native'})
 assert.match(error?.message??'',/stub launch/)
 assert.equal(launches.length,1)
 assert.equal(launches[0].name,'firefox')
 assert.deepEqual(launches[0].options.firefoxUserPrefs,{'webgl.sanitize-unmasked-renderer':false,'webgl.disable-angle':true})
})

test('NM_REFERENCE_GL is refused with Chrome before any browser starts',async()=>{
 const {launches,error}=await launchWith({NM_REFERENCE_BROWSER:'chrome',NM_REFERENCE_GL:'native'})
 assert.match(error?.message??'',/NM_REFERENCE_GL applies only to Firefox/)
 assert.equal(launches.length,0)
})

test('an unknown NM_REFERENCE_GL value is refused before any browser starts',async()=>{
 const {launches,error}=await launchWith({NM_REFERENCE_GL:'angle'})
 assert.match(error?.message??'',/NM_REFERENCE_GL must be native or unset/)
 assert.equal(launches.length,0)
})

test('the reference plan carries the requested GL path for the report',()=>{
 assert.equal(typeof referenceTool.referenceBrowserPlan,'function')
 assert.equal(referenceTool.referenceBrowserPlan({NM_REFERENCE_GL:'native'}).referenceGl,'native')
 assert.equal(referenceTool.referenceBrowserPlan({}).referenceGl,null)
})
