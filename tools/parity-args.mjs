// Argument handling for scripts/parity-summary [case-id ...] (family contract: with case-id
// arguments, only those cases are expected). Each argument that is not an option or an
// option value is a case ID.
const VALUE_OPTIONS=new Set(['--tier','--limit','--out','--ids'])
export function parseParityArguments(argv){
 const options={},caseIds=[]
 for(let i=0;i<argv.length;i++){
  const arg=argv[i]
  if(VALUE_OPTIONS.has(arg)){
   if(i+1>=argv.length)throw Error('Missing value for '+arg)
   if(!(arg in options))options[arg]=argv[i+1]
   i++
  }else caseIds.push(arg)
 }
 const ids=[...(options['--ids']?.split(',').filter(Boolean)??[]),...caseIds]
 return {
  tier:options['--tier']??'all',
  limit:Number(options['--limit']??Infinity),
  out:options['--out']??null,
  ids:ids.length||options['--ids']!==undefined?[...new Set(ids)]:null
 }
}
// Unknown IDs stop the run here, before any runner or browser starts.
export function selectParityCases(cases,ids){
 if(!ids)return cases
 const available=new Set(cases.map(item=>item.id))
 for(const id of ids)if(!available.has(id))throw Error('Unknown parity case '+id)
 return cases.filter(item=>ids.includes(item.id))
}
