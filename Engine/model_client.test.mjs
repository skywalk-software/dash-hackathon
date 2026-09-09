import test from 'node:test';
import assert from 'node:assert/strict';
import {callModel} from './model_client.mjs';

function setup(t, response) {
  const names = ['OPENAI_API_KEY', 'OPENAI_BASE_URL', 'DASH_REASONING_EFFORT'];
  const saved = Object.fromEntries(names.map(name => [name, process.env[name]]));
  process.env.OPENAI_API_KEY = 'test-only-not-a-real-key';
  delete process.env.OPENAI_BASE_URL;
  delete process.env.DASH_REASONING_EFFORT;
  t.after(() => { for (const name of names) { if (saved[name] === undefined) delete process.env[name]; else process.env[name] = saved[name]; } });
  const calls = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    calls.push({url: String(url), ...options, body: JSON.parse(options.body)});
    return {ok: true, json: async () => response};
  });
  return calls;
}
const completed = text => ({status: 'completed', output: [
  {type: 'reasoning', summary: []},
  {type: 'message', content: [{type: 'output_text', text}]}
]});

test('all editing phases use Astra Responses and preserve returned text', async t => {
  const calls = setup(t, completed(' Revised text. '));
  for (const phase of ['interpretation', 'generation', 'reconciliation']) {
    const result = await callModel({instructions: 'Only edit the selection.', input: {text: 'Original'}, phase});
    assert.equal(result.text, ' Revised text. ');
  }
  for (const call of calls) {
    assert.equal(call.url, 'https://api.openai.com/v1/responses');
    assert.equal(call.body.model, 'gpt-6-astra');
    assert.equal(call.body.store, false);
    assert.deepEqual(call.body.reasoning, {effort: 'low'});
    assert.equal(call.body.input, '{"text":"Original"}');
    for (const unsupported of ['temperature', 'messages', 'chat_template_kwargs', 'max_tokens']) assert.equal(unsupported in call.body, false);
  }
});

test('structured output contract survives the API migration', async t => {
  const calls = setup(t, completed('{"status":"ready"}'));
  const schema = {type: 'object', properties: {status: {type: 'string'}}, required: ['status'], additionalProperties: false};
  const result = await callModel({instructions: 'Reconcile.', input: 'text', schema});
  assert.deepEqual(result.json, {status: 'ready'});
  assert.deepEqual(calls[0].body.text.format, {type: 'json_schema', name: 'editor_result', strict: true, schema});
});

test('incomplete model output cannot become an edit', async t => {
  setup(t, {status: 'incomplete', output: []});
  await assert.rejects(callModel({instructions: 'Edit.', input: 'text'}), /incomplete/);
});

test('missing key fails locally without a network call', async t => {
  const calls = setup(t, completed('text'));
  delete process.env.OPENAI_API_KEY;
  await assert.rejects(callModel({instructions: 'Edit.', input: 'text'}), /OPENAI_API_KEY/);
  assert.equal(calls.length, 0);
});
