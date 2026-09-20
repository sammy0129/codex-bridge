import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BridgeError, type ObjectMap } from '@codex-bridge/protocol';
import { Controller } from '../controller.js';
import { Store } from '../store.js';

class ManagementPeer extends EventEmitter {
  ready = true;
  calls: { method: string; params: ObjectMap }[] = [];
  handler?: (method: string, params: ObjectMap) => Promise<ObjectMap>;
  async request(method: string, params: ObjectMap): Promise<ObjectMap> {
    this.calls.push({ method, params });
    if (this.handler) return this.handler(method, params);
    if (method === 'configRequirements/read') return { requirements: null };
    if (method === 'thread/read' || method === 'thread/resume') return { thread: { id: params.threadId, status: { type: 'idle' }, turns: [] } };
    return {};
  }
  respond(): void {}
  reject(): void {}
}

function setup() {
  const store = new Store(':memory:');
  const project = store.addProject('fixture', tmpdir());
  store.ownThread('task', project.id);
  const peer = new ManagementPeer();
  const controller = new Controller(store, peer);
  return { store, project, peer, controller, params: { projectId: project.id, threadId: 'task' } };
}

for (const method of ['thread/archive', 'thread/unarchive', 'thread/delete']) {
  test(method + ' validates ownership, state, requests and project before forwarding', async () => {
    const { store, project, peer, controller, params } = setup();
    try {
      await assert.rejects(() => controller.dispatch(method, { ...params, threadId: 'external' }), { code: 'EXTERNAL_THREAD' });
      const other = store.addProject('other', join(tmpdir(), 'other-project'));
      await assert.rejects(() => controller.dispatch(method, { ...params, projectId: other.id }), { code: 'PROJECT_MISMATCH' });
      for (const state of ['running', 'starting', 'unknown']) {
        store.threadState('task', state);
        await assert.rejects(() => controller.dispatch(method, params), { code: state === 'unknown' ? 'OUTCOME_UNKNOWN' : 'THREAD_BUSY' });
      }
      store.threadState('task', 'idle');
      store.saveApproval('approval', { params: { threadId: 'task' } });
      await assert.rejects(() => controller.dispatch(method, params), { code: 'THREAD_PENDING_APPROVAL' });
      store.resolveApproval('approval');
      await assert.rejects(() => controller.dispatch(method, { ...params, threadId: 42 }), { code: 'INVALID_PARAMS' });
      await assert.rejects(() => controller.dispatch(method, { ...params, extra: true }), { code: 'INVALID_PARAMS' });
      assert.equal(peer.calls.length, 0);
      await controller.dispatch(method, params);
      assert.deepEqual(peer.calls, [{ method, params: { threadId: 'task' } }]);
      if (method === 'thread/delete') assert.equal(store.thread('task'), undefined);
      else assert.equal(store.thread('task')?.project, project.id);
    } finally { store.close(); }
  });

  test(method + ' shares the turn-start and resume lock', async () => {
    const { store, peer, controller, params } = setup();
    try {
      let release!: () => void;
      const gate = new Promise<void>(resolve => { release = resolve; });
      peer.handler = async () => { await gate; return {}; };
      const pending = controller.dispatch(method, params);
      for (const blocked of ['thread/delete', 'thread/archive', 'thread/unarchive', 'thread/resume', 'turn/start']) {
        await assert.rejects(() => controller.dispatch(blocked, { ...params, ...(blocked === 'turn/start' ? { input: [{ type: 'text', text: 'test' }] } : {}) }), { code: 'THREAD_BUSY' });
      }
      assert.equal(peer.calls.length, 1);
      release();
      await pending;
    } finally { store.close(); }
  });
}

test('delete requires projectId and advertises its capability', async () => {
  const { store, controller, peer } = setup();
  try {
    assert.ok(controller.info().capabilities.includes('threadDelete'));
    await assert.rejects(() => controller.dispatch('thread/delete', { threadId: 'task' }), { code: 'INVALID_PARAMS' });
    assert.equal(peer.calls.length, 0);
  } finally { store.close(); }
});

