import {writeFile, mkdir} from 'node:fs/promises';
import path from 'node:path';

/** OpenAI-compatible chat API, defaulting to a local vLLM Qwen3 server. */
export async function callModel({instructions, input, schema, outputDir, phase}) {
  const base = (process.env.DASH_LLM_BASE_URL || 'http://127.0.0.1:8000/v1').replace(/\/$/, '');
  const url = new URL(base + '/chat/completions');
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname))) {
    throw Error('Use HTTPS for a remote model service, or an SSH forward to localhost.');
  }
  const model = (phase === 'reconciliation' && process.env.DASH_RECONCILIATION_MODEL) || process.env.DASH_LLM_MODEL || 'Qwen/Qwen3-8B';
  const body = {model, messages: [
    {role: 'system', content: instructions},
    {role: 'user', content: typeof input === 'string' ? input : JSON.stringify(input)}
  ], temperature: 0.2, max_tokens: 4096, chat_template_kwargs: {enable_thinking: false}};
  if (schema) body.response_format = {type: 'json_schema', json_schema: {name: 'editor_result', strict: true, schema}};
  if (outputDir) {
    await mkdir(outputDir, {recursive: true, mode: 0o700});
    await writeFile(path.join(outputDir, 'request.json'), JSON.stringify(body, null, 2), {mode: 0o600});
  }
  const headers = {'Content-Type': 'application/json'};
  if (process.env.DASH_LLM_API_KEY) headers.Authorization = 'Bearer ' + process.env.DASH_LLM_API_KEY;
  const start = performance.now();
  const response = await fetch(url, {method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(180000)});
  if (!response.ok) throw Error(`Qwen model request failed (HTTP ${response.status}). Check the configured vLLM server.`);
  const result = await response.json();
  const choice = result.choices?.[0];
  if (choice?.finish_reason !== 'stop') throw Error('Model response incomplete; try a smaller selection.');
  const text = choice.message?.content?.trim();
  if (!text) throw Error('Model returned no text.');
  if (outputDir) await writeFile(path.join(outputDir, 'response.json'), JSON.stringify(result, null, 2), {mode: 0o600});
  return {text, ...(schema ? {json: JSON.parse(text)} : {}), elapsedMs: performance.now() - start};
}
