export const paragraphs=[
{label:'p1',text:'Our community workshop welcomes families, teachers, and makers. We want everyone to feel at home, even if this is their first visit.'},
{label:'p2',text:'For the reception, we need 12 chairs, 8 tables, and 3 lamps. The supplier must deliver everything before Friday afternoon.'},
{label:'p3',text:'The hall contains several voids for recording interviews. Each void has a microphone and adjustable lighting. Volunteers should arrive at 9 am.'},
{label:'p4',text:'Please reserve the quiet voids for speakers who need to rehearse. Registration closes on Thursday, and cancellations remain free until Wednesday.'},
{label:'p5',text:'The budget is $2,400. Catering costs $900, transport costs $300, and equipment costs $1,200. Keep every receipt for the reimbursement team.'},
{label:'p6',text:'We will email the access instructions on Tuesday. Reply to the coordinator if you need step-free entry or a parking space.'},
{label:'p7',text:'More details follow. More details follow. Contact Maya for the complete safety checklist.'}
];
const text=id=>paragraphs.find(p=>p.label===id).text;
const click=(paragraph,quote,at_ms)=>({type:'click',paragraph,offset:text(paragraph).indexOf(quote),at_ms});
const selection=(paragraph,quote,at_ms)=>({type:'selection',paragraph,start:text(paragraph).indexOf(quote),end:text(paragraph).indexOf(quote)+quote.length,text:quote,at_ms});
const speech=(text,start_ms,end_ms)=>({type:'speech',text,start_ms,end_ms,final:true});
const make=(name,interaction,checks)=>({name,input:{document:{paragraphs},interaction,capture:{now_ms:90000,gesture_window_closed:true}},checks});
export const fixtures=[
make('long_multi_action',[
speech('I am reviewing the workshop announcement. First, make this opening warmer, but do not make it longer. Next, these three things should be a list. I am pointing at each of them. Also, we have used the wrong word throughout: change voids to booths and void to booth everywhere. Leave the delivery deadline as it is. Now, this budget explanation is too wordy. Actually, I mean the reimbursement sentence, make that shorter. Finally, when does registration close?',1000,44000),
click('p1','welcomes',5100),click('p1','feel',5900),click('p2','12',12000),click('p2','8',13000),click('p2','3 lamps',14000),selection('p5','Catering costs $900, transport costs $300, and equipment costs $1,200.',31500),selection('p5','Keep every receipt for the reimbursement team.',38000)
],{editParagraphs:['p1','p2','p3','p4','p5'],questionCount:1,correctedScope:'Keep every receipt for the reimbursement team.',listReferences:['12 chairs','8 tables','3 lamps']}),
make('partial_selection_after_speech',[speech('Replace this with accessible parking.',1000,3200),selection('p6','a parking space',3500)],{editParagraphs:['p6'],exactScope:'a parking space'}),
make('three_number_clicks',[click('p2','12',100),click('p2','8',300),click('p2','3 lamps',600),speech('Make those three into a list.',900,2800)],{editParagraphs:['p2'],listReferences:['12 chairs','8 tables','3 lamps']}),
make('same_paragraph_multiple_clicks',[click('p1','families',100),click('p1','everyone',500),speech('Make this whole opening paragraph more welcoming.',700,2600)],{editParagraphs:['p1'],exactScope:text('p1')}),
make('duplicate_quote_ambiguous',[speech('Shorten the sentence that says more details follow.',1000,3600)],{clarification:true}),
make('unrelated_actions_and_missing_reference',[speech('Change every voids to booths. Also make that shorter.',1000,5000)],{editParagraphs:['p3','p4'],clarification:true}),
make('question_with_selection',[selection('p1','community workshop',500),speech('When does registration close?',1000,2500)],{questionCount:1,noEdits:true,questionContext:'p4'}),
make('correction_replaces_target',[selection('p1',text('p1'),500),speech('Shorten this opening. Actually no, leave the opening alone. Shorten the final access instructions instead.',1000,6200)],{editParagraphs:['p6'],noEditParagraphs:['p1']})
];
export function checkFixture(fixture,result){
  const c=fixture.checks, errors=[],edits=result.tasks.filter(t=>t.operation==='edit'),qs=result.tasks.filter(t=>t.operation==='question');
  for(const p of c.editParagraphs??[])if(!edits.some(t=>t.working_area.paragraph===p))errors.push(`Missing edit for ${p}`);
  if(c.editParagraphs)for(const t of edits)if(!c.editParagraphs.includes(t.working_area.paragraph))errors.push(`Unexpected edit for ${t.working_area.paragraph}`);
  for(const p of c.noEditParagraphs??[])if(edits.some(t=>t.working_area.paragraph===p))errors.push(`Unexpected edit for ${p}`);
  for(const forbidden of c.forbiddenInstructionLiterals??[])if(result.tasks.some(t=>t.instruction.includes(forbidden)))errors.push(`Source fact promoted to instruction: ${forbidden}`);
  if(c.noEdits&&edits.length)errors.push('Unexpected edit for question');
  if(c.questionCount!==undefined&&qs.length!==c.questionCount)errors.push('Question count mismatch');
  if(c.questionContext&&!qs.some(t=>t.context.includes(c.questionContext)))errors.push('Question lacks relevant context');
  if(c.clarification&&!result.needs_input.some(n=>n.kind==='clarify'))errors.push('Missing clarification');
  if(c.exactScope&&!edits.some(t=>t.working_area.quote===c.exactScope))errors.push('Exact scope mismatch');
  if(c.correctedScope&&!edits.some(t=>t.working_area.quote===c.correctedScope))errors.push('Correction scope mismatch');
  for(const quote of c.listReferences??[])if(!edits.some(t=>t.references.some(r=>r.quote===quote)))errors.push(`Missing list reference ${quote}`);
  return errors;
}

// Regression: the spoken role is product name; its stale document spelling must
// stay in source references, not become an explicitly demanded literal.
fixtures.push({name:'referential_name_not_literal_constraint',input:{
 document:{paragraphs:[
  {label:'p1',text:'The Example Headphones announcement draft needs an editorial pass.'},
  {label:'p2',text:'For the Example Headphones review, collect feedback in this document. Read the Example Headphones introduction first, then check buying details and the call to action. Keep the draft unpublished until factual questions are resolved.'}
 ]},
 interaction:[{type:'click',at_ms:500,paragraph:'p2',offset:10},
 {type:'speech',start_ms:1000,end_ms:7000,final:true,text:'Turn this into a review checklist with the product name in its heading. Keep the instruction to resolve factual questions before publishing.'}],
 capture:{now_ms:9000,gesture_window_closed:true}
},checks:{editParagraphs:['p2'],forbiddenInstructionLiterals:['Example Headphones','Example Headphones']}});