test('successful delete is journaled once and clears runtime without erasing audit records', async () => {
  const { store, controller, peer, params } = setup();
  try {
    store.append('item/completed', { threadId: 'task', item: { id: 'history' } });
    const request = { type: 'request' as const, requestId: 'delete-once', method: 'thread/delete', params };
    const first = await controller.request('device', request);
    assert.deepEqual(first.result, {});
    assert.deepEqual(await controller.request('device', request), first);
    assert.equal(peer.calls.filter(call => call.method === 'thread/delete').length, 1);
    assert.equal(store.runtime().threads.length, 0);
    assert.deepEqual(store.replay(0).map(event => event.method), ['item/completed', 'thread/deleted']);
    const collision = await controller.request('device', { ...request, params: { ...params, threadId: 'other' } });
    assert.equal(collision.error.code, 'REQUEST_CONFLICT');
  } finally { store.close(); }
});

test('delete notifications clean state idempotently and suppress late task activity', async () => {
  const { store, controller, peer, params } = setup();
  try {
    await controller.dispatch('thread/resume', params);
    peer.emit('serverRequest', { id: 1, method: 'item/commandExecution/requestApproval', params: { threadId: 'task' } });
    for (let repeat = 0; repeat < 2; repeat++) peer.emit('notification', { method: 'thread/deleted', params: { threadId: 'task' } });
    peer.emit('notification', { method: 'turn/started', params: { threadId: 'task', turn: { id: 'late' } } });
    peer.emit('serverRequest', { id: 2, method: 'item/commandExecution/requestApproval', params: { threadId: 'task' } });
    assert.equal(store.thread('task'), undefined);
    assert.equal(store.pending().length, 0);
    await assert.rejects(() => controller.dispatch('thread/resume', params), { code: 'THREAD_DELETED' });
    await assert.rejects(() => controller.dispatch('approval/respond', { id: store.epoch + ':1', result: { decision: 'decline' } }), { code: 'APPROVAL_EXPIRED' });
  } finally { store.close(); }
});

test('upstream deletion notification before reply does not produce duplicate success events', async () => {
  const { store, controller, peer, params } = setup();
  try {
    peer.handler = async () => {
      peer.emit('notification', { method: 'thread/deleted', params: { threadId: 'task' } });
      return {};
    };
    await controller.dispatch('thread/delete', params);
    assert.equal(store.replay(0).filter(event => event.method === 'thread/deleted').length, 1);
  } finally { store.close(); }
});

for (const code of ['CODEX_ERROR', 'OUTCOME_UNKNOWN', 'UPSTREAM_LOST']) {
  test('delete preserves records on ' + code + ' and never replays uncertain writes', async () => {
    const { store, controller, peer, params } = setup();
    try {
      peer.handler = async () => { throw new BridgeError(code, 'fixture'); };
      const request = { type: 'request' as const, requestId: 'failure', method: 'thread/delete', params };
      assert.equal((await controller.request('device', request)).error.code, code);
      assert.equal(store.thread('task')?.state, code === 'CODEX_ERROR' ? 'idle' : 'unknown');
      assert.equal((await controller.request('device', request)).error.code, code === 'CODEX_ERROR' ? code : 'OUTCOME_UNKNOWN');
      assert.equal(peer.calls.length, 1);
      assert.equal(store.replay(0).length, 0);
    } finally { store.close(); }
  });
}

test('an in-flight resume blocks deletion and archive unloads the task', async () => {
  const { store, controller, peer, params } = setup();
  try {
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    peer.handler = async method => {
      if (method === 'configRequirements/read') { await gate; return { requirements: null }; }
      return { thread: { id: 'task', status: { type: 'idle' } } };
    };
    const opening = controller.dispatch('thread/resume', params);
    await assert.rejects(() => controller.dispatch('thread/delete', params), { code: 'THREAD_BUSY' });
    release();
    await opening;
    peer.handler = undefined;
    await controller.dispatch('thread/archive', params);
    await assert.rejects(() => controller.dispatch('turn/start', { ...params, input: [{ type: 'text', text: 'test' }] }), { code: 'THREAD_NOT_RESUMED' });
  } finally { store.close(); }
});
