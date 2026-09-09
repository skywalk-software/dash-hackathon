import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import readline from 'node:readline';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import os from 'node:os';
import path from 'node:path';

test('interpretation errors are attributed to their recording and reset clears old results', async () => {
  const env = {...process.env, DASH_LLM_BASE_URL: 'http://127.0.0.1:1/v1'};
  delete env.DASH_LLM_API_KEY;
  delete env.EDITOR_EVIDENCE_DIR;
  const child = spawn(process.execPath, [fileURLToPath(new URL('./worker.mjs', import.meta.url))], {env, stdio: ['pipe', 'pipe', 'pipe']});
  const reader = readline.createInterface({input: child.stdout});
  const lines = reader[Symbol.asyncIterator]();
  async function send(message) {
    child.stdin.write(JSON.stringify({documentID: 'document-test', ...message}) + '\n');
    const next = await lines.next();
    assert.equal(next.done, false);
    return JSON.parse(next.value);
  }
  try {
    await send({op: 'init', text: 'The opening.'});
    await send({op: 'begin', recordingID: 'recording-test'});
    await send({op: 'observe', ranges: [{location: 0, length: 12}], at_ms: 10, source: 'test', actionID: 'gesture-test'});
    await send({op: 'end'});
    await send({op: 'process', recordingID: 'recording-test', transcript: 'Rewrite this.', duration_ms: 100});
    let state;
    for (let n = 0; n < 100; n++) {
      state = await send({op: 'poll'});
      if (state.interpretations[0]?.status === 'failed') break;
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    assert.equal(state.interpretations[0].recordingID, 'recording-test');
    assert.equal(state.interpretations[0].status, 'failed');
    assert.match(state.interpretations[0].error, /fetch failed/);
    await send({op: 'init', text: 'Fresh document.'});
    state = await send({op: 'poll'});
    assert.deepEqual(state.interpretations, []);
    assert.deepEqual(state.jobs, []);
    assert.equal(state.error, null);
  } finally {
    reader.close();
    child.kill();
  }
});
