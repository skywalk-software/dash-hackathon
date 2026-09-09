const paragraph='Hi Maya,\n\nWe are sorry about a late shipment from our supplier. Your lamp will arrive Tuesday.\n\nBest,\nAlex ';
function input(text,selected,speech,id='shipment-selection',start=text.indexOf(selected)){
 return {document:{paragraphs:[{label:'document',text}]},interaction:[
  {type:'selection',at_ms:300,paragraph:'document',start,end:start+selected.length,text:selected,selection_id:id,gesture_id:'action-grammar',range_index:0},
  {type:'speech',start_ms:1000,end_ms:6000,text:speech,final:true}
 ],capture:{now_ms:7000,gesture_window_closed:true}};
}
export const fixtures=[
 {name:'article-expansion',input:input(paragraph,' late shipment','Make this exceptionally late—about a month late.'),quote:'a late shipment',selectionId:null,referenceQuote:' late shipment',referenceId:'shipment-selection'},
 {name:'literal-phrase-no-expansion',input:input(paragraph,' late shipment','Replace only the selected text with exactly: exceptionally late shipment. Do not change anything outside the selection.'),quote:' late shipment',selectionId:'shipment-selection',referenceQuote:' late shipment',referenceId:'shipment-selection'},
 {name:'literal-duplicate-token',input:input('First order: pending.\nSecond order: pending.\nBest,\nAlex ','pending','Replace only this selected word with confirmed.','second-pending','First order: pending.\nSecond order: pending.\nBest,\nAlex '.lastIndexOf('pending')),quote:'pending',selectionId:'second-pending',referenceQuote:'pending',referenceId:'second-pending'}
];
export function checkFixture(f,r){
 const errors=[];
 if(r.needs_input?.length||r.tasks?.length!==1)return ['Expected one unambiguous task'];
 const t=r.tasks[0];
 if(t.operation!=='edit'||t.working_area?.paragraph!=='document')errors.push('Expected document edit');
 if(t.working_area?.quote!==f.quote)errors.push('Working area does not match minimal expected grammatical/literal scope');
 if((t.working_area?.selection_id??null)!==f.selectionId)errors.push('Wrong working area identity');
 if(!t.references?.some(x=>x.paragraph==='document'&&x.quote===f.referenceQuote&&x.selection_id===f.referenceId))errors.push('Exact selected reference was lost or widened');
 return errors;
}
