import React from 'react';
import { NativeModules, Switch, TextInput } from 'react-native';
import { act, create, type ReactTestRenderer } from 'react-test-renderer';
import { ProviderConfigurationCard } from '../src/components/ProviderConfigurationCard';
import {
  parseProviderBinding,
  providerHostMatches,
  type ProviderConfiguration,
} from '../src/providers/configuration';
const native = {
  providerConfiguration: jest.fn(),
  saveProviderConfiguration: jest.fn(),
  resetProviderConfiguration: jest.fn(),
};
const official = (harness: ProviderConfiguration['harness_id']): ProviderConfiguration => ({
  schema_version: 1,
  harness_id: harness,
  name: '',
  endpoint_url: 'https://api.example.com/v1/messages',
  protocol: harness === 'claude-code' ? 'messages' : 'responses',
  auth_type: 'bearer',
  send_reasoning: true,
  model_mappings: {},
  official: true,
});
beforeEach(() => {
  jest.clearAllMocks();
  (NativeModules as Record<string, unknown>).LocalRuntime = native;
  native.providerConfiguration.mockImplementation(async harness =>
    official(harness),
  );
  native.saveProviderConfiguration.mockImplementation(async value => value);
});
test('saves endpoint and model mapping without passing credentials through JS', async () => {
  const onSaved = jest.fn();
  let renderer!: ReactTestRenderer;
  await act(async () => {
    renderer = create(
      <ProviderConfigurationCard
        model="claude-sonnet-5"
        disabled={false}
        visible
        onSaved={onSaved}
      />,
    );
  });
  await act(async () => {
    renderer.root.findAllByType(Switch)[0].props.onValueChange(true);
  });
  const input = (label: string) =>
    renderer.root
      .findAllByType(TextInput)
      .find(x => x.props.accessibilityLabel === label)!;
  await act(async () => {
    input('Provider name').props.onChangeText('My relay');
    input('Base URL or full endpoint').props.onChangeText(
      'https://relay.example/v1',
    );
  });
  await act(async () => {
    renderer.root
      .findByProps({ placeholder: 'claude-sonnet-5' })
      .props.onChangeText('relay-sonnet');
  });
  await act(async () => {
    await renderer.root
      .findAll(
        x =>
          x.props.accessibilityLabel === 'Save provider settings' &&
          typeof x.props.onPress === 'function',
      )[0]
      .props.onPress();
  });
  expect(native.saveProviderConfiguration).toHaveBeenCalledWith(
    expect.objectContaining({
      harness_id: 'claude-code',
      name: 'My relay',
      endpoint_url: 'https://relay.example/v1',
      model_mappings: { 'claude-sonnet-5': 'relay-sonnet' },
      send_reasoning: false,
    }),
  );
  expect(native.saveProviderConfiguration.mock.calls[0][0]).not.toHaveProperty(
    'official',
  );
  expect(native.saveProviderConfiguration.mock.calls[0][0]).not.toHaveProperty(
    'api_key',
  );
  expect(onSaved).toHaveBeenCalledWith('claude-code');
  await act(async () => renderer.unmount());
});
test('ignores a late provider load after the harness changes', async () => {
  let resolve!: (value: ProviderConfiguration) => void;
  native.providerConfiguration.mockImplementation(harness =>
    harness === 'claude-code'
      ? new Promise(r => {
          resolve = r;
        })
      : Promise.resolve({
          ...official('codex'),
          name: 'Codex relay',
          official: undefined,
        }),
  );
  let renderer!: ReactTestRenderer;
  await act(async () => {
    renderer = create(
      <ProviderConfigurationCard
        model="claude-sonnet-5"
        disabled={false}
        visible
        onSaved={() => {}}
      />,
    );
  });
  await act(async () =>
    renderer.update(
      <ProviderConfigurationCard
        model="gpt-5.6"
        disabled={false}
        visible
        onSaved={() => {}}
      />,
    ),
  );
  await act(async () =>
    resolve({
      ...official('claude-code'),
      name: 'Stale Claude',
      official: undefined,
    }),
  );
  expect(
    renderer.root
      .findAllByType(TextInput)
      .some(x => x.props.value === 'Codex relay'),
  ).toBe(true);
  expect(
    renderer.root
      .findAllByType(TextInput)
      .some(x => x.props.value === 'Stale Claude'),
  ).toBe(false);
  await act(async () => renderer.unmount());
});
test('accepts bound custom hosts and rejects mismatched hosts or credential-bearing URLs', () => {
  const binding = {
    schema_version: 1,
    harness_id: 'claude-code',
    protocol: 'messages',
    auth_type: 'bearer',
    endpoint_url: 'https://relay.example/v1/messages',
    model_id: 'relay-sonnet',
    send_reasoning: false,
    profile_id: 'a'.repeat(64),
  };
  expect(parseProviderBinding(binding, 'claude-sonnet-5')).not.toBeNull();
  expect(providerHostMatches('claude-sonnet-5', 'relay.example', binding)).toBe(
    true,
  );
  expect(
    providerHostMatches('claude-sonnet-5', 'api.anthropic.com', binding),
  ).toBe(false);
  expect(providerHostMatches('claude-sonnet-5', 'relay.example')).toBe(false);
  expect(parseProviderBinding(binding, 'gpt-5.6')).toBeNull();
  expect(
    parseProviderBinding(
      { ...binding, endpoint_url: 'https://key@relay.example/v1/messages' },
      'claude-sonnet-5',
    ),
  ).toBeNull();
  const hostile = { ...binding };
  Object.defineProperty(hostile, 'model_id', {
    get: () => {
      throw Error('must not run');
    },
    enumerable: true,
  });
  expect(parseProviderBinding(hostile, 'claude-sonnet-5')).toBeNull();
});

