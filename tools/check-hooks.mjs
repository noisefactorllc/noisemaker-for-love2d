import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { resolveReference } from './reference.mjs'
import { isDeepStrictEqual } from 'node:util'
const projectRoot=resolve(import.meta.dirname,'..')
const {root,sourceIdentity}=await resolveReference({projectRoot,referenceRoot:process.env.NM_REFERENCE_ROOT})
const {SeededRNG,traceWorms}=await import(pathToFileURL(join(root,'shaders/src/cpu/wormTracer.js')).href)
const cases=[]
cases.push({name:'values/prefilled-object',valuesProbe:true})
for(const seed of [0,1,42,1000,-17,4294967295,3.5]) cases.push({name:`rng/${seed}`,hooksRNG:{seed,count:32}})
for(const [name,fields] of [
  ['fibers',{seed:1000,density:1.4,kink:5,stride:.75,strideDeviation:.125,duration:1,behavior:'chaotic',flowFreq:4,lineWidth:1.5,colorMode:'fibers'}],
  ['scratches',{seed:1251,density:.25,kink:.15,stride:.75,strideDeviation:.5,duration:3,behavior:'unruly',flowFreq:3,lineWidth:.5,colorMode:'white'}],
  ['scratches-default-layer0',{seed:1000,density:.22,kink:.125,stride:.75,strideDeviation:.5,duration:3,behavior:'obedient',flowFreq:3,lineWidth:.5,colorMode:'white'}],
  ['strayHair',{seed:1042,density:.005,kink:12,stride:.5,strideDeviation:.25,duration:9,behavior:'unruly',flowFreq:4,lineWidth:1,colorMode:'hair'}]
]) for(const [width,height] of [[8,8],[17,11],[31,23]]) cases.push({name:`trace/${name}/${width}x${height}`,hooksTrace:{width,height,...fields}})
cases.push({name:'lifecycle/dot-keys',hooksLifecycle:{width:8,height:8,stepIndex:1,passes:[
  {effectKey:'filter.scratches',nodeId:'node_1',stepIndex:1,uniforms:{seed:1,density:.3,alpha:.75}},
  {effectKey:'synth.media',nodeId:'node_2',stepIndex:2,uniforms:{imageSize:[1,1]}}
]}})
cases.push({name:'lifecycle/transaction',hooksTransaction:{width:8,height:8,stepIndex:1,passes:[
  {effectKey:'filter.scratches',nodeId:'node_1',stepIndex:1},
  {effectKey:'synth.media',nodeId:'node_2',stepIndex:2}
]}})
const expected=[]
for(const item of cases) {
  if(item.valuesProbe) {expected.push({keys:['alpha','beta'],indexKeys:['1','2','10'],roundtrip:{alpha:1,beta:2}});continue}
  if(item.hooksLifecycle) {expected.push({initialUploads:1,afterAlpha:1,afterDensity:2,afterResize:3,inheritedDensity:.75,inheritedAgain:{node_1:{alpha:.25,density:.75}},initialUniforms:{'synth/media':{imageSize:[1,1]}},updatedUniforms:{'synth/media':{imageSize:[320,240]}},calls:[{id:'node_1_overlayTex',width:8,height:8,format:'rgba8',length:256},{id:'node_1_overlayTex',width:8,height:8,format:'rgba8',length:256},{id:'node_1_overlayTex',width:9,height:9,format:'rgba8',length:324}]});continue}
  if(item.hooksTransaction) {expected.push({initialUploads:1,initialDensity:.3,initialOverrides:{},
    afterFailure:{accepted:false,errorMatched:true,density:.3,overrides:{},uploads:1,attempted:1},
    afterAlpha:{candidate:true,uploads:0,originalAlpha:.75,nextAlpha:.25,mediaWidth:320,mediaHeight:240,mediaInitialized:true},
    afterDensity:{stagedUploads:1,originalDensity:.3,nextDensity:.75,overrides:{node_1:{alpha:.25,density:.75}},irrelevant:true,unchanged:true}});continue}
  if(item.hooksRNG) {
    const rng=new SeededRNG(item.hooksRNG.seed)
    expected.push(Array.from({length:item.hooksRNG.count},()=>rng.next()))
    continue
  }
  const opts=item.hooksTrace
  const colorFn=opts.colorMode==='fibers'?(rng)=>({r:Math.floor(rng.float()*200+55),g:Math.floor(rng.float()*200+55),b:Math.floor(rng.float()*200+55),a:.5}):
    opts.colorMode==='hair'?(rng)=>({r:Math.floor(rng.float()*30),g:Math.floor(rng.float()*30),b:Math.floor(rng.float()*30),a:.666}):()=>({r:255,g:255,b:255,a:1})
  const segments=[]
  let start,end
  let color
  const ctx={lineWidth:1,lineCap:'round',lineJoin:'round',strokeStyle:'',beginPath(){start=null;end=null},
    moveTo(x,y){start=[x,y]},lineTo(x,y){end=[x,y]},stroke(){
      const parts=this.strokeStyle.match(/^rgba\((\d+), (\d+), (\d+), ([^)]+)\)$/)
      color=parts.slice(1).map(Number)
      segments.push([start[0],start[1],end[0],end[1],this.lineWidth,...color,Math.floor((segments.length)/(Math.max(1,Math.floor(Math.max(opts.width,opts.height)*opts.density)))),-1])
    }}
  await traceWorms(ctx,{...opts,colorFn,isCancelled:()=>false})
  expected.push(segments)
}
const temp=mkdtempSync(join(tmpdir(),'nm-love-hooks-'))
try {
  const input=join(temp,'input.json'),output=join(temp,'output.json')
  writeFileSync(input,JSON.stringify(cases))
  execFileSync(process.env.LOVE_BIN??'love',['tests/compiler'],{
    cwd:projectRoot,env:{...process.env,NM_FRONTEND_INPUT:input,NM_FRONTEND_OUTPUT:output},stdio:'inherit'
  })
  const actual=JSON.parse(readFileSync(output,'utf8'))
  let errors=0,maxError=0
  for(let i=0;i<cases.length;i++) {
    const got=actual[i]?.value,ref=expected[i]
    if(cases[i].valuesProbe||cases[i].hooksLifecycle||cases[i].hooksTransaction){if(!isDeepStrictEqual(got,ref)){console.error(`MISMATCH lifecycle: ${JSON.stringify(got)}`);errors++}continue}
    if(!actual[i]?.ok || !Array.isArray(got) || got.length!==ref.length) {
      console.error(`MISMATCH ${cases[i].name} length/error native=${JSON.stringify(actual[i]).slice(0,500)} ref=${ref.length}`);errors++;continue
    }
    for(let j=0;j<ref.length;j++) {
      const a=Array.isArray(ref[j])?ref[j]:[ref[j]]
      const b=Array.isArray(got[j])?got[j]:[got[j]]
      for(let k=0;k<a.length;k++) {
        if(k>=9) continue
        const diff=Math.abs(a[k]-b[k])
        maxError=Math.max(maxError,diff)
        if(diff>1e-7) {console.error(`MISMATCH ${cases[i].name}/${j}/${k} ref=${a[k]} native=${b[k]} diff=${diff}`);errors++;break}
      }
      if(errors>=12)break
    }
    if(errors>=12)break
  }
  console.log(`HOOKS-GEOMETRY-DIFFERENTIAL ${JSON.stringify({reference:sourceIdentity.revision,cases:cases.length,errors,maxError})}`)
  if(errors) process.exitCode=1
} finally {rmSync(temp,{recursive:true,force:true})}
