import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';
import { EventEmitter } from 'node:events';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { CODEX_VERSION, BridgeError, type ObjectMap } from '@codex-bridge/protocol';

export interface RpcPeer extends EventEmitter {
  ready: boolean;
  request(method: string, params: ObjectMap, timeout?: number): Promise<any>;
  respond(id: string | number, result: unknown): void;
  reject(id: string | number, message: string): void;
}
export function codexCommand(): { executable: string; args: string[] } {
  if (process.env.BRIDGE_CODEX_BIN) return { executable: process.env.BRIDGE_CODEX_BIN, args: [] };
  if (process.platform === 'win32') {
    for (const directory of [dirname(process.execPath), ...((process.env.PATH ?? '').split(';'))]) {
      const script = join(directory, 'node_modules', '@openai', 'codex', 'bin', 'codex.js');
      if (existsSync(script)) return { executable: process.execPath, args: [script] };
      const executable = join(directory, 'codex.exe');
      if (existsSync(executable)) return { executable, args: [] };
    }
    throw new BridgeError('CODEX_NOT_FOUND', 'Set BRIDGE_CODEX_BIN to the Codex executable');
  }
  return { executable: 'codex', args: [] };
}
export class CodexPeer extends EventEmitter implements RpcPeer {
  ready = false;
  private process?: ChildProcessWithoutNullStreams;
  private sequence = 0;
  private pending = new Map<number, { resolve: (value: any) => void; reject: (reason: unknown) => void; timer?: NodeJS.Timeout }>();
  async start(): Promise<void> {
    const command = codexCommand();
    const version = spawnSync(command.executable, [...command.args, '--version'], { encoding: 'utf8', windowsHide: true, timeout: 15_000 });
    if (version.status !== 0 || version.stdout.trim() !== `codex-cli ${CODEX_VERSION}`) {
      throw new BridgeError('VERSION_MISMATCH', `This adapter requires codex-cli ${CODEX_VERSION}; found ${version.stdout?.trim() || 'unavailable'}`);
    }
    const child = spawn(command.executable, [...command.args, 'app-server', '--stdio'], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    this.process = child;
    child.stderr.on('data', () => {});
    child.stdin.on('error', () => this.disconnected());
    child.on('error', () => this.disconnected());
    child.on('exit', () => this.disconnected());
    const lines = createInterface({ input: child.stdout });
    lines.on('line', line => {
      try {
        const message = JSON.parse(line) as ObjectMap;
        if (message.method) {
          this.emit(message.id === undefined ? 'notification' : 'serverRequest', message);
        } else {
          const waiter = this.pending.get(message.id);
          if (!waiter) return;
          clearTimeout(waiter.timer);
          this.pending.delete(message.id);
          if (message.error) waiter.reject(new BridgeError('CODEX_ERROR', message.error.message, { upstreamCode: message.error.code }));
          else waiter.resolve(message.result);
        }
      } catch { this.emit('protocolWarning', { message: 'Unreadable upstream message' }); }
    });
    await this.request('initialize', { clientInfo: { name: 'codex_android_bridge', title: 'Codex Bridge (Unofficial)', version: '0.1.0' }, capabilities: { experimentalApi: true } });
    this.write({ method: 'initialized', params: {} });
    this.ready = true;
  }
  private write(message: ObjectMap): void {
    if (!this.process || this.process.stdin.destroyed) throw new BridgeError('UPSTREAM_LOST', 'Codex process is unavailable');
    this.process.stdin.write(`${JSON.stringify(message)}\n`);
  }
  request(method: string, params: ObjectMap, timeout = 120_000): Promise<any> {
    return new Promise((resolve, reject) => {
      const id = ++this.sequence;
      const timer = timeout > 0 ? setTimeout(() => {
        this.pending.delete(id);
        reject(new BridgeError('OUTCOME_UNKNOWN', 'Codex did not acknowledge in time; inspect state before retrying'));
      }, timeout) : undefined;
      this.pending.set(id, { resolve, reject, timer });
      try { this.write({ id, method, params }); }
      catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }
  respond(id: string | number, result: unknown): void { this.write({ id, result }); }
  reject(id: string | number, message: string): void { this.write({ id, error: { code: -32601, message } }); }
  private disconnected(): void {
    const wasReady = this.ready;
    this.ready = false;
    for (const waiter of this.pending.values()) { clearTimeout(waiter.timer); waiter.reject(new BridgeError('UPSTREAM_LOST', 'Codex exited; operation outcome may be unknown')); }
    this.pending.clear();
    if (wasReady) this.emit('disconnected');
  }
  async stop(): Promise<void> {
    const child = this.process;
    if (!child || child.exitCode !== null) return;
    await new Promise<void>(resolve => {
      const timer = setTimeout(() => { child.kill(); resolve(); }, 2000);
      child.once('exit', () => { clearTimeout(timer); resolve(); });
      child.stdin.end();
    });
  }
}
