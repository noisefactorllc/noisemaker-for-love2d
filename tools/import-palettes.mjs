#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { resolveReference } from './reference.mjs'

const projectRoot=resolve(import.meta.dirname,'..')
const {root,lock}=await resolveReference({projectRoot,referenceRoot:process.env.NM_REFERENCE_ROOT})
const {expandPalette}=await import(pathToFileURL(join(root,'shaders/src/runtime/palette-expansion.js')).href)
const paletteNames=Object.keys(JSON.parse(readFileSync(join(root,'share/palettes.json'),'utf8')))
const path=join(projectRoot,'noisemaker/catalog/palettes.lua')
const number=value=>Object.is(value,-0)?'-0':String(value)
const array=items=>'{ ' + items.map(number).join(', ') + ' }'
let output=`-- Generated from ${lock.commit}; run node tools/import-palettes.mjs to refresh.\nreturn {\n`
for(let index=1;;index++){
  const entry=expandPalette(index)
  if(!entry)break
  output+=`  [${index}] = { paletteOffset=${array(entry.paletteOffset)}, paletteAmp=${array(entry.paletteAmp)}, paletteFreq=${array(entry.paletteFreq)}, palettePhase=${array(entry.palettePhase)}, paletteMode=${number(entry.paletteMode)} },\n`
}
output+='  names = {\n'
for(const [index,name] of paletteNames.entries()) output+=`    [${JSON.stringify(name)}] = ${index},\n`
output+='  },\n}\n'
if(process.argv.includes('--check')){
  if(readFileSync(path,'utf8')!==output)throw new Error('Generated palette expansion is stale')
  console.log('palette expansion current')
}else{
  writeFileSync(path,output)
  console.log('palette expansion imported')
}
