/* Rish host ABI 1. Pi schedules opaque native capabilities; their contents and
 * effects remain in the native authority. This is not a Node or CLI runtime. */
(() => {
  const { Agent, createAssistantMessageEventStream } = globalThis.PiCore;
  delete globalThis.PiCore;
  let agent, pending, state, activeContext, model;
  const key = c => `${c.round_id}/${c.call_id}`;
  function makeTool(name) {
    return {
      name, label: name, description: 'Opaque native capability; returns a verified receipt, not private tool output.',
      parameters: { type: 'object', properties: { native_call: { type: 'object' } }, required: ['native_call'], additionalProperties: false },
      execute: (id, args) => new Promise((resolve, reject) => {
        if (pending || id !== key(args.native_call)) throw new Error('Native capability sequence mismatch');
        pending = { kind: 'tool', call: args.native_call, resolve, reject };
      }),
    };
  }
  function snapshot() {
    return JSON.stringify({ done: state?.done === true, error: state?.error ?? null,
      events: state?.events ?? [], intent: !pending ? null : pending.kind === 'model'
        ? { kind: 'model', round_index: pending.round_index }
        : { kind: 'tool', ...pending.call } });
  }
  globalThis.__rishPi = Object.freeze({
    start(json) {
      const input = JSON.parse(json);
      if (agent) throw new Error('Runtime already started');
      model = { api: 'rish-native-capability-v1', provider: 'rish-native', id: input.model };
      state = { done: false, error: null, events: [], next_round: input.round_index };
      agent = new Agent({
        initialState: { model, tools: [], systemPrompt: 'The native host retains authoritative model context and tool results. This loop schedules opaque capabilities only.' },
        toolExecution: 'sequential',
        prepareRequest: ({ context }) => { activeContext = context; },
        streamFn: () => {
          if (pending) throw new Error('Native model overlap');
          const stream = createAssistantMessageEventStream();
          pending = { kind: 'model', round_index: state.next_round++, stream };
          return stream;
        },
      });
      agent.subscribe(event => {
        if (state.events.length < 512) state.events.push(event.type);
      });
      agent.prompt({ role: 'user', content: [{ type: 'text', text: `Native context reference: ${input.context_ref}` }], timestamp: input.timestamp })
        .then(() => { state.done = true; state.error = agent.state.errorMessage ?? null; })
        .catch(error => { state.done = true; state.error = String(error); });
    },
    snapshot,
    modelReply(json) {
      const value = JSON.parse(json);
      if (pending?.kind !== 'model' || pending.round_index !== value.round_index) throw new Error('Native model reply mismatch');
      const stream = pending.stream;
      pending = null;
      const calls = value.calls ?? [];
      const tools = [...new Set(calls.map(c => c.name))].map(makeTool);
      activeContext.tools = tools;
      agent.state.tools = tools;
      const content = [];
      if (value.text !== undefined) content.push({ type: 'text', text: value.text });
      for (const call of calls) content.push({ type: 'toolCall', id: key(call), name: call.name, arguments: { native_call: call } });
      const message = { role: 'assistant', api: model.api, provider: model.provider, model: model.id,
        content, timestamp: Date.now(), stopReason: value.kind === 'tool_batch' ? 'toolUse' : value.kind === 'final' ? 'stop' : 'error',
        nativeOpaque: value.kind === 'tool_batch', ...(value.failure_code ? { errorMessage: value.failure_code } : {}) };
      if (message.stopReason === 'error') stream.push({ type: 'error', reason: 'error', error: message });
      else stream.push({ type: 'done', reason: message.stopReason, message });
    },
    toolReply(json) {
      const value = JSON.parse(json);
      if (pending?.kind !== 'tool' || key(pending.call) !== key(value.call)
          || pending.call.name !== value.call.name || pending.call.arguments_sha256 !== value.call.arguments_sha256)
        throw new Error('Native receipt identity mismatch');
      const resolve = pending.resolve;
      pending = null;
      resolve({ content: [{ type: 'text', text: JSON.stringify({ native_receipt: value.receipt, private_output: 'retained_by_native' }) }],
        details: { native_receipt: value.receipt }, isError: value.receipt.outcome !== 'ok' });
    },
    abort() {
      if (!agent) return;
      agent.abort();
      if (pending?.kind === 'tool') {
        const reject = pending.reject; pending = null; reject(new Error('Native task cancelled'));
      } else if (pending?.kind === 'model') {
        const stream = pending.stream; pending = null;
        stream.push({ type: 'error', reason: 'aborted', error: { role: 'assistant', api: model.api, provider: model.provider,
          model: model.id, content: [], stopReason: 'aborted', errorMessage: 'Native task cancelled', timestamp: Date.now() } });
      }
    },
  });
})();
