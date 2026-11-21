// Reviewed per-case NEAR policies (parity/near-policy.json). Each entry binds a case to the
// pinned authority, the capture protocol, the measured bound and a reviewed pair of reference
// and candidate bytes. An entry may list further reviewed pairs in `pairs`, for example the
// same candidate against another platform's reference; every pair shares the entry's
// authority, protocol and bound, and carries its own platform and review.
const PAIR_KEYS=['referenceSha256','candidateSha256','platform','review']
const sha256=value=>typeof value==='string'&&/^[0-9a-f]{64}$/.test(value)
const text=value=>typeof value==='string'&&value.length>0

export function validateNearPolicies(policies){
 if(policies?.version!==1||typeof policies.cases!=='object'||policies.cases===null)throw Error('Invalid parity/near-policy.json')
 for(const [id,entry] of Object.entries(policies.cases)){
  if(typeof entry!=='object'||entry===null||Array.isArray(entry))throw Error(`Invalid near policy for ${id}`)
  if(entry.pairs===undefined)continue
  if(!Array.isArray(entry.pairs))throw Error(`Invalid near policy pairs for ${id}`)
  for(const pair of entry.pairs){
   // A pair carries its hashes, platform and review only; the authority, protocol and bound stay the entry's.
   if(typeof pair!=='object'||pair===null||Object.keys(pair).some(key=>!PAIR_KEYS.includes(key))||
    !sha256(pair.referenceSha256)||!sha256(pair.candidateSha256)||!text(pair.platform)||!text(pair.review))throw Error(`Invalid near policy pair for ${id}`)
  }
 }
 return policies
}

// The checks for one near capture, or null when the case has no policy. The capture is
// reviewed only when every check holds: its reference and candidate bytes must match the
// same reviewed pair, not one pair each.
export function reviewNearCase(policy,{authority,protocol,referenceSha256,candidateSha256,max,ssim}){
 if(!policy)return null
 const pairs=[{referenceSha256:policy.referenceSha256,candidateSha256:policy.candidateSha256},...(policy.pairs||[])]
 return {authority:policy.authority===authority,protocol:JSON.stringify(policy.protocol)===JSON.stringify(protocol),
  reference:pairs.some(pair=>pair.referenceSha256===referenceSha256),candidate:pairs.some(pair=>pair.candidateSha256===candidateSha256),
  pair:pairs.some(pair=>pair.referenceSha256===referenceSha256&&pair.candidateSha256===candidateSha256),
  bound:max<=policy.maxChannelDelta&&ssim>=policy.minSsim}
}

export function isReviewed(checks){
 return Boolean(checks)&&Object.values(checks).every(Boolean)
}
