import type { TranslationKey, Translator } from '../preferences';

const reasons: Readonly<Record<string, TranslationKey>> = {
  E_ATTEMPT_PERSISTENCE: 'recovery.save',
  E_AGENT_PERSISTENCE: 'recovery.save',
  E_AGENT_EVENT_CAPACITY: 'recovery.eventCapacity',
  E_WORKSPACE_PERSISTENCE: 'recovery.bindingSave',
  E_SESSION_PROTECTION: 'recovery.locked',
  E_ATTEMPT_INTERRUPTED: 'recovery.interrupted',
  E_WORKSPACE_REVOKED: 'recovery.regrant',
  E_WORKSPACE_STATUS_STALE: 'recovery.regrant',
  E_WORKSPACE_ROOT_CHANGED: 'recovery.regrant',
  E_WORKSPACE_NOT_FOUND: 'recovery.missing',
  E_WORKSPACE_NOT_DOWNLOADED: 'recovery.download',
  E_WORKSPACE_IMPORT_REQUIRED: 'recovery.import',
  E_WORKSPACE_UNAVAILABLE: 'recovery.unavailable',
  E_WORKSPACE_CAPABILITY: 'recovery.capability',
  E_WORKSPACE_CONFLICT: 'recovery.changed',
  E_AGENT_CONFLICT: 'messages.toolFailure.conflict',
  E_AGENT_CAPABILITY: 'recovery.agentCapability',
  E_AGENT_ROUND_AMBIGUOUS: 'recovery.roundAmbiguous',
  E_AGENT_EXECUTION_AMBIGUOUS: 'recovery.executionAmbiguous',
  E_CONTEXT_CHANGED: 'recovery.contextRefresh',
  E_CONTEXT_STORAGE: 'recovery.contextStorage',
  E_CONTEXT_SNAPSHOT_MISSING: 'recovery.contextRefresh',
  E_CONTEXT_CONSENT_INVALID: 'recovery.contextRefresh',
  E_WORKSPACE_BUSY: 'recovery.busy',
  E_COMPLETION_BUSY: 'recovery.busy',
  E_WORKSPACE_CLEARANCE_UNAVAILABLE: 'recovery.clearance',
  E_WORKSPACE_REMOVAL_PENDING: 'workspaces.removalPending',
  E_COMPLETION_TIMEOUT: 'recovery.timeout',
  E_COMPLETION_LENGTH: 'recovery.outputLimit',
  E_COMPLETION_TRANSPORT: 'recovery.network',
  E_COMPLETION_HTTP_429: 'recovery.rateLimit',
  E_COMPLETION_CREDENTIAL_UNAVAILABLE: 'recovery.credential',
  E_COMPLETION_CREDENTIAL_CHANGED: 'recovery.credential',
};

export function recoveryCode(error: string): string | null {
  return error.match(/\bE_[A-Z][A-Z0-9_]*\b/u)?.[0] ?? null;
}

export function recoveryMessage(error: string, t: Translator): string {
  const code = recoveryCode(error);
  return t((code === null ? undefined : reasons[code]) ?? 'recovery.generic');
}

/** Keep native structured codes even when their human message omits them. */
export function recoveryErrorText(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === 'string' &&
    /^E_[A-Z0-9_]+$/u.test(code) &&
    !message.includes(code)
    ? `${code}: ${message}`
    : message;
}

export function completionRecoveryLabel(phase: string, t: Translator): string {
  if (phase === 'persistence_pending' || phase === 'commit_pending')
    return t('recovery.retrySave');
  if (phase === 'resume_available') return t('recovery.resume');
  return t('messages.retryResponse');
}
