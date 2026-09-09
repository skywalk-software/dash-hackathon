import {writeFile, mkdir} from 'node:fs/promises';
import path from 'node:path';

/** GPT-6 Astra powers interpretation, generation, and reconciliation. */
export async function callModel({instructions, input, schema, outputDir, phase}) {
  const key = process.env.OPENAI_API_KEY;
  if (!key?.trim()) throw Error('Set OPENAI_API_KEY in .env.local and relaunch Dash.');
  const base = (process.env.OPENAI_BASE_URL || 'https://api.openai.com/v1').replace(/\/$/, '');
  const url = new URL(base + '/responses');
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname))) {
    throw Error('Use HTTPS for the Astra API, or loopback HTTP for local tests.');
  }
  const effort = process.env.DASH_REASONING_EFFORT || 'low';
  if (!['low', 'medium', 'high', 'xhigh', 'max'].includes(effort)) throw Error('Unsupported Astra reasoning effort.');
  const body = {
    model: 'gpt-6-astra', instructions,
    input: typeof input === 'string' ? input : JSON.stringify(input),
    reasoning: {effort}, store: false, max_output_tokens: 7000
  };
  if (schema) body.text = {format: {type: 'json_schema', name: 'editor_result', strict: true, schema}};
  if (outputDir) {
    await mkdir(outputDir, {recursive: true, mode: 0o700});
    await writeFile(path.join(outputDir, 'request.json'), JSON.stringify(body, null, 2), {mode: 0o600});
  }
  const start = performance.now();
  const response = await fetch(url, {
    method: 'POST', headers: {'Content-Type': 'application/json', Authorization: 'Bearer ' + key},
    body: JSON.stringify(body), signal: AbortSignal.timeout(180000)
  });
  if (!response.ok) throw Error(`Astra request failed (HTTP ${response.status}). Check your API key, model access, and credits.`);
  const result = await response.json();
  if (result.status !== 'completed') throw Error('Astra response incomplete; try a smaller selection.');
  const content = (result.output || []).flatMap(item => item.content || []);
  if (content.some(item => item.type === 'refusal')) throw Error('Astra declined this editing request.');
  const text = content.filter(item => item.type === 'output_text').map(item => item.text).join('');
  if (!text.trim()) throw Error('Astra returned no text.');
  if (outputDir) await writeFile(path.join(outputDir, 'response.json'), JSON.stringify(result, null, 2), {mode: 0o600});
  return {text, ...(schema ? {json: JSON.parse(text)} : {}), elapsedMs: performance.now() - start};
}
