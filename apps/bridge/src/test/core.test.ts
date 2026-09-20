import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, mkdir, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { EventEmitter } from 'node:events';
import { Store, hash } from '../store.js';
import { Workspace } from '../workspace.js';
import { Controller } from '../controller.js';
import { BridgeError, validateSchema, codexMethods, approvalSchemas, type ObjectMap } from '@codex-bridge/protocol';

class FakeCodex extends EventEmitter {
  ready = true;
  calls: string[] = [];
  answers: any[] = [];
  requirements: unknown = null;
  gate?: Promise<unknown>;
  async request(method: string, _params: ObjectMap): Promise<any> {
    this.calls.push(method);
    if (method === 'configRequirements/read') return { requirements: this.requirements };
    if (method === 'thread/start') return { thread: { id: 'thread-1', turns: [], status: { type: 'idle' } } };
    if (method === 'thread/read') return { thread: { id: 'external', turns: [], status: { type: 'notLoaded' } } };
    if (method === 'thread/fork') return { thread: { id: 'fork-1' } };
    if (method === 'turn/start') { if (this.gate) await this.gate; return { turn: { id: 'turn-1' } }; }
    return {};
  }
  respond(id: string | number, result: unknown): void { this.answers.push({ id, result }); }
  reject(id: string | number, message: string): void { this.answers.push({ id, message }); }
}
async function setup() {
  const directory = await mkdtemp(join(tmpdir(), 'codex-bridge-test-'));
  const store = new Store(join(directory, 'state.sqlite'));
  const codex = new FakeCodex();
  const controller = new Controller(store, codex);
  const project = await controller.workspace.register(directory);
  return { directory, store, codex, controller, project };
}
test('pairing is single use, expires, and device revocation is immediate', () => {
  const store = new Store(':memory:');
  const pair = store.createPair();
  const device = store.pair(pair.code, 'test');
  assert.equal(store.authenticate(device.token), device.deviceId);
  assert.throws(() => store.pair(pair.code, 'replay'), /expired or already used/);
  assert.equal(store.authenticate('invalid'), undefined);
  const expired = store.createPair(); store.db.prepare('UPDATE pairs SET expires=0').run();
  assert.throws(() => store.pair(expired.code, 'expired'));
  store.revoke(device.deviceId); assert.equal(store.authenticate(device.token), undefined);
  const row = store.db.prepare('SELECT hash FROM devices').get() as any;
  assert.notEqual(row.hash, device.token); store.close();
});
test('request journal caches replies, rejects collisions, and marks crash outcomes unknown', async () => {
  const { store, directory } = await setup();
  assert.equal(store.beginRequest('device', 'id', 'digest'), undefined);
  assert.throws(() => store.beginRequest('device', 'id', 'other'), /different content/);
  assert.throws(() => store.beginRequest('device', 'id', 'digest'), /still processing/);
  store.finishRequest('device', 'id', { result: { value: 7 } });
  assert.deepEqual(store.beginRequest('device', 'id', 'digest'), { result: { value: 7 } });
  store.beginRequest('device', 'lost', 'digest'); store.close();
  const rebooted = new Store(join(directory, 'state.sqlite'));
  assert.throws(() => rebooted.beginRequest('device', 'lost', 'digest'), /may have executed/); rebooted.close();
});
test('events have monotonic cursors and survive restart with a new epoch', async () => {
  const { store, directory } = await setup();
  const first = store.append('one', { value: 1 }); const second = store.append('two', {});
  assert.ok(second.seq > first.seq); assert.equal(store.replay(first.seq).length, 1);
  store.close(); const rebooted = new Store(join(directory, 'state.sqlite'));
  assert.notEqual(rebooted.epoch, first.epoch); assert.equal(rebooted.replay(0).length, 2); rebooted.close();
});
test('file operations preserve content, reject conflicts and escape attempts', async () => {
  const { store, project, directory } = await setup(); const workspace = new Workspace(store);
  await writeFile(join(directory, 'source.txt'), 'before\r\n');
  const opened = await workspace.read(project.id, 'source.txt');
  await workspace.save(project.id, 'source.txt', 'after\r\n', opened.version);
  assert.equal(await readFile(join(directory, 'source.txt'), 'utf8'), 'after\r\n');
  await assert.rejects(() => workspace.save(project.id, 'source.txt', 'stale', opened.version), /changed/);
  await assert.rejects(() => workspace.list(project.id, '..'), /escapes/);
  const outside = await mkdtemp(join(tmpdir(), 'outside-'));
  await symlink(outside, join(directory, 'escape'), process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(() => workspace.list(project.id, 'escape'), /escapes/);
  store.close();
});
test('parallel saves of the same revision have only one winner', async () => {
  const { store, controller, project, directory } = await setup();
  await writeFile(join(directory, 'race.txt'), 'original');
  const version = hash('original');
  const results = await Promise.allSettled(['one', 'two'].map(content => controller.workspace.save(project.id, 'race.txt', content, version)));
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1); store.close();
});
test('unknown methods and extra configuration cannot reach Codex', async () => {
  const { store, controller, codex, project } = await setup();
  await assert.rejects(() => controller.dispatch('config/value/write', {}), /not exposed/);
  await assert.rejects(() => controller.dispatch('thread/start', { projectId: project.id, config: {} }), /not accepted/);
  assert.equal(codex.calls.length, 0); store.close();
});
test('full access default is blocked rather than silently downgraded by host policy', async () => {
  const { store, controller, codex, project } = await setup();
  codex.requirements = { allowedSandboxModes: ['read-only'], allowedApprovalPolicies: ['on-request'] };
  await assert.rejects(() => controller.dispatch('thread/start', { projectId: project.id }), /prohibits/);
  const allowed = await controller.dispatch('thread/start', { projectId: project.id, permissionMode: 'read-only' });
  assert.equal(allowed.thread.id, 'thread-1'); store.close();
});
test('external history needs explicit stopped confirmation or a fork', async () => {
  const { store, controller, project } = await setup();
  await assert.rejects(() => controller.dispatch('thread/resume', { projectId: project.id, threadId: 'external' }), /Confirm/);
  const fork = await controller.dispatch('thread/fork', { projectId: project.id, threadId: 'external' });
  assert.equal(fork.thread.id, 'fork-1'); store.close();
});
test('same thread cannot start concurrent turns; replayed request never resubmits', async () => {
  const { store, controller, codex, project } = await setup();
  await controller.dispatch('thread/start', { projectId: project.id });
  let release!: () => void; codex.gate = new Promise<void>(resolve => { release = resolve; });
  const request = { type: 'request' as const, requestId: 'unique', method: 'turn/start', params: { threadId: 'thread-1', input: [{ type: 'text', text: 'test' }] } };
  const first = controller.request('device', request);
  await new Promise(resolve => setTimeout(resolve, 10));
  const busy = await controller.request('device', { ...request, requestId: 'other' });
  assert.equal(busy.error.code, 'THREAD_BUSY'); release();
  const response = await first; assert.equal(response.result.turn.id, 'turn-1');
  assert.deepEqual(await controller.request('device', request), response);
  assert.equal(codex.calls.filter(method => method === 'turn/start').length, 1); store.close();
});
test('new threads use legacy history and empty loaded threads remain usable', async () => {
  const { store, controller, codex, project } = await setup();
  const original = codex.request.bind(codex);
  codex.request = async (method, params) => {
    if (method === 'thread/start') assert.equal(params.historyMode, 'legacy');
    if (method === 'thread/read' && params.includeTurns) throw new BridgeError('CODEX_ERROR', `thread ${params.threadId} is not materialized yet; includeTurns is unavailable before first user message`);
    return original(method, params);
  };
  await controller.dispatch('thread/start', { projectId: project.id });
  const resumed = await controller.dispatch('thread/resume', { projectId: project.id, threadId: 'thread-1' });
  assert.deepEqual(resumed.thread.turns, []);
  await controller.dispatch('thread/read', { threadId: 'thread-1', includeTurns: true });
  await assert.rejects(() => controller.dispatch('thread/read', { threadId: 'external', includeTurns: true }), /not materialized/);
  codex.request = async () => { throw new BridgeError('CODEX_ERROR', 'unrelated failure'); };
  await assert.rejects(() => controller.dispatch('thread/read', { threadId: 'thread-1', includeTurns: true }), /unrelated failure/);
  store.close();
});
test('pending approvals survive mobile disconnect, resolve once, and unknown requests are rejected', async () => {
  const { store, controller, codex } = await setup();
  codex.emit('serverRequest', { id: 7, method: 'item/commandExecution/requestApproval', params: { threadId: 'task', turnId: 'turn' } });
  assert.equal(store.pending().length, 1);
  const id = store.pending()[0]!.id;
  await controller.dispatch('approval/respond', { id, result: { decision: 'decline' } });
  assert.equal(store.pending().length, 0);
  await assert.rejects(() => controller.dispatch('approval/respond', { id, result: { decision: 'accept' } }), /no longer pending/);
  codex.emit('serverRequest', { id: 8, method: 'unknown/sensitive', params: {} });
  assert.equal(codex.answers.length, 2); assert.ok(codex.answers[1].message); store.close();
});
test('upstream disconnect marks running work unknown and terminals lost', async () => {
  const { store, codex, project } = await setup();
  store.ownThread('task', project.id); store.threadState('task', 'running', 'turn');
  store.db.prepare("INSERT INTO terminals VALUES ('terminal',?,?,'running','')").run(project.id, store.epoch);
  codex.emit('disconnected'); assert.equal(store.thread('task')!.state, 'unknown');
  assert.equal((store.runtime().terminals as any[])[0].state, 'lost'); store.close();
});
test('all published methods and approval schemas are present in pinned protocol', () => {
  for (const schema of [...Object.values(codexMethods), ...Object.values(approvalSchemas)]) {
    try { validateSchema(schema, {}); } catch (error: any) { assert.equal(error.code, 'INVALID_PARAMS', schema); }
  }
  validateSchema('CommandExecParams', { command: ['echo', 'test'], tty: true, streamStdin: true, streamStdoutStderr: true });
  assert.throws(() => validateSchema('TurnStartParams', { threadId: 'id' }));
});
