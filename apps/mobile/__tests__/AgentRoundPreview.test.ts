import type {
  AgentRoundPreviewDeltaEvent,
  AgentRoundPreviewEndEvent,
} from '../src/agent/AgentRoundPreview';
import {
  agentRoundPreviewIsEmpty,
  createAgentRoundPreviewState,
  parseAgentRoundPreviewEvent,
  reduceAgentRoundPreview,
} from '../src/agent/AgentRoundPreview';

const snakeCorrelation = {
  task_id: 'task-1',
  attempt_id: 'attempt-1',
  round_id: 'round-1',
  round_index: 0,
  operation_id: 'operation-1',
  provider_request_id: 'request-1',
  harness_id: 'harness-1',
};
const camelCorrelation = {
  taskId: 'task-1',
  attemptId: 'attempt-1',
  roundId: 'round-1',
  roundIndex: 0,
  operationId: 'operation-1',
  providerRequestId: 'request-1',
  harnessId: 'harness-1',
};

function rawEvent(kind: 'delta' | 'end', seq: number, extra: Record<string, unknown> = {}) {
  const base: Record<string, unknown> = { schema_version: 1, kind, ...snakeCorrelation, seq };
  if (kind === 'end') {
    base.status = 'validated';
    base.truncated = false;
  }
  return { ...base, ...extra };
}

function delta(seq: number, extra: Record<string, unknown> = {}): AgentRoundPreviewDeltaEvent {
  return parseAgentRoundPreviewEvent(rawEvent('delta', seq, extra)) as AgentRoundPreviewDeltaEvent;
}

function end(seq: number, extra: Record<string, unknown> = {}): AgentRoundPreviewEndEvent {
  return parseAgentRoundPreviewEvent(rawEvent('end', seq, extra)) as AgentRoundPreviewEndEvent;
}

test('parses a delta mapping snake_case keys to a frozen camelCase event', () => {
  const toolCalls = [{ index: 0, id: 'call-1', name: 'read_file', arguments: '{"path"' }];
  const event = delta(1, {
    text: 'Hello',
    reasoning: 'thinking',
    tool_calls: toolCalls,
    finish_reason: 'tool_calls',
  });
  expect(event).toEqual({
    ...camelCorrelation,
    kind: 'delta',
    seq: 1,
    text: 'Hello',
    reasoning: 'thinking',
    toolCalls: [{ index: 0, id: 'call-1', name: 'read_file', arguments: '{"path"' }],
    finishReason: 'tool_calls',
  });
  expect(Object.isFrozen(event)).toBe(true);
  expect(event.toolCalls).not.toBe(toolCalls);
  expect(event.toolCalls![0]).not.toBe(toolCalls[0]);
  expect(Object.isFrozen(event.toolCalls)).toBe(true);
  expect(Object.isFrozen(event.toolCalls![0])).toBe(true);
});

test('treats empty text, reasoning and fragment arguments as absent', () => {
  const event = delta(1, {
    text: '',
    reasoning: '',
    tool_calls: [{ index: 0, id: 'call-1', arguments: '' }],
  });
  expect(event.text).toBeUndefined();
  expect(event.reasoning).toBeUndefined();
  expect(event.toolCalls).toEqual([{ index: 0, id: 'call-1' }]);
  expect('arguments' in event.toolCalls![0]).toBe(false);
});

test('rejects non-object bodies, wrong schema versions and unknown kinds', () => {
  expect(parseAgentRoundPreviewEvent(null)).toBeNull();
  expect(parseAgentRoundPreviewEvent('delta')).toBeNull();
  expect(parseAgentRoundPreviewEvent(17)).toBeNull();
  expect(parseAgentRoundPreviewEvent([rawEvent('delta', 1, { text: 'x' })])).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', schema_version: 2 }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', schema_version: '1' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', kind: 'progress' }))).toBeNull();
});

test('rejects correlation deviations', () => {
  for (const key of Object.keys(snakeCorrelation)) {
    const raw = rawEvent('delta', 1, { text: 'x' });
    delete raw[key];
    expect(parseAgentRoundPreviewEvent(raw)).toBeNull();
  }
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', task_id: '' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', task_id: 'x'.repeat(257) }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', harness_id: 7 }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', round_index: -1 }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', round_index: 1.5 }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', round_index: '0' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, {
    text: 'x', task_id: 'x'.repeat(256),
  }))).not.toBeNull();
});

test('rejects seq deviations', () => {
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 0, { text: 'x' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 2.5, { text: 'x' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', seq: '1' }))).toBeNull();
  const missing = rawEvent('delta', 1, { text: 'x' });
  delete missing.seq;
  expect(parseAgentRoundPreviewEvent(missing)).toBeNull();
});

test('rejects empty deltas and non-string payloads', () => {
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: '' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: null }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 5 }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { reasoning: [] }))).toBeNull();
});

