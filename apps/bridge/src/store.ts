import { DatabaseSync } from 'node:sqlite';
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { BridgeError, type ObjectMap, type BridgeEvent } from '@codex-bridge/protocol';

export const hash = (value: string | Buffer): string => createHash('sha256').update(value).digest('hex');
const token = (): string => randomBytes(32).toString('base64url');

export class Store {
  readonly db: DatabaseSync;
  readonly epoch: string;
  constructor(path: string, boot = true) {
    this.db = new DatabaseSync(path);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, hash TEXT UNIQUE NOT NULL, created INTEGER NOT NULL, revoked INTEGER);
      CREATE TABLE IF NOT EXISTS pairs (hash TEXT PRIMARY KEY, expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT UNIQUE NOT NULL);
      CREATE TABLE IF NOT EXISTS requests (device TEXT NOT NULL, id TEXT NOT NULL, hash TEXT NOT NULL, state TEXT NOT NULL, result TEXT, PRIMARY KEY(device,id));
      CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT, epoch TEXT NOT NULL, method TEXT NOT NULL, params TEXT NOT NULL, created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS approvals (id TEXT PRIMARY KEY, epoch TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS threads (id TEXT PRIMARY KEY, project TEXT NOT NULL, state TEXT NOT NULL, turn TEXT);
      CREATE TABLE IF NOT EXISTS terminals (id TEXT PRIMARY KEY, project TEXT NOT NULL, epoch TEXT NOT NULL, state TEXT NOT NULL, output TEXT NOT NULL);
    `);
    this.epoch = boot ? randomUUID() : (this.meta('epoch') ?? randomUUID());
    if (boot) {
      this.setMeta('epoch', this.epoch);
      this.db.exec("UPDATE requests SET state='unknown' WHERE state='pending'; UPDATE approvals SET state='expired' WHERE state='pending'; UPDATE threads SET state='unknown' WHERE state IN ('running','starting'); UPDATE terminals SET state='lost' WHERE state IN ('running','starting');");
    }
  }
  meta(key: string): string | undefined { return (this.db.prepare('SELECT value FROM meta WHERE key=?').get(key) as any)?.value; }
  setMeta(key: string, value: string): void { this.db.prepare('INSERT OR REPLACE INTO meta VALUES (?,?)').run(key, value); }
  createPair(): { code: string; expiresAt: number } {
    const code = token();
    const expiresAt = Date.now() + 5 * 60_000;
    this.db.prepare('DELETE FROM pairs WHERE expires<?').run(Date.now());
    this.db.prepare('INSERT INTO pairs VALUES (?,?)').run(hash(code), expiresAt);
    return { code, expiresAt };
  }
  pair(code: string, name: string): { deviceId: string; token: string } {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const pair = this.db.prepare('SELECT expires FROM pairs WHERE hash=?').get(hash(code)) as any;
      if (!pair || pair.expires < Date.now()) throw new BridgeError('PAIR_INVALID', 'Pairing code expired or already used');
      this.db.prepare('DELETE FROM pairs WHERE hash=?').run(hash(code));
      const deviceId = randomUUID();
      const secret = token();
      this.db.prepare('INSERT INTO devices VALUES (?,?,?,?,NULL)').run(deviceId, name, hash(secret), Date.now());
      this.db.exec('COMMIT');
      return { deviceId, token: secret };
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  authenticate(secret: string): string | undefined {
    return (this.db.prepare('SELECT id FROM devices WHERE hash=? AND revoked IS NULL').get(hash(secret)) as any)?.id;
  }
  deviceActive(id: string): boolean { return !!this.db.prepare('SELECT id FROM devices WHERE id=? AND revoked IS NULL').get(id); }
  devices(): unknown[] { return this.db.prepare('SELECT id,name,created,revoked FROM devices').all(); }
  revoke(id: string): void { this.db.prepare('UPDATE devices SET revoked=? WHERE id=?').run(Date.now(), id); }
  projects(): ObjectMap[] { return this.db.prepare('SELECT * FROM projects ORDER BY name').all() as ObjectMap[]; }
  project(id: string): ObjectMap {
    const project = this.db.prepare('SELECT * FROM projects WHERE id=?').get(id) as ObjectMap | undefined;
    if (!project) throw new BridgeError('PROJECT_NOT_FOUND', 'Select a registered project');
    return project;
  }
  addProject(name: string, path: string): ObjectMap {
    const existing = this.db.prepare('SELECT * FROM projects WHERE path=?').get(path) as ObjectMap | undefined;
    if (existing) return existing;
    const project = { id: randomUUID(), name, path };
    this.db.prepare('INSERT INTO projects VALUES (?,?,?)').run(project.id, name, path);
    return project;
  }
  removeProject(id: string): void {
    if (this.db.prepare("SELECT id FROM threads WHERE project=? AND state IN ('running','starting')").get(id)) throw new BridgeError('PROJECT_BUSY', 'Project has running tasks');
    this.db.prepare('DELETE FROM projects WHERE id=?').run(id);
  }
  beginRequest(device: string, id: string, digest: string): ObjectMap | undefined {
    const prior = this.db.prepare('SELECT * FROM requests WHERE device=? AND id=?').get(device, id) as ObjectMap | undefined;
    if (prior) {
      if (prior.hash !== digest) throw new BridgeError('REQUEST_CONFLICT', 'requestId was reused with different content');
      if (prior.state === 'unknown') throw new BridgeError('OUTCOME_UNKNOWN', 'Previous request may have executed. Inspect history before sending a new operation.');
      if (prior.state === 'pending') throw new BridgeError('REQUEST_PENDING', 'Previous request is still processing');
      return JSON.parse(prior.result);
    }
    this.db.prepare("INSERT INTO requests VALUES (?,?,?,'pending',NULL)").run(device, id, digest);
    return undefined;
  }
  finishRequest(device: string, id: string, result: ObjectMap, unknown = false): void {
    this.db.prepare('UPDATE requests SET state=?,result=? WHERE device=? AND id=?').run(unknown ? 'unknown' : 'done', JSON.stringify(result), device, id);
  }
  append(method: string, params: ObjectMap): BridgeEvent {
    const result = this.db.prepare('INSERT INTO events (epoch,method,params,created) VALUES (?,?,?,?)').run(this.epoch, method, JSON.stringify(params), Date.now());
    const seq = Number(result.lastInsertRowid);
    if (seq % 1000 === 0) this.db.prepare('DELETE FROM events WHERE seq<?').run(seq - 50_000);
    return { type: 'event', epoch: this.epoch, seq, method, params };
  }
  cursor(): number { return Number((this.db.prepare('SELECT MAX(seq) AS seq FROM events').get() as any).seq ?? 0); }
  replay(after: number): BridgeEvent[] {
    return (this.db.prepare('SELECT * FROM events WHERE seq>? ORDER BY seq LIMIT 50001').all(after) as ObjectMap[]).map(row => ({ type: 'event', epoch: row.epoch, seq: Number(row.seq), method: row.method, params: JSON.parse(row.params) }));
  }
  pending(): ObjectMap[] { return (this.db.prepare("SELECT payload FROM approvals WHERE state='pending' AND epoch=?").all(this.epoch) as any[]).map(row => JSON.parse(row.payload)); }
  saveApproval(id: string, payload: ObjectMap): void { this.db.prepare("INSERT OR REPLACE INTO approvals VALUES (?,?,?,'pending')").run(id, this.epoch, JSON.stringify(payload)); }
  resolveApproval(id: string): void { this.db.prepare("UPDATE approvals SET state='resolved' WHERE id=?").run(id); }
  thread(id: string): ObjectMap | undefined { return this.db.prepare('SELECT * FROM threads WHERE id=?').get(id) as ObjectMap | undefined; }
  ownThread(id: string, project: string): void { this.db.prepare("INSERT OR IGNORE INTO threads VALUES (?,?,'idle',NULL)").run(id, project); }
  removeThread(id: string): void {
    this.db.prepare('DELETE FROM threads WHERE id=?').run(id);
    this.db.prepare("UPDATE approvals SET state='resolved' WHERE json_extract(payload, '$.params.threadId')=? AND state='pending'").run(id);
  }
  threadState(id: string, state: string, turn?: string): void { this.db.prepare('UPDATE threads SET state=?,turn=? WHERE id=?').run(state, turn ?? null, id); }
  runtime(): ObjectMap { return { threads: this.db.prepare('SELECT * FROM threads').all(), terminals: this.db.prepare('SELECT * FROM terminals').all(), approvals: this.pending() }; }
  close(): void { this.db.close(); }
}
