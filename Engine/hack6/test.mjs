import test from 'node:test';
import assert from 'node:assert/strict';
import {prepareInput,validateResult,interpret,schema} from '../interpretation.mjs';
import {fixtures,paragraphs,checkFixture} from './fixtures.mjs';
const input=()=>structuredClone(fixtures[2].input);
const task=()=>({operation:'edit',instruction:'Make reference_1 shorter.',context:['p1'],references:[{name:'reference_1',paragraph:'p1',quote:paragraphs[0].text}],working_area:{paragraph:'p1',quote:paragraphs[0].text}});
const result=()=>({tasks:[task()],needs_input:[]});
test('captures clicks as offsets and mechanical context, not semantic references',()=>{let p=prepareInput(input());assert.equal(p.interaction[0].context_after.startsWith('12 chairs'),true);assert.equal(p.interaction[0].quote,undefined);});
test('selection content must match its document snapshot',()=>{let p=structuredClone(fixtures[1].input);p.interaction[1].text='wrong';assert.throws(()=>prepareInput(p),/does not match/);});
test('rejects unavailable pointer paragraph',()=>{let p=input();p.interaction[0].paragraph='absent';assert.throws(()=>prepareInput(p),/unavailable/);});
test('does not expose future gestures or late-arriving speech',()=>{let p=input();p.capture.now_ms=1000;p.interaction[0].received_ms=2000;const s=prepareInput(p);assert.equal(s.interaction.length,2);});
test('rejects invalid timing and offsets',()=>{let p=input();p.interaction[0].offset=-1;assert.throws(()=>prepareInput(p),/outside/);p=input();p.interaction[3].end_ms=0;assert.throws(()=>prepareInput(p),/valid capture times/);});
test('duplicate paragraph labels fail',()=>{let p=input();p.document.paragraphs.push(p.document.paragraphs[0]);assert.throws(()=>prepareInput(p),/unique/);});
test('valid assignment passes verbatim',()=>assert.deepEqual(validateResult(result(),input()),result()));
test('invented quote fails visibly and preserves other actions',()=>{let r=result();r.tasks.push({...task(),working_area:{paragraph:'p1',quote:'invented'}});let v=validateResult(r,input());assert.equal(v.tasks.length,1);assert.equal(v.needs_input.length,1);});
test('duplicate exact quote requires clarification',()=>{let r=result();r.tasks[0].working_area={paragraph:'p7',quote:'More details follow.'};assert.equal(validateResult(r,input()).tasks.length,0);});
test('unknown context fails visibly',()=>{let r=result();r.tasks[0].context=['p100'];assert.equal(validateResult(r,input()).tasks.length,0);});
test('duplicate reference names fail',()=>{let r=result();r.tasks[0].references.push(r.tasks[0].references[0]);assert.equal(validateResult(r,input()).tasks.length,0);});
test('questions must not mutate',()=>{let r=result();r.tasks[0].operation='question';assert.equal(validateResult(r,input()).tasks.length,0);r.tasks[0].working_area=null;assert.equal(validateResult(r,input()).tasks.length,1);});
test('open window never calls model',async()=>{let p=input();p.capture.gesture_window_closed=false;let r=await interpret(p,{callModel:()=>assert.fail('called model')});assert.equal(r.needs_input[0].kind,'wait');});
test('failed ASR never calls model',async()=>{let p=input();p.interaction[3].failed=true;let r=await interpret(p,{callModel:()=>assert.fail('called model')});assert.equal(r.needs_input[0].kind,'asr_error');});
test('partial ASR never calls model',async()=>{let p=input();p.interaction[3].final=false;let r=await interpret(p,{callModel:()=>assert.fail('called model')});assert.equal(r.needs_input[0].kind,'wait');});
test('actual boundary supplies schema and input without internal IDs',async()=>{let r=await interpret(input(),{callModel:async request=>{assert.deepEqual(request.schema,schema);assert.ok(request.instructions.includes('Do not rewrite'));assert.deepEqual(Object.keys(JSON.parse(request.input)),['document','interaction','capture']);return {json:result()};}});assert.equal(r.tasks.length,1);});
test('malformed model output becomes visible failure',async()=>{let r=await interpret(input(),{callModel:async()=>({text:'not json'})});assert.equal(r.tasks.length,0);assert.match(r.needs_input[0].message,/Could not interpret/);});
test('API failure becomes visible failure',async()=>{let r=await interpret(input(),{callModel:async()=>{throw Error('unavailable');}});assert.equal(r.needs_input.length,1);});
test('invalid word alignment rejected',()=>{let p=input();p.interaction[3].words=[['list',0,200]];assert.throws(()=>prepareInput(p),/inside/);});

