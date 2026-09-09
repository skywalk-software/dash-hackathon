import assert from 'node:assert/strict';
import { Scheduler } from '../scheduler.mjs';

const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const tick = () => new Promise(resolve => setImmediate(resolve));
const edit = { operation: 'edit', working_area: { paragraph: 'p1', quote: 'Tuesday' } };

function makeStore() {
  return {
    revision: 0, text: 'Tuesday', commits: [], captures: [], prepares: [],
    capture(task) { const capture = { task, originalText: this.text }; this.captures.push(capture); return capture; },
    humanEdit(text) { this.text = text; this.revision++; },
    async prepareCandidate(capture, proposedText) {
      this.prepares.push({ current: this.text, capture });
      return { revision: this.revision, text: proposedText, question: capture.task.operation === 'question' };
    },
    commit(candidate) {
      if (candidate.revision !== this.revision) return { status: 'stale' };
      if (candidate.question) return { status: 'answered', answer: candidate.text };
      this.text = candidate.text; this.revision++; this.commits.push(candidate);
      return { status: 'committed' };
    },
  };
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test('same-paragraph agents generate concurrently; every response reconciles serially against latest state', async () => {
  const store = makeStore(); const generation = [deferred(), deferred()]; const merge = deferred();
  let generated = 0, active = 0, maxActive = 0;
  const normal = store.prepareCandidate.bind(store);
  store.prepareCandidate = async (...args) => {
    active++; maxActive = Math.max(maxActive, active);
    if (store.prepares.length === 0) await merge.promise;
    const result = await normal(...args); active--; return result;
  };
  const scheduler = new Scheduler({ store, generate: () => generation[generated++].promise });
  const a = scheduler.submit(edit), b = scheduler.submit(edit);
  await tick(); assert.equal(generated, 2);
  generation[0].resolve('Thursday'); await tick();
  generation[1].resolve('Friday'); await tick();
  assert.equal(a.state, 'reconciling'); assert.equal(b.state, 'queued_reconciliation');
  merge.resolve(); await scheduler.wait();
  assert.equal(maxActive, 1);
  assert.deepEqual(store.prepares.map(p => p.current), ['Tuesday', 'Thursday']);
  assert.equal(store.commits.length, 2);
});

test('human edits during reconciliation force a refresh before commit', async () => {
  const store = makeStore(), gate = deferred(); let attempts = 0;
  store.prepareCandidate = async () => {
    const candidate = { revision: store.revision, text: `Short ${store.text}` };
    if (++attempts === 1) await gate.promise;
    return candidate;
  };
  const scheduler = new Scheduler({ store, generate: async () => 'Short Tuesday' });
  const job = scheduler.submit(edit); await tick();
  store.humanEdit('Thursday'); gate.resolve(); await scheduler.wait();
  assert.equal(job.attempts, 2); assert.equal(store.text, 'Short Thursday');
  assert.equal(store.commits.length, 1);
  const starts = scheduler.events.filter(e => e.type === 'commit_started');
  assert.equal(starts.length, 2);
  for (const start of starts) assert.equal(scheduler.events[start.sequence].type, 'commit_finished');
});

test('cancellation during generation discards late output', async () => {
  const store = makeStore(), gate = deferred();
  const scheduler = new Scheduler({ store, generate: () => gate.promise });
  const job = scheduler.submit(edit); await tick(); scheduler.cancel(job.id);
  await scheduler.wait(); gate.resolve('Friday'); await tick();
  assert.equal(job.state, 'cancelled'); assert.equal(store.commits.length, 0);
  assert.equal(store.prepares.length, 0);
});

test('cancellation during reconciliation cannot commit', async () => {
  const store = makeStore(), gate = deferred();
  store.prepareCandidate = async () => { await gate.promise; return { revision: 0, text: 'Friday' }; };
  const scheduler = new Scheduler({ store, generate: async () => 'Friday' });
  const job = scheduler.submit(edit); await tick(); scheduler.cancel(job.id);
  gate.resolve(); await scheduler.wait(); await tick();
  assert.equal(store.commits.length, 0); assert.equal(job.state, 'cancelled');
});

test('bounded stale retry becomes visible conflict and releases next reconciliation', async () => {
  const store = makeStore();
  store.commit = candidate => candidate.text === 'bad' ? { status: 'stale' } : { status: 'noop' };
  let n = 0;
  const scheduler = new Scheduler({ store, generate: async () => ++n === 1 ? 'bad' : 'good', maxReconcileRetries: 2 });
  const a = scheduler.submit(edit), b = scheduler.submit(edit); await scheduler.wait();
  assert.equal(a.state, 'conflict'); assert.equal(a.attempts, 3); assert.equal(b.state, 'completed');
});

test('question after two edits captures latest text and still passes reconciliation without mutation', async () => {
  const store = makeStore(); let n = 0;
  const scheduler = new Scheduler({ store, generate: async capture =>
    capture.task.operation === 'question' ? capture.originalText : (++n === 1 ? 'Thursday' : 'Friday') });
  const a = scheduler.submit(edit), b = scheduler.submit(edit);
  const q = scheduler.submit({ operation: 'question' }, { after: [a.id, b.id] });
  await scheduler.wait(); assert.equal(q.state, 'answered'); assert.equal(q.result.answer, 'Friday');
  assert.equal(store.commits.length, 2); assert.equal(store.prepares.length, 3);
});

test('failed generation and cancelled prerequisite cannot leave the queue stuck', async () => {
  const store = makeStore(); let n = 0;
  const scheduler = new Scheduler({ store, generate: async () => { if (++n === 1) throw new Error('offline'); return 'good'; } });
  const a = scheduler.submit(edit);
  const q = scheduler.submit({ operation: 'question' }, { after: [a.id] });
  const b = scheduler.submit(edit); await scheduler.wait();
  assert.equal(a.state, 'failed'); assert.equal(q.state, 'failed'); assert.equal(b.state, 'completed');
  assert.throws(() => scheduler.submit(edit, { after: ['missing'] }));
});

test('capture and reconciliation exceptions are visible failures', async () => {
  const store = makeStore(); store.capture = () => { throw new Error('ambiguous target'); };
  const scheduler = new Scheduler({ store, generate: async () => 'text' });
  assert.equal(scheduler.submit(edit).state, 'failed'); await scheduler.wait();
  const other = makeStore(); other.prepareCandidate = async () => { throw new Error('offline'); };
  const second = new Scheduler({ store: other, generate: async () => 'text' });
  const job = second.submit(edit); await second.wait(); assert.equal(job.state, 'failed');
});

test('cancel queued jobs prevents starting them; concurrency bound holds', async () => {
  const store = makeStore(), gate = deferred(); let started = 0;
  const scheduler = new Scheduler({ store, generate: () => { started++; return gate.promise; }, maxConcurrent: 1 });
  const a = scheduler.submit(edit), b = scheduler.submit(edit); await tick();
  assert.equal(started, 1); scheduler.cancel(b.id); gate.resolve('done'); await scheduler.wait();
  assert.equal(started, 1); assert.equal(a.state, 'completed'); assert.equal(b.state, 'cancelled');
});

test('request replay returns same job before and after completion and never re-applies', async () => {
  const store = makeStore(), gate = deferred(); let generated = 0;
  const scheduler = new Scheduler({ store, generate: () => { generated++; return gate.promise; } });
  const a = scheduler.submit(edit, { requestId: 'input-1' });
  assert.equal(scheduler.submit({ ...edit }, { requestId: 'input-1' }), a);
  await tick(); assert.equal(generated, 1);
  gate.resolve('Thursday'); await scheduler.wait();
  assert.equal(scheduler.submit(edit, { requestId: 'input-1' }), a);
  assert.equal(store.commits.length, 1); assert.equal(scheduler.jobs.length, 1);
});

test('request identity rejects changed intent or dependencies and does not retry cancellation', async () => {
  const store = makeStore(), gate = deferred();
  const scheduler = new Scheduler({ store, generate: () => gate.promise });
  const prerequisite = scheduler.submit(edit);
  const a = scheduler.submit(edit, { requestId: 'input-1', after: [prerequisite.id] });
  assert.throws(() => scheduler.submit({ ...edit, instruction: 'Different' }, { requestId: 'input-1', after: [prerequisite.id] }));
  assert.throws(() => scheduler.submit(edit, { requestId: 'input-1' }));
  scheduler.cancel(a.id);
  assert.equal(scheduler.submit(edit, { requestId: 'input-1', after: [prerequisite.id] }), a);
  assert.equal(a.state, 'cancelled'); scheduler.cancel(prerequisite.id); await scheduler.wait();
  gate.resolve('ignored'); await tick();
  assert.equal(store.commits.length, 0);
});

for (const [name, fn] of tests) { await fn(); console.log(`PASS ${name}`); }
console.log(`${tests.length}/${tests.length} scheduler tests passed`);
