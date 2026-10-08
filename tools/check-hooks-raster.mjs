import { chromium, firefox } from 'playwright'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { resolveReference } from './reference.mjs'
import { gradePixels } from './grade.mjs'
import { renderReference } from './render-reference.mjs'
const projectRoot=resolve(import.meta.dirname,'..')
const {root,sourceIdentity}=await resolveReference({projectRoot,referenceRoot:process.env.NM_REFERENCE_ROOT})
const source=readFileSync(join(root,'shaders/src/cpu/wormTracer.js'),'utf8')
const cases=[]
for(const [effect,params] of [
  ['filter/fibers',{seed:1,density:0.5}],
  ['filter/scratches',{seed:1,density:0.3}],
  ['filter/strayHair',{seed:1,density:0.5}],
]) for(const [width,height] of [[8,8],[31,23]]) cases.push({hooksOverlay:{effect,width,height,params}})
if(process.env.NM_HOOK_FULL==='1') cases.push({hooksOverlay:{effect:'filter/fibers',width:257,height:129,params:{seed:1,density:Number(process.env.NM_HOOK_DENSITY??1)}}})
const browserName=process.env.NM_REFERENCE_BROWSER||'firefox'
if(browserName!=='firefox'&&browserName!=='chrome')throw Error('NM_REFERENCE_BROWSER must be firefox or chrome')
const browser=browserName==='firefox'
  ?await firefox.launch({headless:true,firefoxUserPrefs:{'webgl.sanitize-unmasked-renderer':false}})
  :await chromium.launch({channel:process.env.NM_BROWSER_CHANNEL||'chrome',headless:true,args:['--enable-gpu']})
