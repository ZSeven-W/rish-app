/**
 * Pure display-only contract for the native `agentRoundPreview` stream.
 *
 * Preview material is ephemeral: it is never persisted and never enters
 * session proofs. The parser rejects any deviation instead of repairing
 * it, and the reducer folds validated events into one round's preview.
 */

export type AgentRoundPreviewToolFragment = {
  readonly index: number;
  readonly id?: string;
  readonly name?: string;
  readonly arguments?: string;
};

export type AgentRoundPreviewCorrelation = {
  readonly taskId: string;
  readonly attemptId: string;
  readonly roundId: string;
  readonly roundIndex: number;
  readonly operationId: string;
  readonly providerRequestId: string;
  readonly harnessId: string;
};

export type AgentRoundPreviewDeltaEvent = AgentRoundPreviewCorrelation & {
  readonly kind: 'delta';
  readonly seq: number;
  readonly text?: string;
  readonly reasoning?: string;
  readonly toolCalls?: readonly AgentRoundPreviewToolFragment[];
  readonly finishReason?: string;
};

export type AgentRoundPreviewEndEvent = AgentRoundPreviewCorrelation & {
  readonly kind: 'end';
  readonly seq: number;
  readonly status: 'validated' | 'failed';
  readonly failureCode?: string;
  /** The HTTP status a provider answered with, when that is why it failed. */
  readonly httpStatus?: number;
  readonly truncated: boolean;
};

export type AgentRoundPreviewEvent =
  | AgentRoundPreviewDeltaEvent
  | AgentRoundPreviewEndEvent;

export type AgentRoundPreviewToolCall = {
  readonly index: number;
  readonly id: string | null;
  readonly name: string | null;
  readonly arguments: string;
};

export type AgentRoundPreviewState = {
  readonly correlation: AgentRoundPreviewCorrelation;
  readonly text: string;
  readonly reasoning: string;
  readonly toolCalls: readonly AgentRoundPreviewToolCall[];
  readonly finishReason: string | null;
  readonly lastSeq: number;
  readonly incomplete: boolean;
  readonly ended: null | {
    readonly status: 'validated' | 'failed';
    readonly failureCode: string | null;
    readonly httpStatus: number | null;
  };
};

const FINISH_REASONS = new Set(['stop', 'tool_calls', 'length', 'content_filter']);
const FRAGMENT_KEYS = new Set(['index', 'id', 'name', 'arguments']);
const CORRELATION_FIELDS = [
  'taskId', 'attemptId', 'roundId', 'roundIndex', 'operationId', 'providerRequestId', 'harnessId',
] as const;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isIntegerInRange(value: unknown, min: number, max?: number): value is number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) return false;
  return value >= min && (max === undefined || value <= max);
}

function boundedString(value: unknown, max: number): string | null {
  if (typeof value !== 'string' || value.length === 0 || value.length > max) return null;
  return value;
}

function parseCorrelation(raw: Record<string, unknown>): AgentRoundPreviewCorrelation | null {
  const taskId = boundedString(raw.task_id, 256);
  const attemptId = boundedString(raw.attempt_id, 256);
  const roundId = boundedString(raw.round_id, 256);
  const operationId = boundedString(raw.operation_id, 256);
  const providerRequestId = boundedString(raw.provider_request_id, 256);
  const harnessId = boundedString(raw.harness_id, 256);
  if (taskId === null || attemptId === null || roundId === null) return null;
  if (operationId === null || providerRequestId === null) return null;
  if (harnessId === null || !isIntegerInRange(raw.round_index, 0)) return null;
  return Object.freeze({
    taskId, attemptId, roundId, roundIndex: raw.round_index, operationId, providerRequestId, harnessId,
  });
}

function parseFragment(raw: unknown): AgentRoundPreviewToolFragment | null {
  if (!isRecord(raw)) return null;
  for (const key of Object.keys(raw)) {
    if (!FRAGMENT_KEYS.has(key)) return null;
  }
  if (!isIntegerInRange(raw.index, 0, 15)) return null;
  const fragment: { index: number; id?: string; name?: string; arguments?: string } = { index: raw.index };
  if (raw.id !== undefined) {
    const id = boundedString(raw.id, 128);
    if (id === null) return null;
    fragment.id = id;
  }
  if (raw.name !== undefined) {
    const name = boundedString(raw.name, 64);
    if (name === null) return null;
    fragment.name = name;
  }
  if (raw.arguments !== undefined) {
    if (typeof raw.arguments !== 'string' || raw.arguments.length > 262144) return null;
    if (raw.arguments !== '') fragment.arguments = raw.arguments;
  }
  return Object.freeze(fragment);
}

