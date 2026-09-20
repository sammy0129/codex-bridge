import { mkdir, readFile, writeFile, chmod } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { X509Certificate } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { generate } from 'selfsigned';
import { BridgeError } from '@codex-bridge/protocol';

export type Config = { dataDir: string; host: string; port: number; publicUrl: string; certPath: string; keyPath: string };
export function dataDirectory(): string { return resolve(process.env.BRIDGE_DATA_DIR ?? join(homedir(), '.codex-android-bridge')); }
export async function initialize(publicUrl: string, host = '127.0.0.1', port = 8787): Promise<Config> {
  const url = new URL(publicUrl);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.pathname !== '/') throw new BridgeError('INVALID_URL', 'Use an HTTPS origin without credentials or path');
  const dataDir = dataDirectory();
  await mkdir(dataDir, { recursive: true, mode: 0o700 });
  if (process.platform === 'win32') {
    const execute = promisify(execFile);
    const identity = await execute('whoami', ['/user', '/fo', 'csv', '/nh'], { windowsHide: true });
    const sid = identity.stdout.match(/S-1-[0-9-]+/)?.[0];
    if (!sid) throw new BridgeError('ACL_FAILED', 'Cannot determine the current Windows account SID');
    await execute('icacls', [dataDir, '/inheritance:r', '/grant:r', `*${sid}:(OI)(CI)F`, '*S-1-5-18:(OI)(CI)F'], { windowsHide: true });
  }
  const configPath = join(dataDir, 'config.json');
  if (existsSync(configPath)) throw new BridgeError('ALREADY_INITIALIZED', `Existing configuration at ${configPath}; edit it rather than replacing credentials`);
  const certPath = join(dataDir, 'server.pem');
  const keyPath = join(dataDir, 'server.key');
  const generated = await generate([{ name: 'commonName', value: url.hostname }], { keySize: 2048, days: 825, algorithm: 'sha256', extensions: [{ name: 'subjectAltName', altNames: [{ type: 2, value: 'localhost' }, { type: 7, ip: '127.0.0.1' }, /^(\d{1,3}\.){3}\d{1,3}$/.test(url.hostname) ? { type: 7, ip: url.hostname } : { type: 2, value: url.hostname }] }] });
  await writeFile(certPath, generated.cert, { mode: 0o600, flag: 'wx' });
  await writeFile(keyPath, generated.private, { mode: 0o600, flag: 'wx' });
  const config = { dataDir, host, port, publicUrl: url.origin, certPath, keyPath };
  await writeFile(configPath, JSON.stringify(config, null, 2), { mode: 0o600, flag: 'wx' });
  return config;
}
export async function loadConfig(): Promise<Config> {
  const dataDir = dataDirectory();
  const config = JSON.parse(await readFile(join(dataDir, 'config.json'), 'utf8')) as Config;
  return { ...config, dataDir };
}
export async function tls(config: Config): Promise<{ key: Buffer; cert: Buffer }> {
  return { key: await readFile(config.keyPath), cert: await readFile(config.certPath) };
}
export async function fingerprint(config: Config): Promise<string> { return new X509Certificate(await readFile(config.certPath)).fingerprint256.replaceAll(':', '').toLowerCase(); }
export async function protect(path: string): Promise<void> { if (process.platform !== 'win32') await chmod(path, 0o600); }
