import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { request as httpsRequest } from 'node:https';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { EventEmitter, once } from 'node:events';
import { X509Certificate } from 'node:crypto';
import { WebSocket } from 'ws';
import { initialize } from '../config.js';
import { Store } from '../store.js';
import { Controller } from '../controller.js';
import { createServer } from '../server.js';
import type { ObjectMap } from '@codex-bridge/protocol';

class NetworkPeer extends EventEmitter {
  ready = true;
  thread: ObjectMap = {};
  async request(): Promise<unknown> { return { thread: this.thread }; }
  respond(): void {}
  reject(): void {}
}
let store: Store;
let controller: Controller;
let app: Awaited<ReturnType<typeof createServer>>;
let certificate: Buffer;
let address: string;
const sockets = new Set<WebSocket>();
before(async () => {
  process.env.BRIDGE_DATA_DIR = await mkdtemp(join(tmpdir(), 'bridge-tls-'));
  const config = await initialize('https://127.0.0.1:8787');
  delete process.env.BRIDGE_DATA_DIR;
  certificate = await readFile(config.certPath);
  store = new Store(':memory:'); controller = new Controller(store, new NetworkPeer());
  app = await createServer(controller, config); address = await app.listen({ host: '127.0.0.1', port: 0 });
});
after(async () => { for (const socket of sockets) socket.terminate(); await app.close(); store.close(); });
function http(path: string, secret?: string, body?: ObjectMap, pin?: string): Promise<{ status: number; data: ObjectMap }> {
  return new Promise((resolve, reject) => {
    const request = httpsRequest(`${address}${path}`, { agent: false, ca: certificate, method: body ? 'POST' : 'GET', headers: { ...(secret ? { authorization: `Bearer ${secret}` } : {}), ...(body ? { 'content-type': 'application/json' } : {}) }, ...(pin ? { checkServerIdentity: (_hostname, cert) => new X509Certificate(cert.raw).fingerprint256 === pin ? undefined : new Error('PIN_MISMATCH') } : {}) }, response => {
      const chunks: Buffer[] = []; response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode!, data: JSON.parse(Buffer.concat(chunks).toString()) }));
    });
    request.on('error', reject); if (body) request.write(JSON.stringify(body)); request.end();
  });
}
async function connect(secret: string, afterSeq = 0, epoch?: string) {
  const socket = new WebSocket(`${address.replace('https:', 'wss:')}/v1/ws`, { ca: certificate, headers: { authorization: `Bearer ${secret}` } });
  sockets.add(socket);
  const messages: ObjectMap[] = [];
  socket.on('message', raw => messages.push(JSON.parse(raw.toString())));
  await once(socket, 'open');
  socket.send(JSON.stringify({ type: 'hello', protocolVersion: 1, afterSeq, epoch }));
  const wait = async (predicate: (value: ObjectMap) => boolean): Promise<ObjectMap> => {
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      const message = messages.find(predicate); if (message) return message;
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    throw new Error('WebSocket message timed out');
  };
  await wait(value => value.type === 'synced'); return { socket, messages, wait };
}
test('HTTPS pairing requires explicit consent, consumes code, and protects all other endpoints', async () => {
  assert.equal((await http('/v1/info')).status, 401);
  assert.equal((await http('/v1/health', 'bad')).status, 401);
  const pair = store.createPair();
  assert.equal((await http('/v1/pair', undefined, { code: pair.code, deviceName: 'Android' })).data.error.code, 'CONSENT_REQUIRED');
  const response = await http('/v1/pair', undefined, { code: pair.code, deviceName: 'Android', acceptFullAccess: true });
  assert.equal(response.status, 200);
  assert.equal((await http('/v1/info', response.data.token)).data.protocolVersion, 1);
  assert.equal((await http('/v1/pair', undefined, { code: pair.code, deviceName: 'Android', acceptFullAccess: true })).data.error.code, 'PAIR_INVALID');
});
test('TLS rejects incorrect certificate identity before application traffic', async () => {
  await assert.rejects(() => http('/v1/info', undefined, undefined, '00:00'), /PIN_MISMATCH/);
  await new Promise<void>((resolve, reject) => {
    const request = httpsRequest(`${address}/v1/info`, response => { response.resume(); reject(new Error('Untrusted certificate was accepted')); });
    request.on('error', () => resolve()); request.end();
  });
});
test('image uploads use the same durable idempotency journal as WebSocket writes', async () => {
  const device = store.pair(store.createPair().code, 'upload');
  const directory = await mkdtemp(join(tmpdir(), 'bridge-upload-'));
  const project = await controller.workspace.register(directory);
  const body = { requestId: 'upload-1', projectId: project.id, dataBase64: 'iVBORw0KGgo=' };
  const first = await http('/v1/uploads', device.token, body);
  const second = await http('/v1/uploads', device.token, body);
  assert.equal(first.status, 200); assert.deepEqual(second.data, first.data);
  const conflict = await http('/v1/uploads', device.token, { ...body, dataBase64: '/9j/AA==' });
  assert.equal(conflict.data.error.code, 'REQUEST_CONFLICT');
  assert.equal((await http('/v1/uploads', device.token, { projectId: project.id, dataBase64: body.dataBase64 })).status, 400);
});
test('image endpoint authenticates binary responses and rejects forged references', async () => {
  const device = store.pair(store.createPair().code, 'image-read');
  const directory = await mkdtemp(join(tmpdir(), 'bridge-preview-'));
  const project = await controller.workspace.register(directory);
  const bytes = Buffer.from('iVBORw0KGgo=', 'base64');
  const path = join(directory, 'photo.png');
  await writeFile(path, bytes);
  (controller.codex as NetworkPeer).thread = { id: 'preview', cwd: directory, turns: [{ items: [{ id: 'user', type: 'userMessage', content: [{ type: 'localImage', path }] }] }] };
  const url = `/v1/thread-images?projectId=${project.id}&threadId=preview&itemId=user&contentIndex=0`;
  assert.equal((await app.inject({ url })).statusCode, 401);
  const headers = { authorization: `Bearer ${device.token}` };
  const response = await app.inject({ url, headers });
  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.rawPayload, bytes);
  assert.equal(response.headers['content-type'], 'image/png');
  assert.equal(response.headers['cache-control'], 'private, no-store');
  assert.equal(response.headers['x-content-type-options'], 'nosniff');
  for (const suffix of ['&path=secret', '&contentIndex=-1']) assert.equal((await app.inject({ url: url + suffix, headers })).statusCode, 400);
  assert.equal((await app.inject({ url: url.replace('itemId=user', 'itemId=forged'), headers })).statusCode, 400);
  store.revoke(device.deviceId);
  assert.equal((await app.inject({ url, headers })).statusCode, 401);
});
test('WebSocket auth, request validation, and idempotent replies use the real network boundary', async () => {
  const pair = store.createPair(); const device = store.pair(pair.code, 'WS');
  const connection = await connect(device.token);
  assert.equal(connection.messages.find(message => message.type === 'hello')!.reset, true);
  connection.socket.send(JSON.stringify({ type: 'request', requestId: 'test-1', method: 'bridge/info', params: {} }));
  assert.equal((await connection.wait(message => message.requestId === 'test-1')).result.protocolVersion, 1);
  connection.socket.send(JSON.stringify({ type: 'request', requestId: 'blocked', method: 'process/spawn', params: {} }));
  assert.equal((await connection.wait(message => message.requestId === 'blocked')).error.code, 'METHOD_NOT_ALLOWED');
  connection.socket.close();
  const unauthorized = new WebSocket(`${address.replace('https:', 'wss:')}/v1/ws`, { ca: certificate });
  await new Promise<void>((resolve, reject) => { unauthorized.on('error', () => resolve()); unauthorized.on('open', () => { unauthorized.close(); reject(new Error('Unauthenticated socket accepted')); }); });
});
test('disconnect does not kill upstream; reconnect replays events and approvals once', async () => {
  const device = store.pair(store.createPair().code, 'replay');
  const first = await connect(device.token, 0, store.epoch);
  const cursor = store.cursor(); first.socket.terminate();
  controller.codex.emit('serverRequest', { id: 90, method: 'item/fileChange/requestApproval', params: { threadId: 'task', turnId: 'turn' } });
  controller.publish('item/agentMessage/delta', { threadId: 'task', itemId: 'message', delta: 'offline work' });
  const restored = await connect(device.token, cursor, store.epoch);
  assert.equal(restored.messages.filter(message => message.method === 'bridge/approval').length, 1);
  assert.equal(restored.messages.filter(message => message.method === 'item/agentMessage/delta').length, 1);
  assert.equal(restored.messages.find(message => message.type === 'hello')!.runtime.approvals.length, 1);
  assert.equal(controller.codex.ready, true);
  store.revoke(device.deviceId);
  const closed = once(restored.socket, 'close');
  restored.socket.send(JSON.stringify({ type: 'request', requestId: 'after-revoke', method: 'bridge/info', params: {} }));
  assert.equal((await closed)[0], 4001);
});
test('expired replay cursor forces snapshot reset rather than claiming complete history', async () => {
  store.append('one', {}); store.append('two', {});
  store.db.prepare('DELETE FROM events WHERE seq<?').run(store.cursor());
  const device = store.pair(store.createPair().code, 'gap');
  const connection = await connect(device.token, 0, store.epoch);
  assert.equal(connection.messages.find(message => message.type === 'hello')!.reset, true);
  assert.equal(connection.messages.filter(message => message.type === 'event').length, 0);
  connection.socket.close();
});

test('revoked devices cannot delete a managed task over an existing socket', async () => {
  const device = store.pair(store.createPair().code, 'delete-revocation');
  const directory = await mkdtemp(join(tmpdir(), 'bridge-delete-auth-'));
  const project = await controller.workspace.register(directory);
  store.ownThread('protected-task', project.id);
  const connection = await connect(device.token);
  assert.ok(connection.messages.find(message => message.type === 'hello')!.capabilities.includes('threadDelete'));
  store.revoke(device.deviceId);
  const closed = once(connection.socket, 'close');
  connection.socket.send(JSON.stringify({ type: 'request', requestId: 'revoked-delete', method: 'thread/delete', params: { projectId: project.id, threadId: 'protected-task' } }));
  assert.equal((await closed)[0], 4001);
  assert.equal(store.thread('protected-task')?.project, project.id);
  assert.equal(connection.messages.some(message => message.requestId === 'revoked-delete' && message.result), false);
});
