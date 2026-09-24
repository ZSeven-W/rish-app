import {
  harnessForModel,
  isHarnessModelId,
  providerHostForModel,
  type HarnessModelId,
} from '../harness/types';

export type ConfigurableHarness = 'claude-code' | 'codex' | 'dsh' | 'glm';
export const CONFIGURABLE_HARNESSES: readonly ConfigurableHarness[] = [
  'claude-code',
  'codex',
  'dsh',
  'glm',
];
export type ProviderProtocol = 'messages' | 'responses' | 'chat-completions';
export type ProviderAuth = 'bearer' | 'x-api-key' | 'api-key';
export type ProviderConfiguration = {
  schema_version: 1;
  harness_id: ConfigurableHarness;
  name: string;
  endpoint_url: string;
  protocol: ProviderProtocol;
  auth_type: ProviderAuth;
  send_reasoning: boolean;
  model_mappings: Readonly<Record<string, string>>;
  official?: true;
  full_url?: boolean;
};
export type ProviderBinding = {
  schema_version: 1;
  harness_id: ConfigurableHarness;
  endpoint_url: string;
  protocol: ProviderProtocol;
  auth_type: ProviderAuth;
  send_reasoning: boolean;
  model_id: string;
  profile_id: string;
};
export function providerBindingHost(binding: ProviderBinding): string {
  return new URL(binding.endpoint_url).hostname
    .replace(/^\[|\]$/g, '')
    .toLowerCase();
}
export function parseProviderBinding(
  value: unknown,
  model: HarnessModelId,
): ProviderBinding | null {
  if (
    !isHarnessModelId(model) ||
    !value ||
    typeof value !== 'object' ||
    Array.isArray(value)
  )
    return null;
  if (
    ![Object.prototype, null].includes(Object.getPrototypeOf(value)) ||
    Object.getOwnPropertySymbols(value).length > 0
  )
    return null;
  if (
    Object.values(Object.getOwnPropertyDescriptors(value)).some(
      d => !('value' in d) || !d.enumerable,
    )
  )
    return null;
  const raw = value as Record<string, unknown>;
  const keys = [
    'schema_version',
    'harness_id',
    'endpoint_url',
    'protocol',
    'auth_type',
    'send_reasoning',
    'model_id',
    'profile_id',
  ];
  if (
    Object.keys(raw).length !== keys.length ||
    keys.some(key => !Object.prototype.hasOwnProperty.call(raw, key)) ||
    raw.schema_version !== 1 ||
    !(CONFIGURABLE_HARNESSES as readonly string[]).includes(String(raw.harness_id)) ||
    raw.harness_id !== harnessForModel(model) ||
    !['messages', 'responses', 'chat-completions'].includes(
      String(raw.protocol),
    ) ||
    !['bearer', 'x-api-key', 'api-key'].includes(String(raw.auth_type)) ||
    typeof raw.send_reasoning !== 'boolean' ||
    // Explicitly reject control characters in wire model identifiers.
    typeof raw.model_id !== 'string' ||
    // eslint-disable-next-line no-control-regex
    !/^[^\s\u0000-\u001f\u007f]{1,128}$/u.test(raw.model_id) ||
    typeof raw.profile_id !== 'string' ||
    !/^[a-f0-9]{64}$/.test(raw.profile_id) ||
    typeof raw.endpoint_url !== 'string' ||
    raw.endpoint_url.length > 2048
  )
    return null;
  try {
    const url = new URL(raw.endpoint_url);
    const host = url.hostname.replace(/^\[|\]$/g, '');
    if (
      !host ||
      url.username ||
      url.password ||
      url.search ||
      url.hash ||
      (url.protocol !== 'https:' &&
        !(
          url.protocol === 'http:' &&
          ['localhost', '127.0.0.1', '::1'].includes(host)
        ))
    )
      return null;
  } catch {
    return null;
  }
  return { ...raw } as ProviderBinding;
}

export function providerHostMatches(
  model: HarnessModelId,
  host: unknown,
  binding?: unknown,
): boolean {
  if (!isHarnessModelId(model)) return false;
  if (binding === undefined) return host === providerHostForModel(model);
  const parsed = parseProviderBinding(binding, model);
  return parsed !== null && host === providerBindingHost(parsed);
}
export function providerRecordKeys(
  value: unknown,
  keys: ReadonlySet<string>,
): ReadonlySet<string> {
  return value !== null &&
    typeof value === 'object' &&
    Object.prototype.hasOwnProperty.call(value, 'provider_configuration')
    ? new Set([...keys, 'provider_configuration'])
    : keys;
}
