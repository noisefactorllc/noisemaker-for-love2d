#!/usr/bin/env node
import {readFileSync,readdirSync,mkdirSync,writeFileSync,existsSync} from 'node:fs'
import {join,resolve,relative} from 'node:path'
import {createHash} from 'node:crypto'
import {execFileSync} from 'node:child_process'
import {resolveReference} from './reference.mjs'
const project=resolve(import.meta.dirname,'..')
const source=process.env.NM_SHARED_CORPUS_ROOT
const sha=x=>createHash('sha256').update(x).digest('hex')
const provenancePath=join(project,'parity/corpus.json')
if(process.argv.includes('--check')){
 const inventory=JSON.parse(readFileSync(provenancePath));let count=0
 for(const entry of inventory.files){if(sha(readFileSync(join(project,entry.path)))!==entry.sha256)throw Error(`Corpus changed: ${entry.path}`);count++}
 console.log(`CORPUS-CHECK ${count} source-bound files`)
}else{
 if(!source)throw Error('Set NM_SHARED_CORPUS_ROOT to the shared port repository to import its corpus')
 const files=[]
 for(const family of ['programs','coverage','portable','timed','curated']){
  const directory=join(source,'parity',family)
  for(const filename of readdirSync(directory).sort()){
   if(!/\.(dsl|json|glsl|vert|frag|wgsl)$/.test(filename))continue
   const bytes=readFileSync(join(directory,filename)),target=join(project,'parity',family,filename)
   mkdirSync(join(project,'parity',family),{recursive:true});writeFileSync(target,bytes)
   files.push({path:relative(project,target),sha256:sha(bytes)})
  }
 }
 const reference=await resolveReference({referenceRoot:process.env.NM_REFERENCE_ROOT})
 const effectManifest=JSON.parse(readFileSync(join(reference.root,'shaders/effects/manifest.json')))
 mkdirSync(join(project,'parity/upstream'),{recursive:true})
 for(const effect of Object.keys(effectManifest).sort()){
  const sourcePath=join(reference.root,'shaders/effects',effect,'parity-case.json')
  if(!existsSync(sourcePath))continue
  const bytes=readFileSync(sourcePath),path='parity/upstream/'+effect.replace('/','_')+'.json'
  writeFileSync(join(project,path),bytes);files.push({path,sha256:sha(bytes),authority:effect+'/parity-case.json'})
 }
 const revision=execFileSync('git',['rev-parse','HEAD'],{cwd:source,encoding:'utf8'}).trim()
 const dirty=execFileSync('git',['status','--porcelain','--','parity/programs','parity/coverage','parity/portable','parity/timed','parity/curated'],{cwd:source,encoding:'utf8'}).trim()!==''
 writeFileSync(provenancePath,JSON.stringify({version:1,source:'noisefactorllc/noisemaker-for-rust-gpu',revision,dirty,authority:reference.sourceIdentity.revision,files},null,2)+'\n')
 console.log(`Imported ${files.length} shared corpus files`)
}
