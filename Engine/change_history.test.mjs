import test from 'node:test';
import assert from 'node:assert/strict';
import {createStore} from './automerge_store.mjs';
import {changeHunks} from './change_history.mjs';
const task=quote=>({operation:'edit',instruction:'Update',context:['document'],references:[],working_area:{paragraph:'document',quote}});
const model=text=>async()=>({json:{status:'ready',text,reason:''}});
async function apply(s,quote,proposed,actual=proposed){
 const c=await s.prepareCandidate(s.capture(task(quote)),proposed,{callModel:model(actual)});
 assert.equal(s.commit(c,{taskID:'job-1',instruction:'Update'}).status,'committed');
 return s.changeHistory()[0];
}
test('separate words and Unicode offsets identify exact inserted text',()=>{
 const h=changeHunks('😀 red cat and blue dog','😀 green cat and gold dog');
 assert.equal(h.length,2);assert.deepEqual(h.map(x=>x.after),['green','gold']);
 for(const x of h)assert.equal('😀 green cat and gold dog'.slice(x.location,x.location+x.length),x.after);
});
test('history attributes only actual commit, follows typing, and marks overwritten spans',async()=>{
 const s=createStore([{label:'document',text:'Hello pending. Day Tuesday.'}]);
 const capture=s.capture(task('pending'));
 s.humanEdit('document','Hello pending. Day Thursday.');
 const c=await s.prepareCandidate(capture,'Hello confirmed. Day Tuesday.',{callModel:model('Hello confirmed. Day Thursday.')});
 s.commit(c,{taskID:'job-7',instruction:'Confirm'});
 let record=s.changeHistory()[0];assert.equal(record.taskID,'job-7');assert.match(record.beforeText,/Thursday/);
 assert.deepEqual(record.hunks.map(h=>[h.before,h.after]),[['pending','confirmed']]);
 s.humanEdit('document','😀 Prefix Hello confirmed. Day Thursday.');
 record=s.changeHistory()[0];assert.equal(record.hunks[0].active,true);assert.equal(record.hunks[0].location,16);
 s.humanEdit('document','😀 Prefix Hello cancelled. Day Thursday.');
 record=s.changeHistory()[0];assert.equal(record.hunks[0].active,false);assert.match(record.afterText,/confirmed/);
});
test('deletions retain an inspectable zero-width marker, including end of document',async()=>{
 for(const [before,after] of [['A red B','A B'],['A red','A ']]){
  const s=createStore([{label:'document',text:before}]);await apply(s,before,after);
  const h=s.changeHistory()[0].hunks[0];assert.equal(h.active,true);assert.equal(h.length,0);assert.ok(h.before.length>0);assert.equal(h.after,'');
 }
});
test('stale candidates do not enter change history',async()=>{
 const s=createStore([{label:'document',text:'A red B'}]);
 const c=await s.prepareCandidate(s.capture(task('red')),'A blue B',{callModel:model('A blue B')});
 s.humanEdit('document','A green B');assert.equal(s.commit(c).status,'stale');assert.equal(s.changeHistory().length,0);
});
