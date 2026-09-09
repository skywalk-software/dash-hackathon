// Word-level presentation diff. Offsets are UTF-16, matching NSTextView and JS.
export function changeHunks(before, after) {
 const tokenize=s=>s.match(/\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]/gu)||[];
 const a=tokenize(before),b=tokenize(after);
 if(a.length*b.length>1000000){
  let start=0,endA=before.length,endB=after.length;
  while(start<endA&&start<endB&&before[start]===after[start])start++;
  while(endA>start&&endB>start&&before[endA-1]===after[endB-1]){endA--;endB--;}
  return start===endA&&start===endB?[]:[{before:before.slice(start,endA),after:after.slice(start,endB),location:start,length:endB-start}];
 }
 const dp=Array.from({length:a.length+1},()=>new Uint32Array(b.length+1));
 for(let i=a.length-1;i>=0;i--)for(let j=b.length-1;j>=0;j--)dp[i][j]=a[i]===b[j]?dp[i+1][j+1]+1:Math.max(dp[i+1][j],dp[i][j+1]);
 let i=0,j=0,offset=0,h=null;const out=[];
 const flush=()=>{if(h){h.length=h.after.length;out.push(h);h=null;}};
 while(i<a.length||j<b.length){
  if(i<a.length&&j<b.length&&a[i]===b[j]){flush();offset+=b[j].length;i++;j++;continue;}
  h??={before:'',after:'',location:offset};
  if(j<b.length&&(i===a.length||dp[i][j+1]>dp[i+1][j])){h.after+=b[j];offset+=b[j++].length;}else h.before+=a[i++];
 }
 flush();return out;
}
