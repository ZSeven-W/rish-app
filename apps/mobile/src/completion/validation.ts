import { dshModelSupportsImages } from '../models/catalog';
import { LocalAttachments } from '../native/LocalAttachments';
import { isHarnessModelId } from '../harness/types';
import { parseProviderBinding } from '../providers/configuration';
import type {
  HarnessId,
  HarnessModelId,
  ProviderId,
} from '../harness/types';
import {
  harnessForModel,
  isHarnessId,
  isProviderId,
  providerForModel,
} from '../harness/types';
import type {
  CompleteRoundV2Request,
  CompleteRoundV2Result,
  CompleteRoundV3Request,
  CompleteRoundV3Result,
  CompleteV2Result,
  CompleteV2ToolCall,
  CompletionAttachmentReference,
  CompletionFinishReasonV2,
  CompletionProviderToolV2,
  CompletionProjectContextReceiptV3,
  CompletionProjectContextV3,
  CompletionRoundTranscriptMessageV2,
  CompletionVisibleMessageV2,
  DeepSeekThinkingMode,
} from './types';

export type CompletionResultErrorCode =
  | 'E_COMPLETION_RESULT_KEYS'
  | 'E_COMPLETION_RESULT_TYPE'
  | 'E_COMPLETION_RESULT_IDENTIFIER'
  | 'E_COMPLETION_RESULT_BOUNDS'
  | 'E_COMPLETION_RESULT_ENUM'
  | 'E_COMPLETION_RESULT_DIGEST'
  | 'E_COMPLETION_RESULT_RELATION'
  | 'E_COMPLETION_RESULT_CORRELATION'
  | 'E_COMPLETION_NATIVE';

type CompletionRequestErrorCode =
  | 'E_COMPLETION_SCHEMA'
  | 'E_COMPLETION_IDENTIFIER'
  | 'E_COMPLETION_ROUND'
  | 'E_COMPLETION_MODEL'
  | 'E_COMPLETION_THINKING'
  | 'E_COMPLETION_HISTORY'
  | 'E_COMPLETION_TRANSCRIPT'
  | 'E_COMPLETION_TOOLS'
  | 'E_COMPLETION_CONTEXT_INVALID'
  | 'E_COMPLETION_CONTEXT_UNSUPPORTED';

type StableCompletionErrorCode =
  | CompletionResultErrorCode
  | CompletionRequestErrorCode
  | NativeCompletionErrorCode
  | NativeProjectContextErrorCode;

const CLAUDE_LOCAL_ERROR_CODES = [
  'E_CLAUDE_OFFICIAL_TEXT_INVALID',
  'E_CLAUDE_OFFICIAL_TEXT_FAILED',
  'E_CLAUDE_OFFICIAL_TEXT_TIMEOUT',
  'E_CLAUDE_OFFICIAL_TEXT_CANCELLED',
  'E_CLAUDE_OFFICIAL_TEXT_BUSY',
  'E_CLAUDE_OFFICIAL_TEXT_AUTH_REQUIRED',
  'E_CLAUDE_ATTACHMENTS_UNSUPPORTED',
  'E_CLAUDE_TEXT_ONLY',
] as const;

type NativeCompletionErrorCode =
  | (typeof CLAUDE_LOCAL_ERROR_CODES)[number]
  | 'E_COMPLETION_CREDENTIAL_UNAVAILABLE'
  | 'E_COMPLETION_CREDENTIAL_CHANGED'
  | 'E_COMPLETION_BODY_INVALID'
  | 'E_COMPLETION_BODY_TOO_LARGE'
  | 'E_COMPLETION_BUSY'
  | 'E_COMPLETION_CANCELLED'
  | 'E_COMPLETION_REDIRECT'
  | 'E_COMPLETION_TIMEOUT'
  | 'E_COMPLETION_TRANSPORT'
  | 'E_COMPLETION_HTTP_STATUS'
  | 'E_COMPLETION_HTTP_429'
  | 'E_COMPLETION_RESPONSE_SIZE'
  | 'E_COMPLETION_RESPONSE_JSON'
  | 'E_COMPLETION_PROVIDER_REQUEST_ID'
  | 'E_COMPLETION_PROVIDER_RESPONSE_ID'
  | 'E_COMPLETION_RESPONSE_MODEL'
  | 'E_COMPLETION_MODEL_MISMATCH'
  | 'E_COMPLETION_FINISH_RELATION'
  | 'E_COMPLETION_LENGTH'
  | 'E_COMPLETION_TOOL_CALL_INVALID'
  | 'E_COMPLETION_EMPTY_RESPONSE';

type NativeProjectContextErrorCode =
  | 'E_PROJECT_NOT_FOUND'
  | 'E_CONTEXT_CHANGED'
  | 'E_CONTEXT_SECRET'
  | 'E_CONTEXT_BUDGET'
  | 'E_CONTEXT_STORAGE'
  | 'E_CONTEXT_TIMEOUT'
  | 'E_CONTEXT_CONSENT_INVALID'
  | 'E_CONTEXT_INTEGRITY'
  | 'E_CONTEXT_SNAPSHOT_MISSING';

export class CompletionBridgeError extends Error {
  readonly code: StableCompletionErrorCode;

  constructor(code: StableCompletionErrorCode) {
    super(code);
    this.name = 'CompletionBridgeError';
    this.code = code;
  }
}

const MAX_ROUND_INDEX = 7;
const MAX_VISIBLE_MESSAGES = 200;
const MAX_VISIBLE_HISTORY_BYTES = 2 * 1024 * 1024;
const MAX_MESSAGE_BYTES = 256 * 1024;
const MAX_ATTACHMENT_BYTES = 24 * 1024 * 1024;
const MAX_ATTACHMENTS_PER_MESSAGE = 6;
const MAX_ATTACHMENTS_PER_REQUEST = 24;
const MAX_TOOL_COUNT = 32;
const MAX_TOOL_CALLS = 16;
const MAX_TOOL_NAME_BYTES = 64;
const MAX_TOOL_DESCRIPTION_LENGTH = 1024;
const MAX_TOOL_SCHEMA_BYTES = 6144;
const MAX_TOOL_SCHEMA_NODES = 1024;
const MAX_TOOL_ARGUMENT_BYTES = 32_768;
const MAX_OPAQUE_ID_BYTES = 128;
const MAX_TRANSCRIPT_BYTES = 4 * 1024 * 1024;

type JSONValue =
  | null
  | boolean
  | number
  | string
  | JSONValue[]
  | { [key: string]: JSONValue };

