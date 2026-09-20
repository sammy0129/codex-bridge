import { readFileSync, existsSync } from 'node:fs';
import { Ajv, type ValidateFunction } from 'ajv';
export type { ThreadReadParams } from './generated/v2/ThreadReadParams.js';
export type { ThreadHistoryMode } from './generated/v2/ThreadHistoryMode.js';
export type { CommandExecWriteParams } from './generated/v2/CommandExecWriteParams.js';
export type { TurnInterruptParams } from './generated/v2/TurnInterruptParams.js';

export const PROTOCOL_VERSION = 1;
export const CODEX_VERSION = '0.155.1';
export type ObjectMap = Record<string, any>;
export type BridgeRequest = { type: 'request'; requestId: string; method: string; params: ObjectMap };
export type BridgeEvent = { type: 'event'; epoch: string; seq: number; method: string; params: ObjectMap };
export class BridgeError extends Error {
  constructor(public code: string, message: string, public details?: unknown) { super(message); }
}
export const codexMethods: Record<string, string> = {
  'thread/list': 'ThreadListParams', 'thread/read': 'ThreadReadParams',
  'thread/start': 'ThreadStartParams', 'thread/resume': 'ThreadResumeParams',
  'thread/fork': 'ThreadForkParams', 'thread/name/set': 'ThreadSetNameParams',
  'thread/archive': 'ThreadArchiveParams', 'thread/unarchive': 'ThreadUnarchiveParams',
  'thread/delete': 'ThreadDeleteParams',
  'turn/start': 'TurnStartParams', 'turn/steer': 'TurnSteerParams', 'turn/interrupt': 'TurnInterruptParams',
  'model/list': 'ModelListParams', 'collaborationMode/list': 'CollaborationModeListParams',
  'skills/list': 'SkillsListParams', 'mcpServerStatus/list': 'ListMcpServerStatusParams',
  'configRequirements/read': 'EmptyParams', 'account/read': 'GetAccountParams',
};
export const approvalSchemas: Record<string, string> = {
  'item/commandExecution/requestApproval': 'CommandExecutionRequestApprovalResponse',
  'item/fileChange/requestApproval': 'FileChangeRequestApprovalResponse',
  'item/tool/requestUserInput': 'ToolRequestUserInputResponse',
  'mcpServer/elicitation/request': 'McpServerElicitationRequestResponse',
  'item/permissions/requestApproval': 'PermissionsRequestApprovalResponse',
};
const ajv = new Ajv({ strict: false, validateFormats: false, allErrors: true });
const validators = new Map<string, ValidateFunction>();
export function validateSchema(name: string, value: unknown): void {
  if (name === 'EmptyParams') {
    if (Object.keys(object(value)).length) throw new BridgeError('INVALID_PARAMS', 'Expected empty parameters');
    return;
  }
  let validator = validators.get(name);
  if (!validator) {
    const versioned = new URL(`../schema/v2/${name}.json`, import.meta.url);
    const location = existsSync(versioned) ? versioned : new URL(`../schema/${name}.json`, import.meta.url);
    const schema = JSON.parse(readFileSync(location, 'utf8'));
    validator = ajv.compile(schema);
    validators.set(name, validator);
  }
  if (!validator(value)) throw new BridgeError('INVALID_PARAMS', `Invalid ${name}`, validator.errors);
}
export function object(value: unknown): ObjectMap {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new BridgeError('INVALID_PARAMS', 'Expected an object');
  return value as ObjectMap;
}
export function text(value: unknown, name: string, max = 4096): string {
  if (typeof value !== 'string' || !value.length || value.length > max || value.includes('\0')) {
    throw new BridgeError('INVALID_PARAMS', `Invalid ${name}`);
  }
  return value;
}
export function parseRequest(value: unknown): BridgeRequest {
  const envelope = object(value);
  if (envelope.type !== 'request') throw new BridgeError('INVALID_REQUEST', 'Expected request envelope');
  text(envelope.requestId, 'requestId', 128);
  text(envelope.method, 'method', 128);
  object(envelope.params);
  return envelope as BridgeRequest;
}
export function errorPayload(error: unknown): ObjectMap {
  if (error instanceof BridgeError) return { code: error.code, message: error.message, details: error.details };
  return { code: 'INTERNAL_ERROR', message: 'Operation failed; inspect the host diagnostics.' };
}