test('undeclared instruction reference fails visibly',()=>{let r=result();r.tasks[0].instruction='Shorten reference_9.';assert.equal(validateResult(r,input()).tasks.length,0);});

test('naming regression checker catches source literal promoted to user instruction',()=>{
 const fixture=fixtures.find(f=>f.name==='referential_name_not_literal_constraint');
 const p=fixture.input.document.paragraphs[1];
 const t={operation:'edit',instruction:'Make a review checklist with the product name in its heading.',context:['p2'],references:[{name:'reference_1',paragraph:'p2',quote:p.text}],working_area:{paragraph:'p2',quote:p.text}};
 assert.equal(checkFixture(fixture,{tasks:[t],needs_input:[]}).length,0);
 t.instruction='Make a review checklist with the product name, Example Headphones, in its heading.';
 assert.match(checkFixture(fixture,{tasks:[t],needs_input:[]})[0],/promoted/);
});

function identityInput(){
 const text='😀 Same words.\nSame words.\nLast item.';
 const start=text.lastIndexOf('Same words.');
 return {document:{paragraphs:[{label:'document',text}]},interaction:[
  {type:'selection',at_ms:100,paragraph:'document',start,end:start+'Same words.'.length,text:'Same words.',selection_id:'selected-second',gesture_id:'action-7',range_index:0},
  {type:'selection',at_ms:120,paragraph:'document',start:text.indexOf('Last item.'),end:text.length,text:'Last item.',selection_id:'selected-last',gesture_id:'action-7',range_index:1},
  {type:'speech',start_ms:200,end_ms:1500,text:'Make this shorter.',final:true}
 ],capture:{now_ms:2000,gesture_window_closed:true}};
}
function identityResult(){return {tasks:[{operation:'edit',instruction:'Make reference_1 shorter.',context:['document'],references:[{name:'reference_1',paragraph:'document',quote:'Same words.',selection_id:'selected-second'}],working_area:{paragraph:'document',quote:'Same words.',selection_id:'selected-second'}}],needs_input:[]};}
test('preserves group IDs, range order, UTF-16 offsets and document newlines',()=>{
 const raw=identityInput(),prepared=prepareInput(raw);
 assert.deepEqual(prepared.interaction.slice(0,2),raw.interaction.slice(0,2));
 assert.equal(prepared.document.paragraphs[0].text,raw.document.paragraphs[0].text);
 assert.equal(prepared.interaction[0].start,15);
});
test('selected repeated quote resolves exact occurrence by app selection identity',()=>{
 const r=identityResult();assert.deepEqual(validateResult(r,prepareInput(identityInput())),r);
});
test('repeated quote without identity still clarifies, including nullable identity',()=>{
 for(const value of [undefined,null]){
  const r=identityResult();if(value===undefined)delete r.tasks[0].working_area.selection_id;else r.tasks[0].working_area.selection_id=value;
  assert.equal(validateResult(r,identityInput()).tasks.length,0);
 }
});
test('unknown, wrong-range, wrong-paragraph and invalid identities cannot authorize edits',()=>{
 for(const mutation of [
  r=>r.tasks[0].working_area.selection_id='unknown',
  r=>r.tasks[0].working_area.selection_id='selected-last',
  r=>r.tasks[0].working_area.paragraph='absent',
  r=>r.tasks[0].working_area.selection_id=9,
  r=>r.tasks[0].working_area.quote='Same words.\nLast item.',
  r=>r.tasks[0].references[0].selection_id='selected-last',
 ]){const r=identityResult();mutation(r);assert.equal(validateResult(r,identityInput()).tasks.length,0);}
});
test('null selection identity retains legacy unique quote behavior',()=>{
 const r=result();r.tasks[0].working_area.selection_id=null;r.tasks[0].references[0].selection_id=null;
 assert.deepEqual(validateResult(r,input()),r);
});
test('rejects malformed capture identity metadata',()=>{
 for(const [key,value] of [['selection_id',''],['selection_id',null],['gesture_id',7],['gesture_id',' '],['range_index',-1],['range_index',0.5],['range_index',Number.MAX_SAFE_INTEGER+1]]){
  const p=identityInput();p.interaction[0][key]=value;assert.throws(()=>prepareInput(p),/Invalid/);
 }
});
test('same selection ID cannot identify two different ranges',()=>{
 const p=identityInput();p.interaction[1].selection_id='selected-second';
 assert.throws(()=>prepareInput(p),/conflicting ranges/);
 assert.equal(validateResult(identityResult(),p).tasks.length,0);
});
test('repeated gestures may refer to the same stable selected range',()=>{
 const p=identityInput();p.interaction.push({...p.interaction[0],at_ms:160,gesture_id:'action-8'});
 assert.equal(prepareInput(p).interaction.at(-1).gesture_id,'action-8');
 assert.equal(validateResult(identityResult(),p).tasks.length,1);
});
test('future or not-yet-received selection identities cannot resolve a quote',()=>{
 for(const property of ['at_ms','received_ms']){
  const p=identityInput();p.interaction[0][property]=2100;
  assert.equal(validateResult(identityResult(),p).tasks.length,0);
  assert.equal(validateResult(identityResult(),prepareInput(p)).tasks.length,0);
 }
});
test('multiple grouped selected ranges retain distinct explicit references',()=>{
 const p=identityInput(),r=identityResult();r.tasks[0].instruction='Make reference_1 and reference_2 a list.';
 r.tasks[0].references.push({name:'reference_2',paragraph:'document',quote:'Last item.',selection_id:'selected-last'});
 r.tasks[0].working_area={paragraph:'document',quote:'Same words.\nLast item.',selection_id:null};
 assert.deepEqual(validateResult(r,prepareInput(p)),r);
});
test('strict schema declares nullable selection IDs while old tasks remain valid',()=>{
 const props=schema.properties.tasks.items.properties;
 for(const object of [props.references.items,props.working_area.anyOf[1]]){
  assert.ok(object.required.includes('selection_id'));assert.deepEqual(object.properties.selection_id.type,['string','null']);
 }
 assert.deepEqual(validateResult(result(),input()),result());
});
test('model boundary receives identities and returns selected occurrence unchanged',async()=>{
 const r=await interpret(identityInput(),{callModel:async request=>{
  const captured=JSON.parse(request.input);assert.equal(captured.interaction[0].selection_id,'selected-second');assert.equal(captured.interaction[1].range_index,1);
  assert.match(request.instructions,/never use an id to authorize an expanded/i);
  return {json:identityResult()};
 }});
 assert.deepEqual(r,identityResult());
});

