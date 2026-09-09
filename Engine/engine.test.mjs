import test from 'node:test';
import assert from 'node:assert/strict';
import {createStore} from './automerge_store.mjs';
import {prepareInput,validateResult} from './interpretation.mjs';
const task=(quote,id=null)=>({operation:'edit',instruction:'Replace the selected text',context:['document'],references:[],working_area:{paragraph:'document',quote,selection_id:id}});
const model=text=>async()=>({json:{status:'ready',text,reason:''}});
test('selection IDs capture exact repeated occurrence',async()=>{
 const store=createStore([{label:'document',text:'pending pending'}]);
 const capture=store.captureContext(new Map([['second',{start:8,end:15}]]))(task('pending','second'));
 assert.deepEqual(capture.span,{start:8,end:15});
 const candidate=await store.prepareCandidate(capture,'pending confirmed',{callModel:model('pending confirmed')});
 assert.equal(store.commit(candidate).status,'committed');assert.equal(store.snapshot().paragraphs[0].text,'pending confirmed');
});
test('gesture anchor follows insertion before selection',()=>{
 const store=createStore([{label:'document',text:'Hello selected end'}]);const anchor=store.anchorRange(6,14);
 store.humanEdit('document','Prefix Hello selected end');assert.deepEqual(store.resolveRange(anchor),{start:13,end:21,text:'selected'});
});
test('selection preserves emoji and cross-line UTF16 offsets',()=>{
 const store=createStore([{label:'document',text:'A😀\nB end'}]);const anchor=store.anchorRange(1,5);
 assert.equal(store.resolveRange(anchor).text,'😀\nB');
});
test('deleted anchored boundary does not broaden scope',()=>{
 const store=createStore([{label:'document',text:'A selected end'}]);const anchor=store.anchorRange(2,10);
 store.humanEdit('document','A end');assert.throws(()=>store.resolveRange(anchor),/boundary/);
});
test('capture retains interpretation snapshot across human typing',async()=>{
 const store=createStore([{label:'document',text:'Hello pending. Day Tuesday.'}]);
 const context=store.captureContext(new Map([['word',{start:6,end:13}]]));
 store.humanEdit('document','Hello pending. Day Thursday.');
 const capture=context(task('pending','word'));
 assert.equal(capture.originalText,'Hello pending. Day Tuesday.');
 const candidate=await store.prepareCandidate(capture,'Hello confirmed. Day Tuesday.',{callModel:model('Hello confirmed. Day Thursday.')});
 assert.equal(store.commit(candidate).status,'committed');
 assert.equal(store.snapshot().paragraphs[0].text,'Hello confirmed. Day Thursday.');
});
test('typing during reconciliation rejects stale commit',async()=>{
 const store=createStore([{label:'document',text:'Hello pending. Day Tuesday.'}]);const capture=store.capture(task('pending'));
 const candidate=await store.prepareCandidate(capture,'Hello confirmed. Day Tuesday.',{callModel:async()=>{store.humanEdit('document','Hello pending. Day Thursday.');return {json:{status:'ready',text:'Hello confirmed. Day Tuesday.',reason:''}};}});
 assert.equal(store.commit(candidate).status,'stale');assert.match(store.snapshot().paragraphs[0].text,/Thursday/);
});
test('Hack 6 keeps grouping and resolves duplicate identity',()=>{
 const input=prepareInput({document:{paragraphs:[{label:'document',text:'pending pending'}]},interaction:[{type:'selection',paragraph:'document',start:8,end:15,text:'pending',at_ms:1,selection_id:'second',gesture_id:'gesture',range_index:0}],capture:{now_ms:2,gesture_window_closed:true}});
 assert.equal(input.interaction[0].gesture_id,'gesture');
 assert.equal(validateResult({tasks:[task('pending','second')],needs_input:[]},input).tasks.length,1);
 assert.equal(validateResult({tasks:[task('pending')],needs_input:[]},input).tasks.length,0);
});
test('restore model-omitted read-only trailing space at both stages',async()=>{
 const s=createStore([{label:'document',text:'Refund $200.\nBest,\nAlex '}]);
 const capture=s.capture(task('$200'));let request;
 const c=await s.prepareCandidate(capture,'Refund $20.\nBest,\nAlex',{callModel:async q=>{request=JSON.parse(q.input);return {json:{status:'ready',text:'Refund $20.\nBest,\nAlex',reason:''}};}});
 assert.equal(request.scope_error,null);assert.equal(request.proposed,'Refund $20.\nBest,\nAlex ');
 assert.equal(s.commit(c).status,'committed');assert.equal(s.snapshot().paragraphs[0].text,'Refund $20.\nBest,\nAlex ');
 assert.deepEqual(c.frameRestorations,{generation:true,reconciliation:true});
});
test('restoration does not allow another signature name',async()=>{
 const s=createStore([{label:'document',text:'Refund $200.\nBest,\nAlex '}]);
 const c=await s.prepareCandidate(s.capture(task('$200')),'Refund $20.\nBest,\nJohn',{callModel:model('Refund $20.\nBest,\nJohn')});
 assert.equal(s.commit(c).status,'conflict');
});
test('restoration preserves latest human boundary whitespace',async()=>{
 const s=createStore([{label:'document',text:'Refund $200.\nAlex '}]);const c=s.capture(task('$200'));
 s.humanEdit('document','Refund $200.\nAlex  \n');
 const p=await s.prepareCandidate(c,'Refund $20.\nAlex',{callModel:model('Refund $20.\nAlex')});
 assert.equal(s.commit(p).status,'committed');assert.equal(s.snapshot().paragraphs[0].text,'Refund $20.\nAlex  \n');
});
test('internal read-only whitespace remains strict',async()=>{
 const s=createStore([{label:'document',text:'Refund $200.\nBest,  Alex '}]);
 const c=await s.prepareCandidate(s.capture(task('$200')),'Refund $20.\nBest, Alex',{callModel:model('Refund $20.\nBest, Alex')});
 assert.equal(s.commit(c).status,'conflict');
});
test('editable trailing whitespace is not restored',async()=>{
 const text='Refund $200. ';const s=createStore([{label:'document',text}]);
 const c=await s.prepareCandidate(s.capture(task(text)),'Refund $20.',{callModel:model('Refund $20.')});
 assert.equal(s.commit(c).status,'committed');assert.equal(s.snapshot().paragraphs[0].text,'Refund $20.');
});
test('whitespace-only frame restores wholly omitted boundaries',async()=>{
 const s=createStore([{label:'document',text:'  $200 \n'}]);
 const c=await s.prepareCandidate(s.capture(task('$200')),'$20',{callModel:model('$20')});
 assert.equal(s.commit(c).status,'committed');assert.equal(s.snapshot().paragraphs[0].text,'  $20 \n');
});
test('trailing-space recovery preserves a later human signature extension',async()=>{
 const s=createStore([{label:'document',text:'Refund $200.\nAlex '}]);const c=s.capture(task('$200'));
 s.humanEdit('document','Refund $200.\nAlex Morgan');
 const p=await s.prepareCandidate(c,'Refund $20.\nAlex',{callModel:model('Refund $20.\nAlex Morgan')});
 assert.equal(s.commit(p).status,'committed');assert.equal(s.snapshot().paragraphs[0].text,'Refund $20.\nAlex Morgan');
});
test('CRDT-aware reconciliation preserves rewritten greeting while adding job title',async()=>{
 const before='The message.\n\nBest,\nAlex Morgan';const s=createStore([{label:'document',text:before}]);
 const c=s.capture(task('Best,\nAlex Morgan'));
 s.humanEdit('document','The message.\n\nSorry for the trouble,\nAlex Morgan');let input;
 const p=await s.prepareCandidate(c,before+'\nHead of technology at Example Studio',{callModel:async q=>{input=JSON.parse(q.input);return {json:{status:'ready',text:input.crdt_merge_candidate,reason:''}};}});
 assert.equal(input.scope_mapping.method,'stable_surrounding_cursors');assert.ok(input.scope_mapping.surviving_target_tokens.includes('Alex'));
 assert.equal(input.intervening_changes[0].origin,'human');assert.match(input.intervening_changes[0].after,/Sorry/);
 assert.match(input.proposed_change.after,/Head of technology/);assert.equal(s.commit(p).status,'committed');
 assert.equal(s.snapshot().paragraphs[0].text,'The message.\n\nSorry for the trouble,\nAlex Morgan\nHead of technology at Example Studio');
});
test('surrounding-cursor recovery does not resurrect a wholly deleted sign-off',async()=>{
 const before='The message.\n\nBest,\nAlex Morgan';const s=createStore([{label:'document',text:before}]);const c=s.capture(task('Best,\nAlex Morgan'));
 s.humanEdit('document','The message.\n\n');
 const p=await s.prepareCandidate(c,before+'\nHead of technology',{callModel:model(before+'\nHead of technology')});assert.equal(s.commit(p).status,'conflict');
});
test('changed surrounding boundary prevents unsafe scope recovery',async()=>{
 const before='The message.\n\nBest,\nAlex Morgan';const s=createStore([{label:'document',text:before}]);const c=s.capture(task('Best,\nAlex Morgan'));
 s.humanEdit('document','Other section: Sorry for the trouble, Alex Morgan');
 const p=await s.prepareCandidate(c,before+'\nHead of technology',{callModel:model('Other section: Sorry for the trouble, Alex Morgan\nHead of technology')});assert.equal(s.commit(p).status,'conflict');
});
test('expanded grammar scope permits a to an without authorizing other changes',async()=>{
 const before='We received a late shipment from our supplier.';const s=createStore([{label:'document',text:before}]);const c=s.capture(task('a late shipment'));
 const after='We received an exceptionally late shipment (about a month late) from our supplier.';
 const p=await s.prepareCandidate(c,after,{callModel:model(after)});assert.equal(s.commit(p).status,'committed');
});
test('captured selection itself survives an internal greeting replacement',()=>{
 const s=createStore([{label:'document',text:'Intro\nBest,\nAlex Morgan'}]);const a=s.anchorRange(6,23);
 s.humanEdit('document','Intro\nSorry for the trouble,\nAlex Morgan');assert.equal(s.resolveRange(a).text,'Sorry for the trouble,\nAlex Morgan');
});
