import { realpath, stat, readdir, readFile, writeFile, mkdir, rename, unlink } from 'node:fs/promises';
import { basename, dirname, isAbsolute, relative, resolve, sep, join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID } from 'node:crypto';
import { BridgeError, text, type ObjectMap } from '@codex-bridge/protocol';
import { Store, hash } from './store.js';

const execute = promisify(execFile);
export class Workspace {
  private locks = new Map<string, Promise<unknown>>();
  constructor(private store: Store) {}
  async register(path: string, name?: string): Promise<ObjectMap> {
    if (!isAbsolute(path)) throw new BridgeError('INVALID_PATH', 'Project path must be absolute');
    const canonical = await realpath(path);
    if (!(await stat(canonical)).isDirectory()) throw new BridgeError('INVALID_PATH', 'Project must be a directory');
    return this.store.addProject(name || basename(canonical) || canonical, canonical);
  }
  async locate(projectId: string, path = ''): Promise<string> {
    const root = this.store.project(projectId).path as string;
    const target = await realpath(resolve(root, path));
    const displacement = relative(root, target);
    if (displacement === '..' || displacement.startsWith(`..${sep}`) || isAbsolute(displacement)) throw new BridgeError('PATH_OUTSIDE_PROJECT', 'Path escapes the selected project');
    return target;
  }
  async list(projectId: string, path = ''): Promise<ObjectMap> {
    const directory = await this.locate(projectId, path);
    const entries = await readdir(directory, { withFileTypes: true });
    return { entries: entries.filter(entry => entry.name !== '.git').slice(0, 3000).map(entry => ({ name: entry.name, isDirectory: entry.isDirectory(), isFile: entry.isFile(), isLink: entry.isSymbolicLink() })).sort((left, right) => Number(right.isDirectory) - Number(left.isDirectory) || left.name.localeCompare(right.name)) };
  }
  async read(projectId: string, path: string): Promise<ObjectMap> {
    const target = await this.locate(projectId, path);
    const info = await stat(target);
    if (!info.isFile() || info.size > 1024 * 1024) throw new BridgeError('FILE_TOO_LARGE', 'Text editor supports regular files up to 1 MiB');
    const bytes = await readFile(target);
    if (bytes.includes(0)) throw new BridgeError('BINARY_FILE', 'Binary files cannot be edited as text');
    let content: string;
    try { content = new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch { throw new BridgeError('FILE_ENCODING', 'Only UTF-8 text files are editable'); }
    return { content, version: hash(bytes), path, bytes: bytes.length, bom: bytes.subarray(0, 3).equals(Buffer.from([239, 187, 191])) };
  }
  async save(projectId: string, path: string, content: string, version: string, bom = false): Promise<ObjectMap> {
    const target = await this.locate(projectId, path);
    const previous = this.locks.get(target) ?? Promise.resolve();
    const operation = previous.catch(() => {}).then(async () => {
      const current = await readFile(target);
      if (hash(current) !== version) throw new BridgeError('FILE_CONFLICT', 'File changed on the host; reload before saving');
      const output = Buffer.concat([bom ? Buffer.from([239, 187, 191]) : Buffer.alloc(0), Buffer.from(content, 'utf8')]);
      if (output.length > 1024 * 1024) throw new BridgeError('FILE_TOO_LARGE', 'Maximum editable file size is 1 MiB');
      const temporary = join(dirname(target), `.bridge-${randomUUID()}.tmp`);
      try {
        await writeFile(temporary, output, { flag: 'wx', mode: (await stat(target)).mode });
        if (hash(await readFile(target)) !== version) throw new BridgeError('FILE_CONFLICT', 'File changed while saving');
        await rename(temporary, target);
      } finally { await unlink(temporary).catch(() => {}); }
      return { path, version: hash(output), bom };
    });
    this.locks.set(target, operation);
    try { return await operation; } finally { if (this.locks.get(target) === operation) this.locks.delete(target); }
  }
  async upload(projectId: string, dataBase64: string): Promise<ObjectMap> {
    const bytes = Buffer.from(dataBase64, 'base64');
    if (bytes.length > 20 * 1024 * 1024) throw new BridgeError('IMAGE_TOO_LARGE', 'Image exceeds 20 MiB');
    let suffix: string;
    if (bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) suffix = '.png';
    else if (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) suffix = '.jpg';
    else throw new BridgeError('INVALID_IMAGE', 'Only PNG and JPEG images are accepted');
    const root = this.store.project(projectId).path as string;
    const directory = join(root, '.codex-bridge-uploads');
    await mkdir(directory, { recursive: true, mode: 0o700 });
    await this.locate(projectId, '.codex-bridge-uploads');
    const name = `${randomUUID()}${suffix}`;
    const target = join(directory, name);
    await writeFile(target, bytes, { flag: 'wx', mode: 0o600 });
    return { path: target, name };
  }
  async git(projectId: string): Promise<ObjectMap> {
    const cwd = this.store.project(projectId).path as string;
    const run = async (args: string[]) => (await execute('git', ['--no-pager', ...args], { cwd, windowsHide: true, maxBuffer: 5 * 1024 * 1024, timeout: 15_000, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_PAGER: 'cat' } })).stdout;
    try { await run(['rev-parse', '--is-inside-work-tree']); } catch { return { isGit: false }; }
    return { isGit: true, status: await run(['status', '--short']), unstaged: await run(['diff', '--no-ext-diff', '--no-textconv']), staged: await run(['diff', '--cached', '--no-ext-diff', '--no-textconv']) };
  }
  async dispatch(method: string, params: ObjectMap): Promise<unknown> {
    const projectId = text(params.projectId, 'projectId', 128);
    if (method === 'files/upload') return this.upload(projectId, text(params.dataBase64, 'image', 28 * 1024 * 1024));
    const path = typeof params.path === 'string' ? params.path : '';
    if (method === 'files/list') return this.list(projectId, path);
    if (method === 'files/read') return this.read(projectId, text(path, 'path'));
    if (method === 'files/save') {
      if (typeof params.content !== 'string') throw new BridgeError('INVALID_PARAMS', 'content must be a string');
      return this.save(projectId, text(path, 'path'), params.content, text(params.version, 'version', 64), params.bom === true);
    }
    if (method === 'git/status') return this.git(projectId);
    throw new BridgeError('METHOD_NOT_ALLOWED', 'Unknown workspace operation');
  }
}
