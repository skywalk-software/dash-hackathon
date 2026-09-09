import test from 'node:test';
import assert from 'node:assert/strict';
import {presentJob} from './presentation.mjs';

test('presentation preserves exact resolved references, selection identity, scope, and outcome', () => {
  const task = {operation: 'edit', instruction: 'Rewrite reference_1', context: ['read-only-document'],
    references: [{name: 'reference_1', paragraph: 'document', quote: 'Actual selected passage', selection_id: 'selection-7'}],
    working_area: {paragraph: 'document', quote: 'Actual selected passage', selection_id: 'selection-7'}};
  const row = presentJob({id: 'job-2', requestId: 'recording-1:1', state: 'completed', task, result: {status: 'noop'}});
  assert.equal(row.id, 'job-2');
  assert.equal(row.recordingID, 'recording-1');
  assert.equal(row.outcome, 'noop');
  assert.deepEqual(row.references, task.references);
  assert.deepEqual(row.working_area, task.working_area);
  assert.equal(row.operation, 'edit');
  assert.notEqual(row.references[0].quote, row.context[0]);
});

test('question answer and failure remain associated with their stable task', () => {
  const task = {operation: 'question', instruction: 'Why?', context: [], references: [], working_area: null};
  assert.equal(presentJob({id: 'job-1', requestId: 'r:0', state: 'answered', task, result: {status: 'answered', answer: 'Because'}}).answer, 'Because');
  assert.equal(presentJob({id: 'job-1', requestId: 'r:0', state: 'failed', task, error: 'Network failed'}).error, 'Network failed');
});
