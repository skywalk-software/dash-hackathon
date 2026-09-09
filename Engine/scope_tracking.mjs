import * as A from '@automerge/automerge';
const pair=(doc,path,index)=>({after:A.getCursor(doc,path,index,'after'),before:A.getCursor(doc,path,index,'before')});
function position(doc,path,c){const a=A.getCursorPosition(doc,path,c.after),b=A.getCursorPosition(doc,path,c.before);if(a!==b)throw Error('Deleted anchor');return a;}
export function trackScope(doc,path,text,start,end){
 const left=start>0?Array.from(text.slice(0,start)).at(-1):null;
 const right=end<text.length?Array.from(text.slice(end))[0]:null;
 const witnesses=[...text.slice(start,end).matchAll(/[\p{L}\p{N}]{3,}/gu)].slice(0,32).map(m=>({text:m[0],start:pair(doc,path,start+m.index),end:pair(doc,path,start+m.index+m[0].length)}));
 return {start:pair(doc,path,start),end:pair(doc,path,end),left:left?{text:left,cursor:pair(doc,path,start-left.length)}:null,right:right?{text:right,cursor:pair(doc,path,end)}:null,witnesses};
}
export function resolveScope(doc,path,text,tracking){
 try{
  const start=position(doc,path,tracking.start),end=position(doc,path,tracking.end);
  if(start<0||end<=start||end>text.length)throw Error('Collapsed scope');
  return {start,end,method:'original_boundary_cursors'};
 }catch{
  const left=tracking.left,right=tracking.right;
  const leftAt=left?position(doc,path,left.cursor):0;
  const rightAt=right?position(doc,path,right.cursor):text.length;
  if(left&&text.slice(leftAt,leftAt+left.text.length)!==left.text)throw Error('Left context changed');
  if(right&&text.slice(rightAt,rightAt+right.text.length)!==right.text)throw Error('Right context changed');
  const start=left?leftAt+left.text.length:0,end=rightAt;
  if(start<0||end<=start||end>text.length)throw Error('Scope deleted');
  const survivors=tracking.witnesses.filter(w=>{try{const a=position(doc,path,w.start),b=position(doc,path,w.end);return a>=start&&b<=end&&text.slice(a,b)===w.text;}catch{return false;}}).map(w=>w.text);
  if(!survivors.length)throw Error('No surviving target identity');
  return {start,end,method:'stable_surrounding_cursors',surviving_target_tokens:survivors};
 }
}
export function describeChange(before,after){
 if(before===after)return null;
 const a=Array.from(before),b=Array.from(after);let first=0,last=0;
 while(first<Math.min(a.length,b.length)&&a[first]===b[first])first++;
 while(last<Math.min(a.length-first,b.length-first)&&a[a.length-last-1]===b[b.length-last-1])last++;
 return {before:a.slice(first,a.length-last).join(''),after:b.slice(first,b.length-last).join(''),context_before:a.slice(Math.max(0,first-40),first).join(''),context_after:a.slice(a.length-last,a.length-last+40).join('')};
}
export function summarizeHistory(history){
 const groups=[];
 for(const event of history){const previous=groups.at(-1);if(previous&&previous.origin===event.origin&&previous.paragraph===event.paragraph)previous.after=event.after;else groups.push({...event});}
 return groups.map(x=>({origin:x.origin,paragraph:x.paragraph,...describeChange(x.before,x.after)})).filter(x=>Object.hasOwn(x,'before'));
}
