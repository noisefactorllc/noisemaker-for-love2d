import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { resolveReference } from './reference.mjs'
const projectRoot=resolve(import.meta.dirname,'..')
const {root,sourceIdentity}=await resolveReference({projectRoot,referenceRoot:process.env.NM_REFERENCE_ROOT})
const {Pipeline}=await import(pathToFileURL(join(root,'shaders/src/runtime/pipeline.js')).href)
const osc=(oscType,fields={})=>({type:'Oscillator',oscType,min:0,max:1,speed:1,offset:0,seed:1,...fields})
const midi=(mode,fields={})=>({type:'Midi',channel:1,mode,min:0,max:1,sensitivity:1,...fields})
const audio=(band,fields={})=>({type:'Audio',band,min:0,max:1,...fields})
const cases=[]
cases.push({name:'midi/default-millisecond-wall-clock',automationClockProbe:true})
for (let kind=0;kind<=6;kind++) for (const time of [-1.25,-0.1,0,0.125,0.25,0.5,0.9,1,1.75]) {
  cases.push({name:`osc/${kind}/${time}`,automation:osc(kind,{seed:47,speed:-2.5,offset:0.125,min:-0.2,max:0.85}),time,range:{min:-3,max:7}})
}
for (const kind of [0,1,2,3,4,5,6]) for (const time of [0,0.1,0.35,0.9,1]) {
  cases.push({name:`modulated/${kind}/${time}`,automation:osc(kind,{speed:osc(2,{speed:3,min:0.25,max:0.8}),min:osc(0,{speed:2}),max:osc(1,{speed:-1,offset:0.2})}),time,range:{min:4,max:14}})
}
for (const kind of [0,1,2,3,4]) for (const time of [0.125,0.5,1.75]) {
  cases.push({name:`exact-integral/${kind}/${time}`,automation:osc(0,{speed:osc(kind,{min:0.1,max:0.9,speed:-3,offset:0.35})}),time})
}
for (const band of [0,1,2,3,4,9]) for (const rawReady of [true,false]) {
  cases.push({name:`audio/${band}/${rawReady}`,automation:audio(band,{min:-1,max:2}),time:0.5,
    external:{audio:{low:0.2,mid:0.5,high:0.9,vol:0.35,raw:-0.4,rawReady}}})
}
for (const mode of [0,1,2,3,4,5,6,7,8,9,10]) for (const gate of [0,1]) {
  const channel={key:60,velocity:100,gate,time:900,cc:[32,64],cc14:[8192,16383],nrpn:{'100':4096},pitchBend:1024,pressure:50,polyPressure:Array(61).fill(0)}
  channel.polyPressure[60]=42
  cases.push({name:`midi/${mode}/${gate}`,automation:midi(mode,{cc:1,nrpn:100,min:0.1,max:0.9}),time:0.4,
    external:{midi:{channels:{'1':channel}}},wallTime:1000})
}
for (const time of [0.13,0.51,0.88]) {
  cases.push({name:`nested-midi/${time}`,automation:osc(0,{speed:midi(5,{cc:0,min:0,max:1})}),time,
    external:{midi:{channels:{'1':{key:60,velocity:90,gate:1,time:900,cc:[64]}}}},wallTime:1000})
}
const temp=mkdtempSync(join(tmpdir(),'nm-love-automation-'))
try {
  const input=join(temp,'input.json'),output=join(temp,'output.json')
  writeFileSync(input,JSON.stringify(cases))
  const launchTime=Date.now()
  execFileSync(process.env.LOVE_BIN ?? 'love',['tests/compiler'],{
    cwd:projectRoot,env:{...process.env,NM_FRONTEND_INPUT:input,NM_FRONTEND_OUTPUT:output},stdio:'inherit'
  })
  const exitTime=Date.now()
  const actual=JSON.parse(readFileSync(output,'utf8'))
  const originalNow=Date.now
  let errors=0,maxError=0
  for (let i=0;i<cases.length;i++) {
    const item=cases[i]
    if (item.automationClockProbe) {
      const observed=actual[i]
      if (!observed?.ok || !Number.isSafeInteger(observed.value.wallTime) ||
        observed.value.wallTime<launchTime-100 ||
        observed.value.wallTime>exitTime+100 ||
        Math.abs(observed.value.resolved-0.75)>0.02) {
        console.error(`MISMATCH ${item.name}: ${JSON.stringify(observed)} (launch=${launchTime}, exit=${exitTime})`)
        errors++
      }
      continue
    }
    const external=structuredClone(item.external ?? {})
    if (external.midi) {
      const midiState=external.midi
      midiState.getChannel=channel=>midiState.channels[channel]
      for (const channel of Object.values(midiState.channels)) {
        channel.nrpn=new Map(Object.entries(channel.nrpn ?? {}).map(([key,value])=>[Number(key),value]))
      }
    }
    Date.now=()=>item.wallTime ?? 1000
    let expected
    try { expected=Pipeline.prototype.resolveUniformValue.call({externalState:external},item.automation,item.time,item.range) }
    catch (error) {expected=String(error)}
    finally { Date.now=originalNow }
    const observed=actual[i]
    if (!observed?.ok || typeof observed.value!=='number' || !Number.isFinite(expected)) {
      console.error(`MISMATCH ${item.name}: ref=${expected} native=${JSON.stringify(observed)}`);errors++
    } else {
      const diff=Math.abs(expected-observed.value)
      maxError=Math.max(maxError,diff)
      if (diff>1e-9) { console.error(`MISMATCH ${item.name}: ref=${expected} native=${observed.value} diff=${diff}`);errors++ }
    }
    if (errors>=15) break
  }
  console.log(`AUTOMATION-DIFFERENTIAL ${JSON.stringify({reference:sourceIdentity.revision,cases:cases.length,errors,maxError})}`)
  if (errors) process.exitCode=1
} finally {Date.now=Date.now;rmSync(temp,{recursive:true,force:true})}
