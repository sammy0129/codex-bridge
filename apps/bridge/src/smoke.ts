import { mkdir, readFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { CodexPeer } from './codex.js';
import { Store } from './store.js';
import { Controller } from './controller.js';
import type { TurnInterruptParams } from '@codex-bridge/protocol';

const directory = resolve('.local', `smoke-${Date.now()}`);
await mkdir(directory, { recursive: true });
const store = new Store(join(directory, 'bridge.sqlite'));
const codex = new CodexPeer();
const controller = new Controller(store, codex);
const results: string[] = [];
try {
  await codex.start(); results.push('real Codex initialization');
  const project = await controller.workspace.register(directory);
  const models = await controller.dispatch('model/list', { limit: 100 });
  if (!models.data?.length) throw new Error('No models available'); results.push('model catalog');
  await controller.dispatch('collaborationMode/list', {}); results.push('collaboration modes');
  await controller.dispatch('thread/list', { projectId: project.id, limit: 10 }); results.push('history listing');
  const terminal = await controller.dispatch('terminal/open', { projectId: project.id });
  await delay(1500);
  const command = process.platform === 'win32' ? "Write-Output ('BRIDGE_TERMINAL_' + 'OK')\r" : "printf '%s%s\\n' BRIDGE_TERMINAL_ OK\r";
  await controller.dispatch('terminal/write', { projectId: project.id, id: terminal.id, deltaBase64: Buffer.from(command).toString('base64') });
  await controller.dispatch('terminal/resize', { projectId: project.id, id: terminal.id, cols: 100, rows: 30 });
  await delay(1500);
  const output = await controller.dispatch('terminal/read', { projectId: project.id, id: terminal.id });
  if (!output.output.includes('BRIDGE_TERMINAL_OK')) throw new Error(`PTY did not stream output (${output.state})`);
  await controller.dispatch('terminal/close', { projectId: project.id, id: terminal.id }); results.push('PTY input/output/resize/close');
  if (process.argv.includes('--agent')) {
    const started = await controller.dispatch('thread/start', { projectId: project.id, model: models.data.find((entry: any) => entry.isDefault)?.model ?? models.data[0].model });
    const completed = new Promise<void>((resolveTurn, reject) => {
      const timeout = setTimeout(() => reject(new Error('Agent smoke timed out')), 180_000);
      controller.on('event', event => {
        if (event.params.threadId === started.thread.id && event.method === 'turn/completed') {
          clearTimeout(timeout);
          if (event.params.turn.status === 'failed') reject(new Error(JSON.stringify(event.params.turn.error)));
          else resolveTurn();
        }
      });
    });
    await controller.dispatch('turn/start', { threadId: started.thread.id, effort: 'low', input: [{ type: 'text', text: 'Environment smoke test. Do not delegate or use subagents. Create bridge-smoke.txt in the current directory with exactly BRIDGE_AGENT_OK followed by a newline. Run a shell command that reads it and verifies that text. Do not modify any other file. Respond with a short success message.' }] });
    await completed;
    if ((await readFile(join(directory, 'bridge-smoke.txt'), 'utf8')).trim() !== 'BRIDGE_AGENT_OK') throw new Error('Agent artifact did not match');
    await controller.dispatch('thread/read', { threadId: started.thread.id, includeTurns: true });
    const interrupted = new Promise<void>((resolveTurn, reject) => {
      const timeout = setTimeout(() => reject(new Error('Interrupt smoke timed out')), 30_000);
      const listener = (event: any) => {
        if (event.params.threadId === started.thread.id && event.method === 'turn/completed') {
          clearTimeout(timeout); controller.off('event', listener);
          if (event.params.turn.status !== 'interrupted') reject(new Error('Turn did not report interrupted'));
          else resolveTurn();
        }
      };
      controller.on('event', listener);
    });
    const pending = await controller.dispatch('turn/start', { threadId: started.thread.id, effort: 'low', input: [{ type: 'text', text: 'Do not delegate or use subagents. Wait twenty seconds before responding. Do not modify files.' }] });
    await controller.dispatch('turn/interrupt', { threadId: started.thread.id, turnId: pending.turn.id } satisfies TurnInterruptParams);
    await interrupted; results.push('real active turn interruption');
    await controller.dispatch('thread/archive', { threadId: started.thread.id }); results.push('real agent writes file, runs verification, persists history, and archives');
  }
  console.log(JSON.stringify({ passed: results, directory }, null, 2));
} finally { await codex.stop(); store.close(); }