// DeepSeek and GLM through a relay too (2026-09-24, "only Claude works"):
// the card appears for them, DSH maps its catalog's models, GLM its own.
test.each([
  ['deepseek-v4-flash', 'dsh', ['deepseek-v4-flash', 'deepseek-v4-pro']],
  ['GLM-5.3', 'glm', ['GLM-5.3', 'GLM-5.3-Flash']],
] as const)('offers a relay for %s and saves it for %s', async (model, harness, slots) => {
  const onSaved = jest.fn();
  let renderer!: ReactTestRenderer;
  await act(async () => {
    renderer = create(
      <ProviderConfigurationCard model={model} disabled={false} visible onSaved={onSaved} />,
    );
  });
  expect(native.providerConfiguration).toHaveBeenCalledWith(harness);
  await act(async () => {
    renderer.root.findAllByType(Switch)[0].props.onValueChange(true);
  });
  for (const slot of slots) {
    expect(renderer.root.findAllByProps({ placeholder: slot }).length).toBeGreaterThan(0);
  }
  const input = (label: string) =>
    renderer.root.findAllByType(TextInput).find(x => x.props.accessibilityLabel === label)!;
  await act(async () => {
    input('Base URL or full endpoint').props.onChangeText('https://relay.example/v1');
  });
  await act(async () => {
    renderer.root.findAllByProps({ placeholder: model })[0].props.onChangeText('relay-model');
  });
  await act(async () => {
    await renderer.root
      .findAll(x => x.props.accessibilityLabel === 'Save provider settings' && typeof x.props.onPress === 'function')[0]
      .props.onPress();
  });
  expect(native.saveProviderConfiguration).toHaveBeenCalledWith(
    expect.objectContaining({ harness_id: harness, model_mappings: { [model]: 'relay-model' } }),
  );
  expect(onSaved).toHaveBeenCalledWith(harness);
  const binding = {
    schema_version: 1, harness_id: harness, protocol: 'chat-completions', auth_type: 'bearer',
    endpoint_url: 'https://relay.example/v1/chat/completions', model_id: 'relay-model',
    send_reasoning: false, profile_id: 'a'.repeat(64),
  };
  expect(parseProviderBinding(binding, model)).not.toBeNull();
  expect(parseProviderBinding(binding, 'claude-sonnet-5')).toBeNull();
  await act(async () => renderer.unmount());
});
