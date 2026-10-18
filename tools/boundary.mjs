// The parameter-boundary family: one `min` case and one `max` case for each bounded numeric
// parameter of the locked catalog (type float or int, numeric min and max, no choices). Each
// case is the effect's coverage default program, parity/coverage/<ns>_<func>.dsl, with the
// parameter set on the effect's first call, as the shared coverage generator sets a choice.
import {readFileSync} from 'node:fs'
import {join} from 'node:path'

export function boundedNumericParameters(definitions){
 const parameters=[]
 for(const effect of Object.keys(definitions).sort())for(const [name,spec] of Object.entries(definitions[effect].globals||{})){
  if(spec.type!=='float'&&spec.type!=='int')continue
  if(spec.choices&&typeof spec.choices==='object')continue
  if(typeof spec.min!=='number'||typeof spec.max!=='number'||!Number.isFinite(spec.min)||!Number.isFinite(spec.max))continue
  parameters.push({effect,name,spec})
 }
 return parameters
}

// A DSL number literal without exponent notation.
export function numberLiteral(value){
 if(!Number.isFinite(value))throw Error('Boundary value is not finite: '+value)
 let text=String(value)
 if(/e/i.test(text))text=value.toFixed(20).replace(/0+$/,'').replace(/\.$/,'')
 return text
}

// Insert or replace a keyword argument in the first call of `func`. Returns null when the call
// is missing or takes positional arguments.
export function withCallArgument(source,func,name,literal){
 const match=new RegExp(`(^|[^A-Za-z0-9_])${func}\\s*\\(`).exec(source)
 if(!match)return null
 const open=match.index+match[0].length-1
 let depth=0,close=-1,quote=null
 for(let i=open;i<source.length;i++){
  const c=source[i]
  if(quote){if(c==='\\'){i++;continue}if(c===quote)quote=null;continue}
  if(c==='"'||c==="'"){quote=c;continue}
  if(c==='(')depth++
  else if(c===')'&&--depth===0){close=i;break}
 }
 if(close<0)return null
 const inner=source.slice(open+1,close),items=[]
 let current='';depth=0;quote=null
 for(let i=0;i<inner.length;i++){
  const c=inner[i]
  if(quote){current+=c;if(c==='\\'){current+=inner[++i];continue}if(c===quote)quote=null;continue}
  if(c==='"'||c==="'"){quote=c;current+=c;continue}
  if('([{'.includes(c))depth++
  if(')]}'.includes(c))depth--
  if(c===','&&depth===0){items.push(current);current='';continue}
  current+=c
 }
 if(current.trim())items.push(current)
 const kept=items.map(item=>item.trim()).filter(Boolean).filter(item=>!new RegExp(`^${name}\\s*:`).test(item))
 if(kept.some(item=>!/^[A-Za-z_][A-Za-z0-9_]*\s*:/.test(item)))return null
 return source.slice(0,open+1)+[...kept,`${name}: ${literal}`].join(', ')+source.slice(close)
}

export function boundaryCases(projectRoot,definitions){
 const cases=[]
 for(const {effect,name,spec} of boundedNumericParameters(definitions)){
  const stem=effect.replace('/','_')
  const base=readFileSync(join(projectRoot,'parity/coverage',stem+'.dsl'),'utf8')
  for(const [bound,value] of [['min',spec.min],['max',spec.max]]){
   const source=withCallArgument(base,definitions[effect].func,name,numberLiteral(value))
   if(!source)throw Error(`Cannot place ${name} in the coverage default program of ${effect}`)
   cases.push({id:`boundary-${stem}__${name}_${bound}`,effect,parameter:name,uniform:spec.uniform||name,bound,value,source})
  }
 }
 return cases
}