type JSONProjectionBudget = { nodes: number };

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const OPAQUE_ID_PATTERN = /^[A-Za-z0-9._:-]+$/;
const TOOL_NAME_PATTERN = /^[A-Za-z0-9_-]+$/;

const THINKING_MODES: ReadonlySet<string> = new Set(['off', 'high', 'max']);
const FINISH_REASONS: ReadonlySet<string> = new Set([
  'stop',
  'tool_calls',
  'length',
  'content_filter',
]);

const NATIVE_ERROR_CODES: ReadonlySet<string> = new Set([
  ...CLAUDE_LOCAL_ERROR_CODES,
  'E_COMPLETION_SCHEMA',
  'E_COMPLETION_IDENTIFIER',
  'E_COMPLETION_ROUND',
  'E_COMPLETION_MODEL',
  'E_COMPLETION_THINKING',
  'E_COMPLETION_HISTORY',
  'E_COMPLETION_TRANSCRIPT',
  'E_COMPLETION_TOOLS',
  'E_COMPLETION_CONTEXT_INVALID',
  'E_COMPLETION_CONTEXT_UNSUPPORTED',
  'E_COMPLETION_CREDENTIAL_UNAVAILABLE',
  'E_COMPLETION_CREDENTIAL_CHANGED',
  'E_COMPLETION_BODY_INVALID',
  'E_COMPLETION_BODY_TOO_LARGE',
  'E_COMPLETION_BUSY',
  'E_COMPLETION_CANCELLED',
  'E_COMPLETION_REDIRECT',
  'E_COMPLETION_TIMEOUT',
  'E_COMPLETION_TRANSPORT',
  'E_COMPLETION_HTTP_STATUS',
  'E_COMPLETION_HTTP_429',
  'E_COMPLETION_RESPONSE_SIZE',
  'E_COMPLETION_RESPONSE_JSON',
  'E_COMPLETION_PROVIDER_REQUEST_ID',
  'E_COMPLETION_PROVIDER_RESPONSE_ID',
  'E_COMPLETION_RESPONSE_MODEL',
  'E_COMPLETION_MODEL_MISMATCH',
  'E_COMPLETION_FINISH_RELATION',
  'E_COMPLETION_LENGTH',
  'E_COMPLETION_TOOL_CALL_INVALID',
  'E_COMPLETION_EMPTY_RESPONSE',
  'E_PROJECT_NOT_FOUND',
  'E_CONTEXT_CHANGED',
  'E_CONTEXT_SECRET',
  'E_CONTEXT_BUDGET',
  'E_CONTEXT_STORAGE',
  'E_CONTEXT_TIMEOUT',
  'E_CONTEXT_CONSENT_INVALID',
  'E_CONTEXT_INTEGRITY',
  'E_CONTEXT_SNAPSHOT_MISSING',
]);

function isNativeErrorCode(
  value: string,
): value is
  | CompletionRequestErrorCode
  | NativeCompletionErrorCode
  | NativeProjectContextErrorCode {
  return NATIVE_ERROR_CODES.has(value);
}

const RESULT_ERROR_CODES: ReadonlySet<string> = new Set([
  'E_COMPLETION_RESULT_KEYS',
  'E_COMPLETION_RESULT_TYPE',
  'E_COMPLETION_RESULT_IDENTIFIER',
  'E_COMPLETION_RESULT_BOUNDS',
  'E_COMPLETION_RESULT_ENUM',
  'E_COMPLETION_RESULT_DIGEST',
  'E_COMPLETION_RESULT_RELATION',
  'E_COMPLETION_RESULT_CORRELATION',
  'E_COMPLETION_NATIVE',
]);

function isStableCompletionErrorCode(
  value: unknown,
): value is StableCompletionErrorCode {
  return (
    typeof value === 'string' &&
    (NATIVE_ERROR_CODES.has(value) || RESULT_ERROR_CODES.has(value))
  );
}

const LEGACY_NATIVE_ERROR_MAP: Readonly<
  Record<string, StableCompletionErrorCode>
> = Object.freeze({
  model: 'E_COMPLETION_MODEL',
  request: 'E_COMPLETION_SCHEMA',
  thinking: 'E_COMPLETION_THINKING',
  history: 'E_COMPLETION_HISTORY',
  tools: 'E_COMPLETION_TOOLS',
  credential: 'E_COMPLETION_CREDENTIAL_UNAVAILABLE',
  transport: 'E_COMPLETION_TRANSPORT',
  response: 'E_COMPLETION_RESPONSE_JSON',
  api: 'E_COMPLETION_HTTP_STATUS',
  cancelled: 'E_COMPLETION_CANCELLED',
});

const SCHEMA2_RESULT_KEYS = [
  'schema_version',
  'turn_id',
  'attempt_id',
  'round_id',
  'round_index',
  'provider_request_id',
  'provider_response_id',
  'requested_model',
  'model',
  'thinking_mode',
  'text',
  'reasoning',
  'tool_calls',
  'finish_reason',
  'latency_ms',
  'visible_history_sha256',
  'model_input_sha256',
  'request_body_sha256',
  'project_context_receipt',
] as const;

const SCHEMA3_CONTEXT_KEYS = [
  'schemaVersion',
  'snapshotId',
  'consentReceiptId',
  'conversationId',
  'projectId',
  'provider',
  'policy',
] as const;

const SCHEMA3_RECEIPT_KEYS = [
  'schema_version',
  'snapshot_id',
  'snapshot_sha256',
  'source_fingerprint',
  'context_bytes',
  'verified_at',
] as const;

const SCHEMA1_RESULT_KEYS = [
  'schema_version',
  'text',
  'tool_calls',
  'finish_reason',
  'model',
  'request_id',
  'latency_ms',
  'reasoning',
  'thinking_mode',
] as const;

function fail(code: StableCompletionErrorCode): never {
  throw new CompletionBridgeError(code);
}

