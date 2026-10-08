#!/usr/bin/env node
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { isDeepStrictEqual } from 'node:util'
import { resolveReference } from './reference.mjs'

const projectRoot=resolve(import.meta.dirname,'..')
const {root,sourceIdentity}=await resolveReference({projectRoot,referenceRoot:process.env.NM_REFERENCE_ROOT})
const {validateEffectDefinition}=await import(pathToFileURL(join(root,'shaders/src/runtime/effect-validator.js')).href)
const base={name:'Portable',namespace:'user',func:'portable',globals:{gain:{type:'float',default:0.5,min:0,max:1,uniform:'gain'}},
  passes:[{program:'main',inputs:{},outputs:{color:'outputTex'}}],shaders:{main:{glsl:'#version 300 es\nvoid main(){}'}}}
const cases=[{name:'valid',def:base},{name:'null',def:null},{name:'array',def:[]},{name:'number',def:7}]
function variant(name,change){const def=structuredClone(base); change(def); cases.push({name,def})}
variant('name',d=>delete d.name)
variant('unknown-top',d=>d.surprise=true)
variant('missing-passes',d=>d.passes=[])
variant('invalid-tag',d=>d.tags=['bogus'])
variant('invalid-globals',d=>d.globals='bad')
variant('unknown-global-type',d=>d.globals.gain.type='quaternion')
variant('global-default',d=>d.globals.gain.default='bad')
variant('global-min',d=>d.globals.gain.min='bad')
variant('global-range',d=>d.globals.gain.min=2)
variant('global-choices',d=>d.globals.gain.choices={one:1,two:2})
variant('global-ui',d=>d.globals.gain.ui={label:'Gain',control:'slider',surprise:true})
variant('global-ui-enabled',d=>d.globals.gain.ui={enabledBy:'missing'})
variant('global-unknown',d=>d.globals.gain.unexpected=2)
variant('global-alias',d=>d.paramAliases={old:'missing'})
variant('unknown-pass-field',d=>d.passes[0].nonsense=true)
variant('pass-program',d=>delete d.passes[0].program)
variant('pass-input',d=>d.passes[0].inputs={src:'unknown'})
variant('pass-output',d=>d.passes[0].outputs={color:'unknown'})
variant('pass-count',d=>d.passes[0].count=0)
variant('pass-repeat',d=>d.passes[0].repeat=0)
variant('pass-blend',d=>d.passes[0].blend=['one'])
variant('pass-condition',d=>d.passes[0].conditions={runIf:[{uniform:'missing',equals:1}]})
variant('pass-sampler',d=>d.passes[0].samplerTypes={src:'bad'})
variant('pass-viewport',d=>d.passes[0].viewport={width:{param:'x',power:'bad'}})
variant('texture-format',d=>d.textures={state:{format:'bad'}})
variant('texture-dimension',d=>d.textures={state:{width:{scale:'bad',clamp:{min:'bad'}}}})
variant('texture-mipmap',d=>d.textures3d={volume:{mipmaps:true}})
variant('shader-map',d=>d.shaders.main='bad')
variant('layout-entry',d=>d.uniformLayout={gain:{slot:0,components:'wx'}})
variant('layout-conflict',d=>d.uniformLayout={gain:{slot:0,components:'x'},other:{slot:0,components:'x'}})
variant('byte-layout',d=>d.uniformLayout={type:'byte',layout:[{name:'a',offset:0,size:8,type:'float'},{name:'b',offset:4,size:8,type:'float'}]})

const directory=mkdtempSync(join(tmpdir(),'nm-love-portable-'))
try{
  const input=join(directory,'input.json'),output=join(directory,'output.json')
  writeFileSync(input,JSON.stringify(cases.map(item=>item.def)))
  execFileSync(process.env.LOVE_BIN??'love',['tests/compiler'],{cwd:projectRoot,
    env:{...process.env,NM_PORTABLE_INPUT:input,NM_PORTABLE_OUTPUT:output},stdio:'inherit'})
  const actual=JSON.parse(readFileSync(output,'utf8'))
  let errors=0
  for(let i=0;i<cases.length;i++){
    const expected=validateEffectDefinition(cases[i].def)
    if(!isDeepStrictEqual(expected,actual[i])){
      console.error(`MISMATCH ${cases[i].name}: ${JSON.stringify(expected)} != ${JSON.stringify(actual[i])}`)
      errors++
    }
  }
  console.log(`PORTABLE-DIFFERENTIAL ${JSON.stringify({reference:sourceIdentity.revision,cases:cases.length,errors})}`)
  if(errors)process.exitCode=1
}finally{rmSync(directory,{recursive:true,force:true})}
