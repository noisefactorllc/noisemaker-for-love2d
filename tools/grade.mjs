import {readFileSync} from 'node:fs'
export function gradePixels(reference,candidate,width,height){
 const expected=width*height*4
 if(reference.length!==expected||candidate.length!==expected)return {bucket:'fail',reason:'dimensions or byte length differ'}
 let max=0,sumA=0,sumB=0,sumAA=0,sumBB=0,sumAB=0,alphaMax=0
 const colors=new Map(),n=width*height
 for(let i=0;i<expected;i+=4){
  for(let c=0;c<4;c++)max=Math.max(max,Math.abs(reference[i+c]-candidate[i+c]))
  alphaMax=Math.max(alphaMax,Math.abs(reference[i+3]-candidate[i+3]))
  const a=.299*reference[i]+.587*reference[i+1]+.114*reference[i+2],b=.299*candidate[i]+.587*candidate[i+1]+.114*candidate[i+2]
  sumA+=a;sumB+=b;sumAA+=a*a;sumBB+=b*b;sumAB+=a*b
  const key=reference.readUInt32LE(i);colors.set(key,(colors.get(key)||0)+1)
 }
 const meanA=sumA/n,meanB=sumB/n,varA=Math.max(0,sumAA/n-meanA*meanA),varB=Math.max(0,sumBB/n-meanB*meanB),cov=sumAB/n-meanA*meanB
 const c1=(.01*255)**2,c2=(.03*255)**2
 const ssim=((2*meanA*meanB+c1)*(2*cov+c2))/((meanA*meanA+meanB*meanB+c1)*(varA+varB+c2))
 let dominant=0;for(const count of colors.values())dominant=Math.max(dominant,count/n)
 const uninformative=dominant>.99||Math.sqrt(varA)<1
 const bucket=max===0?'exact':max<=2.001&&ssim>=.98?'strict':max<=12&&ssim>=.95?'near':'fail'
 return {bucket,max,alphaMax,ssim,uninformative,lumaStd:Math.sqrt(varA),dominant}
}