function withStableFailure<T>(
  fallback: StableCompletionErrorCode,
  operation: () => T,
): T {
  try {
    return operation();
  } catch (error) {
    let stableCode: StableCompletionErrorCode | null = null;
    try {
      if (
        error instanceof CompletionBridgeError &&
        isStableCompletionErrorCode(error.code)
      ) {
        stableCode = error.code;
      }
    } catch {
      stableCode = null;
    }
    if (stableCode !== null) throw new CompletionBridgeError(stableCode);
    fail(fallback);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function hasExactKeys(
  value: Record<string, unknown>,
  expected: readonly string[],
): boolean {
  const actual = Object.keys(value);
  return (
    actual.length === expected.length &&
    expected.every(key => Object.prototype.hasOwnProperty.call(value, key))
  );
}

/**
 * Hermes-safe UTF-8 byte count. Invalid UTF-16 is rejected instead of being
 * silently replaced, so JS and Foundation validate the same bytes.
 */
export function utf8ByteLength(value: string): number | null {
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit <= 0x7f) {
      bytes += 1;
    } else if (unit <= 0x7ff) {
      bytes += 2;
    } else if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return null;
      bytes += 4;
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return null;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

function boundedString(value: unknown, maximum: number): value is string {
  if (typeof value !== 'string') return false;
  const size = utf8ByteLength(value);
  return size !== null && size <= maximum;
}

function canonicalUUID(value: unknown): value is string {
  return typeof value === 'string' && UUID_PATTERN.test(value);
}

function isoTimestamp(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.length <= 64 &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/u.test(
      value,
    ) &&
    Number.isFinite(Date.parse(value))
  );
}

function opaqueIdentifier(value: unknown): value is string {
  if (typeof value !== 'string' || !OPAQUE_ID_PATTERN.test(value)) return false;
  const size = utf8ByteLength(value);
  return size !== null && size >= 1 && size <= MAX_OPAQUE_ID_BYTES;
}

function validToolName(value: unknown): value is string {
  if (typeof value !== 'string' || !TOOL_NAME_PATTERN.test(value)) return false;
  const size = utf8ByteLength(value);
  return size !== null && size >= 1 && size <= MAX_TOOL_NAME_BYTES;
}

function validModel(value: unknown): value is HarnessModelId {
  return typeof value === 'string' && isHarnessModelId(value);
}

function validHarnessId(value: unknown): value is HarnessId {
  return isHarnessId(value);
}

function validThinkingMode(value: unknown): value is DeepSeekThinkingMode {
  return typeof value === 'string' && THINKING_MODES.has(value);
}

function validFinishReason(value: unknown): value is CompletionFinishReasonV2 {
  return typeof value === 'string' && FINISH_REASONS.has(value);
}

function safeJSONStringify(
  value: unknown,
  code: CompletionRequestErrorCode,
): string {
  try {
    const encoded = JSON.stringify(value);
    if (typeof encoded !== 'string') fail(code);
    return encoded;
  } catch {
    fail(code);
  }
}

function projectJSONValue(
  value: unknown,
  ancestors: Set<object>,
  budget: JSONProjectionBudget,
  depth: number,
): JSONValue {
  budget.nodes += 1;
  if (budget.nodes > MAX_TOOL_SCHEMA_NODES) fail('E_COMPLETION_TOOLS');
  if (depth > 64) fail('E_COMPLETION_TOOLS');
  if (value === null || typeof value === 'boolean') return value;
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) fail('E_COMPLETION_TOOLS');
    return value;
  }
  if (typeof value === 'string') {
    if (utf8ByteLength(value) === null) fail('E_COMPLETION_TOOLS');
    return value;
  }
  if (typeof value !== 'object') fail('E_COMPLETION_TOOLS');
  if (ancestors.has(value)) fail('E_COMPLETION_TOOLS');
  ancestors.add(value);
  if (Array.isArray(value)) {
    const projected: JSONValue[] = [];
    for (let index = 0; index < value.length; index += 1) {
      if (!Object.prototype.hasOwnProperty.call(value, index)) {
        fail('E_COMPLETION_TOOLS');
      }
      projected.push(
        projectJSONValue(value[index], ancestors, budget, depth + 1),
      );
    }
    ancestors.delete(value);
    return projected;
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    fail('E_COMPLETION_TOOLS');
  }
  if (Object.getOwnPropertySymbols(value).length > 0) {
    fail('E_COMPLETION_TOOLS');
  }
  const projected: { [key: string]: JSONValue } = {};
  for (const key of Object.keys(value)) {
    if (utf8ByteLength(key) === null) fail('E_COMPLETION_TOOLS');
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (descriptor === undefined || !('value' in descriptor)) {
      fail('E_COMPLETION_TOOLS');
    }
    Object.defineProperty(projected, key, {
      configurable: true,
      enumerable: true,
      writable: true,
      value: projectJSONValue(
        descriptor.value,
        ancestors,
        budget,
        depth + 1,
      ),
    });
  }
  ancestors.delete(value);
  return projected;
}

function projectAttachment(value: unknown): CompletionAttachmentReference {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      'schema_version',
      'id',
      'kind',
      'name',
      'mime_type',
      'size',
    ]) ||
    value.schema_version !== 1 ||
    !canonicalUUID(value.id) ||
    (value.kind !== 'image' && value.kind !== 'text' && value.kind !== 'pdf') ||
    !boundedString(value.name, 512) ||
    value.name.length === 0 ||
    !boundedString(value.mime_type, 128) ||
    value.mime_type.length === 0 ||
    !Number.isSafeInteger(value.size) ||
    typeof value.size !== 'number' ||
    value.size < 1 ||
    value.size > MAX_ATTACHMENT_BYTES
  ) {
    fail('E_COMPLETION_HISTORY');
  }
  return {
    schema_version: 1,
    id: value.id,
    kind: value.kind,
    name: value.name,
    mime_type: value.mime_type,
    size: value.size,
  };
}