const grammar=await import('./grammatical-scope-fixtures.mjs');
function grammarResult(f){return {tasks:[{operation:'edit',instruction:f.input.interaction.at(-1).text,context:['document'],references:[{name:'reference_1',paragraph:'document',quote:f.referenceQuote,selection_id:f.referenceId}],working_area:{paragraph:'document',quote:f.quote,selection_id:f.selectionId}}],needs_input:[]};}
test('grammatical scope can include article while preserving exact selected reference',()=>{
 const f=grammar.fixtures[0],r=grammarResult(f);assert.deepEqual(validateResult(r,prepareInput(f.input)),r);assert.deepEqual(grammar.checkFixture(f,r),[]);
});
test('grammatical expansion cannot reuse the narrower selection ID',()=>{
 const f=grammar.fixtures[0],r=grammarResult(f);r.tasks[0].working_area.selection_id=f.referenceId;assert.equal(validateResult(r,prepareInput(f.input)).tasks.length,0);
});
test('explicit literal phrase and duplicate token remain narrow',()=>{
 for(const f of grammar.fixtures.slice(1)){const r=grammarResult(f);assert.deepEqual(validateResult(r,prepareInput(f.input)),r);assert.deepEqual(grammar.checkFixture(f,r),[]);}
});
test('grammar fixture checks reject too-narrow rewrite and unnecessary whole-sentence expansion',()=>{
 const f=grammar.fixtures[0];for(const quote of [' late shipment','We are sorry about a late shipment from our supplier.']){const r=grammarResult(f);r.tasks[0].working_area.quote=quote;assert.ok(grammar.checkFixture(f,r).length);}
 const r=grammarResult(f);r.tasks[0].references[0].quote='a late shipment';assert.ok(grammar.checkFixture(f,r).length);
});
test('literal fixture checks reject grammar expansion beyond explicit selected-only instruction',()=>{
 const f=grammar.fixtures[1],r=grammarResult(f);r.tasks[0].working_area={paragraph:'document',quote:'a late shipment',selection_id:null};assert.ok(grammar.checkFixture(f,r).length);
});
