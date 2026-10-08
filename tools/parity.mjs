#!/usr/bin/env node
import {readFileSync,writeFileSync,readdirSync,mkdirSync,existsSync,statSync} from 'node:fs'
import {join,resolve,relative} from 'node:path'
import {execFileSync} from 'node:child_process'
import {createHash} from 'node:crypto'
import {pathToFileURL} from 'node:url'
import {renderReference} from './render-reference.mjs'
import {gradePixels} from './grade.mjs'
import {resolveReference} from './reference.mjs'
import {authoredAttributionTarget,rgbContrast,effectEvidenceKind} from './attribution.mjs'
const root=resolve(import.meta.dirname,'..')
const definitions=JSON.parse(readFileSync(join(root,'noisemaker/catalog/definitions.json')))
const authority=await resolveReference()
const effects=Object.keys(JSON.parse(readFileSync(join(authority.root,'shaders/effects/manifest.json'))))
if(effects.length!==Object.keys(definitions).length||effects.some(id=>!definitions[id]))throw Error('Candidate catalog differs from locked authority')
execFileSync(process.execPath,['tools/import-corpus.mjs','--check'],{cwd:root,stdio:'inherit'})
const args=process.argv.slice(2)
const option=(name,fallback)=>{const i=args.indexOf(name);return i<0?fallback:args[i+1]}
const tier=option('--tier','all'),limit=Number(option('--limit',Infinity)),output=resolve(option('--out',join(root,'parity/out',new Date().toISOString().replaceAll(':','-'))))
mkdirSync(output,{recursive:true});mkdirSync(join(output,'inputs'),{recursive:true})
const sha256=bytes=>createHash('sha256').update(bytes).digest('hex')
const sourceEffects=source=>effects.filter(id=>new RegExp('\\b'+definitions[id].func+'\\s*\\(').test(source))
const capture={backend:'webgl2',width:257,height:129,time:.25,deltaTime:0,frame:0,frames:8,seed:1,seedPolicy:'authored',reset:true,inputs:[]}
let cases=[]
for(const family of tier==='defaults'?['coverage']:tier==='all'?['programs','coverage','portable','curated','timed']:[tier]){
 if(family==='upstream'||family==='supplemental')continue
 for(const file of readdirSync(join(root,'parity',family)).filter(x=>x.endsWith('.dsl')).sort()){
  if(tier==='defaults'&&!effects.some(id=>file===id.replace('/','_')+'.dsl'))continue
  const path=join(root,'parity',family,file),source=readFileSync(path,'utf8'),id=family+'-'+file.slice(0,-4)
  const fixture={id,source,effects:sourceEffects(source),path:relative(root,path),capture:{...capture}}
  if(family==='coverage')fixture.attributionTarget=effects.find(effect=>{
   const prefix=effect.replace('/','_')
   return file===prefix+'.dsl'||file.startsWith(prefix+'__')
  })
  if(family==='timed'){fixture.capture.frames=30;fixture.capture.deltaTime=1/60;fixture.capture.time=0;fixture.capture.advanceTime=true}
  const portable=path.replace(/\.dsl$/,'.portable.json');if(existsSync(portable)){
   fixture.portable=JSON.parse(readFileSync(portable));fixture.portable.shaders={}
   for(const pass of fixture.portable.passes){const shader=fixture.portable.func==='rings'?'rings':fixture.portable.func+'-'+pass.program;fixture.portable.shaders[pass.program]={glsl:readFileSync(join(root,'noisemaker/shaders/portable',shader+'.glsl'),'utf8')}}
  }
  const bindings=fixture.effects.map(id=>definitions[id].externalTexture).filter(Boolean)
  fixture.capture.inputs=[...new Set(bindings)].map(binding=>({binding,asset:'parity/inputs/marker.rgba',width:17,height:13,sha256:createHash('sha256').update(readFileSync(join(root,'parity/inputs/marker.rgba'))).digest('hex'),origin:'top-left',format:'rgba8'}))
  if(family==='timed'){for(const frames of [1,2,4,10,30])cases.push({...fixture,id:fixture.id+'-frame'+frames,capture:{...fixture.capture,frames}})}else cases.push(fixture)
 }
}
if(tier==='upstream'||tier==='all'||tier==='supplemental'){
 const {parseOBJ,packMeshDataForTextures}=await import(pathToFileURL(join(authority.root,'shaders/src/runtime/obj-parser.js')).href)
 const appendAuthored=(authored,file,id,source=authored.dsl,target=authoredAttributionTarget(file,authored.effects,effects),declaredEffects=authored.effects)=>{
  const inputs=[]
  for(const [index,texture] of (authored.textureInputs||[]).entries()){
   const bytes=Buffer.from(texture.data)
   if(bytes.length!==texture.width*texture.height*4)throw Error(`${file}: texture input has wrong byte count`)
   const asset=`inputs/${id}-texture${index}.rgba`
   writeFileSync(join(output,asset),bytes)
   inputs.push({kind:'texture',effect:texture.effect,uniform:texture.uniform,binding:texture.uniform,asset,assetRoot:'capture',width:texture.width,height:texture.height,format:'rgba8',sha256:sha256(bytes),origin:'bottom-left',flipY:false})
  }
  for(const [index,mesh] of (authored.meshInputs||[]).entries()){
   if(!/^share\/meshes\/[A-Za-z0-9_.-]+\.obj$/.test(mesh.path))throw Error(`${file}: invalid locked mesh path`)
   const bytes=readFileSync(join(authority.root,mesh.path))
   const parsed=parseOBJ(bytes.toString('utf8'))
   const packed=packMeshDataForTextures(parsed.positions,parsed.normals,parsed.uvs,256,256)
   if(!packed.vertexCount)throw Error(`${file}: empty mesh`)
   for(const [component,data] of [['positions',packed.positionData],['normals',packed.normalData],['uvs',packed.uvData]]){
    const binary=Buffer.from(data.buffer,data.byteOffset,data.byteLength)
    const asset=`inputs/${id}-mesh${index}-${component}.f32`
    writeFileSync(join(output,asset),binary)
    inputs.push({kind:'mesh',mesh:mesh.mesh,component,binding:`global_${mesh.mesh}_${component}`,sourcePath:mesh.path,sourceSha256:sha256(bytes),vertexCount:packed.vertexCount,asset,assetRoot:'capture',width:256,height:256,format:'rgba32f',sha256:sha256(binary),origin:'bottom-left'})
   }
  }
  cases.push({id,source,effects:declaredEffects,attributionTarget:target||undefined,authored:{schemaVersion:authored.schemaVersion,sourcePath:'parity/upstream/'+file,surface:authored.surface,settleMs:authored.settleMs||0,epsilon:authored.epsilon,requireColorVariation:authored.requireColorVariation===true,textureInputs:(authored.textureInputs||[]).length,meshInputs:(authored.meshInputs||[]).length},capture:{...capture,width:authored.resolution[0],height:authored.resolution[1],frames:authored.frames||8,surface:authored.surface||'o0',settleMs:authored.settleMs||0,requireColorVariation:authored.requireColorVariation===true,inputs}})
 }
 if(tier==='upstream'||tier==='all')for(const file of readdirSync(join(root,'parity/upstream')).filter(x=>x.endsWith('.json')).sort()){
  const authored=JSON.parse(readFileSync(join(root,'parity/upstream',file)))
  appendAuthored(authored,file,'upstream-'+file.slice(0,-5))
 }
 if(tier==='supplemental'||tier==='all'){
  const file='render_meshRender.json',authored=JSON.parse(readFileSync(join(root,'parity/upstream',file)))
  appendAuthored(authored,file,'supplemental-render_meshLoader-preview','search render\nmeshLoader().write(o0)\nrender(o0)','render/meshLoader',['render/meshLoader'])
  cases.at(-1).capture.width=31;cases.at(-1).capture.height=13
  const width=64,height=64,rgba=Buffer.alloc(width*height*4)
  const glyphs=[['10001','10001','10001','11111','10001','10001','10001'],['11111','00100','00100','00100','00100','00100','11111']]
  for(let letter=0;letter<glyphs.length;letter++)for(let row=0;row<7;row++)for(let column=0;column<5;column++){
   if(glyphs[letter][row][column]!=='1')continue
   for(let dy=0;dy<5;dy++)for(let dx=0;dx<5;dx++){
    const x=3+letter*32+column*5+dx,y=14+row*5+dy,at=(y*width+x)*4
    rgba[at]=255;rgba[at+1]=255;rgba[at+2]=255;rgba[at+3]=255
   }
  }
  const id='supplemental-filter_text-glyph',asset='inputs/'+id+'.rgba'
  writeFileSync(join(output,asset),rgba)
  cases.push({id,source:'search synth, filter\ntestPattern(pattern: colorBars).text(matteColor: #000000, matteOpacity: 0).write(o0)\nrender(o0)',effects:['synth/testPattern','filter/text'],attributionTarget:'filter/text',
   authored:{schemaVersion:1,sourcePath:'shaders/effects/filter/text/definition.js',textureInputs:1,meshInputs:0,requireColorVariation:true},
   capture:{...capture,width,height,surface:'o0',requireColorVariation:true,inputs:[{kind:'texture',effect:'filter/text',uniform:'textTex',binding:'textTex',asset,assetRoot:'capture',width,height,format:'rgba8',sha256:sha256(rgba),origin:'bottom-left',flipY:false}]}})
  const activeFrames={...capture,time:0,deltaTime:1/60,frames:12,advanceTime:true}
  cases.push({id:'supplemental-filter_motionBlur-active',
   source:'search synth, filter\nnoise(seed: 1, speed: 40, scaleX: 50, scaleY: 50).motionBlur(amount: 80).write(o0)\nrender(o0)\n',
   effects:['synth/noise','filter/motionBlur'],attributionTarget:'filter/motionBlur',capture:{...activeFrames}})
  cases.push({id:'supplemental-filter_temporalAberration-active',
   source:readFileSync(join(root,'parity/coverage/filter_temporalAberration.dsl'),'utf8'),
   effects:['synth/noise','filter/temporalAberration'],attributionTarget:'filter/temporalAberration',capture:{...activeFrames}})
  const loopSource='search synth, filter, render\nnoise(seed: 1, speed: 40, scaleX: 50, scaleY: 50).loopBegin(alpha: 100).blur().loopEnd().write(o0)\nrender(o0)\n'
  cases.push({id:'supplemental-render_loopEnd-active',source:loopSource,
   effects:['synth/noise','render/loopBegin','filter/blur','render/loopEnd'],attributionTarget:'render/loopEnd',
   causalControl:'supplemental-render_loopEnd-control',capture:{...activeFrames}})
  cases.push({id:'supplemental-render_loopEnd-control',source:loopSource.replace('.loopEnd()',''),
   effects:['synth/noise','render/loopBegin','filter/blur'],capture:{...activeFrames}})
  const midi={clockCount:24,notes:[{channel:1,key:60,velocity:127},{channel:1,key:64,velocity:96},{channel:9,key:72,velocity:110}]}
  cases.push({id:'supplemental-synth_roll-midi',
   source:readFileSync(join(root,'parity/coverage/synth_roll.dsl'),'utf8'),effects:['synth/roll'],attributionTarget:'synth/roll',
   capture:{...capture,time:.25,deltaTime:1/60,frames:8,advanceTime:true,midi}})
  const physicalSource=readFileSync(join(root,'parity/coverage/points_physical.dsl'),'utf8')
  if(!physicalSource.includes('.physical()'))throw Error('Physical coverage source no longer has the default physics step')
  const forcedPhysical=physicalSource.replace('.physical()',
   '.physical(gravity: 2, wind: 2, energy: 2, drag: 0, deviation: 0, wander: 0)')
  cases.push({id:'supplemental-points_physical-forced',source:forcedPhysical,
   effects:sourceEffects(forcedPhysical),attributionTarget:'points/physical',capture:{...capture}})
  const heightGridSource=readFileSync(join(root,'parity/coverage/points_heightGrid.dsl'),'utf8')
  cases.push({id:'supplemental-points_heightGrid-first-state',source:heightGridSource,
   effects:sourceEffects(heightGridSource),attributionTarget:'points/heightGrid',
   capture:{...capture,frames:1}})
 }
}
const ids=option('--ids',null)?.split(',').filter(Boolean)
if(ids){const available=new Set(cases.map(item=>item.id));for(const id of ids)if(!available.has(id))throw Error('Unknown parity case '+id);cases=cases.filter(item=>ids.includes(item.id))}
const expected=cases.length;cases=cases.slice(0,limit)
mkdirSync(join(output,'reference'));mkdirSync(join(output,'candidate'))
const nativeCapabilitiesPath=join(output,'native-capabilities.json')
execFileSync(process.env.LOVE_BIN||'love',['parity/runner'],{cwd:root,env:{...process.env,NM_PARITY_CAPS_OUTPUT:nativeCapabilitiesPath},stdio:'inherit'})
const {maxTextureSize:nativeMaxTextureSize}=JSON.parse(readFileSync(nativeCapabilitiesPath,'utf8'))
if(!Number.isSafeInteger(nativeMaxTextureSize)||nativeMaxTextureSize<1)throw Error('Invalid native texture limit probe')
let sourceFiles={}
function hashTree(directory){for(const entry of readdirSync(directory,{withFileTypes:true})){const path=join(directory,entry.name);if(entry.isDirectory())hashTree(path);else if(entry.isFile())sourceFiles[relative(root,path)]=createHash('sha256').update(readFileSync(path)).digest('hex')}}
for(const directory of ['noisemaker','tools','parity/runner'])hashTree(join(root,directory))
writeFileSync(join(output,'candidate-source.json'),JSON.stringify(sourceFiles,null,2)+'\n')
const reference=await renderReference({cases,output:join(output,'reference'),nativeMaxTextureSize,onProgress:r=>console.error('reference '+r.id+': '+r.status+(r.message?' '+r.message:''))})
const capabilities=reference.capabilities
if(capabilities.nativeMaxTextureSize!==nativeMaxTextureSize||
   capabilities.commonMaxTextureSize!==Math.min(capabilities.browserMaxTextureSize,nativeMaxTextureSize))throw Error('Invalid common texture limit negotiation')