function projectVisibleHistory(
  value: unknown,
  model: HarnessModelId,
): CompletionVisibleMessageV2[] {
  if (
    !Array.isArray(value) ||
    value.length < 1 ||
    value.length > MAX_VISIBLE_MESSAGES
  ) {
    fail('E_COMPLETION_HISTORY');
  }
  let totalBytes = 0;
  let totalAttachmentBytes = 0;
  let totalAttachmentCount = 0;
  const projected = value.map(message => {
    if (
      !isRecord(message) ||
      !hasExactKeys(message, ['role', 'content', 'attachments']) ||
      (message.role !== 'user' && message.role !== 'assistant') ||
      !boundedString(message.content, MAX_MESSAGE_BYTES) ||
      !Array.isArray(message.attachments) ||
      message.attachments.length > MAX_ATTACHMENTS_PER_MESSAGE
    ) {
      fail('E_COMPLETION_HISTORY');
    }
    const contentBytes = utf8ByteLength(message.content);
    if (contentBytes === null) fail('E_COMPLETION_HISTORY');
    totalBytes += contentBytes;
    if (totalBytes > MAX_VISIBLE_HISTORY_BYTES) fail('E_COMPLETION_HISTORY');
    const attachments = message.attachments.map(projectAttachment);
    const attachmentIds = new Set(attachments.map(item => item.id));
    if (attachmentIds.size !== attachments.length) {
      fail('E_COMPLETION_HISTORY');
    }
    totalAttachmentCount += attachments.length;
    if (totalAttachmentCount > MAX_ATTACHMENTS_PER_REQUEST) {
      fail('E_COMPLETION_HISTORY');
    }
    for (const attachment of attachments) {
      if (
        attachment.size > MAX_ATTACHMENT_BYTES - totalAttachmentBytes ||
        (LocalAttachments.kindNeedsVision(attachment.kind) &&
          !dshModelSupportsImages(model))
      ) {
        fail('E_COMPLETION_HISTORY');
      }
      totalAttachmentBytes += attachment.size;
    }
    if (message.role === 'assistant' && attachments.length > 0) {
      fail('E_COMPLETION_HISTORY');
    }
    if (
      message.content.trim().length === 0 &&
      (message.role !== 'user' || attachments.length === 0)
    ) {
      fail('E_COMPLETION_HISTORY');
    }
    const role: 'user' | 'assistant' =
      message.role === 'user' ? 'user' : 'assistant';
    return {
      role,
      content: message.content,
      attachments,
    };
  });
  if (projected.at(-1)?.role !== 'user') fail('E_COMPLETION_HISTORY');
  return projected;
}

function projectProviderTools(value: unknown): CompletionProviderToolV2[] {
  if (!Array.isArray(value) || value.length > MAX_TOOL_COUNT) {
    fail('E_COMPLETION_TOOLS');
  }
  return value.map(tool => {
    if (
      !isRecord(tool) ||
      !hasExactKeys(tool, ['type', 'function']) ||
      tool.type !== 'function' ||
      !isRecord(tool.function) ||
      !hasExactKeys(tool.function, [
        'name',
        'description',
        'parameters',
      ]) ||
      !validToolName(tool.function.name) ||
      typeof tool.function.description !== 'string' ||
      tool.function.description.length > MAX_TOOL_DESCRIPTION_LENGTH ||
      utf8ByteLength(tool.function.description) === null ||
      !isRecord(tool.function.parameters)
    ) {
      fail('E_COMPLETION_TOOLS');
    }
    const parameters = projectJSONValue(
      tool.function.parameters,
      new Set<object>(),
      { nodes: 0 },
      0,
    );
    if (!isRecord(parameters)) fail('E_COMPLETION_TOOLS');
    const parameterJSON = safeJSONStringify(parameters, 'E_COMPLETION_TOOLS');
    const parameterBytes = utf8ByteLength(parameterJSON);
    if (parameterBytes === null || parameterBytes > MAX_TOOL_SCHEMA_BYTES) {
      fail('E_COMPLETION_TOOLS');
    }
    return {
      type: 'function',
      function: {
        name: tool.function.name,
        description: tool.function.description,
        parameters,
      },
    };
  });
}

function projectTranscript(
  value: unknown,
  roundIndex: number,
): CompletionRoundTranscriptMessageV2[] {
  if (!Array.isArray(value)) fail('E_COMPLETION_TRANSCRIPT');
  const projected: CompletionRoundTranscriptMessageV2[] = [];
  const callIds = new Set<string>();
  let groups = 0;
  let cursor = 0;
  let totalBytes = 0;
  while (cursor < value.length) {
    const assistant = value[cursor];
    if (
      !isRecord(assistant) ||
      !hasExactKeys(assistant, [
        'role',
        'content',
        'reasoning_content',
        'tool_calls',
      ]) ||
      assistant.role !== 'assistant' ||
      !boundedString(assistant.content, MAX_MESSAGE_BYTES) ||
      !boundedString(assistant.reasoning_content, MAX_MESSAGE_BYTES) ||
      !Array.isArray(assistant.tool_calls) ||
      assistant.tool_calls.length < 1 ||
      assistant.tool_calls.length > MAX_TOOL_CALLS
    ) {
      fail('E_COMPLETION_TRANSCRIPT');
    }
    const contentBytes = utf8ByteLength(assistant.content);
    const reasoningBytes = utf8ByteLength(assistant.reasoning_content);
    if (contentBytes === null || reasoningBytes === null) {
      fail('E_COMPLETION_TRANSCRIPT');
    }
    totalBytes += contentBytes + reasoningBytes;
    if (totalBytes > MAX_TRANSCRIPT_BYTES) {
      fail('E_COMPLETION_TRANSCRIPT');
    }
    const projectedCalls = assistant.tool_calls.map(call => {
      if (
        !isRecord(call) ||
        !hasExactKeys(call, ['id', 'type', 'function']) ||
        !opaqueIdentifier(call.id) ||
        callIds.has(call.id) ||
        call.type !== 'function' ||
        !isRecord(call.function) ||
        !hasExactKeys(call.function, ['name', 'arguments']) ||
        !validToolName(call.function.name) ||
        !boundedString(call.function.arguments, MAX_TOOL_ARGUMENT_BYTES)
      ) {
        fail('E_COMPLETION_TRANSCRIPT');
      }
      callIds.add(call.id);
      return {
        id: call.id,
        type: 'function' as const,
        function: {
          name: call.function.name,
          arguments: call.function.arguments,
        },
      };
    });
    projected.push({
      role: 'assistant',
      content: assistant.content,
      reasoning_content: assistant.reasoning_content,
      tool_calls: projectedCalls,
    });
    cursor += 1;
    for (const call of projectedCalls) {
      const tool = value[cursor];
      if (
        !isRecord(tool) ||
        !hasExactKeys(tool, ['role', 'tool_call_id', 'content']) ||
        tool.role !== 'tool' ||
        tool.tool_call_id !== call.id ||
        !boundedString(tool.content, MAX_MESSAGE_BYTES)
      ) {
        fail('E_COMPLETION_TRANSCRIPT');
      }
      const toolBytes = utf8ByteLength(tool.content);
      if (toolBytes === null) fail('E_COMPLETION_TRANSCRIPT');
      totalBytes += toolBytes;
      if (totalBytes > MAX_TRANSCRIPT_BYTES) {
        fail('E_COMPLETION_TRANSCRIPT');
      }
      projected.push({
        role: 'tool',
        tool_call_id: tool.tool_call_id,
        content: tool.content,
      });
      cursor += 1;
    }
    groups += 1;
  }
  if (groups !== roundIndex || (roundIndex === 0 && projected.length !== 0)) {
    fail('E_COMPLETION_TRANSCRIPT');
  }
  return projected;
}

