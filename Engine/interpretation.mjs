import {readFile} from 'node:fs/promises';
export const schema = {
  type:'object', additionalProperties:false, required:['tasks','needs_input'], properties:{
    tasks:{type:'array',items:{type:'object',additionalProperties:false,
      required:['operation','instruction','context','references','working_area'],properties:{
        operation:{type:'string',enum:['edit','question']},instruction:{type:'string'},
        context:{type:'array',items:{type:'string'}},
        references:{type:'array',items:{type:'object',additionalProperties:false,required:['name','paragraph','quote','selection_id'],properties:{name:{type:'string'},paragraph:{type:'string'},quote:{type:'string'},selection_id:{type:['string','null']}}}},
        working_area:{anyOf:[{type:'null'},{type:'object',additionalProperties:false,required:['paragraph','quote','selection_id'],properties:{paragraph:{type:'string'},quote:{type:'string'},selection_id:{type:['string','null']}}}]}
      }}}, needs_input:{type:'array',items:{type:'object',additionalProperties:false,required:['kind','message'],properties:{kind:{type:'string',enum:['wait','clarify','asr_error']},message:{type:'string'}}}}
  }
};
const finite = x=>typeof x==='number' && Number.isFinite(x) && x>=0;
const exactKeys=(o,keys,optional=[])=>o && typeof o==='object' && !Array.isArray(o) && keys.every(k=>Object.hasOwn(o,k)) && Object.keys(o).every(k=>keys.includes(k)||optional.includes(k));
function occurrences(text,quote){let n=0,p=0;while((p=text.indexOf(quote,p))!==-1){n++;p++;}return n;}
function fail(message,kind='clarify'){return {tasks:[],needs_input:[{kind,message}]};}
export function prepareInput(input){
  if(!input?.document || !Array.isArray(input.document.paragraphs) || !Array.isArray(input.interaction)) throw Error('Document paragraphs and interaction events are required.');
  const paragraphs=input.document.paragraphs.map(p=>{
    if(typeof p.label!=='string'||!p.label||typeof p.text!=='string') throw Error('Each paragraph needs a label and text.');
    return {label:p.label,text:p.text};
  });
  const byLabel=new Map(paragraphs.map(p=>[p.label,p.text]));
  if(byLabel.size!==paragraphs.length) throw Error('Paragraph labels must be unique.');
  if(!finite(input.capture?.now_ms)||typeof input.capture?.gesture_window_closed!=='boolean') throw Error('Capture time and gesture-window state are required.');
  const interaction=[];
  const selections=new Map();
  for(const e of input.interaction){
    if(!e||typeof e.type!=='string') throw Error('Invalid interaction event.');
    if(e.received_ms!==undefined&&!finite(e.received_ms)) throw Error('Invalid event receipt time.');
    if(e.received_ms>input.capture.now_ms) continue;
    if(e.type==='speech'){
      if(!finite(e.start_ms)||!finite(e.end_ms)||e.end_ms<e.start_ms||typeof e.text!=='string'||typeof e.final!=='boolean') throw Error('Speech requires valid capture times, text, and final state.');
      if(e.end_ms>input.capture.now_ms) continue;
      const event={type:'speech',start_ms:e.start_ms,end_ms:e.end_ms,text:e.text,final:e.final};
      if(e.failed===true) event.failed=true;
      if(e.words!==undefined){
        if(!Array.isArray(e.words)||e.words.some(w=>!Array.isArray(w)||w.length!==3||typeof w[0]!=='string'||!finite(w[1])||!finite(w[2])||w[2]<w[1]||w[1]<e.start_ms||w[2]>e.end_ms)) throw Error('Word timestamps must lie inside the speech interval.');
        event.words=e.words;
      }
      interaction.push(event);continue;
    }
    if(!['click','selection'].includes(e.type)) throw Error('Unsupported interaction event type.');
    if(!finite(e.at_ms)) throw Error('Pointer capture time is required.');
    if(e.at_ms>input.capture.now_ms) continue;
    const text=byLabel.get(e.paragraph);
    if(text===undefined) throw Error('Pointer paragraph is unavailable in the supplied document state.');
    if(e.type==='click'){
      if(!Number.isInteger(e.offset)||e.offset<0||e.offset>text.length) throw Error('Click offset is outside the paragraph.');
      interaction.push({type:'click',at_ms:e.at_ms,paragraph:e.paragraph,offset:e.offset,context_before:text.slice(Math.max(0,e.offset-40),e.offset),context_after:text.slice(e.offset,e.offset+40)});
    }else{
      if(!Number.isInteger(e.start)||!Number.isInteger(e.end)||e.start<0||e.end<=e.start||e.end>text.length) throw Error('Selection offsets are invalid.');
      const selected=text.slice(e.start,e.end);
      if(e.text!==undefined&&e.text!==selected) throw Error('Selection text does not match the supplied document state.');
      const identity={};
      for(const key of ['selection_id','gesture_id'])if(e[key]!==undefined){
        if(typeof e[key]!=='string'||!e[key].trim())throw Error(`Invalid ${key}.`);
        identity[key]=e[key];
      }
      if(e.range_index!==undefined){
        if(!Number.isSafeInteger(e.range_index)||e.range_index<0)throw Error('Invalid range_index.');
        identity.range_index=e.range_index;
      }
      if(e.selection_id!==undefined){
        const signature=JSON.stringify([e.paragraph,e.start,e.end]);
        if(selections.has(e.selection_id)&&selections.get(e.selection_id)!==signature)throw Error('selection_id identifies conflicting ranges in this document state.');
        selections.set(e.selection_id,signature);
      }
      interaction.push({type:'selection',at_ms:e.at_ms,paragraph:e.paragraph,start:e.start,end:e.end,text:selected,...identity});
    }
  }
  return {document:{paragraphs},interaction,capture:{now_ms:input.capture.now_ms,gesture_window_closed:input.capture.gesture_window_closed}};
}
export function validateResult(result,input){
  if(!exactKeys(result,['tasks','needs_input'])||!Array.isArray(result.tasks)||!Array.isArray(result.needs_input)||result.needs_input.some(x=>!exactKeys(x,['kind','message'])||!['wait','clarify','asr_error'].includes(x.kind)||typeof x.message!=='string'||!x.message.trim())) throw Error('Invalid interpretation response shape.');
  const docs=new Map(input.document.paragraphs.map(p=>[p.label,p.text]));
  const tasks=[], needs_input=[...result.needs_input];
  const selections=new Map(), conflictingIds=new Set();
  for(const e of input.interaction??[]){
    if(e.type!=='selection'||typeof e.selection_id!=='string'||!e.selection_id.trim())continue;
    if(!finite(e.at_ms)||e.at_ms>input.capture.now_ms||e.received_ms>input.capture.now_ms)continue;
    const text=docs.get(e.paragraph);
    if(typeof text!=='string'||!Number.isInteger(e.start)||!Number.isInteger(e.end)||e.start<0||e.end<=e.start||e.end>text.length)continue;
    const quote=text.slice(e.start,e.end);
    if(e.text!==undefined&&e.text!==quote)continue;
    const record={paragraph:e.paragraph,start:e.start,end:e.end,quote};
    if(selections.has(e.selection_id)&&JSON.stringify(selections.get(e.selection_id))!==JSON.stringify(record))conflictingIds.add(e.selection_id);
    selections.set(e.selection_id,record);
  }
  const resolvedQuote=q=>{
    if(!exactKeys(q,['paragraph','quote'],['selection_id'])||!docs.has(q.paragraph)||typeof q.quote!=='string'||!q.quote.length)return false;
    if(q.selection_id===undefined||q.selection_id===null)return occurrences(docs.get(q.paragraph),q.quote)===1;
    if(typeof q.selection_id!=='string'||conflictingIds.has(q.selection_id))return false;
    const selected=selections.get(q.selection_id);
    return !!selected&&selected.paragraph===q.paragraph&&selected.quote===q.quote;
  };
  for(const [index,t] of result.tasks.entries()){
    let error;
    if(!exactKeys(t,['operation','instruction','context','references','working_area'])||!['edit','question'].includes(t.operation)||typeof t.instruction!=='string'||!t.instruction.trim()) error='invalid assignment';
    else if(!Array.isArray(t.context)||t.context.some(x=>!docs.has(x))) error='unknown context paragraph';
    else if(!Array.isArray(t.references)||t.references.some(r=>!exactKeys(r,['name','paragraph','quote'],['selection_id'])||!/^reference_[1-9]\d*$/.test(r.name)||!resolvedQuote({paragraph:r.paragraph,quote:r.quote,...(Object.hasOwn(r,'selection_id')?{selection_id:r.selection_id}:{})}))||new Set(t.references.map(r=>r.name)).size!==t.references.length) error='unresolved or ambiguous reference';
    else if([...t.instruction.matchAll(/\breference_[1-9]\d*\b/g)].some(m=>!t.references.some(r=>r.name===m[0]))) error='instruction uses an undeclared reference';
    else if(t.operation==='question'&&t.working_area!==null) error='question cannot have a working area';
    else if(t.operation==='edit'&&!resolvedQuote(t.working_area)) error='unresolved or ambiguous working area';
    if(error) needs_input.push({kind:'clarify',message:`Action ${index+1} needs clarification: ${error}.`});
    else tasks.push(t);
  }
  return {tasks,needs_input};
}
export async function interpret(input,{callModel,outputDir,onFailure}={}){
  let prepared;
  try{prepared=prepareInput(input);}catch(e){onFailure?.(e);return fail(e.message);}
  if(!prepared.capture.gesture_window_closed) return fail('Waiting for the pointing window to close.','wait');
  if(!prepared.interaction.some(e=>e.type==='speech'&&e.final&&!e.failed&&e.text.trim())) return fail('Waiting for a final successful transcription.',prepared.interaction.some(e=>e.failed)?'asr_error':'wait');
  // Failed and interim ASR are not commands and cannot override final speech.
  prepared.interaction=prepared.interaction.filter(e=>e.type!=='speech'||(e.final&&!e.failed));
  try{
    if(typeof callModel!=='function') throw Error('An interpretation model is required.');
    const instructions=await readFile(new URL('./hack6/interpret.txt',import.meta.url),'utf8');
    const response=await callModel({instructions,input:JSON.stringify(prepared),schema,outputDir});
    return validateResult(response.json??JSON.parse(response.text),prepared);
  }catch(e){onFailure?.(e);return fail(`Could not interpret this interaction: ${e.message}`);}
}
