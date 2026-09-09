import {changeHunks} from './change_history.mjs';
import * as A from '@automerge/automerge';
import {readFileSync} from 'node:fs';
import {restoreOuterFrame} from './scope_frame.mjs';
import {trackScope,resolveScope,describeChange,summarizeHistory} from './scope_tracking.mjs';
const instructions=readFileSync(new URL('./hack8/reconcile.txt',import.meta.url),'utf8');
const schema={type:'object',properties:{status:{type:'string',enum:['ready','conflict']},text:{type:'string'},reason:{type:'string'}},required:['status','text','reason'],additionalProperties:false};
const sameHeads=(a,b)=>JSON.stringify([...a].sort())===JSON.stringify([...b].sort());
function locate(text,quote){if(!quote)throw new Error('Empty working area');const start=text.indexOf(quote);if(start<0||text.indexOf(quote,start+1)>=0)throw new Error('Working area must uniquely match supplied paragraph');return {start,end:start+quote.length};}
function segments(text,span){return {before:text.slice(0,span.start),editable:text.slice(span.start,span.end),after:text.slice(span.end)};}
function inScope(text,scope){return text.startsWith(scope.before)&&text.endsWith(scope.after)&&text.length>=scope.before.length+scope.after.length;}
export function createStore(paragraphs){
 if(new Set(paragraphs.map(p=>p.label)).size!==paragraphs.length)throw new Error('Duplicate paragraph label');
 let doc=A.from({paragraphs:Object.fromEntries(paragraphs.map(p=>[p.label,p.text])),order:paragraphs.map(p=>p.label)});
 const initialBytes=A.save(doc);
 const evidence=[],history=[],changeRecords=[];
 const snapshot=()=>({heads:A.getHeads(doc),paragraphs:doc.order.map(label=>({label,text:doc.paragraphs[label]}))});
 function humanEdit(label,newText,origin='human'){
 if(!(label in doc.paragraphs)||typeof newText!=='string')throw new Error('Invalid human edit');
 const before=A.getHeads(doc),oldText=doc.paragraphs[label];doc=A.change(doc,'human edit',d=>A.updateText(d,['paragraphs',label],newText));
 evidence.push({kind:'human',label,before,after:A.getHeads(doc)});history.push({origin,paragraph:label,before:oldText,after:newText});changeHistory();
 }
 function capture(task,source=doc,selectionRanges=new Map(),historyIndex=history.length){const baseSnapshot={heads:A.getHeads(source),paragraphs:source.order.map(label=>({label,text:source.paragraphs[label]}))};const targetLabel=task.operation==='question'?null:task.working_area?.paragraph;
 if(task.operation!=='edit'&&task.operation!=='question')throw new Error('Invalid operation');
 const originalText=targetLabel?source.paragraphs[targetLabel]:null;
 if(task.operation==='edit'&&typeof originalText!=='string')throw new Error('Missing paragraph');
 const selected=task.working_area?.selection_id?selectionRanges.get(task.working_area.selection_id):null;
 if(task.working_area?.selection_id&&!selected)throw Error('Selection ID unavailable');
 const span=targetLabel?(selected?{start:selected.start,end:selected.end}:locate(originalText,task.working_area.quote)):null;
 if(selected&&originalText.slice(span.start,span.end)!==task.working_area.quote)throw Error('Selected occurrence does not match interpretation snapshot');
 const out={task:structuredClone(task),baseSnapshot,targetLabel,originalText,span};Object.defineProperty(out,'baseDoc',{value:source});Object.defineProperty(out,'historyIndex',{value:historyIndex});
 if(span)Object.defineProperty(out,'tracking',{value:trackScope(source,['paragraphs',targetLabel],originalText,span.start,span.end)});
 return out;}
 async function prepareCandidate(capture,proposedText,{callModel,outputDir}={}){
 const at=snapshot(),{task,targetLabel,originalText,span}=capture;const currentText=targetLabel?doc.paragraphs[targetLabel]:null;const currentDoc=doc;
 let currentScope=null,scopeError=null,originalScope=null,scopeMapping=null;
 const frameRestorations={generation:false,reconciliation:false};
 if(span){originalScope=segments(originalText,span);const framed=restoreOuterFrame(proposedText,originalScope);proposedText=framed.text;frameRestorations.generation=framed.restored;if(typeof proposedText!=='string'||!inScope(proposedText,originalScope))scopeError='Generated paragraph changed text outside its working area';
 if(typeof currentText!=='string')scopeError='Target paragraph no longer exists';
 else if(span.start===0&&span.end===originalText.length)currentScope=segments(currentText,{start:0,end:currentText.length});
 else {try{
 const mapped=resolveScope(currentDoc,['paragraphs',targetLabel],currentText,capture.tracking);
 currentScope=segments(currentText,mapped);scopeMapping=mapped;
 }catch{scopeError='Working area was deleted or its surrounding context is ambiguous';}}

 }
 let proposalChanges=null,provisionalMerge=null;
 if(span&&typeof proposedText==='string'&&originalScope&&inScope(proposedText,originalScope)){
  let branch=A.clone(capture.baseDoc);branch=A.change(branch,'agent proposal',d=>A.updateText(d,['paragraphs',targetLabel],proposedText));
  proposalChanges=A.getChanges(capture.baseDoc,branch);
  const [merged]=A.applyChanges(A.clone(currentDoc),proposalChanges);provisionalMerge=merged.paragraphs[targetLabel];
 }
 const interveningChanges=summarizeHistory(history.slice(capture.historyIndex));
 const result=await callModel({phase:'reconciliation',instructions,input:JSON.stringify({operation:task.operation,instruction:task.instruction,references:task.references,original_document:capture.baseSnapshot.paragraphs,current_document:at.paragraphs,original:originalText,proposed:proposedText,current:currentText,original_scope:originalScope,current_scope:currentScope,scope_error:scopeError,scope_mapping:scopeMapping,proposed_change:span&&typeof proposedText==='string'?describeChange(originalText,proposedText):null,intervening_changes:interveningChanges,crdt_merge_candidate:provisionalMerge}),schema,outputDir});
 const resolved=result.json??JSON.parse(result.text);
 const candidate={heads:at.heads,targetLabel,operation:task.operation,status:resolved.status,text:resolved.text,reason:resolved.reason,currentText,frameRestorations,scopeMapping,provisionalMerge,interveningChanges};
 if(scopeError){candidate.status='conflict';candidate.reason=scopeError;}
 if(!['ready','conflict'].includes(candidate.status)||typeof candidate.text!=='string')throw new Error('Invalid reconciliation output');
 if(candidate.status==='ready'&&span&&currentScope){const framed=restoreOuterFrame(candidate.text,currentScope);candidate.text=framed.text;frameRestorations.reconciliation=framed.restored;}
 if(candidate.status==='ready'&&span&&!inScope(candidate.text,currentScope)){candidate.status='conflict';candidate.reason='Reconciliation changed text outside its working area';}
 if(candidate.status==='ready'&&span){
 // Proposal changes were built against the retained base and supplied as a
 // provisional merge, not committed blindly.
 // Reconciled operations use the latest snapshot read by reconciliation, never stale replacement vs live text.
 let branch=A.clone(currentDoc);branch=A.change(branch,'reconciled agent edit',d=>A.updateText(d,['paragraphs',targetLabel],candidate.text));
 candidate.changes=A.getChanges(currentDoc,branch);candidate.proposalChangeBytes=proposalChanges.map(c=>Buffer.from(c).toString('base64'));candidate.changeBytes=candidate.changes.map(c=>Buffer.from(c).toString('base64'));candidate.patches=A.diff(branch,at.heads,A.getHeads(branch));
 }
 return candidate;
 }
 function commit(candidate,metadata={}){
 if(!sameHeads(candidate.heads,A.getHeads(doc)))return {status:'stale'};
 if(candidate.status==='conflict')return {status:'conflict',reason:candidate.reason};
 if(candidate.operation==='question')return {status:'answered',answer:candidate.text};
 if(candidate.text===doc.paragraphs[candidate.targetLabel])return {status:'noop',text:candidate.text};
 const before=A.getHeads(doc);const [merged]=A.applyChanges(doc,candidate.changes);if(merged.paragraphs[candidate.targetLabel]!==candidate.text)throw new Error('Native change result mismatched validated replacement');doc=merged;
 changeHistory();
 const changeID=A.getHeads(doc).join(':');
 const path=['paragraphs',candidate.targetLabel];
 const hunks=changeHunks(candidate.currentText,candidate.text).map((h,index)=>({...h,id:`${changeID}:${index}`,start:A.getCursor(doc,path,h.location,'after'),end:A.getCursor(doc,path,h.location+h.length,'before')}));
 changeRecords.push({id:changeID,taskID:metadata.taskID??null,instruction:metadata.instruction??'',committedAt:Date.now(),label:candidate.targetLabel,beforeText:candidate.currentText,afterText:candidate.text,beforeHeads:before,afterHeads:A.getHeads(doc),hunks});
 const record={changeID,kind:'agent',label:candidate.targetLabel,before,after:A.getHeads(doc),proposalChanges:candidate.proposalChangeBytes,changes:candidate.changeBytes,patches:candidate.patches,text:candidate.text,frameRestorations:candidate.frameRestorations,scopeMapping:candidate.scopeMapping,provisionalMerge:candidate.provisionalMerge};evidence.push(record);history.push({origin:'agent',paragraph:candidate.targetLabel,before:candidate.currentText,after:candidate.text});return {status:'committed',...record};
 }
 function changeHistory(){return changeRecords.map(record=>({...record,hunks:record.hunks.map(h=>{
  try{const path=['paragraphs',record.label],start=A.getCursorPosition(doc,path,h.start),end=A.getCursorPosition(doc,path,h.end);
   const active=!h.superseded&&(h.length===0||(end>=start&&doc.paragraphs[record.label].slice(start,end)===h.after));
   if(!active)h.superseded=true;
   return {...h,location:start,length:active&&h.length>0?Math.max(0,end-start):0,active};
  }catch{return {...h,active:false,length:0};}
 })}));}
 function anchorRange(start,end) {
 const text=doc.paragraphs.document;
 if(!Number.isInteger(start)||!Number.isInteger(end)||start<0||end<start||end>text.length)throw Error('Invalid selection range');
 const path=['paragraphs','document'];
 return {start:A.getCursor(doc,path,start,'after'),end:A.getCursor(doc,path,end,'before'),startGuard:A.getCursor(doc,path,start,'before'),endGuard:A.getCursor(doc,path,end,'after'),empty:start===end,original:text.slice(start,end),tracking:start===end?null:trackScope(doc,path,text,start,end)};
 }
 function resolveRange(anchor) {
 const path=['paragraphs','document'],text=doc.paragraphs.document;
 if(anchor.empty){const start=A.getCursorPosition(doc,path,anchor.start);return {start,end:start,text:''};}
 try{const {start,end}=resolveScope(doc,path,text,anchor.tracking);return {start,end,text:text.slice(start,end)};}
 catch{throw Error('Selection boundary was deleted or became ambiguous');}
 }
 function captureContext(ranges){const source=doc,index=history.length;return task=>capture(task,source,ranges,index);}
 return {changeHistory,snapshot,humanEdit,capture,prepareCandidate,commit,evidence,anchorRange,resolveRange,captureContext,save:()=>A.save(doc),initialBytes};
}