function projectSchema3Context(
  value: unknown,
): CompletionProjectContextV3 {
  if (!isRecord(value) || !hasExactKeys(value, SCHEMA3_CONTEXT_KEYS)) {
    fail('E_COMPLETION_CONTEXT_INVALID');
  }
  if (
    value.schemaVersion !== 1 ||
    !canonicalUUID(value.snapshotId) ||
    !canonicalUUID(value.consentReceiptId) ||
    !canonicalUUID(value.conversationId) ||
    !canonicalUUID(value.projectId) ||
    !isProviderId(value.provider) ||
    value.policy !== 'chat-read-v1'
  ) {
    fail('E_COMPLETION_CONTEXT_INVALID');
  }
  return {
    schemaVersion: 1,
    snapshotId: value.snapshotId,
    consentReceiptId: value.consentReceiptId,
    conversationId: value.conversationId,
    projectId: value.projectId,
    provider: value.provider as ProviderId,
    policy: 'chat-read-v1',
  };
}

/** Projects a typed request into the exact native snake-case wire. */
function encodeCompleteV2RequestUnsafe(
  request: CompleteRoundV2Request,
  harnessId: HarnessId,
): string {
  if (request.schemaVersion !== 2) fail('E_COMPLETION_SCHEMA');
  const identifiersValid = withStableFailure('E_COMPLETION_IDENTIFIER', () =>
    canonicalUUID(request.turnId) &&
    canonicalUUID(request.attemptId) &&
    canonicalUUID(request.roundId),
  );
  if (!identifiersValid) {
    fail('E_COMPLETION_IDENTIFIER');
  }
  const roundValid = withStableFailure('E_COMPLETION_ROUND', () =>
    Number.isSafeInteger(request.roundIndex) &&
    request.roundIndex >= 0 &&
    request.roundIndex <= MAX_ROUND_INDEX,
  );
  if (!roundValid) {
    fail('E_COMPLETION_ROUND');
  }
  if (!withStableFailure('E_COMPLETION_MODEL', () => validModel(request.model))) {
    fail('E_COMPLETION_MODEL');
  }
  if (
    !withStableFailure('E_COMPLETION_THINKING', () =>
      validThinkingMode(request.thinkingMode),
    )
  ) {
    fail('E_COMPLETION_THINKING');
  }
  if (
    !withStableFailure(
      'E_COMPLETION_MODEL',
      () =>
        validHarnessId(harnessId) &&
        harnessForModel(request.model) === harnessId,
    )
  ) {
    fail('E_COMPLETION_MODEL');
  }
  if (
    !withStableFailure(
      'E_COMPLETION_CONTEXT_UNSUPPORTED',
      () => request.projectContext === null,
    )
  ) {
    fail('E_COMPLETION_CONTEXT_UNSUPPORTED');
  }

  const visibleHistory = withStableFailure('E_COMPLETION_HISTORY', () =>
    projectVisibleHistory(request.visibleHistory, request.model),
  );
  const roundTranscript = withStableFailure('E_COMPLETION_TRANSCRIPT', () =>
    projectTranscript(request.roundTranscript, request.roundIndex),
  );
  const tools = withStableFailure('E_COMPLETION_TOOLS', () =>
    projectProviderTools(request.tools),
  );
  return safeJSONStringify(
    {
      schema_version: 2,
      harness_id: harnessId,
      turn_id: request.turnId,
      attempt_id: request.attemptId,
      round_id: request.roundId,
      round_index: request.roundIndex,
      model: request.model,
      thinking_mode: request.thinkingMode,
      visible_history: visibleHistory,
      round_transcript: roundTranscript,
      tools,
      project_context: null,
    },
    'E_COMPLETION_SCHEMA',
  );
}

export function encodeCompleteV2Request(
  request: CompleteRoundV2Request,
  harnessId: HarnessId = 'dsh',
): string {
  return withStableFailure('E_COMPLETION_SCHEMA', () =>
    encodeCompleteV2RequestUnsafe(request, harnessId),
  );
}

function encodeCompleteV3RequestUnsafe(
  request: CompleteRoundV3Request,
  harnessId: HarnessId,
): string {
  if (request.schemaVersion !== 3) fail('E_COMPLETION_SCHEMA');
  const identifiersValid = withStableFailure('E_COMPLETION_IDENTIFIER', () =>
    canonicalUUID(request.turnId) &&
    canonicalUUID(request.attemptId) &&
    canonicalUUID(request.roundId),
  );
  if (!identifiersValid) fail('E_COMPLETION_IDENTIFIER');
  if (
    !withStableFailure('E_COMPLETION_ROUND', () =>
      Number.isSafeInteger(request.roundIndex) &&
      !Object.is(request.roundIndex, -0) &&
      request.roundIndex >= 0 &&
      request.roundIndex <= MAX_ROUND_INDEX,
    )
  ) {
    fail('E_COMPLETION_ROUND');
  }
  if (!withStableFailure('E_COMPLETION_MODEL', () => validModel(request.model))) {
    fail('E_COMPLETION_MODEL');
  }
  if (
    !withStableFailure('E_COMPLETION_THINKING', () =>
      validThinkingMode(request.thinkingMode),
    )
  ) {
    fail('E_COMPLETION_THINKING');
  }
  if (
    !withStableFailure(
      'E_COMPLETION_MODEL',
      () =>
        validHarnessId(harnessId) &&
        harnessForModel(request.model) === harnessId,
    )
  ) {
    fail('E_COMPLETION_MODEL');
  }
  const context = withStableFailure('E_COMPLETION_CONTEXT_INVALID', () =>
    projectSchema3Context(request.projectContext),
  );
  if (
    !withStableFailure(
      'E_COMPLETION_CONTEXT_INVALID',
      () => providerForModel(request.model) === context.provider,
    )
  ) {
    fail('E_COMPLETION_CONTEXT_INVALID');
  }
  const visibleHistory = withStableFailure('E_COMPLETION_HISTORY', () =>
    projectVisibleHistory(request.visibleHistory, request.model),
  );
  const roundTranscript = withStableFailure('E_COMPLETION_TRANSCRIPT', () =>
    projectTranscript(request.roundTranscript, request.roundIndex),
  );
  const tools = withStableFailure('E_COMPLETION_TOOLS', () =>
    projectProviderTools(request.tools),
  );
  return safeJSONStringify(
    {
      schema_version: 3,
      harness_id: harnessId,
      turn_id: request.turnId,
      attempt_id: request.attemptId,
      round_id: request.roundId,
      round_index: request.roundIndex,
      model: request.model,
      thinking_mode: request.thinkingMode,
      visible_history: visibleHistory,
      round_transcript: roundTranscript,
      tools,
      project_context: {
        schema_version: 1,
        snapshot_id: context.snapshotId,
        consent_receipt_id: context.consentReceiptId,
        conversation_id: context.conversationId,
        project_id: context.projectId,
        provider: context.provider,
        policy: context.policy,
      },
    },
    'E_COMPLETION_SCHEMA',
  );
}

