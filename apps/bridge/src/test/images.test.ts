import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, writeFile, mkdir, symlink, unlink, open } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Store } from '../store.js';
import { Controller } from '../controller.js';
import { imageContentType, MAX_IMAGE_BYTES, readReferencedImage } from '../images.js';
import type { ObjectMap } from '@codex-bridge/protocol';

const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1cAAAAASUVORK5CYII=', 'base64');

test('history image references authorize only the selected task, project and user content', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'bridge-image-'));
  const outside = await mkdtemp(join(tmpdir(), 'bridge-image-external-'));
  const imagePath = join(outside, 'photo.png');
  await writeFile(imagePath, png);
  const store = new Store(':memory:');
  const calls: string[] = [];
  const thread: ObjectMap = { id: 'desktop', cwd: directory, turns: [{ items: [
    { id: 'message', type: 'userMessage', content: [{ type: 'text', text: 'photo' }, { type: 'localImage', path: imagePath }] },
    { id: 'agent', type: 'agentMessage', content: [{ type: 'localImage', path: imagePath }] },
  ] }] };
  class Peer extends EventEmitter {
    ready = true;
    async request(method: string): Promise<ObjectMap> { calls.push(method); return { thread }; }
    respond(): void {}
    reject(): void {}
  }
  const controller = new Controller(store, new Peer());
  try {
    const project = await controller.workspace.register(directory);
    const other = await controller.workspace.register(outside);
    const reference = { projectId: project.id, threadId: 'desktop', itemId: 'message', contentIndex: 1 };
    assert.deepEqual((await controller.threadImage(reference)).bytes, png);
    assert.deepEqual(calls, ['thread/read']);
    assert.equal(store.thread('desktop'), undefined);
    for (const override of [
      { contentIndex: 0 }, { contentIndex: 2 }, { contentIndex: -1 }, { contentIndex: 0.5 },
      { itemId: 'forged' }, { itemId: 'agent', contentIndex: 0 }, { threadId: 'forged' },
      { projectId: other.id }, { path: imagePath },
    ]) await assert.rejects(() => controller.threadImage({ ...reference, ...override }));
    store.ownThread('desktop', other.id);
    await assert.rejects(() => controller.threadImage(reference), /another project/);
    assert.ok(calls.every(method => method === 'thread/read'));
  } finally { store.close(); }
});

test('image reads reject missing, non-image, oversized and linked files', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'bridge-image-read-'));
  await writeFile(join(directory, 'photo.png'), png);
  assert.equal((await readReferencedImage('photo.png', directory)).contentType, 'image/png');
  await assert.rejects(() => readReferencedImage('missing.png', directory), /unavailable/);
  await assert.rejects(() => readReferencedImage('.', directory), /regular file/);
  await writeFile(join(directory, 'fake.png'), 'private text');
  await assert.rejects(() => readReferencedImage('fake.png', directory), /Unsupported/);
  const large = await open(join(directory, 'large.png'), 'w');
  await large.truncate(MAX_IMAGE_BYTES + 1); await large.close();
  await assert.rejects(() => readReferencedImage('large.png', directory), /20 MiB/);
  const original = join(directory, 'original');
  const changed = join(directory, 'changed');
  await mkdir(original); await mkdir(changed);
  await writeFile(join(original, 'photo.png'), png); await writeFile(join(changed, 'photo.png'), png);
  const link = join(directory, 'link');
  await symlink(original, link, process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(() => readReferencedImage(join(link, 'photo.png'), directory), /Linked/);
  await unlink(link);
  await symlink(changed, link, process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(() => readReferencedImage(join(link, 'photo.png'), directory), /Linked/);
});

test('history preview recognizes only supported raster signatures', () => {
  assert.equal(imageContentType(png), 'image/png');
  assert.equal(imageContentType(Buffer.from([255, 216, 255, 224])), 'image/jpeg');
  assert.equal(imageContentType(Buffer.from('GIF89a')), 'image/gif');
  assert.equal(imageContentType(Buffer.from('RIFF1234WEBP')), 'image/webp');
  assert.throws(() => imageContentType(Buffer.from('<svg/>')), /Unsupported/);
  assert.throws(() => imageContentType(Buffer.alloc(0)), /Unsupported/);
});
