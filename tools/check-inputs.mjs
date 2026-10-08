import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { resolveReference } from './reference.mjs'
const projectRoot=resolve(import.meta.dirname,'..')
const {root,sourceIdentity}=await resolveReference({projectRoot,referenceRoot:process.env.NM_REFERENCE_ROOT})
const {expandPalette}=await import(pathToFileURL(join(root,'shaders/src/runtime/palette-expansion.js')).href)
const {MidiState,AudioState}=await import(pathToFileURL(join(root,'shaders/src/runtime/external-input.js')).href)
const cases=[]
for(let index=0;index<=56;index++) cases.push({name:`palette/${index}`,paletteIndex:index})
const keys=Array(128).fill(0); keys[0]=127;keys[60]=80;keys[127]=32
cases.push({name:'midi/noteGrid',inputSnapshot:{midi:{clockCount:24,channels:{'1':{keys},'3':{keys:keys.map((x,i)=>i===5?100:0)}}}}})
cases.push({name:'audio/arrays',inputSnapshot:{audio:{low:0.2,mid:0.4,high:0.7,vol:0.5,raw:-0.25,rawReady:true,
  waveform:[0.1,0.2,0.3],spectrum:[0.4,0.5]}}})
cases.push({name:'midi/selectById',inputSnapshot:{midi:{ports:[
  {id:'a',name:'keys',connected:true,channels:{'1':{key:50,velocity:90,gate:1,time:100}}},
  {id:'b',name:'keys',connected:true,channels:{'1':{key:60,velocity:80,gate:1,time:200}}}]}},midiSelector:{id:'b',name:'keys',channel:1}})
cases.push({name:'midi/ambiguousName',inputSnapshot:{midi:{ports:[
  {id:'a',name:'keys',connected:true,channels:{'1':{key:50}}},
  {id:'b',name:'keys',connected:true,channels:{'1':{key:60}}}]}},midiSelector:{name:'keys',channel:1}})
cases.push({name:'audio/selectById',inputSnapshot:{audio:{devices:[
  {id:'a',name:'mic',connected:true,channels:{'1':{low:0.1,mid:0.2,high:0.3,vol:0.2}}},
  {id:'b',name:'mic',connected:true,channels:{'1':{low:0.6,mid:0.7,high:0.8,vol:0.7}}}]}},audioSelector:{id:'b',name:'mic',channel:1}})
const temp=mkdtempSync(join(tmpdir(),'nm-love-inputs-'))
try {
  const input=join(temp,'input.json'),output=join(temp,'output.json')
  writeFileSync(input,JSON.stringify(cases))
  execFileSync(process.env.LOVE_BIN??'love',['tests/compiler'],{
    cwd:projectRoot,env:{...process.env,NM_FRONTEND_INPUT:input,NM_FRONTEND_OUTPUT:output},stdio:'inherit'
  })
  const actual=JSON.parse(readFileSync(output,'utf8'))
  let errors=0,maxError=0
  for(let i=0;i<cases.length;i++) {
    const item=cases[i],observed=actual[i]
    let expected
    if(item.paletteIndex!==undefined) expected=expandPalette(item.paletteIndex)
    else if(item.name==='midi/noteGrid') {
      const midi=new MidiState({portRegistry:false})
      midi.clockCount=24
      midi.channels[1].keys.set(keys)
      midi.channels[3].keys[5]=100
      midi.updateNoteGrid()
      expected={uniforms:{midiClockCount:24},textures:{midiNoteGrid:{width:128,height:16,format:'rgba32float',data:[...midi.noteGrid]}}}
    } else if(item.name==='audio/arrays') {
      expected={uniforms:{audioWaveform:[0.1,0.2,0.3,...Array(125).fill(0.5)],audioSpectrum:[0.4,0.5,...Array(126).fill(0)]},textures:{},}
    } else if(item.name==='midi/selectById') expected={selectedMidi:{key:60,velocity:80,gate:1,time:200}}
    else if(item.name==='midi/ambiguousName') expected={selectedMidi:null}
    else if(item.name==='audio/selectById') expected={selectedAudio:{low:0.6,mid:0.7,high:0.8,vol:0.7}}
    const value=observed?.value
    if(!observed?.ok) {console.error(`MISMATCH ${item.name}: ${JSON.stringify(observed)}`);errors++;continue}
    function check(exp,got,path) {
      if(exp===null) {if(got!==null) {console.error(`MISMATCH ${item.name} ${path}: ${JSON.stringify(got)}`);errors++}return}
      if(typeof exp==='number') {const diff=Math.abs(exp-got);maxError=Math.max(maxError,diff);if(!Number.isFinite(diff)||diff>1e-7){console.error(`MISMATCH ${item.name} ${path}: ${exp} != ${got}`);errors++}return}
      if(Array.isArray(exp)) {if(!Array.isArray(got)||exp.length!==got.length){console.error(`MISMATCH ${item.name} ${path} length`);errors++;return}for(let j=0;j<exp.length;j++) check(exp[j],got[j],`${path}/${j}`);return}
      if(typeof exp==='object') {if(!got||typeof got!=='object'){console.error(`MISMATCH ${item.name} ${path} object`);errors++;return}for(const key of Object.keys(exp))check(exp[key],got[key],`${path}/${key}`);return}
      if(exp!==got){console.error(`MISMATCH ${item.name} ${path}: ${exp} != ${got}`);errors++}
    }
    check(expected,value,item.name)
  }
  console.log(`INPUTS-DIFFERENTIAL ${JSON.stringify({reference:sourceIdentity.revision,cases:cases.length,errors,maxError})}`)
  if(errors)process.exitCode=1
} finally {rmSync(temp,{recursive:true,force:true})}