export function encodeCompleteV3Request(
  request: CompleteRoundV3Request,
  harnessId: HarnessId = 'dsh',
): string {
  return withStableFailure('E_COMPLETION_SCHEMA', () =>
    encodeCompleteV3RequestUnsafe(request, harnessId),
  );
}

function resultRecord(
  value: unknown,
  keys: readonly string[],
): Record<string, unknown> {
  if (!isRecord(value) || !hasExactKeys(value, keys)) {
    fail('E_COMPLETION_RESULT_KEYS');
  }
  return value;
}

/// Like resultRecord, but tolerates optional wire keys added after the
/// schema shipped (currently only `harness_id`). Optional keys are
/// validated when present and normalized to a default when absent.
function resultRecordWithOptionalKeys(
  value: unknown,
  keys: readonly string[],
  optionalKeys: readonly string[],
): Record<string, unknown> {
  if (!isRecord(value)) fail('E_COMPLETION_RESULT_KEYS');
  for (const key of Object.keys(value)) {
    if (!keys.includes(key) && !optionalKeys.includes(key)) {
      fail('E_COMPLETION_RESULT_KEYS');
    }
  }
  for (const key of keys) {
    if (!Object.prototype.hasOwnProperty.call(value, key)) {
      fail('E_COMPLETION_RESULT_KEYS');
    }
  }
  return value;
}

function projectResultHarnessId(value: unknown): HarnessId {
  if (value === undefined) return 'dsh';
  if (!validHarnessId(value)) fail('E_COMPLETION_RESULT_ENUM');
  return value;
}

function projectLegacyToolCalls(value: unknown): CompleteV2ToolCall[] {
  if (!Array.isArray(value)) fail('E_COMPLETION_RESULT_TYPE');
  if (value.length > MAX_TOOL_CALLS) fail('E_COMPLETION_RESULT_BOUNDS');
  return value.map(call => {
    if (!isRecord(call) || !hasExactKeys(call, ['id', 'name', 'arguments'])) {
      fail('E_COMPLETION_RESULT_KEYS');
    }
    if (
      typeof call.id !== 'string' ||
      call.id.length < 1 ||
      call.id.length > MAX_OPAQUE_ID_BYTES ||
      typeof call.name !== 'string' ||
      call.name.length < 1 ||
      call.name.length > 128 ||
      typeof call.arguments !== 'string'
    ) {
      fail('E_COMPLETION_RESULT_TYPE');
    }
    if (!boundedString(call.arguments, MAX_TOOL_ARGUMENT_BYTES)) {
      fail('E_COMPLETION_RESULT_BOUNDS');
    }
    return {
      id: call.id,
      name: call.name,
      arguments: call.arguments,
    };
  });
}

function projectResultToolCalls(value: unknown): CompleteV2ToolCall[] {
  if (!Array.isArray(value)) fail('E_COMPLETION_RESULT_TYPE');
  if (value.length > MAX_TOOL_CALLS) fail('E_COMPLETION_RESULT_BOUNDS');
  const identifiers = new Set<string>();
  return value.map(call => {
    if (!isRecord(call) || !hasExactKeys(call, ['id', 'name', 'arguments'])) {
      fail('E_COMPLETION_RESULT_KEYS');
    }
    if (!opaqueIdentifier(call.id) || !validToolName(call.name)) {
      fail('E_COMPLETION_RESULT_IDENTIFIER');
    }
    if (identifiers.has(call.id)) fail('E_COMPLETION_RESULT_RELATION');
    identifiers.add(call.id);
    if (typeof call.arguments !== 'string') fail('E_COMPLETION_RESULT_TYPE');
    if (!boundedString(call.arguments, MAX_TOOL_ARGUMENT_BYTES)) {
      fail('E_COMPLETION_RESULT_BOUNDS');
    }
    return {
      id: call.id,
      name: call.name,
      arguments: call.arguments,
    };
  });
}

