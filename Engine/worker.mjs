import readline from 'node:readline';
import {spawn} from 'node:child_process';
import {mkdirSync,writeFileSync,appendFileSync,readFileSync,readdirSync,copyFileSync,renameSync} from 'node:fs';
import path from 'node:path';
import {createStore} from './automerge_store.mjs';
import {Scheduler} from './scheduler.mjs';
import {generate} from './editing.mjs';
import {interpret} from './interpretation.mjs';
import {callModel} from './model_client.mjs';
import {presentJob} from './presentation.mjs';

// Only request/reply messages use stdout. Commits are gated by a UI poll, so
// no document mutation can occur between a UI acknowledgement and its next edit.
let recoveredProposals=new WeakMap();
let captures=new WeakMap(),uiAnchors=[],recordings=new Map(),audioResults=[];
let store,scheduler,documentID,session,epoch=0,pending=[],interpretations=[],requests=new Set(),lastError,phase="Ready · Automerge";
const outputRoot=process.env.EDITOR_EVIDENCE_DIR;
function state(){return {documentID,phase,audioResults,changes:store?.changeHistory()??[],ranges:uiAnchors.map(a=>{try{const r=store.resolveRange(a);return {location:r.start,length:r.end-r.start};}catch{return {location:Math.min(a.fallback,store.snapshot().paragraphs[0].text.length),length:0};}}),text:store?.snapshot().paragraphs[0].text??'',heads:store?.snapshot().heads??[],jobs:scheduler?.jobs.map(presentJob)??[],interpretations,error:lastError??null};}
function reset(id,text){
 if(scheduler)for(const j of scheduler.jobs)scheduler.cancel(j.id);
 for(const g of pending)g.resolve(g.candidate);pending=[];
 epoch++;documentID=id;session=null;audioResults=[];recordings=new Map();uiAnchors=[];requests=new Set();interpretations=[];lastError=null;
 store=createStore([{label:'document',text}]);const ownedStore=store, ownedEpoch=epoch;
 scheduler=new Scheduler({store:{...store,commit:(candidate,metadata)=>{
  const result=ownedStore.commit(candidate,metadata);
  if(result.status==='committed'&&outputRoot){try{
   mkdirSync(outputRoot,{recursive:true,mode:0o700});
   const file=path.join(outputRoot,'change-history.json');
   writeFileSync(file+'.tmp',JSON.stringify({documentID,changes:ownedStore.changeHistory()},null,2),{mode:0o600});renameSync(file+'.tmp',file);
  }catch(error){lastError='Change applied, but history could not be saved: '+error.message;}}
  return result;
 },capture:task=>captures.get(task)||ownedStore.capture(task),prepareCandidate:async(...args)=>{
  const candidate=await ownedStore.prepareCandidate(...args);
  if(ownedEpoch!==epoch)return candidate;
  return await new Promise(resolve=>pending.push({candidate,resolve}));
 }},generate:async(capture,options)=>{
  const saved=recoveredProposals.get(capture);
  if(!saved)return generate(capture,options);
  if(options.outputDir){mkdirSync(options.outputDir,{recursive:true});for(const file of ['request.json','response.json','result.json'])copyFileSync(path.join(saved.directory,file),path.join(options.outputDir,file));writeFileSync(path.join(options.outputDir,'reused.json'),JSON.stringify({source:saved.directory}));}
  return saved.text;
 },callModel,outputDir:outputRoot?path.join(outputRoot,`document-${epoch}`):undefined});
}
function observe(m){
 uiAnchors=m.ranges.map(r=>({...store.anchorRange(r.location,r.location+r.length),fallback:r.location}));
 if(!session||session.closed||m.at_ms<0)return;
 if(m.source==='typing'){session.typingActions.add(m.actionID);return;}
 if(session.typingActions.has(m.actionID))return;
 const ranges=m.ranges.map((r,index)=>({index,anchor:store.anchorRange(r.location,r.location+r.length)}));
 const key=m.actionID||`event-${session.events.length}`;
 const e={key,at_ms:m.at_ms,ranges,source:m.source};
 // A drag produces intermediate ranges. Retain only its last observation;
 // repeated clicks have distinct action IDs and remain separate evidence.
 const previous=session.events.findIndex(x=>x.key===key);
 if(previous>=0)session.events[previous]=e;else session.events.push(e);
}
async function processSpeech(m){
 const ownedEpoch=epoch,ownedScheduler=scheduler,ownedStore=store,ownedSession=recordings.get(m.recordingID);
 try {
 if(!ownedSession||ownedSession.id!==m.recordingID)throw Error('Recording session is unavailable');
 if(requests.has(m.recordingID))return;
 requests.add(m.recordingID);
 const interaction=[],selectionRanges=new Map();
 for(const e of ownedSession.events){for(const r of e.ranges){const x=ownedStore.resolveRange(r.anchor),selectionID=`${ownedSession.id}:${e.key}:${r.index}`;selectionRanges.set(selectionID,x);interaction.push(x.start===x.end?{type:'click',at_ms:e.at_ms,paragraph:'document',offset:x.start}:{type:'selection',at_ms:e.at_ms,paragraph:'document',start:x.start,end:x.end,text:x.text,selection_id:selectionID,gesture_id:e.key,range_index:r.index});}}
 interaction.push({type:'speech',start_ms:0,end_ms:m.duration_ms,text:m.transcript,final:true,...(m.words?{words:m.words}:{})});
 const input={document:{paragraphs:ownedStore.snapshot().paragraphs},interaction,capture:{now_ms:Math.max(m.duration_ms,...interaction.map(e=>e.at_ms||0)),gesture_window_closed:true}};
 interpretations.push({recordingID:m.recordingID,status:'interpreting'});
 // Retain state seen by interpretation, then map task scopes through any typing
 // that arrives while interpretation itself is running.
 const captureTask=ownedStore.captureContext(selectionRanges);
 let interpretationFailure;
 const result=await interpret(input,{callModel,onFailure:error=>{interpretationFailure=error;},outputDir:outputRoot?path.join(outputRoot,m.recordingID,'interpretation'):undefined});
 if(ownedEpoch!==epoch)return;
 if(interpretationFailure)throw interpretationFailure;
 const record=interpretations.find(x=>x.recordingID===m.recordingID);record.status='interpreted';record.result=result;phase='Editing · Automerge';
 result.tasks.forEach((task,index)=>{captures.set(task,captureTask(task));ownedScheduler.submit(task,{requestId:`${m.recordingID}:${index}`});});
 }catch(error){
  if(ownedEpoch!==epoch)return;
  let record=interpretations.find(x=>x.recordingID===m.recordingID);
  if(!record){record={recordingID:m.recordingID};interpretations.push(record);}
  record.status='failed';record.error=String(error.message??error);
  throw error;
 }

}
async function handle(m){
 if(outputRoot&&m.op!=='poll'){mkdirSync(outputRoot,{recursive:true,mode:0o700});appendFileSync(path.join(outputRoot,'ui-events.jsonl'),JSON.stringify({at:new Date().toISOString(),...m})+'\n',{mode:0o600});}
 if(m.op==='init'){reset(m.documentID,m.text);return state();}
 if(!store||m.documentID!==documentID)throw Error('Wrong document');
 if(m.op==='edit'){
  if(m.before!==state().text)throw Error('The editor and CRDT revisions differ; edit was not applied.');
  store.humanEdit('document',m.text);
 }else if(m.op==='begin'){session={id:m.recordingID,events:[],closed:false,typingActions:new Set()};recordings.set(m.recordingID,session);}
 else if(m.op==='observe')observe(m);
 else if(m.op==='cancel'){scheduler.cancel(m.jobID);}
 else if(m.op==='end'){if(session)session.closed=true;}
 else if(m.op==='cancelCapture'){if(session)recordings.delete(session.id);session=null;}
 else if(m.op==='audio') {
  const ownedEpoch=epoch;phase='Transcribing and aligning audio';
  const runner=process.env.EDITOR_AUDIO_PIPELINE;
  if(!runner)throw Error('Configure EDITOR_AUDIO_PIPELINE');
  const args=[runner,m.audioPath];
  if(m.transcriptionResult&&m.recordingMetadata)args.push('--transcription-result',m.transcriptionResult,'--recording-metadata',m.recordingMetadata);
  const child=spawn(process.env.EDITOR_PYTHON||'python3',args,{stdio:['ignore','pipe','inherit']});
  let raw='';child.stdout.on('data',b=>raw+=b);
  child.on('error',e=>{if(epoch===ownedEpoch){lastError=e.message;phase='Audio failed';}});
  child.on('close',code=>{if(epoch!==ownedEpoch)return;try{if(code!==0)throw Error('ASR/alignment failed; see the pipeline log');const result=JSON.parse(raw);audioResults.push({recordingID:m.recordingID,audioPath:m.audioPath,resultPath:result.result_file});phase='Interpreting';void processSpeech({...m,transcript:result.text,words:result.words,duration_ms:result.duration_ms}).catch(e=>lastError=e.message);}catch(e){lastError=e.message;phase='Audio failed';}});
 }
 else if(m.op==='recover') {
  const original=JSON.parse(readFileSync(path.join(m.directory,'engine-result.json'),'utf8'));
  const plan=m.planFile?JSON.parse(readFileSync(m.planFile,'utf8')):null;
  if(plan&&path.resolve(plan.source)!==path.resolve(m.directory))throw Error('Recovery plan belongs to another session');
  const overrides=new Map((plan?.repairs||[]).map(x=>[x.originalJobID,x]));
  const jobs=original.jobs.filter(j=>['failed','conflict'].includes(j.state));
  if(scheduler.jobs.length)throw Error('Recovery requires a fresh engine');
  const latestText=state().text;let originalText=null;
  const prepared=[];
  for(const job of jobs){
   if(!/^job-\d+$/.test(job.id))throw Error('Invalid recovery job');
   const directories=readdirSync(m.directory).filter(n=>/^document-\d+$/.test(n));
   const override=overrides.get(job.id);
   const base=override?.generationDirectory||directories.map(n=>path.join(m.directory,n,job.id,'generation')).find(p=>{try{readFileSync(path.join(p,'result.json'));return true;}catch{return false;}});
   if(!base)throw Error('Original generation evidence unavailable');
   const request=JSON.parse(readFileSync(path.join(base,'request.json'),'utf8'));const input=JSON.parse(request.input);
   const source=input.paragraph.before+input.paragraph.editable+input.paragraph.after;
   if(originalText!==null&&originalText!==source)throw Error('Recovery requests have different source revisions');
   originalText=source;
   const task=override?.task||original.interpretations.flatMap(x=>x.result?.tasks||[]).find(t=>t.instruction===job.instruction);
   if(!task||task.instruction!==input.instruction||task.working_area.quote!==input.paragraph.editable)throw Error('Recovery scope does not match original request');
   const ranges=new Map();if(task.working_area.selection_id)ranges.set(task.working_area.selection_id,{start:input.paragraph.before.length,end:input.paragraph.before.length+input.paragraph.editable.length});
   createStore([{label:'document',text:source}]).captureContext(ranges)(task);
   const result=JSON.parse(readFileSync(path.join(base,'result.json'),'utf8'));
   prepared.push({task,ranges,base,text:result.text,recordingID:job.recordingID});
  }
  if(!prepared.length)throw Error('No failed edits to recover');
  reset(documentID,originalText);
  prepared.forEach(p=>{p.capture=store.captureContext(p.ranges)(p.task);});
  if(latestText!==originalText)store.humanEdit('document',latestText,'recovered_document_changes');
  prepared.forEach((p,index)=>{captures.set(p.task,p.capture);recoveredProposals.set(p.capture,{directory:p.base,text:p.text});scheduler.submit(p.task,{requestId:`${p.recordingID}:recovery:${index}`});});
  phase='Retrying recovered edits';
 }
 else if(m.op==='process')void processSpeech(m).catch(e=>{lastError=e.message;});
 else if(m.op==='poll'){
  for(const g of pending.splice(0))g.resolve(g.candidate);
  // Complete the synchronous scheduler continuation before returning UI state.
  await new Promise(resolve=>setImmediate(resolve));
 }else if(m.op==='export'){
  if(!outputRoot)throw Error('Evidence output directory not configured');
  mkdirSync(outputRoot,{recursive:true});writeFileSync(path.join(outputRoot,'initial.automerge'),store.initialBytes);writeFileSync(path.join(outputRoot,'final.automerge'),store.save());writeFileSync(path.join(outputRoot,'engine-result.json'),JSON.stringify({...state(),events:scheduler.events,evidence:store.evidence},null,2));
 }
 return state();
}
let chain=Promise.resolve();
for await(const line of readline.createInterface({input:process.stdin})){
 chain=chain.then(async()=>{try{const m=JSON.parse(line);const result=await handle(m);process.stdout.write(JSON.stringify({ok:true,...result})+'\n');}catch(e){process.stdout.write(JSON.stringify({ok:false,error:e.message})+'\n');}});
}