function parseDeltaEvent(
  raw: Record<string, unknown>,
  correlation: AgentRoundPreviewCorrelation,
  seq: number,
): AgentRoundPreviewDeltaEvent | null {
  let text: string | undefined;
  if (raw.text !== undefined) {
    if (typeof raw.text !== 'string') return null;
    if (raw.text !== '') text = raw.text;
  }
  let reasoning: string | undefined;
  if (raw.reasoning !== undefined) {
    if (typeof raw.reasoning !== 'string') return null;
    if (raw.reasoning !== '') reasoning = raw.reasoning;
  }
  let toolCalls: readonly AgentRoundPreviewToolFragment[] | undefined;
  if (raw.tool_calls !== undefined) {
    if (!Array.isArray(raw.tool_calls)) return null;
    if (raw.tool_calls.length < 1 || raw.tool_calls.length > 16) return null;
    const fragments: AgentRoundPreviewToolFragment[] = [];
    for (const entry of raw.tool_calls) {
      const fragment = parseFragment(entry);
      if (fragment === null) return null;
      fragments.push(fragment);
    }
    toolCalls = Object.freeze(fragments);
  }
  let finishReason: string | undefined;
  if (raw.finish_reason !== undefined) {
    if (typeof raw.finish_reason !== 'string') return null;
    if (!FINISH_REASONS.has(raw.finish_reason)) return null;
    finishReason = raw.finish_reason;
  }
  if (text === undefined && reasoning === undefined &&
      toolCalls === undefined && finishReason === undefined) return null;
  return Object.freeze({
    ...correlation,
    kind: 'delta' as const,
    seq,
    ...(text !== undefined ? { text } : {}),
    ...(reasoning !== undefined ? { reasoning } : {}),
    ...(toolCalls !== undefined ? { toolCalls } : {}),
    ...(finishReason !== undefined ? { finishReason } : {}),
  });
}

function parseEndEvent(
  raw: Record<string, unknown>,
  correlation: AgentRoundPreviewCorrelation,
  seq: number,
): AgentRoundPreviewEndEvent | null {
  if (typeof raw.status !== 'string' ||
      (raw.status !== 'validated' && raw.status !== 'failed')) return null;
  if (typeof raw.truncated !== 'boolean') return null;
  let failureCode: string | undefined;
  if (raw.failure_code !== undefined) {
    const code = boundedString(raw.failure_code, 64);
    if (code === null) return null;
    failureCode = code;
  }
  let httpStatus: number | undefined;
  if (raw.http_status !== undefined) {
    if (!isIntegerInRange(raw.http_status, 100, 599)) return null;
    httpStatus = raw.http_status;
  }
  return Object.freeze({
    ...correlation,
    kind: 'end' as const,
    seq,
    status: raw.status,
    truncated: raw.truncated,
    ...(failureCode !== undefined ? { failureCode } : {}),
    ...(httpStatus !== undefined ? { httpStatus } : {}),
  });
}

export function parseAgentRoundPreviewEvent(raw: unknown): AgentRoundPreviewEvent | null {
  if (!isRecord(raw)) return null;
  if (raw.schema_version !== 1) return null;
  if (raw.kind !== 'delta' && raw.kind !== 'end') return null;
  const correlation = parseCorrelation(raw);
  if (correlation === null || !isIntegerInRange(raw.seq, 1)) return null;
  return raw.kind === 'delta'
    ? parseDeltaEvent(raw, correlation, raw.seq)
    : parseEndEvent(raw, correlation, raw.seq);
}

export function createAgentRoundPreviewState(
  correlation: AgentRoundPreviewCorrelation,
): AgentRoundPreviewState {
  return Object.freeze({
    correlation: Object.freeze({ ...correlation }),
    text: '',
    reasoning: '',
    toolCalls: Object.freeze([]),
    finishReason: null,
    lastSeq: 0,
    incomplete: false,
    ended: null,
  });
}

function sameCorrelation(
  left: AgentRoundPreviewCorrelation,
  right: AgentRoundPreviewCorrelation,
): boolean {
  return CORRELATION_FIELDS.every(field => left[field] === right[field]);
}

function mergeToolFragments(
  calls: readonly AgentRoundPreviewToolCall[],
  fragments: readonly AgentRoundPreviewToolFragment[],
): readonly AgentRoundPreviewToolCall[] {
  const merged: {
    index: number;
    id: string | null;
    name: string | null;
    arguments: string;
  }[] = calls.map(call => ({ ...call }));
  for (const fragment of fragments) {
    let call = merged.find(entry => entry.index === fragment.index);
    if (call === undefined) {
      call = { index: fragment.index, id: null, name: null, arguments: '' };
      merged.push(call);
    }
    if (call.id === null && fragment.id !== undefined) call.id = fragment.id;
    if (call.name === null && fragment.name !== undefined) call.name = fragment.name;
    if (fragment.arguments !== undefined) call.arguments += fragment.arguments;
  }
  merged.sort((left, right) => left.index - right.index);
  return Object.freeze(merged.map(call => Object.freeze(call)));
}

export function reduceAgentRoundPreview(
  state: AgentRoundPreviewState,
  event: AgentRoundPreviewEvent,
): AgentRoundPreviewState {
  if (!sameCorrelation(state.correlation, event)) return state;
  if (state.ended !== null) return state;
  if (event.seq <= state.lastSeq) return state;
  const incomplete = state.incomplete || event.seq > state.lastSeq + 1;
  if (event.kind === 'delta') {
    const toolCalls = event.toolCalls === undefined
      ? state.toolCalls
      : mergeToolFragments(state.toolCalls, event.toolCalls);
    return Object.freeze({
      ...state,
      text: state.text + (event.text ?? ''),
      reasoning: state.reasoning + (event.reasoning ?? ''),
      toolCalls,
      finishReason: event.finishReason ?? state.finishReason,
      lastSeq: event.seq,
      incomplete,
    });
  }
  return Object.freeze({
    ...state,
    lastSeq: event.seq,
    incomplete: incomplete || event.truncated,
    ended: Object.freeze({
      status: event.status,
      failureCode: event.failureCode ?? null,
      httpStatus: event.httpStatus ?? null,
    }),
  });
}

export function agentRoundPreviewIsEmpty(state: AgentRoundPreviewState): boolean {
  return state.text === '' && state.reasoning === '' && state.toolCalls.length === 0;
}