function validateCompleteV2ResultUnsafe(
  value: unknown,
  request: CompleteRoundV2Request,
): CompleteRoundV2Result {
  const result = resultRecordWithOptionalKeys(value, SCHEMA2_RESULT_KEYS, [
    'harness_id', 'provider_configuration',
  ]);
  const harnessId = projectResultHarnessId(result.harness_id);
  const providerConfiguration = result.provider_configuration === undefined ? undefined :
    parseProviderBinding(result.provider_configuration, request.model);
  if (providerConfiguration === null) fail('E_COMPLETION_RESULT_RELATION');
  if (harnessId !== request.harnessId) fail('E_COMPLETION_MODEL_MISMATCH');
  if (
    typeof result.schema_version !== 'number' ||
    typeof result.round_index !== 'number' ||
    typeof result.latency_ms !== 'number' ||
    typeof result.turn_id !== 'string' ||
    typeof result.attempt_id !== 'string' ||
    typeof result.round_id !== 'string' ||
    typeof result.provider_request_id !== 'string' ||
    typeof result.provider_response_id !== 'string' ||
    typeof result.requested_model !== 'string' ||
    typeof result.model !== 'string' ||
    typeof result.thinking_mode !== 'string' ||
    typeof result.text !== 'string' ||
    typeof result.reasoning !== 'string' ||
    typeof result.finish_reason !== 'string' ||
    typeof result.visible_history_sha256 !== 'string' ||
    typeof result.model_input_sha256 !== 'string' ||
    typeof result.request_body_sha256 !== 'string' ||
    result.project_context_receipt !== null
  ) {
    fail('E_COMPLETION_RESULT_TYPE');
  }
  if (result.schema_version !== 2) fail('E_COMPLETION_RESULT_ENUM');
  if (
    !canonicalUUID(result.turn_id) ||
    !canonicalUUID(result.attempt_id) ||
    !canonicalUUID(result.round_id) ||
    !canonicalUUID(result.provider_request_id) ||
    !opaqueIdentifier(result.provider_response_id)
  ) {
    fail('E_COMPLETION_RESULT_IDENTIFIER');
  }
  if (
    !Number.isSafeInteger(result.round_index) ||
    result.round_index < 0 ||
    result.round_index > MAX_ROUND_INDEX ||
    !Number.isSafeInteger(result.latency_ms) ||
    result.latency_ms < 0 ||
    !boundedString(result.text, MAX_MESSAGE_BYTES) ||
    !boundedString(result.reasoning, MAX_MESSAGE_BYTES)
  ) {
    fail('E_COMPLETION_RESULT_BOUNDS');
  }
  if (
    !validModel(result.requested_model) ||
    !validModel(result.model) ||
    !validThinkingMode(result.thinking_mode) ||
    !validFinishReason(result.finish_reason)
  ) {
    fail('E_COMPLETION_RESULT_ENUM');
  }
  if (
    !SHA256_PATTERN.test(result.visible_history_sha256) ||
    !SHA256_PATTERN.test(result.model_input_sha256) ||
    !SHA256_PATTERN.test(result.request_body_sha256)
  ) {
    fail('E_COMPLETION_RESULT_DIGEST');
  }
  if (
    result.turn_id !== request.turnId ||
    result.attempt_id !== request.attemptId ||
    result.round_id !== request.roundId ||
    result.round_index !== request.roundIndex ||
    result.thinking_mode !== request.thinkingMode ||
    result.requested_model !== request.model ||
    result.model !== request.model ||
    result.model !== result.requested_model
  ) {
    fail('E_COMPLETION_RESULT_CORRELATION');
  }
  const toolCalls = projectResultToolCalls(result.tool_calls);
  const hasToolCalls = toolCalls.length > 0;
  if (
    (result.finish_reason === 'tool_calls') !== hasToolCalls ||
    ((result.finish_reason === 'stop' || result.finish_reason === 'length') &&
      result.text.trim().length === 0)
  ) {
    fail('E_COMPLETION_RESULT_RELATION');
  }
  return {
    schema_version: 2,
    harness_id: harnessId,
    ...(providerConfiguration === undefined ? {} : { provider_configuration: providerConfiguration }),
    turn_id: result.turn_id,
    attempt_id: result.attempt_id,
    round_id: result.round_id,
    round_index: result.round_index,
    provider_request_id: result.provider_request_id,
    provider_response_id: result.provider_response_id,
    requested_model: result.requested_model,
    model: result.model,
    thinking_mode: result.thinking_mode,
    text: result.text,
    reasoning: result.reasoning,
    tool_calls: toolCalls,
    finish_reason: result.finish_reason,
    latency_ms: result.latency_ms,
    visible_history_sha256: result.visible_history_sha256,
    model_input_sha256: result.model_input_sha256,
    request_body_sha256: result.request_body_sha256,
    project_context_receipt: null,
  };
}

export function validateCompleteV2Result(
  value: unknown,
  request: CompleteRoundV2Request,
): CompleteRoundV2Result {
  return withStableFailure('E_COMPLETION_RESULT_TYPE', () =>
    validateCompleteV2ResultUnsafe(value, request),
  );
}

function projectSchema3Receipt(
  value: unknown,
  request: CompleteRoundV3Request,
): CompletionProjectContextReceiptV3 {
  const receipt = resultRecord(value, SCHEMA3_RECEIPT_KEYS);
  if (
    receipt.schema_version !== 1 ||
    typeof receipt.snapshot_id !== 'string' ||
    typeof receipt.snapshot_sha256 !== 'string' ||
    typeof receipt.source_fingerprint !== 'string' ||
    typeof receipt.context_bytes !== 'number' ||
    typeof receipt.verified_at !== 'string'
  ) {
    fail('E_COMPLETION_RESULT_TYPE');
  }
  if (!canonicalUUID(receipt.snapshot_id)) {
    fail('E_COMPLETION_RESULT_IDENTIFIER');
  }
  if (
    !SHA256_PATTERN.test(receipt.snapshot_sha256) ||
    !SHA256_PATTERN.test(receipt.source_fingerprint)
  ) {
    fail('E_COMPLETION_RESULT_DIGEST');
  }
  if (
    !Number.isSafeInteger(receipt.context_bytes) ||
    Object.is(receipt.context_bytes, -0) ||
    receipt.context_bytes < 1 ||
    receipt.context_bytes > 256 * 1024 ||
    !isoTimestamp(receipt.verified_at)
  ) {
    fail('E_COMPLETION_RESULT_BOUNDS');
  }
  if (receipt.snapshot_id !== request.projectContext.snapshotId) {
    fail('E_COMPLETION_RESULT_CORRELATION');
  }
  return {
    schema_version: 1,
    snapshot_id: receipt.snapshot_id,
    snapshot_sha256: receipt.snapshot_sha256,
    source_fingerprint: receipt.source_fingerprint,
    context_bytes: receipt.context_bytes,
    verified_at: receipt.verified_at,
  };
}