for(const fixture of cases)fixture.volumeSizeChanges=reference.cases.find(item=>item.id===fixture.id)?.volumeSizeChanges??null
writeFileSync(join(output,'cases.json'),JSON.stringify({version:1,capabilities,cases},null,2)+'\n')
execFileSync(process.env.LOVE_BIN||'love',['parity/runner'],{cwd:root,env:{...process.env,NM_PARITY_INPUT:join(output,'cases.json'),NM_PARITY_OUTPUT:join(output,'candidate')},stdio:'inherit'})
const candidate=JSON.parse(readFileSync(join(output,'candidate/candidate.json')))
if(candidate.capabilities?.nativeMaxTextureSize!==nativeMaxTextureSize||
   candidate.capabilities?.commonMaxTextureSize!==capabilities.commonMaxTextureSize)throw Error('Native runner did not honor negotiated texture limit')
const results=[],evidenced=new Set()
const summary={expected,executed:cases.length,exact:0,strict:0,near:0,defer:0,skip:0,fail:0,missing:expected-cases.length,uninformative:0,effects:effects.length,effects_evidenced:0}
const consumedKeys=items=>(Array.isArray(items)?items:Object.values(items||{})).flatMap(item=>item.kind==='mesh'&&item.components?item.components.map(part=>part.binding+':'+part.sha256):[item.binding+':'+item.sha256]).sort()
const volumeChangeTuples=changes=>(changes||[]).map(change=>[change.passIndex,change.key,change.requested,change.effective])
for(const fixture of cases){
 const oracle=reference.cases.find(x=>x.id===fixture.id),actual=candidate.cases.find(x=>x.id===fixture.id)
 const expectedInputs=consumedKeys(fixture.capture.inputs)
 let result
 if(!oracle||!actual)result={bucket:'missing',reason:'runner omitted case'}
 else if(oracle.status!=='rendered'||actual.status!=='rendered')result={bucket:'fail',reason:'render failed',reference:oracle,candidate:actual}
 else if(oracle.width!==actual.width||oracle.height!==actual.height)result={bucket:'fail',reason:'dimensions differ'}
 else if(fixture.capture.surface&&(oracle.captureSurface!==fixture.capture.surface||actual.captureSurface!==fixture.capture.surface))result={bucket:'fail',reason:'authored surface was not captured'}
 else if(fixture.capture.settleMs&&(!oracle.settled||!actual.settled))result={bucket:'fail',reason:'authored settling requirement failed'}
 else if(JSON.stringify(fixture.capture.midi||null)!==JSON.stringify(oracle.midiSnapshot||null)||
         JSON.stringify(fixture.capture.midi||null)!==JSON.stringify(actual.midiSnapshot||null))
  result={bucket:'fail',reason:'captured MIDI state differs',expected:fixture.capture.midi||null,reference:oracle.midiSnapshot||null,candidate:actual.midiSnapshot||null}
 else if(JSON.stringify(volumeChangeTuples(oracle.volumeSizeChanges))!==JSON.stringify(volumeChangeTuples(actual.volumeSizeChanges)))result={bucket:'fail',reason:'volume size capability clamp differs',referenceChanges:oracle.volumeSizeChanges,candidateChanges:actual.volumeSizeChanges}
 else if(JSON.stringify(expectedInputs)!==JSON.stringify(consumedKeys(oracle.consumed))||JSON.stringify(expectedInputs)!==JSON.stringify(consumedKeys(actual.consumed)))result={bucket:'fail',reason:'fixture input was not consumed',expectedInputs,referenceInputs:consumedKeys(oracle.consumed),candidateInputs:consumedKeys(actual.consumed)}
 else result=gradePixels(readFileSync(join(output,'reference',fixture.id+'.rgba')),readFileSync(join(output,'candidate',fixture.id+'.rgba')),oracle.width,oracle.height)
 summary[result.bucket]++
 if(result.uninformative&&(result.bucket==='exact'||result.bucket==='strict')){summary[result.bucket]--;summary.uninformative++;result.pixelBucket=result.bucket;result.bucket='uninformative'}
 const target=oracle?.targetEvidence
 results.push({id:fixture.id,contributingEffects:oracle?.contributingEffects||[],targetEvidence:target||null,volumeSizeChanges:oracle?.volumeSizeChanges??null,...result})
}
const byId=new Map(results.map(result=>[result.id,result]))
const pixelMatch=result=>result&&['exact','strict'].includes(result.pixelBucket||result.bucket)
for(const fixture of cases){
 const result=byId.get(fixture.id)
 if(!['exact','strict'].includes(result.bucket)||result.uninformative)continue
 let control
 if(fixture.causalControl){
  const comparison=byId.get(fixture.causalControl)
  const oracle=reference.cases.find(item=>item.id===fixture.id)
  const referenceControl=reference.cases.find(item=>item.id===fixture.causalControl)
  const nativeControl=candidate.cases.find(item=>item.id===fixture.causalControl)
  const matched=Boolean(pixelMatch(comparison)&&referenceControl?.width===oracle.width&&
    referenceControl?.height===oracle.height&&nativeControl?.width===oracle.width&&nativeControl?.height===oracle.height)
  control={id:fixture.causalControl,matched}
  if(matched)for(const side of ['reference','candidate'])control[side]=rgbContrast(
   readFileSync(join(output,side,fixture.id+'.rgba')),
   readFileSync(join(output,side,fixture.causalControl+'.rgba')))
  result.causalControlEvidence=control
 }
 const kind=effectEvidenceKind(result.targetEvidence,result.contributingEffects,control)
 if(kind){result.effectEvidenceKind=kind;evidenced.add(result.targetEvidence.target)}
}
summary.effects_evidenced=evidenced.size
const capturedSource=sourceFiles;sourceFiles={}
for(const directory of ['noisemaker','tools','parity/runner'])hashTree(join(root,directory))
const sourceStable=JSON.stringify(capturedSource)===JSON.stringify(sourceFiles)
if(!sourceStable)console.error('Candidate source changed during parity run; evidence is diagnostic only')
writeFileSync(join(output,'results.json'),JSON.stringify({summary,sourceStable,capabilities,unevidenced:effects.filter(x=>!evidenced.has(x)),cases:results},null,2)+'\n')
console.log('PARITY-SUMMARY '+JSON.stringify(summary))
console.log('PARITY-RESULT '+output)
const requiredEffects=ids?[...new Set(cases.map(item=>item.attributionTarget).filter(Boolean))]:effects
if(!sourceStable||summary.near+summary.defer+summary.skip+summary.fail+summary.missing>0||requiredEffects.some(effect=>!evidenced.has(effect)))process.exitCode=1
