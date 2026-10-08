#!/usr/bin/env node
import {createServer} from 'node:http'
import {readFileSync,writeFileSync,mkdirSync,statSync} from 'node:fs'
import {resolve,join,extname,sep} from 'node:path'
import {createRequire} from 'node:module'
import {createHash} from 'node:crypto'
import {resolveReference} from './reference.mjs'

export async function renderReference({cases,output,referenceRoot=process.env.NM_REFERENCE_ROOT,onProgress=()=>{},testInputReadbackFailureCaseId=null,testInputIncompleteFramebufferCaseId=null,nativeMaxTextureSize=null}){
 const reference=await resolveReference({referenceRoot})
 const fixtureAssets=new Map()
 const require=createRequire(import.meta.url)
 const browserName=process.env.NM_REFERENCE_BROWSER||'firefox'
 if(browserName!=='chrome'&&browserName!=='firefox')throw Error('NM_REFERENCE_BROWSER must be chrome or firefox')
 if(browserName==='firefox'&&process.env.NM_ANGLE_BACKEND)throw Error('NM_ANGLE_BACKEND applies only to Chrome')
 const browsers=process.env.NM_PLAYWRIGHT_MODULE?await import(process.env.NM_PLAYWRIGHT_MODULE):require('playwright')
 const server=createServer((req,res)=>{
  try{
   const pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname)
   if(pathname==='/'){res.setHeader('Content-Type','text/html');res.end('<!doctype html><canvas id="render"></canvas>');return}
   if(pathname.startsWith('/__fixture_asset__/')){
    const asset=fixtureAssets.get(pathname.slice('/__fixture_asset__/'.length))
    if(!asset)throw Error('Unknown fixture asset')
    res.setHeader('Content-Type','application/octet-stream');res.end(asset);return
   }
   const path=resolve(reference.root,'.'+pathname)
   if(!path.startsWith(reference.root+sep))throw Error('Invalid path')
   res.setHeader('Content-Type',extname(path)==='.js'?'text/javascript':extname(path)==='.json'?'application/json':'text/plain')
   res.end(readFileSync(path))
  }catch(e){res.statusCode=404;res.end('Not found')}
 })
 await new Promise(r=>server.listen(0,'127.0.0.1',r))
 let browser
 try{
  browser=browserName==='firefox'
   ?await browsers.firefox.launch({headless:true,firefoxUserPrefs:{'webgl.sanitize-unmasked-renderer':false}})
   :await browsers.chromium.launch({channel:process.env.NM_BROWSER_CHANNEL||'chrome',headless:true,args:['--enable-gpu',...(process.env.NM_ANGLE_BACKEND?['--use-angle='+process.env.NM_ANGLE_BACKEND]:[])]})
  const page=await browser.newPage()
  let browserErrors=[]
  page.on('console',message=>{if(message.type()==='error')browserErrors.push(message.text())})
  page.on('pageerror',error=>browserErrors.push(error.message))
  await page.goto(`http://127.0.0.1:${server.address().port}/`)
  await page.evaluate(async()=>{
   const [{CanvasRenderer},enums,{stdEnums},compiler,pipeline]=await Promise.all([
    import('/shaders/src/renderer/canvas.js'),import('/shaders/src/lang/enums.js'),import('/shaders/src/lang/std_enums.js'),import('/shaders/src/runtime/compiler.js'),import('/shaders/src/runtime/pipeline.js')])
   await enums.mergeIntoEnums(stdEnums)
   const manifest=await(await fetch('/shaders/effects/manifest.json')).json()
   for(const [id,entry]of Object.entries(manifest)){
    const [namespace,name]=id.split('/');const mod=await import(`/shaders/effects/${id}/definition.js`)
    const instance=typeof mod.default==='function'?new mod.default():mod.default;instance.shaders??={}
    for(const [program,glsl]of Object.entries(entry.glsl||{})){
     const shader=instance.shaders[program]??={};const base=`/shaders/effects/${id}/glsl/${program}`
     if(glsl==='combined')shader.glsl=await(await fetch(base+'.glsl')).text()
     else{if(glsl.v)shader.vertex=await(await fetch(base+'.vert')).text();if(glsl.f)shader.fragment=await(await fetch(base+'.frag')).text()}
    }
    const effect={namespace,name,instance}
    const choices=CanvasRenderer.prototype.registerEffectWithRuntime.call({},effect)
    if(choices&&Object.keys(choices).length)await enums.mergeIntoEnums(choices)
    CanvasRenderer.prototype.registerStarterOpForEffect.call({},effect)
   }
   window.nmReference={compiler,pipeline,CanvasRenderer,enums}
  })
  const browserMaxTextureSize=await page.evaluate(()=>{
   const gl=document.createElement('canvas').getContext('webgl2')
   if(!gl)throw Error('Reference WebGL2 capability probe failed')
   const limit=gl.getParameter(gl.MAX_TEXTURE_SIZE)
   gl.getExtension('WEBGL_lose_context')?.loseContext()
   return limit
  })
  if(!Number.isSafeInteger(browserMaxTextureSize)||browserMaxTextureSize<1)throw Error('Invalid reference MAX_TEXTURE_SIZE')
  if(nativeMaxTextureSize!==null&&(!Number.isSafeInteger(nativeMaxTextureSize)||nativeMaxTextureSize<1))throw Error('Invalid native max texture size')
  const commonMaxTextureSize=nativeMaxTextureSize===null?null:Math.min(browserMaxTextureSize,nativeMaxTextureSize)
  if(commonMaxTextureSize!==null)for(const fixture of cases){
   fixture.capture={...(fixture.capture||{}),commonMaxTextureSize}
  }
  const results=[];mkdirSync(output,{recursive:true})
  for(const fixture of cases){
   browserErrors=[]
   let result
   try{
    const loadedInputs=(fixture.capture?.inputs||[]).map(spec=>{
     const assetRoot=spec.assetRoot==='capture'?resolve(output,'..'):resolve(import.meta.dirname,'..')
     if(spec.assetRoot&&spec.assetRoot!=='capture')throw Error('Unknown fixture asset root')
     const path=resolve(assetRoot,spec.asset)
     if(!path.startsWith(assetRoot+sep))throw Error('Input asset escapes its root')
     const bytes=readFileSync(path)
     const channels=spec.format==='rgba32f'?16:4
     if(createHash('sha256').update(bytes).digest('hex')!==spec.sha256||bytes.length!==spec.width*spec.height*channels)throw Error('Input asset hash or dimensions mismatch')
     fixtureAssets.set(spec.sha256,bytes)
     return {...spec,url:'/__fixture_asset__/'+spec.sha256}
    })
    result=await page.evaluate(async fixture=>{
     const capture=fixture.capture||{};const width=capture.width||257,height=capture.height||129
     const canvas=document.querySelector('canvas');canvas.width=width;canvas.height=height
     const {compiler,pipeline,CanvasRenderer,enums}=window.nmReference
     if(fixture.portable){
      const {Effect}=await import('/shaders/src/runtime/effect.js')
      const effect={namespace:fixture.portable.namespace||'user',name:fixture.portable.func,instance:new Effect(fixture.portable)}
      const choices=CanvasRenderer.prototype.registerEffectWithRuntime.call({},effect);if(choices)await enums.mergeIntoEnums(choices)
      CanvasRenderer.prototype.registerStarterOpForEffect.call({},effect)
     }
     const graph=compiler.compileGraph(fixture.source)
     const isVolumeSize=name=>name==='volumeSize'||name.startsWith('volumeSize_chain_')||name.startsWith('volumeSize_node_')
     const requestedVolumes=[]
     for(const [passIndex,pass] of graph.passes.entries())for(const [key,requested] of Object.entries(pass.uniforms||{})){
      if(isVolumeSize(key)&&typeof requested==='number')requestedVolumes.push({passIndex,key,requested})
     }
     if(capture.commonMaxTextureSize!=null){
      const limit=capture.commonMaxTextureSize
      if(!Number.isSafeInteger(limit)||limit<1||limit>fixture.__browserMaxTextureSize)throw Error('Invalid common texture size for reference')
      for(const {passIndex,key,requested} of requestedVolumes){
       if(requested*requested<=limit)continue
       let effective=16
       while((effective*2)*(effective*2)<=limit&&effective*2<requested)effective*=2
       graph.passes[passIndex].uniforms[key]=effective
      }
     }
     let executedPasses=[]
     let attributionActive=false
     let targetEvidence={target:fixture.attributionTarget||null,observedPasses:0,comparablePasses:0,defaultBaselinePasses:0,changedRgbPixels:0,outputRgbPixels:0,maxRgbDelta:0,readbackErrors:0,
      stateWriteComparisons:0,stateChangedRgbPixels:0,stateOutputRgbPixels:0,maxStateRgbDelta:0,feedbackReadPasses:0}
     const contributingEffects=()=>{
      const needed=new Set(['global_'+(capture.surface||graph.renderSurface||'o0')]),effects=new Set()
      for(let index=executedPasses.length-1;index>=0;index--){
       const pass=executedPasses[index],outputs=[...Object.values(pass.outputs||{}),...Object.values(pass.storageTextures||{})]
       if(!outputs.some(id=>needed.has(id)))continue
       for(const id of outputs)needed.delete(id)
       for(const id of Object.values(pass.inputs||{}))needed.add(id)
       if(pass.effectKey)effects.add(pass.effectKey.replace('.', '/'))
      }
      return [...effects]
     }
     const p=await pipeline.createPipeline(graph,{canvas,width,height,preferWebGPU:false,texturePooling:capture.texturePooling===true})
     try{
      if(p.backend.getName().toLowerCase()!=='webgl2')throw Error('Reference backend is not WebGL2')
      if(p.backend.capabilities?.maxTextureSize!==fixture.__browserMaxTextureSize)throw Error('Reference pipeline texture limit differs from WebGL2 probe')
      // The upstream backend's readPixels returns a zero-filled buffer when its
      // temporary framebuffer is incomplete and does not check readPixels errors.
      // A zero input can falsely make an identity pass look transformative.
      const verifiedReadPixels=(textureId,incompleteForTest=false)=>{
       const gl=p.backend.gl,texture=p.backend.textures.get(textureId)
       if(!texture)throw Error('Attribution texture not found: '+textureId)
       const {handle,width,height,glFormat}=texture
       const previousRead=gl.getParameter(gl.READ_FRAMEBUFFER_BINDING)
       const previousDraw=gl.getParameter(gl.DRAW_FRAMEBUFFER_BINDING)
       const framebuffer=gl.createFramebuffer()
       if(!framebuffer)throw Error('Cannot create attribution framebuffer')
       try{
        gl.bindFramebuffer(gl.FRAMEBUFFER,framebuffer)
        if(!incompleteForTest)gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,handle,0)
        if(gl.checkFramebufferStatus(gl.FRAMEBUFFER)!==gl.FRAMEBUFFER_COMPLETE)throw Error('Attribution framebuffer is incomplete')
        const data=new Uint8Array(width*height*4)
        if(glFormat&&(glFormat.type===gl.HALF_FLOAT||glFormat.type===gl.FLOAT)){
         const floats=new Float32Array(data.length)
         gl.readPixels(0,0,width,height,gl.RGBA,gl.FLOAT,floats)
         if(gl.getError()!==gl.NO_ERROR)throw Error('Attribution float readback failed')
         for(let i=0;i<data.length;i++)data[i]=Math.max(0,Math.min(255,Math.round(floats[i]*255)))
        }else{
         gl.readPixels(0,0,width,height,gl.RGBA,gl.UNSIGNED_BYTE,data)
         if(gl.getError()!==gl.NO_ERROR)throw Error('Attribution RGBA8 readback failed')
        }
        const flipped=new Uint8Array(data.length),rowBytes=width*4
        for(let y=0;y<height;y++)flipped.set(data.subarray((height-1-y)*rowBytes,(height-y)*rowBytes),y*rowBytes)
        return {width,height,data:flipped}
       }finally{
        gl.bindFramebuffer(gl.READ_FRAMEBUFFER,previousRead)
        gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER,previousDraw)
        gl.deleteFramebuffer(framebuffer)
       }
      }
      const volumeSizeChanges=requestedVolumes.flatMap(({passIndex,key,requested})=>{
       const effective=graph.passes[passIndex].uniforms[key]
       return effective===requested?[]:[{passIndex,key,requested,effective}]
      })
      const executePass=p.backend.executePass
      p.backend.executePass=function(pass,state){
       const targeted=attributionActive&&targetEvidence.target&&pass.effectKey?.replace('.', '/')===targetEvidence.target
       const resolveId=id=>{
        const surface=typeof id==='string'?p.parseGlobalName(id):null
        return surface?(p.frameReadTextures.get(surface)||p.surfaces.get(surface)?.read):id
       }
       let before,stateBefore,stateDestinationId
       if(targeted&&targetEvidence.target==='render/loopEnd'){
        const feedbackOutput=Object.values(pass.outputs||{}).find(id=>typeof id==='string'&&/^accum(?:_chain_\d+)?$/.test(p.parseGlobalName(id)||''))
        if(feedbackOutput){
         const surface=p.parseGlobalName(feedbackOutput)
         stateDestinationId=state.writeSurfaces?.[surface]
         targetEvidence.feedbackReadPasses+=executedPasses.filter(prior=>prior.effectKey?.replace('.', '/')==='render/loopBegin'&&prior.inputs?.accumTex===feedbackOutput).length
         if(stateDestinationId)try{stateBefore=verifiedReadPixels(stateDestinationId)}catch{targetEvidence.readbackErrors++}
        }
       }
       if(targeted){
        const input=pass.inputs?.inputTex||pass.inputs?.sourceTex||Object.values(pass.inputs||{})[0]
        if(input)try{
         if(fixture.__testInputReadbackFailure)throw Error('Injected attribution input readback failure')
         if(input==='none'&&!this.textures.has('none')){
          // The backend binds its 1x1 transparent-black default texture for
          // this compiler sentinel. Verify the actual fallback before using
          // the same zero baseline at the output's dimensions.
          const gl=this.gl,texture=this.defaultTexture
          if(!texture||!gl.isTexture(texture))throw Error('Missing default input texture')
          const framebuffer=gl.createFramebuffer()
          if(!framebuffer)throw Error('Cannot read default input texture')
          const previousRead=gl.getParameter(gl.READ_FRAMEBUFFER_BINDING)
          const previousDraw=gl.getParameter(gl.DRAW_FRAMEBUFFER_BINDING)
          try{
           gl.bindFramebuffer(gl.FRAMEBUFFER,framebuffer)
           gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,texture,0)
           if(gl.checkFramebufferStatus(gl.FRAMEBUFFER)!==gl.FRAMEBUFFER_COMPLETE)throw Error('Default input texture is not readable')
           const pixel=new Uint8Array(4)
           gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel)
           if(gl.getError()!==gl.NO_ERROR||pixel.some(value=>value!==0))throw Error('Default input texture is not transparent black')
           before={defaultBlack:true}
          }finally{
           gl.bindFramebuffer(gl.READ_FRAMEBUFFER,previousRead)
           gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER,previousDraw)
           gl.deleteFramebuffer(framebuffer)
          }
         }else before=verifiedReadPixels(resolveId(input),fixture.__testInputIncompleteFramebuffer)
        }catch{targetEvidence.readbackErrors++}
       }
       const result=executePass.call(this,pass,state)
       executedPasses.push(pass)
       if(targeted){
        targetEvidence.observedPasses++
        const output=Object.values(pass.outputs||{})[0]||Object.values(pass.storageTextures||{})[0]
        const surface=typeof output==='string'?p.parseGlobalName(output):null
        const outputId=surface?state.writeSurfaces?.[surface]:output
        if(outputId)try{
         const after=verifiedReadPixels(outputId)
         if(stateBefore&&stateDestinationId){
          const stateAfter=verifiedReadPixels(stateDestinationId)
          if(stateBefore.width!==stateAfter.width||stateBefore.height!==stateAfter.height||stateBefore.data.length!==stateAfter.data.length)throw Error('Feedback destination dimensions changed during copy')
          targetEvidence.stateWriteComparisons++
          for(let offset=0;offset<stateAfter.data.length;offset+=4){
           let changed=false,nonzero=false
           for(let channel=0;channel<3;channel++){
            const value=stateAfter.data[offset+channel],delta=Math.abs(value-stateBefore.data[offset+channel])
            if(delta>2)changed=true
            if(value>2)nonzero=true
            targetEvidence.maxStateRgbDelta=Math.max(targetEvidence.maxStateRgbDelta,delta)
           }
           if(changed)targetEvidence.stateChangedRgbPixels++
           if(nonzero)targetEvidence.stateOutputRgbPixels++
          }
         }
         const data=after.data,defaultBaseline=before?.defaultBlack===true
         const prior=defaultBaseline?new Uint8Array(data.length):before?.data
         const comparable=defaultBaseline||(prior&&before.width===after.width&&before.height===after.height&&prior.length===data.length)
         if(comparable){targetEvidence.comparablePasses++;if(defaultBaseline)targetEvidence.defaultBaselinePasses++}
         for(let offset=0;offset<data.length;offset+=4){
          let changed=false,nonzero=false
          for(let channel=0;channel<3;channel++){
           const value=data[offset+channel],previous=comparable?prior[offset+channel]:0
           const delta=Math.abs(value-previous)
           if(delta>2)changed=true
           if(value>2)nonzero=true
           targetEvidence.maxRgbDelta=Math.max(targetEvidence.maxRgbDelta,delta)
          }
          if(changed)targetEvidence.changedRgbPixels++
          if(nonzero)targetEvidence.outputRgbPixels++
         }
        }catch{targetEvidence.readbackErrors++}
       }
       return result
      }
      const gl=p.backend.gl,debug=gl.getExtension('WEBGL_debug_renderer_info')
      const gpu=debug?gl.getParameter(debug.UNMASKED_RENDERER_WEBGL):gl.getParameter(gl.RENDERER)
      if(/swiftshader|llvmpipe|software rasterizer/i.test(gpu))throw Error('Reference requires hardware GPU: '+gpu)
      if(capture.reset===false)throw Error('A fresh case requires reset:true; stateful frames belong in one trace')
      if(capture.seed!=null&&capture.seedPolicy!=='authored')p.setUniform('seed',capture.seed)
      const consumed=[]
      const matchesTargetEffectPass=(pass,effectId)=>{
       const separator=effectId.indexOf('/'),namespace=effectId.slice(0,separator),func=effectId.slice(separator+1)
       return (pass.effectFunc===func||pass.effectKey===func||pass.effectKey===effectId||pass.effectKey===effectId.replace('/','.'))&&
        (pass.effectNamespace==null||pass.effectNamespace===namespace)
      }
      for(const spec of (fixture.loadedInputs||[]).filter(x=>x.kind==='texture'||!x.kind)){
       const response=await fetch(spec.url);if(!response.ok)throw Error('Fixture input download failed')
       const bytes=new Uint8ClampedArray(await response.arrayBuffer())
       const image=new ImageData(bytes,spec.width,spec.height)
       const ids=new Set()
       if(spec.effect){
        const passes=graph.passes.filter(pass=>matchesTargetEffectPass(pass,spec.effect))
        if(!passes.length)throw Error('Texture fixture has no executing effect '+spec.effect)
        for(const pass of passes){const id=pass.inputs?.[spec.uniform];if(typeof id!=='string')throw Error('Texture fixture uniform is not bound '+spec.uniform);ids.add(id)}
       }else for(const pass of graph.passes)for(const [sampler,id]of Object.entries(pass.inputs||{}))if(sampler===spec.binding||id===spec.binding)ids.add(id)
       if(!ids.size)throw Error('No input binding '+spec.binding)
       const source=document.createElement('canvas');source.width=spec.width;source.height=spec.height
       source.getContext('2d').putImageData(image,0,0)
       // The WebGL backend accepts Canvas/ImageBitmap sources, not ImageData.
      // Preserve straight-alpha fixture bytes for generic inputs; Canvas2D
      // round-trips semi-transparent pixels through premultiplication.
      const bitmap=spec.effect?null:await createImageBitmap(image,{premultiplyAlpha:'none',colorSpaceConversion:'none',imageOrientation:spec.flipY===false?'none':'flipY'})
      try {
       for(const id of ids){const uploaded=p.backend.updateTextureFromSource(id,bitmap||source,{flipY:spec.flipY!==false});if(uploaded?.width!==spec.width||uploaded?.height!==spec.height)throw Error('Texture fixture upload dimensions differ')}
      } finally { if(bitmap)bitmap.close() }
       if(spec.binding==='imageTex'&&!spec.effect)p.setUniform('imageSize',[spec.width,spec.height])
       consumed.push({kind:spec.kind||'texture',binding:spec.binding,ids:[...ids],sha256:spec.sha256})
      }
      const meshSpecs=(fixture.loadedInputs||[]).filter(x=>x.kind==='mesh')
      const meshes=new Set(meshSpecs.map(spec=>spec.mesh))
      for(const mesh of meshes){
       const parts={};for(const spec of meshSpecs.filter(x=>x.mesh===mesh)){
        if(spec.component!=='uvs'&&!graph.passes.some(pass=>Object.values(pass.inputs||{}).some(id=>id===spec.binding||id.startsWith(spec.binding+'_chain_'))))throw Error('Mesh input is not consumed '+spec.binding)
        const response=await fetch(spec.url);if(!response.ok)throw Error('Mesh asset download failed')
        parts[spec.component]=new Float32Array(await response.arrayBuffer())
       }
       const sample=meshSpecs.find(x=>x.mesh===mesh)
       if(!parts.positions||!parts.normals||!parts.uvs||parts.positions.length!==sample.width*sample.height*4||parts.normals.length!==parts.positions.length||parts.uvs.length!==parts.positions.length)throw Error('Incomplete mesh fixture '+mesh)
       const uploaded=p.backend.uploadMeshData(mesh,parts.positions,parts.normals,parts.uvs,sample.width,sample.height,sample.vertexCount)
       if(!uploaded?.success||uploaded.vertexCount!==sample.vertexCount)throw Error('Mesh fixture upload failed '+mesh)
       consumed.push({kind:'mesh',mesh,vertexCount:uploaded.vertexCount,components:meshSpecs.filter(x=>x.mesh===mesh).map(x=>({binding:x.binding,sha256:x.sha256}))})
      }
      let midiSnapshot=null
      if(capture.midi){
       const {clockCount,notes}=capture.midi
       if(!Number.isInteger(clockCount)||clockCount<0||!Array.isArray(notes))throw Error('Invalid captured MIDI state')
       const {MidiState}=await import('/shaders/src/runtime/external-input.js')
       const midi=new MidiState()
       midi.clockCount=clockCount
       midiSnapshot={clockCount,notes:[]}
       for(const [index,note] of notes.entries()){
        const {channel,key,velocity}=note
        if(!Number.isInteger(channel)||channel<1||channel>16||
           !Number.isInteger(key)||key<0||key>127||
           !Number.isInteger(velocity)||velocity<1||velocity>127)throw Error('Invalid captured MIDI note')
        midi.channels[channel].noteOn(key,velocity,{time:0,order:index+1})
        midiSnapshot.notes.push({channel,key,velocity})
       }
       p.setMidiState(midi)
      }
      await p.whenAsyncInitsSettled()
      for(let i=0;i<(capture.frames||1);i++){
       executedPasses=[]
       attributionActive=i===(capture.frames||1)-1
       if(attributionActive)targetEvidence={target:fixture.attributionTarget||null,observedPasses:0,comparablePasses:0,defaultBaselinePasses:0,changedRgbPixels:0,outputRgbPixels:0,maxRgbDelta:0,readbackErrors:0,
        stateWriteComparisons:0,stateChangedRgbPixels:0,stateOutputRgbPixels:0,maxStateRgbDelta:0,feedbackReadPasses:0}
       p.frameIndex=(capture.frame||0)+i
       const time=(capture.time??.25)+(capture.advanceTime?i*(capture.deltaTime??1/60):0)
       p.lastTime=time-(capture.deltaTime??0)
       p.render(time)
      }
      if(p.backend.getName().toLowerCase()!=='webgl2')throw Error('Backend changed before capture')
      const readCapture=()=>{
       if(capture.surface){
        const surface=p.surfaces.get(capture.surface);if(!surface)throw Error('Missing authored capture surface '+capture.surface)
        const id=p.frameReadTextures?.get(capture.surface)
        if(typeof id!=='string')throw Error('Missing final frame binding for authored surface '+capture.surface)
        const read=verifiedReadPixels(id)
        return {pixels:read.data,surfaceId:id,width:read.width,height:read.height}
       }
       gl.bindFramebuffer(gl.FRAMEBUFFER,null);gl.finish()
       const pixels=new Uint8Array(width*height*4);gl.readPixels(0,0,width,height,gl.RGBA,gl.UNSIGNED_BYTE,pixels)
       const error=gl.getError();if(error!==gl.NO_ERROR)throw Error('Capture GL error '+error)
       const top=new Uint8Array(pixels.length)
       for(let y=0;y<height;y++)top.set(pixels.subarray((height-1-y)*width*4,(height-y)*width*4),y*width*4)
       return {pixels:top,width,height}
      }
      let captured=readCapture(),settled=!capture.settleMs
      if(capture.settleMs){
       const deadline=Date.now()+capture.settleMs
       while(Date.now()<deadline){
        await new Promise(resolve=>setTimeout(resolve,250))
        executedPasses=[]
        attributionActive=false
        p.render(capture.time??.25)
        executedPasses=[]
        targetEvidence={target:fixture.attributionTarget||null,observedPasses:0,comparablePasses:0,defaultBaselinePasses:0,changedRgbPixels:0,outputRgbPixels:0,maxRgbDelta:0,readbackErrors:0,
         stateWriteComparisons:0,stateChangedRgbPixels:0,stateOutputRgbPixels:0,maxStateRgbDelta:0,feedbackReadPasses:0}
        attributionActive=true
        p.render(capture.time??.25)
        const next=readCapture()
        if(next.pixels.length===captured.pixels.length&&next.pixels.every((value,index)=>value===captured.pixels[index])){captured=next;settled=true;break}
        captured=next
       }
       if(!settled)throw Error('Authored fixture did not settle within '+capture.settleMs+' ms')
      }
      if(capture.requireColorVariation){
       const colors=new Set();for(let i=0;i<captured.pixels.length;i+=4)colors.add(captured.pixels[i]+','+captured.pixels[i+1]+','+captured.pixels[i+2])
       if(colors.size<2)throw Error('Authored fixture requires color variation')
      }
      if(captured.width!==width||captured.height!==height)throw Error('Authored surface dimensions differ from resolution')
      return {status:'rendered',width,height,gpu,backend:p.backend.getName(),pixels:Array.from(captured.pixels),passes:graph.passes.length,executedPasses:executedPasses.length,effects:[...new Set(graph.passes.map(pass=>pass.effectKey?.replace('.', '/')).filter(Boolean))],contributingEffects:contributingEffects(),targetEvidence,volumeSizeChanges,captureSurface:capture.surface||null,surfaceId:captured.surfaceId||null,settled,consumed,midiSnapshot}
     }finally{p.dispose()}
    },{...fixture,loadedInputs,__browserMaxTextureSize:browserMaxTextureSize,__testInputReadbackFailure:testInputReadbackFailureCaseId===fixture.id,__testInputIncompleteFramebuffer:testInputIncompleteFramebufferCaseId===fixture.id})
    const {pixels,...metadata}=result
    writeFileSync(join(output,fixture.id+'.rgba'),Buffer.from(pixels));result=metadata
   }catch(error){result={status:'failed',message:error.message}}
   if(browserErrors.length){result.browserErrors=browserErrors;result.status='failed';result.message=result.message||browserErrors.join(' | ')}
   results.push({id:fixture.id,...result});onProgress(results.at(-1))
  }
  const report={authority:reference.sourceIdentity,browser:browser.version(),requestedBrowser:browserName,requestedAngleBackend:process.env.NM_ANGLE_BACKEND||null,capabilities:{browserMaxTextureSize,nativeMaxTextureSize,commonMaxTextureSize},capture:'authored surface when specified, otherwise presented default framebuffer; RGBA8 top-down',cases:results}
  writeFileSync(join(output,'reference.json'),JSON.stringify(report,null,2)+'\n')
  return report
 }finally{if(browser)await browser.close();await new Promise(r=>server.close(r))}
}
if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename){
 const manifest=JSON.parse(readFileSync(process.argv[2],'utf8'))
 const result=await renderReference({cases:manifest.cases,output:resolve(process.argv[3]),onProgress:r=>console.log(`${r.id}: ${r.status}${r.message?' '+r.message:''}`)})
 if(result.cases.some(x=>x.status!=='rendered'))process.exitCode=1
}
