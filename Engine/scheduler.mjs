import { performance } from 'node:perf_hooks';
import path from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { serialize, deserialize } from 'node:v8';

const TERMINAL = new Set(['completed', 'answered', 'failed', 'cancelled', 'conflict']);

/** Concurrent generation, serialized reconciliation, synchronous commits only. */
export class Scheduler {
  constructor({ store, generate, callModel, outputDir, maxConcurrent = 4, maxReconcileRetries = 3 }) {
    if (!Number.isInteger(maxConcurrent) || maxConcurrent < 1) throw new Error('maxConcurrent must be positive');
    if (!Number.isInteger(maxReconcileRetries) || maxReconcileRetries < 0) throw new Error('maxReconcileRetries must be nonnegative');
    this.store = store;
    this.generate = generate;
    this.callModel = callModel;
    this.outputDir = outputDir;
    this.maxConcurrent = maxConcurrent;
    this.maxReconcileRetries = maxReconcileRetries;
    this.jobs = [];
    this.events = [];
    this.activeGenerators = 0;
    this.reconciliationQueue = [];
    this.reconciling = false;
    this.waiters = [];
    this.requests = new Map();
  }

  event(job, type, detail = {}) {
    this.events.push({ sequence: this.events.length + 1, atMs: performance.now(), jobId: job.id, type, ...detail });
  }

  state(job, state, detail = {}) {
    job.state = state;
    this.event(job, state, detail);
    this.notify();
  }

  submit(task, { after = [], requestId } = {}) {
    if (requestId !== undefined && (typeof requestId !== 'string' || requestId.length === 0)) {
      throw new Error('requestId must be a nonempty string');
    }
    if (!Array.isArray(after) || after.some(id => !this.jobs.some(job => job.id === id))) {
      throw new Error('Dependencies must identify previously submitted jobs');
    }
    const dependencies = [...new Set(after)].sort();
    const previous = requestId === undefined ? undefined : this.requests.get(requestId);
    if (previous) {
      if (!isDeepStrictEqual(previous.task, task) || !isDeepStrictEqual(previous.after, dependencies)) {
        throw new Error('requestId was already used with different task or dependencies');
      }
      this.event(previous.job, 'duplicate_submission_ignored');
      return previous.job;
    }
    const job = { id: `job-${this.jobs.length + 1}`, requestId, task, after: dependencies, state: 'queued', attempts: 0 };
    this.jobs.push(job);
    if (requestId !== undefined) this.requests.set(requestId, {
      task: deserialize(serialize(task)), after: [...dependencies], job,
    });
    this.event(job, 'queued');
    try {
      // Explicit follow-up commands read the document after dependencies commit.
      // Independent jobs capture immediately and never acquire paragraph locks.
      if (!job.after.length) job.capture = this.store.capture(task);
    } catch (error) {
      job.error = String(error.message ?? error);
      this.state(job, 'failed', { message: 'Could not identify the requested text.' });
      return job;
    }
    queueMicrotask(() => this.pumpGeneration());
    return job;
  }

  cancel(id) {
    const job = this.jobs.find(item => item.id === id);
    if (!job || TERMINAL.has(job.state)) return false;
    this.state(job, 'cancelled', { message: 'Cancelled.' });
    this.pumpGeneration();
    return true;
  }

  modelOptions(job, phase) {
    return {
      callModel: this.callModel,
      outputDir: this.outputDir ? path.join(this.outputDir, job.id, phase) : undefined,
    };
  }

  pumpGeneration() {
    for (const job of this.jobs.filter(item => item.state === 'queued')) {
      if (job.after.some(id => ['failed', 'cancelled', 'conflict'].includes(this.jobs.find(item => item.id === id).state))) {
        job.error = 'An explicit prerequisite did not complete successfully';
        this.state(job, 'failed', { message: 'A preceding request did not finish. Please retry.' });
      }
    }
    while (this.activeGenerators < this.maxConcurrent) {
      const job = this.jobs.find(item => item.state === 'queued' && item.after.every(id =>
        ['completed', 'answered'].includes(this.jobs.find(previous => previous.id === id).state)));
      if (!job) break;
      try {
        if (!job.capture) job.capture = this.store.capture(job.task);
      } catch (error) {
        job.error = String(error.message ?? error);
        this.state(job, 'failed', { message: 'Could not identify the requested text.' });
        continue;
      }
      this.activeGenerators++;
      this.state(job, 'generating', { message: 'Preparing an edit or answer.' });
      void this.runGeneration(job);
    }
    this.notify();
  }

