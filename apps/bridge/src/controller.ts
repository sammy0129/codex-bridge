import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import { homedir, hostname } from 'node:os';
import { StringDecoder } from 'node:string_decoder';
import { realpath } from 'node:fs/promises';
import { relative } from 'node:path';
import { readReferencedImage } from './images.js';
import { BridgeError, CODEX_VERSION, PROTOCOL_VERSION, codexMethods, approvalSchemas, validateSchema, text, object, errorPayload, type ObjectMap, type BridgeRequest } from '@codex-bridge/protocol';
import { Store, hash } from './store.js';
import { Workspace } from './workspace.js';
import type { RpcPeer } from './codex.js';
import type { ThreadReadParams, ThreadHistoryMode, CommandExecWriteParams } from '@codex-bridge/protocol';

export class Controller extends EventEmitter {
  readonly workspace: Workspace;
  private threadLocks = new Set<string>();
  private liveApprovals = new Map<string, ObjectMap>();
  private loaded = new Set<string>();
  private decoders = new Map<string, StringDecoder>();
  constructor(readonly store: Store, readonly codex: RpcPeer) {
    super();
    this.workspace = new Workspace(store);
    codex.on('notification', message => this.notification(message));
    codex.on('serverRequest', message => this.serverRequest(message));
    codex.on('disconnected', () => {
      store.db.exec("UPDATE threads SET state='unknown' WHERE state IN ('running','starting'); UPDATE terminals SET state='lost' WHERE state IN ('running','starting'); UPDATE approvals SET state='expired' WHERE state='pending';");
      this.liveApprovals.clear(); this.loaded.clear();
      this.publish('bridge/upstreamLost', { message: 'Codex process exited. Restart Bridge; active outcomes require inspection.' });
    });
  }
  publish(method: string, params: ObjectMap): void { this.emit('event', this.store.append(method, params)); }
  info(): ObjectMap {
    const runtime = this.store.runtime();
    return {
      protocolVersion: PROTOCOL_VERSION, bridgeVersion: '0.1.0', codexVersion: CODEX_VERSION,
      hostName: hostname(), platform: process.platform, homeDirectory: homedir(), epoch: this.store.epoch,
      ready: this.codex.ready, runningTasks: runtime.threads.filter((entry: any) => ['running', 'starting'].includes(entry.state)).length,
      pendingRequests: runtime.approvals.length,
      capabilities: ['threads', 'streaming', 'approvals', 'models', 'modes', 'skills', 'mcp', 'files', 'diff', 'terminal', 'replay', 'imageUpload', 'imageRead'],
    };
  }
  private notification(message: ObjectMap): void {
    const params = message.params ?? {};
    if (message.method === 'turn/started') this.store.threadState(params.threadId, 'running', params.turn?.id);
    if (message.method === 'turn/completed') {
      this.store.threadState(params.threadId, 'idle');
      for (const [id, approval] of this.liveApprovals) {
        if (approval.params.threadId === params.threadId && approval.params.turnId === params.turn?.id) {
          this.store.resolveApproval(id); this.liveApprovals.delete(id);
        }
      }
    }
    if (message.method === 'serverRequest/resolved') {
      const id = `${this.store.epoch}:${params.requestId}`;
      this.store.resolveApproval(id); this.liveApprovals.delete(id);
    }
    if (message.method === 'command/exec/outputDelta') {
      const terminal = this.store.db.prepare('SELECT output FROM terminals WHERE id=? AND epoch=?').get(params.processId, this.store.epoch) as any;
      if (terminal) {
        const key = `${params.processId}:${params.stream}`;
        const decoder = this.decoders.get(key) ?? new StringDecoder('utf8');
        this.decoders.set(key, decoder);
        params.textDelta = decoder.write(Buffer.from(params.deltaBase64 ?? '', 'base64'));
        const output = (terminal.output + params.textDelta).slice(-128_000);
        this.store.db.prepare('UPDATE terminals SET output=? WHERE id=?').run(output, params.processId);
      }
    }
    this.publish(message.method, params);
  }
  private serverRequest(message: ObjectMap): void {
    if (!approvalSchemas[message.method]) {
      this.codex.reject(message.id, `Client cannot safely handle ${message.method}`);
      this.publish('bridge/unsupportedRequest', { method: message.method, threadId: message.params?.threadId });
      return;
    }
    const id = `${this.store.epoch}:${message.id}`;
    const approval = { id, upstreamId: message.id, method: message.method, params: message.params };
    this.liveApprovals.set(id, approval);
    this.store.saveApproval(id, approval);
    this.publish('bridge/approval', approval);
  }
  async request(device: string, request: BridgeRequest): Promise<ObjectMap> {
    const digest = hash(JSON.stringify({ method: request.method, params: request.params }));
    try {
      const previous = this.store.beginRequest(device, request.requestId, digest);
      if (previous) return previous;
    } catch (error) { return { type: 'response', requestId: request.requestId, error: errorPayload(error) }; }
    let response: ObjectMap;
    let unknown = false;
    try { response = { type: 'response', requestId: request.requestId, result: await this.dispatch(request.method, request.params) }; }
    catch (error) {
      unknown = error instanceof BridgeError && ['OUTCOME_UNKNOWN', 'UPSTREAM_LOST'].includes(error.code);
      response = { type: 'response', requestId: request.requestId, error: errorPayload(error) };
    }
    this.store.finishRequest(device, request.requestId, response, unknown);
    return response;
  }
  private requireOwned(id: string): ObjectMap {
    const owned = this.store.thread(id);
    if (!owned) throw new BridgeError('EXTERNAL_THREAD', 'Resume or fork this external thread before controlling it');
    return owned;
  }
  private async readThread(input: ThreadReadParams): Promise<ObjectMap> {
    try { return await this.codex.request('thread/read', input); }
    catch (error) {
      if (input.includeTurns === true && this.loaded.has(input.threadId) && error instanceof BridgeError && error.code === 'CODEX_ERROR' && error.message.includes('is not materialized yet; includeTurns is unavailable before first user message')) {
        return this.codex.request('thread/read', { ...input, includeTurns: false });
      }
      throw error;
    }
  }
  async threadImage(params: ObjectMap): Promise<{ bytes: Buffer; contentType: string }> {
    if (Object.keys(params).some(key => !['projectId', 'threadId', 'itemId', 'contentIndex'].includes(key))) throw new BridgeError('INVALID_PARAMS', 'Only message image references are accepted');
    const project = this.store.project(text(params.projectId, 'projectId', 128));
    const threadId = text(params.threadId, 'threadId', 128);
    const itemId = text(params.itemId, 'itemId', 256);
    const index = params.contentIndex;
    if (!Number.isSafeInteger(index) || index < 0) throw new BridgeError('INVALID_PARAMS', 'Invalid contentIndex');
    const owned = this.store.thread(threadId);
    if (owned && owned.project !== project.id) throw new BridgeError('PROJECT_MISMATCH', 'Task belongs to another project');
    if (!this.codex.ready) throw new BridgeError('UPSTREAM_LOST', 'Codex is offline');
    const result = await this.readThread({ threadId, includeTurns: true });
    const thread = result.thread;
    if (thread?.id !== threadId || typeof thread.cwd !== 'string') throw new BridgeError('PROJECT_MISMATCH', 'Cannot verify task project');
    let matches = false;
    try { matches = relative(await realpath(project.path), await realpath(thread.cwd)) === ''; } catch {}
    if (!matches) throw new BridgeError('PROJECT_MISMATCH', 'Task belongs to another project');
    const item = (thread.turns ?? []).flatMap((turn: ObjectMap) => turn.items ?? []).find((entry: ObjectMap) => entry.id === itemId);
    const image = item?.type === 'userMessage' && Array.isArray(item.content) ? item.content[index] : undefined;
    if (image?.type !== 'localImage') throw new BridgeError('IMAGE_NOT_FOUND', 'Message does not contain this local image');
    return readReferencedImage(text(image.path, 'image path'), project.path);
  }
  private async policy(mode: unknown): Promise<{ sandbox: string; approvalPolicy: string; sandboxPolicy: ObjectMap }> {
    const sandbox = mode ?? 'danger-full-access';
    if (!['danger-full-access', 'workspace-write', 'read-only'].includes(String(sandbox))) throw new BridgeError('INVALID_PARAMS', 'Unknown permission mode');
    const approvalPolicy = sandbox === 'danger-full-access' ? 'never' : 'on-request';
    const requirements = (await this.codex.request('configRequirements/read', {})).requirements;
    const normalize = (value: string) => value.replace(/[-_]/g, '').toLowerCase();
    const allowed = (values: string[] | null | undefined, requested: string) => !values || values.some(value => normalize(value) === normalize(requested));
    if (!allowed(requirements?.allowedSandboxModes, String(sandbox)) || !allowed(requirements?.allowedApprovalPolicies, approvalPolicy)) {
      throw new BridgeError('POLICY_BLOCKED', 'Host policy prohibits this permission mode. Select an allowed mode.', requirements);
    }
    return { sandbox: String(sandbox), approvalPolicy, sandboxPolicy: { type: sandbox === 'danger-full-access' ? 'dangerFullAccess' : sandbox === 'workspace-write' ? 'workspaceWrite' : 'readOnly' } };
  }
  async dispatch(method: string, params: ObjectMap): Promise<any> {
    if (method === 'bridge/info') return this.info();
    if (method === 'bridge/runtime') return this.store.runtime();
    if (method === 'projects/list') return { projects: this.store.projects() };
    if (method === 'projects/add') return this.workspace.register(text(params.path, 'path'), typeof params.name === 'string' ? params.name.slice(0, 100) : undefined);
    if (method === 'projects/remove') { this.store.removeProject(text(params.projectId, 'projectId')); return {}; }
    if (method.startsWith('files/') || method === 'git/status') return this.workspace.dispatch(method, params);
    if (!this.codex.ready) throw new BridgeError('UPSTREAM_LOST', 'Codex is offline; restart the host Bridge');
    if (method === 'approval/respond') {
      const id = text(params.id, 'id');
      const pending = this.liveApprovals.get(id);
      if (!pending) throw new BridgeError('APPROVAL_EXPIRED', 'Request is no longer pending');
      validateSchema(approvalSchemas[pending.method]!, object(params.result));
      const decisions = pending.params.availableDecisions;
      if (Array.isArray(decisions) && params.result.decision !== undefined && !decisions.some((decision: any) => JSON.stringify(decision) === JSON.stringify(params.result.decision))) throw new BridgeError('INVALID_DECISION', 'Decision is not offered by the host');
      this.codex.respond(pending.upstreamId, params.result);
      this.liveApprovals.delete(id); this.store.resolveApproval(id);
      this.publish('bridge/approvalResolved', { id });
      return {};
    }
    if (method.startsWith('terminal/')) return this.terminal(method, params);
    if (!codexMethods[method]) throw new BridgeError('METHOD_NOT_ALLOWED', 'This method is not exposed by Bridge Protocol v1');
    const input = structuredClone(params);
    const projectId = input.projectId as string | undefined;
    const permissionMode = input.permissionMode;
    const confirmed = input.confirmExternalStopped === true;
    delete input.projectId; delete input.permissionMode; delete input.confirmExternalStopped;
    for (const forbidden of ['config', 'baseInstructions', 'developerInstructions', 'history', 'path', 'dynamicTools', 'runtimeWorkspaceRoots', 'permissions', 'approvalPolicy', 'sandbox', 'sandboxPolicy']) {
      if (forbidden in input) throw new BridgeError('INVALID_PARAMS', `Field ${forbidden} is not accepted by the bridge`);
    }
    if (method === 'thread/list' && projectId) input.cwd = this.store.project(projectId).path;
    if (method === 'skills/list' && projectId) input.cwds = [this.store.project(projectId).path];
    if (['thread/start', 'thread/resume', 'thread/fork'].includes(method)) {
      const project = this.store.project(text(projectId, 'projectId'));
      const policy = await this.policy(permissionMode);
      input.cwd = project.path; input.sandbox = policy.sandbox; input.approvalPolicy = policy.approvalPolicy;
      if (method === 'thread/start') input.historyMode = 'legacy' satisfies ThreadHistoryMode;
      if (method === 'thread/resume' && !this.store.thread(text(input.threadId, 'threadId'))) {
        const source = await this.codex.request('thread/read', { threadId: input.threadId, includeTurns: true });
        if (source.thread?.status?.type === 'active' || source.thread?.turns?.some((turn: any) => turn.status === 'inProgress')) throw new BridgeError('THREAD_ACTIVE_ELSEWHERE', 'End the external task before resuming; fork to work independently');
        if (!confirmed) throw new BridgeError('CONFIRM_EXTERNAL_STOPPED', 'Confirm the other client has stopped this thread, or fork it');
      }
      if (method === 'thread/resume' && this.loaded.has(input.threadId)) return this.readThread({ threadId: input.threadId, includeTurns: true });
      validateSchema(codexMethods[method]!, input);
      const result = await this.codex.request(method, input);
      this.store.ownThread(result.thread.id, project.id); this.loaded.add(result.thread.id);
      if (this.store.thread(result.thread.id)?.state === 'unknown' && result.thread.status?.type !== 'active') this.store.threadState(result.thread.id, 'idle');
      return result;
    }
    if (['turn/start', 'turn/steer', 'turn/interrupt', 'thread/name/set', 'thread/archive', 'thread/unarchive'].includes(method)) {
      if (method === 'thread/unarchive' && !this.store.thread(text(input.threadId, 'threadId'))) {
        const project = this.store.project(text(projectId, 'projectId'));
        validateSchema(codexMethods[method]!, input);
        const result = await this.codex.request(method, input);
        this.store.ownThread(input.threadId, project.id);
        return result;
      }
      const owned = this.requireOwned(text(input.threadId, 'threadId'));
      if (projectId && owned.project !== projectId) throw new BridgeError('PROJECT_MISMATCH', 'Task belongs to another project');
      if (method === 'turn/start') {
        if (this.threadLocks.has(input.threadId) || ['running', 'starting'].includes(owned.state)) throw new BridgeError('THREAD_BUSY', 'Use steer or wait for the active turn');
        if (!this.loaded.has(input.threadId)) throw new BridgeError('THREAD_NOT_RESUMED', 'Open and resume the thread first');
        this.threadLocks.add(input.threadId);
        this.store.threadState(input.threadId, 'starting');
        try {
          const policy = await this.policy(permissionMode);
          const project = this.store.project(owned.project);
          input.approvalPolicy = policy.approvalPolicy;
          input.sandboxPolicy = policy.sandboxPolicy.type === 'workspaceWrite' ? { ...policy.sandboxPolicy, writableRoots: [project.path] } : policy.sandboxPolicy;
          input.cwd = project.path;
          if (!Array.isArray(input.input) || input.input.length === 0) throw new BridgeError('INVALID_PARAMS', 'At least one input is required');
          for (const item of input.input) {
            if (item.type === 'localImage') await this.workspace.locate(project.id, text(item.path, 'image path'));
            if (item.type === 'text') item.text_elements ??= [];
          }
          validateSchema(codexMethods[method]!, input);
          const result = await this.codex.request(method, input);
          if (this.store.thread(input.threadId)?.state === 'starting') this.store.threadState(input.threadId, 'running', result.turn?.id);
          return result;
        } catch (error) {
          this.store.threadState(input.threadId, error instanceof BridgeError && ['OUTCOME_UNKNOWN', 'UPSTREAM_LOST'].includes(error.code) ? 'unknown' : 'idle');
          throw error;
        } finally { this.threadLocks.delete(input.threadId); }
      }
      if (method === 'turn/steer') for (const item of input.input ?? []) if (item.type === 'text') item.text_elements ??= [];
    }
    validateSchema(codexMethods[method]!, input);
    if (method === 'thread/read') return this.readThread(input as ThreadReadParams);
    return this.codex.request(method, input);
  }
  private async terminal(method: string, params: ObjectMap): Promise<ObjectMap> {
    const project = this.store.project(text(params.projectId, 'projectId'));
    if (method === 'terminal/list') return { terminals: this.store.db.prepare('SELECT * FROM terminals WHERE project=? ORDER BY rowid DESC').all(project.id) };
    if (method === 'terminal/open') {
      const policy = await this.policy(params.permissionMode);
      const id = randomUUID();
      const input = {
        command: process.platform === 'win32' ? ['powershell.exe', '-NoLogo', '-NoProfile'] : ['/bin/bash', '--noprofile', '--norc'],
        processId: id, cwd: project.path, tty: true, streamStdin: true, streamStdoutStderr: true, disableTimeout: true,
        disableOutputCap: true, size: { cols: 90, rows: 24 },
        sandboxPolicy: policy.sandboxPolicy.type === 'workspaceWrite' ? { ...policy.sandboxPolicy, writableRoots: [project.path] } : policy.sandboxPolicy,
      };
      validateSchema('CommandExecParams', input);
      this.store.db.prepare("INSERT INTO terminals VALUES (?,?,?,'running','')").run(id, project.id, this.store.epoch);
      this.codex.request('command/exec', input, 0).then(result => {
        this.store.db.prepare("UPDATE terminals SET state='exited' WHERE id=?").run(id);
        this.publish('bridge/terminalExited', { processId: id, exitCode: result.exitCode });
      }).catch(error => {
        this.store.db.prepare("UPDATE terminals SET state='failed' WHERE id=?").run(id);
        this.publish('bridge/terminalExited', { processId: id, error: errorPayload(error) });
      });
      return { id, state: 'running', output: '' };
    }
    const id = text(params.id, 'terminal id');
    const terminal = this.store.db.prepare('SELECT * FROM terminals WHERE id=? AND project=?').get(id, project.id) as ObjectMap | undefined;
    if (!terminal) throw new BridgeError('TERMINAL_NOT_FOUND', 'Terminal does not belong to this project');
    if (method === 'terminal/read') return { ...terminal, cursor: this.store.cursor() };
    if (terminal.epoch !== this.store.epoch || terminal.state !== 'running') throw new BridgeError('TERMINAL_ENDED', 'Terminal has ended; commands will not be replayed');
    if (method === 'terminal/write') {
      const deltaBase64 = text(params.deltaBase64, 'input', 65536);
      return this.codex.request('command/exec/write', { processId: id, deltaBase64 } satisfies CommandExecWriteParams);
    }
    if (method === 'terminal/resize') {
      const size = { cols: params.cols, rows: params.rows };
      if (![size.cols, size.rows].every(value => Number.isInteger(value) && value >= 1 && value <= 1000)) throw new BridgeError('INVALID_PARAMS', 'Invalid terminal dimensions');
      return this.codex.request('command/exec/resize', { processId: id, size });
    }
    if (method === 'terminal/close') return this.codex.request('command/exec/terminate', { processId: id });
    throw new BridgeError('METHOD_NOT_ALLOWED', 'Unknown terminal operation');
  }
}
