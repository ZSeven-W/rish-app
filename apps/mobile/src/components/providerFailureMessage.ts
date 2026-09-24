import type { ProviderFailure } from '../completion/CompletionController';
import type { Translator } from '../preferences';

/** The round codes a provider's own refusal can hide behind. */
const ROUND_CODES = new Set([
  'E_AGENT_ROUND_AMBIGUOUS',
  'E_AGENT_TRANSCRIPT',
  'E_AGENT_TOOL_FAILED',
]);

const UNREADABLE = new Set([
  'E_COMPLETION_RESPONSE_JSON',
  'E_COMPLETION_RESPONSE_MODEL',
  'E_COMPLETION_MODEL_MISMATCH',
  'E_COMPLETION_PROVIDER_RESPONSE_ID',
  'E_COMPLETION_EMPTY_RESPONSE',
  'E_COMPLETION_TOOL_CALL_INVALID',
  'E_COMPLETION_FINISH_RELATION',
]);

/**
 * What the provider itself said, in words, when a round failed on it: a key
 * refused, an address not found, a reply this app cannot read. The round's
 * recorded code is unchanged -- a dispatched round stays ambiguous -- but
 * "the service refused the key" is what a person setting up a relay needs,
 * where "may have reached the service" sent them nowhere. Null when the
 * transport said nothing more specific than the round's own code.
 */
export function providerFailureMessage(
  roundCode: string | null,
  failure: ProviderFailure | null,
  t: Translator,
): string | null {
  if (roundCode === null || failure === null || !ROUND_CODES.has(roundCode)) return null;
  const status = failure.httpStatus;
  if (failure.code === 'E_COMPLETION_CREDENTIAL_UNAVAILABLE' || status === 401 || status === 403) {
    return t('recovery.provider.credential', { status: status ?? '401/403' });
  }
  if (failure.code === 'E_COMPLETION_HTTP_429' || status === 429) return t('recovery.rateLimit');
  if (status === 404) return t('recovery.provider.notFound');
  if (failure.code === 'E_COMPLETION_HTTP_STATUS') {
    return t('recovery.provider.status', { status: status ?? '?' });
  }
  if (UNREADABLE.has(failure.code)) return t('recovery.provider.unreadable', { code: failure.code });
  return null;
}

/** The line the details show for it. */
export function providerFailureDetail(failure: ProviderFailure): string {
  return `provider: ${failure.code}${failure.httpStatus !== null ? ` HTTP ${failure.httpStatus}` : ''}`;
}