test('rejects malformed tool_calls and fragment bounds', () => {
  const tool = (fragment: unknown) => rawEvent('delta', 1, { text: 'x', tool_calls: [fragment] });
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', tool_calls: [] }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', tool_calls: 'nope' }))).toBeNull();
  const seventeen = Array.from({ length: 17 }, () => ({ index: 0 }));
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { text: 'x', tool_calls: seventeen }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool(null))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool('fragment'))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool({ id: 'call-1' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool({ index: 16 }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool({ index: -1 }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool({ index: 1.5 }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool({ index: 0, extra: true }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool({ index: 0, id: '' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool({ index: 0, name: '' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool({ index: 0, id: 'x'.repeat(129) }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool({ index: 0, name: 'x'.repeat(65) }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool({ index: 0, arguments: 'x'.repeat(262145) }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(tool({
    index: 15,
    id: 'x'.repeat(128),
    name: 'x'.repeat(64),
    arguments: 'x'.repeat(262144),
  }))).not.toBeNull();
});

test('rejects malformed finish reasons', () => {
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { finish_reason: 'abort' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { finish_reason: '' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { finish_reason: 1 }))).toBeNull();
  for (const reason of ['stop', 'tool_calls', 'length', 'content_filter']) {
    expect(parseAgentRoundPreviewEvent(rawEvent('delta', 1, { finish_reason: reason }))).not.toBeNull();
  }
});

test('parses a valid end event and rejects malformed ones', () => {
  const event = end(2, { status: 'failed', failure_code: 'E_COMPLETION_LENGTH', truncated: true });
  expect(event).toEqual({
    ...camelCorrelation,
    kind: 'end',
    seq: 2,
    status: 'failed',
    failureCode: 'E_COMPLETION_LENGTH',
    truncated: true,
  });
  expect(Object.isFrozen(event)).toBe(true);
  expect(parseAgentRoundPreviewEvent(rawEvent('end', 2, { status: 'ok' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('end', 2, { truncated: 'false' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('end', 2, { truncated: 0 }))).toBeNull();
  const missingTruncated = rawEvent('end', 2, {});
  delete missingTruncated.truncated;
  expect(parseAgentRoundPreviewEvent(missingTruncated)).toBeNull();
  const missingStatus = rawEvent('end', 2, {});
  delete missingStatus.status;
  expect(parseAgentRoundPreviewEvent(missingStatus)).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('end', 2, { failure_code: '' }))).toBeNull();
  expect(parseAgentRoundPreviewEvent(rawEvent('end', 2, { failure_code: 'x'.repeat(65) }))).toBeNull();
});

test('ignores unknown top-level keys', () => {
  const event = delta(1, { text: 'x', native_future_field: { nested: [1, 2] } });
  expect(event).toEqual({ ...camelCorrelation, kind: 'delta', seq: 1, text: 'x' });
  const ending = end(2, { another_future_field: null });
  expect(ending).toEqual({
    ...camelCorrelation, kind: 'end', seq: 2, status: 'validated', truncated: false,
  });
});

test('createAgentRoundPreviewState returns the empty frozen state', () => {
  const state = createAgentRoundPreviewState(camelCorrelation);
  expect(state).toEqual({
    correlation: camelCorrelation,
    text: '',
    reasoning: '',
    toolCalls: [],
    finishReason: null,
    lastSeq: 0,
    incomplete: false,
    ended: null,
  });
  expect(Object.isFrozen(state)).toBe(true);
});

test('reducer appends text and reasoning across seqs and records finishReason', () => {
  let state = createAgentRoundPreviewState(camelCorrelation);
  state = reduceAgentRoundPreview(state, delta(1, { text: 'Hello ', reasoning: 'plan' }));
  state = reduceAgentRoundPreview(state, delta(2, { text: 'world' }));
  expect(state.text).toBe('Hello world');
  expect(state.reasoning).toBe('plan');
  expect(state.lastSeq).toBe(2);
  expect(state.finishReason).toBeNull();
  state = reduceAgentRoundPreview(state, delta(3, { finish_reason: 'tool_calls' }));
  expect(state.finishReason).toBe('tool_calls');
  state = reduceAgentRoundPreview(state, delta(4, { text: '!' }));
  expect(state.text).toBe('Hello world!');
  expect(state.finishReason).toBe('tool_calls');
  expect(state.ended).toBeNull();
  expect(Object.isFrozen(state)).toBe(true);
});

test('reducer merges tool fragments by index with first-wins identity', () => {
  let state = createAgentRoundPreviewState(camelCorrelation);
  state = reduceAgentRoundPreview(state, delta(1, {
    tool_calls: [{ index: 2, id: 'call-2', name: 'write_file', arguments: '{"path"' }],
  }));
  state = reduceAgentRoundPreview(state, delta(2, {
    tool_calls: [{ index: 0, id: 'call-0', name: 'read_file', arguments: '{"offset"' }],
  }));
  state = reduceAgentRoundPreview(state, delta(3, {
    tool_calls: [
      { index: 2, id: 'call-other', arguments: ',"mode":"w"}' },
      { index: 0, name: 'later_name', arguments: ':0}' },
      { index: 1, arguments: '{"q"' },
    ],
  }));
  state = reduceAgentRoundPreview(state, delta(4, {
    tool_calls: [{ index: 1, id: 'call-1', name: 'search', arguments: ':1}' }],
  }));
  expect(state.toolCalls).toEqual([
    { index: 0, id: 'call-0', name: 'read_file', arguments: '{"offset":0}' },
    { index: 1, id: 'call-1', name: 'search', arguments: '{"q":1}' },
    { index: 2, id: 'call-2', name: 'write_file', arguments: '{"path","mode":"w"}' },
  ]);
  expect(Object.isFrozen(state.toolCalls)).toBe(true);
  expect(Object.isFrozen(state.toolCalls[0])).toBe(true);
});

test('reducer ignores duplicate and stale seqs and foreign correlations', () => {
  const empty = createAgentRoundPreviewState(camelCorrelation);
  const first = reduceAgentRoundPreview(empty, delta(1, { text: 'a' }));
  const second = reduceAgentRoundPreview(first, delta(2, { text: 'b' }));
  expect(reduceAgentRoundPreview(second, delta(2, { text: 'dup' }))).toBe(second);
  expect(reduceAgentRoundPreview(second, delta(1, { text: 'stale' }))).toBe(second);
  const foreign = parseAgentRoundPreviewEvent(rawEvent('delta', 3, { text: 'x', round_id: 'round-2' }));
  expect(reduceAgentRoundPreview(second, foreign!)).toBe(second);
  expect(second.text).toBe('ab');
  expect(second.lastSeq).toBe(2);
});

test('reducer applies events after a gap but marks the state incomplete', () => {
  const empty = createAgentRoundPreviewState(camelCorrelation);
  const first = reduceAgentRoundPreview(empty, delta(1, { text: 'a' }));
  const jumped = reduceAgentRoundPreview(first, delta(4, { text: 'b' }));
  expect(jumped.incomplete).toBe(true);
  expect(jumped.text).toBe('ab');
  expect(jumped.lastSeq).toBe(4);
  const next = reduceAgentRoundPreview(jumped, delta(5, { text: 'c' }));
  expect(next.incomplete).toBe(true);
  expect(next.text).toBe('abc');
});

test('reducer folds the end event and stops accepting afterwards', () => {
  const empty = createAgentRoundPreviewState(camelCorrelation);
  const first = reduceAgentRoundPreview(empty, delta(1, { text: 'a' }));
  const finished = reduceAgentRoundPreview(first, end(2, {}));
  expect(finished.ended).toEqual({ status: 'validated', failureCode: null, httpStatus: null });
  expect(finished.incomplete).toBe(false);
  expect(finished.lastSeq).toBe(2);
  expect(reduceAgentRoundPreview(finished, delta(3, { text: 'late' }))).toBe(finished);
  expect(reduceAgentRoundPreview(finished, end(4, {}))).toBe(finished);
});

test('reducer carries failure codes and truncation from failed ends', () => {
  const empty = createAgentRoundPreviewState(camelCorrelation);
  const first = reduceAgentRoundPreview(empty, delta(1, { text: 'a' }));
  const failed = reduceAgentRoundPreview(first, end(2, {
    status: 'failed',
    failure_code: 'E_COMPLETION_LENGTH',
    truncated: true,
  }));
  expect(failed.ended).toEqual({ status: 'failed', failureCode: 'E_COMPLETION_LENGTH', httpStatus: null });
  expect(failed.incomplete).toBe(true);
});

test('agentRoundPreviewIsEmpty is true only without accumulated material', () => {
  const empty = createAgentRoundPreviewState(camelCorrelation);
  expect(agentRoundPreviewIsEmpty(empty)).toBe(true);
  const withTool = reduceAgentRoundPreview(empty, delta(1, { tool_calls: [{ index: 0 }] }));
  expect(agentRoundPreviewIsEmpty(withTool)).toBe(false);
  expect(agentRoundPreviewIsEmpty(reduceAgentRoundPreview(empty, delta(1, { text: 'x' })))).toBe(false);
  expect(agentRoundPreviewIsEmpty(reduceAgentRoundPreview(empty, delta(1, { reasoning: 'x' })))).toBe(false);
});
