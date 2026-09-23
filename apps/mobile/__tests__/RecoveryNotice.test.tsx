import React from 'react';
import { act, create, type ReactTestRenderer } from 'react-test-renderer';
import { RecoveryNotice } from '../src/components/RecoveryNotice';
import { sanitizeCompletionError } from '../src/completion/validation';
import {
  completionRecoveryLabel,
  recoveryMessage,
  recoveryErrorText,
} from '../src/components/recoveryMessage';
import {
  createTranslator,
  createPreferencesStore,
  createDefaultPreferences,
} from '../src/preferences';
import { AppPresentationProvider } from '../src/presentation/AppPresentation';

test.each(['en-US', 'zh-CN'] as const)(
  'explains recovery and preserves full diagnostic details in %s',
  async locale => {
    const t = createTranslator(locale);
    const error = `E_WORKSPACE_REVOKED: ${'Detailed native reason. '.repeat(
      100,
    )}END`;
    const store = createPreferencesStore({
      initialPreferences: { ...createDefaultPreferences(), locale },
    });
    const render = (value: string) => (
      <AppPresentationProvider store={store}>
        <RecoveryNotice error={value} />
      </AppPresentationProvider>
    );
    let renderer!: ReactTestRenderer;
    await act(async () => {
      renderer = create(render(error));
    });
    expect(
      renderer.root.findByProps({ accessibilityRole: 'alert' }).props.children,
    ).toBe(t('recovery.regrant'));
    expect(
      renderer.root.findAllByProps({ testID: 'recovery-details-scroll' }),
    ).toHaveLength(0);
    await act(async () =>
      renderer.root
        .findByProps({ testID: 'recovery-details-toggle' })
        .props.onPress(),
    );
    const detail = renderer.root.findByProps({
      testID: 'recovery-details-scroll',
    });
    expect(
      detail.findByProps({ children: error }).props.numberOfLines,
    ).toBeUndefined();
    expect(
      renderer.root.findByProps({ testID: 'recovery-details-toggle' }).props
        .accessibilityState.expanded,
    ).toBe(true);
    await act(async () => renderer.update(render('E_WORKSPACE_PERSISTENCE')));
    expect(
      renderer.root.findAllByProps({ testID: 'recovery-details-scroll' }),
    ).toHaveLength(0);
    expect(
      renderer.root.findByProps({ accessibilityRole: 'alert' }).props.children,
    ).toBe(t('recovery.bindingSave'));
    await act(async () => renderer.unmount());
  },
);

test('recovery distinguishes protection, permission, download and persistence without guessing unknown causes', () => {
  const t = createTranslator('zh-CN');
  expect(recoveryMessage('E_SESSION_PROTECTION', t)).toContain('解锁');
  expect(recoveryMessage('E_CONTEXT_STORAGE', t)).toContain('解锁');
  expect(recoveryMessage('E_CONTEXT_CONSENT_INVALID', t)).toContain('重新确认');
  expect(recoveryMessage('E_WORKSPACE_REVOKED', t)).toContain('重新授权');
  expect(recoveryMessage('E_WORKSPACE_NOT_DOWNLOADED', t)).toContain('下载');
  expect(recoveryMessage('E_AGENT_PERSISTENCE', t)).toContain('保存');
  expect(recoveryMessage('E_AGENT_CONFLICT', t)).toBe('文件版本、会话或工作区状态与这次操作冲突，请读取最新状态后再试。');
  expect(recoveryMessage('E_FUTURE_FAILURE', t)).toBe(t('recovery.generic'));
  expect(recoveryMessage('unknown native message', t)).toBe(
    t('recovery.generic'),
  );
  expect(
    recoveryErrorText(
      Object.assign(new Error('access denied'), {
        code: 'E_WORKSPACE_REVOKED',
      }),
    ),
  ).toBe('E_WORKSPACE_REVOKED: access denied');
});

test.each(['en-US', 'zh-CN'] as const)(
  'labels each actual recovery action in %s',
  locale => {
    const t = createTranslator(locale);
    expect(completionRecoveryLabel('persistence_pending', t)).toBe(
      t('recovery.retrySave'),
    );
    expect(completionRecoveryLabel('commit_pending', t)).toBe(
      t('recovery.retrySave'),
    );
    expect(completionRecoveryLabel('resume_available', t)).toBe(
      t('recovery.resume'),
    );
    expect(completionRecoveryLabel('retryable', t)).toBe(
      t('messages.retryResponse'),
    );
  },
);

test.each(['en-US', 'zh-CN'] as const)('explains a request timeout without asserting a network failure in %s', locale => {
  const t = createTranslator(locale);
  expect(recoveryMessage('E_COMPLETION_TIMEOUT', t)).toBe(t('recovery.timeout'));
  expect(recoveryMessage('E_COMPLETION_TIMEOUT', t)).not.toBe(t('recovery.network'));
});

test.each(['en-US', 'zh-CN'] as const)('preserves and explains the output-limit error in %s', locale => {
  const failure = sanitizeCompletionError({ code: 'E_COMPLETION_LENGTH', message: 'private provider output' });
  expect(failure.code).toBe('E_COMPLETION_LENGTH');
  expect(failure.message).not.toContain('private provider output');
  expect(recoveryMessage(failure.code, createTranslator(locale))).toBe(createTranslator(locale)('recovery.outputLimit'));
});

test('a refused attachment says what to change, on both hosts', () => {
  const zh = createTranslator('zh-CN');
  const en = createTranslator('en-US');
  // Android's projection refusals, which used to read only as "could not finish".
  expect(recoveryMessage('E_COMPLETION_BODY_TOO_LARGE', zh)).toContain('20 页');
  expect(recoveryMessage('E_COMPLETION_BODY_TOO_LARGE', en)).toContain('20 pages');
  expect(recoveryMessage('E_COMPLETION_CONTEXT_UNSUPPORTED', zh)).toContain('加密的 PDF');
  expect(recoveryMessage('E_COMPLETION_CONTEXT_INVALID', en)).toContain('attach it again');
  // iOS reports an attachment it cannot project as history.
  expect(recoveryMessage('E_COMPLETION_HISTORY', zh)).toContain('附件');
  for (const code of [
    'E_COMPLETION_BODY_TOO_LARGE', 'E_COMPLETION_CONTEXT_UNSUPPORTED',
    'E_COMPLETION_CONTEXT_INVALID', 'E_COMPLETION_HISTORY',
  ]) {
    expect(recoveryMessage(code, en)).not.toBe(en('recovery.generic'));
  }
});
