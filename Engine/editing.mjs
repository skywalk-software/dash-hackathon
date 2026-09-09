import {readFileSync} from 'node:fs';
const prompt=readFileSync(new URL('./hack8/generate.txt',import.meta.url),'utf8');
export async function generate(capture,{callModel,outputDir}={}) {
 const {task,baseSnapshot,originalText,span}=capture;
 const input={instruction:task.instruction,operation:task.operation,document:baseSnapshot.paragraphs,references:task.references,
 ...(span?{paragraph:{before:originalText.slice(0,span.start),editable:originalText.slice(span.start,span.end),after:originalText.slice(span.end)}}:{})};
 const result=await callModel({instructions:prompt,input:JSON.stringify(input),outputDir});
 if(typeof result.text!=='string')throw new Error('Model did not return plain text');
 return result.text;
}