const browserVersion=browser.version()
let expected,stages
try {
const page=await browser.newPage()
const evaluated=await page.evaluate(async ({source,cases})=>{
  const lib=new Function(source.replaceAll('export class','class').replaceAll('export async function','async function')+'\nreturn {traceWorms}')()
  const all=[],stages=[]
  for(const {hooksOverlay:o} of cases){
    const canvas=document.createElement('canvas');canvas.width=o.width;canvas.height=o.height
    const ctx=canvas.getContext('2d',{willReadFrequently:true})
    const seed=o.params.seed||1
    const density=o.params.density
    for(let layer=0;layer<(o.effect==='filter/strayHair'?1:4);layer++){
      let opts
      if(o.effect==='filter/fibers'){
        const layerSeed=seed*1000+layer*137
        opts={seed:layerSeed,density:0.5+density*2,kink:5+(layerSeed%5),stride:0.75,strideDeviation:0.125,duration:1,behavior:'chaotic',flowFreq:4,lineWidth:Math.max(1.5,o.width/384),colorFn:rng=>({r:Math.floor(rng.float()*200+55),g:Math.floor(rng.float()*200+55),b:Math.floor(rng.float()*200+55),a:0.5})}
      }else if(o.effect==='filter/scratches'){
        const layerSeed=seed*1000+layer*251
        opts={seed:layerSeed,density:0.1+density*0.4,kink:0.125+(layerSeed%50)/400,stride:0.75,strideDeviation:0.5,duration:2+(layerSeed%3),behavior:layerSeed%2===0?'obedient':'unruly',flowFreq:2+(layerSeed%3),lineWidth:Math.max(0.5,o.width/1024),colorFn:()=>({r:255,g:255,b:255,a:1})}
      }else{
        const layerSeed=seed*1000+42
        opts={seed:layerSeed,density:0.001+density*0.004,kink:5+(layerSeed%45),stride:0.5,strideDeviation:0.25,duration:8+(layerSeed%8),behavior:'unruly',flowFreq:4,lineWidth:Math.max(1,o.width/400),colorFn:rng=>({r:Math.floor(rng.float()*30),g:Math.floor(rng.float()*30),b:Math.floor(rng.float()*30),a:0.666})}
      }
      await lib.traceWorms(ctx,{width:o.width,height:o.height,...opts,isCancelled:()=>false})
      if(o.width===257)stages.push(Array.from(ctx.getImageData(0,0,o.width,o.height).data))
    }
    all.push(Array.from(ctx.getImageData(0,0,o.width,o.height).data))
  }
  return {all,stages}
},{source,cases})
expected=evaluated.all;stages=evaluated.stages
} finally {await browser.close()}
const temp=mkdtempSync(join(tmpdir(),'nm-love-hooks-raster-'))
try {
 const input=join(temp,'in.json'),output=join(temp,'out.json')
 if(process.env.NM_HOOK_DUMP){for(let i=0;i<stages.length;i++)writeFileSync(process.env.NM_HOOK_DUMP+'.stage'+(i+1)+'.rgba',Buffer.from(stages[i]))}
 writeFileSync(input,JSON.stringify(cases))
 execFileSync(process.env.LOVE_BIN??'love',['tests/compiler'],{cwd:projectRoot,env:{...process.env,NM_FRONTEND_INPUT:input,NM_FRONTEND_OUTPUT:output},stdio:'inherit'})
 const actual=JSON.parse(readFileSync(output,'utf8'))
 let errors=0,maxDiff=0,absolute=0,count=0,nonzero=0,finalMax=0,finalSum=0,finalN=0,finalOver2=0
 for(let i=0;i<cases.length;i++){
   let caseMax=0,caseSum=0,caseNonzero=0
   for(let j=0;j<expected[i].length;j++){
     const diff=Math.abs(expected[i][j]-actual[i].value[j])
     caseMax=Math.max(caseMax,diff);caseSum+=diff;if(diff>2)caseNonzero++
     maxDiff=Math.max(maxDiff,diff);absolute+=diff;count++;if(diff>2)nonzero++
   }
   const examples=[];for(let j=0;j<expected[i].length&&examples.length<12;j++){if(Math.abs(expected[i][j]-actual[i].value[j])>2)examples.push({pixel:Math.floor(j/4),channel:j%4,ref:expected[i][j],got:actual[i].value[j]})}
   let blendMax=0,blendSum=0,blendOver2=0,blendN=0
   const referenceFrame=Buffer.alloc(expected[i].length),nativeFrame=Buffer.alloc(expected[i].length)
   if(process.env.NM_HOOK_DUMP && cases[i].hooksOverlay.width===257){writeFileSync(process.env.NM_HOOK_DUMP+'.reference.rgba',Buffer.from(expected[i]));writeFileSync(process.env.NM_HOOK_DUMP+'.native.rgba',Buffer.from(actual[i].value))}
   const kind=cases[i].hooksOverlay.effect
   const strength=kind==='filter/scratches'?.75:.5
   for(let p=0;p<expected[i].length/4;p++){
     for(let c=0;c<3;c++){
       const base=kind==='filter/scratches'?0:[64,128,192][c]
       const ra=expected[i][p*4+3]/255*strength,na=actual[i].value[p*4+3]/255*strength
       const ref=kind==='filter/scratches'?Math.max(base,ra*255):base*(1-ra)+expected[i][p*4+c]*ra
       const got=kind==='filter/scratches'?Math.max(base,na*255):base*(1-na)+actual[i].value[p*4+c]*na
       referenceFrame[p*4+c]=Math.round(ref);nativeFrame[p*4+c]=Math.round(got)
       const d=Math.abs(ref-got);blendMax=Math.max(blendMax,d);blendSum+=d;blendN++;if(d>2)blendOver2++
     }
     referenceFrame[p*4+3]=255;nativeFrame[p*4+3]=255
   }
   const visibleGrade=gradePixels(referenceFrame,nativeFrame,cases[i].hooksOverlay.width,cases[i].hooksOverlay.height)
   finalMax=Math.max(finalMax,blendMax);finalSum+=blendSum;finalN+=blendN;finalOver2+=blendOver2
   const alphaRef=expected[i].filter((_,j)=>j%4===3).reduce((a,b)=>a+b,0)/(expected[i].length/4)
   const alphaGot=actual[i].value.filter((_,j)=>j%4===3).reduce((a,b)=>a+b,0)/(actual[i].value.length/4)
   console.log(JSON.stringify({case:cases[i].hooksOverlay,segments:actual[i].segments,alphaRef,alphaGot,maxDiff:caseMax,mae:caseSum/expected[i].length,over2:caseNonzero,finalMax:blendMax,finalMAE:blendSum/blendN,finalOver2:blendOver2,visibleGrade,examples}))
   if(visibleGrade.bucket!=='exact'&&visibleGrade.bucket!=='strict')errors++
 }
 console.log(`HOOKS-VISIBLE-RASTER-DIFFERENTIAL ${JSON.stringify({reference:sourceIdentity.revision,browser:browserName,browserVersion,cases:cases.length,errors,maxDiff,mae:absolute/count,over2:nonzero,finalMax,finalMAE:finalSum/finalN,finalOver2})}`)
 const gpuCases=cases.map(({hooksOverlay:o})=>({
   id:`overlay-${o.effect.split('/')[1]}-${o.width}`,
   source:`search synth, filter\nsolid(color: ${o.effect==='filter/scratches'?'#000000':'#4080c0'}).${o.effect.split('/')[1]}(seed: 1, density: ${o.params.density}, alpha: ${o.effect==='filter/scratches'?.75:.5}).write(o0)\nrender(o0)`,
   effects:['synth/solid',o.effect],
   capture:{backend:'webgl2',width:o.width,height:o.height,time:0,deltaTime:0,frame:0,frames:1,reset:true,inputs:[],surface:'o0'}
 }))
 const gpuManifest=join(temp,'gpu-cases.json'),gpuReferenceDir=join(temp,'gpu-reference'),gpuCandidateDir=join(temp,'gpu-candidate')
 mkdirSync(gpuReferenceDir);mkdirSync(gpuCandidateDir)
 writeFileSync(gpuManifest,JSON.stringify({version:1,cases:gpuCases}))
 const gpuReference=await renderReference({cases:gpuCases,output:gpuReferenceDir,referenceRoot:process.env.NM_REFERENCE_ROOT})
 execFileSync(process.env.LOVE_BIN??'love',['parity/runner'],{cwd:projectRoot,env:{...process.env,NM_PARITY_INPUT:gpuManifest,NM_PARITY_OUTPUT:gpuCandidateDir},stdio:'inherit'})
 const gpuCandidate=JSON.parse(readFileSync(join(gpuCandidateDir,'candidate.json'),'utf8'))
 let gpuErrors=0
 for(const fixture of gpuCases){
   const referenceCase=gpuReference.cases.find(item=>item.id===fixture.id)
   const candidateCase=gpuCandidate.cases.find(item=>item.id===fixture.id)
   const grade=referenceCase?.status==='rendered'&&candidateCase?.status==='rendered'
     ?gradePixels(readFileSync(join(gpuReferenceDir,fixture.id+'.rgba')),readFileSync(join(gpuCandidateDir,fixture.id+'.rgba')),fixture.capture.width,fixture.capture.height)
     :{bucket:'fail',reference:referenceCase,candidate:candidateCase}
   console.log(`HOOKS-GPU-RASTER ${JSON.stringify({id:fixture.id,grade,referenceSurface:referenceCase?.captureSurface,candidateSurface:candidateCase?.captureSurface})}`)
   if((grade.bucket!=='exact'&&grade.bucket!=='strict')||referenceCase?.captureSurface!=='o0'||candidateCase?.captureSurface!=='o0')gpuErrors++
 }
 console.log(`HOOKS-GPU-RASTER-DIFFERENTIAL ${JSON.stringify({reference:sourceIdentity.revision,cases:gpuCases.length,errors:gpuErrors})}`)
 if(errors||gpuErrors)process.exitCode=1
}finally{rmSync(temp,{recursive:true,force:true})}