function validateCompleteV3ResultUnsafe(
  value: unknown,
  request: CompleteRoundV3Request,
): CompleteRoundV3Result {
  const result = resultRecordWithOptionalKeys(value, SCHEMA2_RESULT_KEYS, [
    'harness_id', 'provider_configuration',
  ]);
  const harnessId = projectResultHarnessId(result.harness_id);
  const providerConfiguration = result.provider_configuration === undefined ? undefined :
    parseProviderBinding(result.provider_configuration, request.model);
  if (providerConfiguration === null) fail('E_COMPLETION_RESULT_RELATION');
  if (harnessId !== request.harnessId) fail('E_COMPLETION_MODEL_MISMATCH');
  if (
    typeof result.schema_version !== 'number' ||
    typeof result.round_index !== 'number' ||
    typeof result.latency_ms !== 'number' ||
    typeof result.turn_id !== 'string' ||
    typeof result.attempt_id !== 'string' ||
    typeof result.round_id !== 'string' ||
    typeof result.provider_request_id !== 'string' ||
    typeof result.provider_response_id !== 'string' ||
    typeof result.requested_model !== 'string' ||
    typeof result.model !== 'string' ||
    typeof result.thinking_mode !== 'string' ||
    typeof result.text !== 'string' ||
    typeof result.reasoning !== 'string' ||
    typeof result.finish_reason !== 'string' ||
    typeof result.visible_history_sha256 !== 'string' ||
    typeof result.model_input_sha256 !== 'string' ||
    typeof result.request_body_sha256 !== 'string' ||
    result.project_context_receipt === null
  ) {
    fail('E_COMPLETION_RESULT_TYPE');
  }
  if (result.schema_version !== 3) fail('E_COMPLETION_RESULT_ENUM');
  if (
    !canonicalUUID(result.turn_id) ||
    !canonicalUUID(result.attempt_id) ||
    !canonicalUUID(result.round_id) ||
    !canonicalUUID(result.provider_request_id) ||
    !opaqueIdentifier(result.provider_response_id)
  ) {
    fail('E_COMPLETION_RESULT_IDENTIFIER');
  }
  if (
    !Number.isSafeInteger(result.round_index) ||
    Object.is(result.round_index, -0) ||
    result.round_index < 0 ||
    result.round_index > MAX_ROUND_INDEX ||
    !Number.isSafeInteger(result.latency_ms) ||
    Object.is(result.latency_ms, -0) ||
    result.latency_ms < 0 ||
    !boundedString(result.text, MAX_MESSAGE_BYTES) ||
    !boundedString(result.reasoning, MAX_MESSAGE_BYTES)
  ) {
    fail('E_COMPLETION_RESULT_BOUNDS');
  }
  if (
    !validModel(result.requested_model) ||
    !validModel(result.model) ||
    !validThinkingMode(result.thinking_mode) ||
    !validFinishReason(result.finish_reason)
  ) {
    fail('E_COMPLETION_RESULT_ENUM');
  }
  if (
    !SHA256_PATTERN.test(result.visible_history_sha256) ||
    !SHA256_PATTERN.test(result.model_input_sha256) ||
    !SHA256_PATTERN.test(result.request_body_sha256)
  ) {
    fail('E_COMPLETION_RESULT_DIGEST');
  }
  if (
    result.turn_id !== request.turnId ||
    result.attempt_id !== request.attemptId ||
    result.round_id !== request.roundId ||
    result.round_index !== request.roundIndex ||
    result.thinking_mode !== request.thinkingMode ||
    result.requested_model !== request.model ||
    result.model !== request.model ||
    result.model !== result.requested_model
  ) {
    fail('E_COMPLETION_RESULT_CORRELATION');
  }
  const toolCalls = projectResultToolCalls(result.tool_calls);
  const hasToolCalls = toolCalls.length > 0;
  if (
    (result.finish_reason === 'tool_calls') !== hasToolCalls ||
    ((result.finish_reason === 'stop' || result.finish_reason === 'length') &&
      result.text.trim().length === 0)
  ) {
    fail('E_COMPLETION_RESULT_RELATION');
  }
  const receipt = projectSchema3Receipt(
    result.project_context_receipt,
    request,
  );
  return {
    schema_version: 3,
    harness_id: harnessId,
    ...(providerConfiguration === undefined ? {} : { provider_configuration: providerConfiguration }),
    turn_id: result.turn_id,
    attempt_id: result.attempt_id,
    round_id: result.round_id,
    round_index: result.round_index,
    provider_request_id: result.provider_request_id,
    provider_response_id: result.provider_response_id,
    requested_model: result.requested_model,
    model: result.model,
    thinking_mode: result.thinking_mode,
    text: result.text,
    reasoning: result.reasoning,
    tool_calls: toolCalls,
    finish_reason: result.finish_reason,
    latency_ms: result.latency_ms,
    visible_history_sha256: result.visible_history_sha256,
    model_input_sha256: result.model_input_sha256,
    request_body_sha256: result.request_body_sha256,
    project_context_receipt: receipt,
  };
}

export function validateCompleteV3Result(
  value: unknown,
  request: CompleteRoundV3Request,
): CompleteRoundV3Result {
  return withStableFailure('E_COMPLETION_RESULT_TYPE', () =>
    validateCompleteV3ResultUnsafe(value, request),
  );
}

/** Schema-1 remains supported, but no native value is trusted by assertion. */
function validateLegacyCompleteV2ResultUnsafe(value: unknown): CompleteV2Result {
  const result = resultRecord(value, SCHEMA1_RESULT_KEYS);
  if (
    result.schema_version !== 1 ||
    typeof result.text !== 'string' ||
    typeof result.finish_reason !== 'string' ||
    typeof result.model !== 'string' ||
    typeof result.request_id !== 'string' ||
    typeof result.latency_ms !== 'number' ||
    !Number.isSafeInteger(result.latency_ms) ||
    result.latency_ms < 0 ||
    typeof result.reasoning !== 'string' ||
    !validThinkingMode(result.thinking_mode)
  ) {
    fail('E_COMPLETION_RESULT_TYPE');
  }
  const toolCalls = projectLegacyToolCalls(result.tool_calls);
  return {
    schema_version: 1,
    text: result.text,
    tool_calls: toolCalls,
    finish_reason: result.finish_reason,
    model: result.model,
    request_id: result.request_id,
    latency_ms: result.latency_ms,
    reasoning: result.reasoning,
    thinking_mode: result.thinking_mode,
  };
}

export function validateLegacyCompleteV2Result(
  value: unknown,
): CompleteV2Result {
  return withStableFailure('E_COMPLETION_RESULT_TYPE', () =>
    validateLegacyCompleteV2ResultUnsafe(value),
  );
}

/** Rebuilds native failures with a value-free message and no attached cause. */
export function sanitizeCompletionError(error: unknown): CompletionBridgeError {
  try {
    // Compatibility with older native adapters: expose one canonical timeout,
    // never the provider's message or arbitrary private error vocabulary.
    if (isRecord(error) && error.code === 'E_CLAUDE_OFFICIAL_TEXT_TIMEOUT') {
      return new CompletionBridgeError('E_COMPLETION_TIMEOUT');
    }
    if (error instanceof CompletionBridgeError) {
      return isStableCompletionErrorCode(error.code)
        ? new CompletionBridgeError(error.code)
        : new CompletionBridgeError('E_COMPLETION_NATIVE');
    }
    if (isRecord(error) && typeof error.code === 'string') {
      const code = error.code;
      if (isNativeErrorCode(code)) {
        return new CompletionBridgeError(code);
      }
      const legacyCode = LEGACY_NATIVE_ERROR_MAP[code];
      if (legacyCode !== undefined) {
        return new CompletionBridgeError(legacyCode);
      }
    }
  } catch {
    return new CompletionBridgeError('E_COMPLETION_NATIVE');
  }
  return new CompletionBridgeError('E_COMPLETION_NATIVE');
}