  async runGeneration(job) {
    try {
      const proposedText = await this.generate(job.capture, this.modelOptions(job, 'generation'));
      if (job.state === 'cancelled') {
        this.event(job, 'late_result_discarded', { phase: 'generation' });
        return;
      }
      if (typeof proposedText !== 'string') throw new Error('Generation must return plain text');
      job.proposedText = proposedText;
      this.state(job, 'queued_reconciliation', { message: 'Waiting to merge.' });
      this.reconciliationQueue.push(job);
      void this.pumpReconciliation();
    } catch (error) {
      if (job.state !== 'cancelled') {
        job.error = String(error.message ?? error);
        this.state(job, 'failed', { message: 'Could not prepare the requested change.' });
      }
    } finally {
      this.activeGenerators--;
      this.pumpGeneration();
    }
  }

  async pumpReconciliation() {
    if (this.reconciling) return;
    this.reconciling = true;
    try {
      while (this.reconciliationQueue.length) {
        const job = this.reconciliationQueue.shift();
        if (job.state === 'cancelled') continue;
        await this.reconcile(job);
        this.pumpGeneration();
      }
    } finally {
      this.reconciling = false;
      this.notify();
    }
  }

  async reconcile(job) {
    try {
      for (let attempt = 1; attempt <= this.maxReconcileRetries + 1; attempt++) {
        if (job.state === 'cancelled') return;
        job.attempts = attempt;
        this.state(job, 'reconciling', { attempt, message: 'Merging with your latest changes.' });
        const candidate = await this.store.prepareCandidate(
          job.capture, job.proposedText, this.modelOptions(job, `reconciliation-${attempt}`),
        );
        if (job.state === 'cancelled') {
          this.event(job, 'late_result_discarded', { phase: 'reconciliation' });
          return;
        }

        // No await between checking cancellation, validating preconditions and
        // committing. On a single editor thread this is the entire mutation freeze.
        const start = performance.now();
        this.event(job, 'commit_started');
        let result;
        try {
          result = this.store.commit(candidate, {taskID: job.id, instruction: job.task.instruction});
        } finally {
          this.event(job, 'commit_finished', { durationMs: performance.now() - start });
        }
        if (result && typeof result.then === 'function') throw new Error('Store commit must be synchronous');
        job.result = result;
        if (result?.status === 'stale') {
          if (attempt > this.maxReconcileRetries) {
            this.state(job, 'conflict', { message: 'The document kept changing. Please retry this request.' });
            return;
          }
          this.state(job, 'retry', { message: 'The document changed; refreshing the merge.' });
          continue;
        }
        if (result?.status === 'conflict') {
          this.state(job, 'conflict', { message: 'This change needs clarification before it can be applied.' });
        } else if (result?.status === 'answered') {
          this.state(job, 'answered', { message: 'Answer ready.' });
        } else if (['committed', 'noop'].includes(result?.status)) {
          this.state(job, 'completed', { message: result.status === 'noop' ? 'No change needed.' : 'Change applied.' });
        } else {
          throw new Error(`Unexpected commit status: ${result?.status}`);
        }
        return;
      }
    } catch (error) {
      if (job.state !== 'cancelled') {
        job.error = String(error.message ?? error);
        this.state(job, 'failed', { message: 'Could not merge the requested change.' });
      }
    }
  }

  notify() {
    if (this.jobs.every(job => TERMINAL.has(job.state))) {
      for (const resolve of this.waiters.splice(0)) resolve(this.jobs);
    }
  }

  wait() {
    if (this.jobs.every(job => TERMINAL.has(job.state))) return Promise.resolve(this.jobs);
    return new Promise(resolve => this.waiters.push(resolve));
  }
}
