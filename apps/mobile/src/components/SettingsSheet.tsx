import { DshModelCatalogCard } from './DshModelCatalogCard';
import { getDshCatalog, subscribeDshCatalog } from '../models/catalog';
import { useSyncExternalStore } from 'react';
import { TaskSettingsCard } from './TaskSettingsCard';
import { ProviderConfigurationCard } from './ProviderConfigurationCard';
import { HarnessSubscriptionCard, harnessSubscriptionIdForModel } from './HarnessSubscriptionCard';
import { GlmAccountCard } from './GlmAccountCard';
import { isGlmModelId } from '../harness/types';
import type { ConfigurableHarness } from '../providers/configuration';
import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Activity from 'lucide-react-native/icons/activity';
import Bot from 'lucide-react-native/icons/bot';
import BrainCircuit from 'lucide-react-native/icons/brain-circuit';
import ChevronRight from 'lucide-react-native/icons/chevron-right';
import CircleAlert from 'lucide-react-native/icons/circle-alert';
import GitBranch from 'lucide-react-native/icons/git-branch';
import KeyRound from 'lucide-react-native/icons/key-round';
import Languages from 'lucide-react-native/icons/languages';
import PackageOpen from 'lucide-react-native/icons/package-open';
import Palette from 'lucide-react-native/icons/palette';
import RotateCcw from 'lucide-react-native/icons/rotate-ccw';
import ShieldCheck from 'lucide-react-native/icons/shield-check';
import Smartphone from 'lucide-react-native/icons/smartphone';
import Sparkles from 'lucide-react-native/icons/sparkles';
import Trash2 from 'lucide-react-native/icons/trash-2';
import Wrench from 'lucide-react-native/icons/wrench';
import X from 'lucide-react-native/icons/x';

import type { LucideIcon } from 'lucide-react-native';

import {
  normalizeGitHttpsProxyUrl,
  type LocalePreference,
  type ThemeMode,
  type ToolPermissionMode,
} from '../preferences';
import { useAppPresentation } from '../presentation/AppPresentation';
import { fonts, hitSlop, type ThemePalette } from '../theme';
import { localizedModelDetails, type SupportedModel } from './ModelPicker';
import type { RuntimeVerificationStatus } from './RuntimeEvidenceSheet';
import { AppIcon } from './AppIcon';
import { SlidingSurface } from './SlidingSurface';

type Props = {
  authOnly?: boolean;
  taskConversationId?: string | null;
  busy: boolean;
  credentialConfigured: boolean;
  harnessName: string;
  providerName: string;
  model: SupportedModel;
  runtimeAvailable: boolean;
  runtimeLabel: string;
  runtimeStatus: RuntimeVerificationStatus;
  covered: boolean;
  visible: boolean;
  onClearCredential: () => void;
  onClose: () => void;
  onDismiss: () => void;
  onConfigureCredential: () => void;
  onOpenModelPicker: () => void;
  onOpenMirrors: () => void;
  onOpenEnvironments?: () => void;
  onOpenRuntime: () => void;
  onPreferencesChanged: () => void;
  onProviderConfigurationChanged?: (harness: ConfigurableHarness) => void;
};

export function SettingsSheet(props: Props) {
  const dshCatalog = useSyncExternalStore(subscribeDshCatalog, getDshCatalog);
  const insets = useSafeAreaInsets();
  const scrollRef = useRef<React.ElementRef<typeof ScrollView>>(null);
  const [presented, setPresented] = useState(false);
  const adjustsKeyboard = props.visible && !props.covered && presented;
  useLayoutEffect(() => {
    if (!props.visible) setPresented(false);
    if (adjustsKeyboard) return;
    // The hidden SlidingSurface stays mounted one screen below the window.
    // Native keyboard insets use window coordinates; do not retain an inset
    // calculated while the surface is translated or covered by another input.
    scrollRef.current?.getNativeScrollRef()?.setNativeProps({
      contentInset: {top: 0, left: 0, bottom: 0, right: 0},
      scrollIndicatorInsets: {top: 0, left: 0, bottom: 0, right: 0},
    });
  }, [adjustsKeyboard, props.visible]);

  const { colors, preferences, store, t } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const [gitProxyDraft, setGitProxyDraft] = useState(
    () => preferences.gitHttpsProxyUrl ?? '',
  );
  const [gitProxyError, setGitProxyError] = useState<string | null>(null);
  const modelName = (model: SupportedModel) =>
    localizedModelDetails(model, t).name;
  const modelDescription = (model: SupportedModel) =>
    localizedModelDetails(model, t).description;
  const runtimeVerified = props.runtimeStatus === 'verified';
  const runtimePillLabel = runtimeVerified
    ? t('settings.local')
    : props.runtimeLabel;
  const subscriptionHarnessId = harnessSubscriptionIdForModel(props.model);

  useEffect(() => {
    if (!props.visible) return;
    setGitProxyDraft(preferences.gitHttpsProxyUrl ?? '');
    setGitProxyError(null);
  }, [preferences.gitHttpsProxyUrl, props.visible]);

  const update = (change: () => void) => {
    change();
    props.onPreferencesChanged();
  };

  const saveGitProxy = () => {
    if (gitProxyDraft.length === 0) {
      setGitProxyError(null);
      update(() => store.setGitHttpsProxyUrl(null));
      return;
    }
    const normalized = normalizeGitHttpsProxyUrl(gitProxyDraft);
    if (normalized === null) {
      setGitProxyError(t('settings.gitHttpsProxy.invalid'));
      return;
    }
    setGitProxyDraft(normalized);
    setGitProxyError(null);
    update(() => store.setGitHttpsProxyUrl(normalized));
  };

  const clearGitProxy = () => {
    setGitProxyDraft('');
    setGitProxyError(null);
    update(() => store.setGitHttpsProxyUrl(null));
  };

  return (
    <SlidingSurface
      closeAccessibilityLabel={t('settings.close')}
      accessibilityHidden={props.covered}
      onClose={props.onClose}
      onDismiss={props.onDismiss}
      onPresented={() => setPresented(true)}
      side="bottom"
      visible={props.visible}
      widthRatio={1}
      scrim={false}
    >
      <View
        style={[
          styles.root,
          { marginTop: insets.top + 8, paddingBottom: insets.bottom + 14 },
        ]}
      >
        <View style={styles.header}>
          <View style={styles.headerSide} />
          <Text accessibilityRole="header" style={styles.headerTitle}>
            {t(props.authOnly ? 'messages.signIn' : 'settings.eyebrow')}
          </Text>
          <Pressable
            accessibilityLabel={t('settings.close')}
            accessibilityRole="button"
            hitSlop={hitSlop}
            onPress={props.onClose}
            style={styles.close}
          >
            <AppIcon color={colors.text} icon={X} size={21} />
          </Pressable>
        </View>

        <ScrollView
          ref={scrollRef}
          testID="settings-scroll"
          automaticallyAdjustKeyboardInsets={adjustsKeyboard}
          contentInsetAdjustmentBehavior="never"
          contentContainerStyle={styles.content}
          keyboardDismissMode="interactive"
          keyboardShouldPersistTaps="handled"
          showsVerticalScrollIndicator
        >
          {isGlmModelId(props.model) && <GlmAccountCard visible={props.visible} disabled={props.busy}
            onSourceChanged={() => props.onProviderConfigurationChanged?.('glm')} />}
          {subscriptionHarnessId !== null && (
            <HarnessSubscriptionCard disabled={props.busy} id={subscriptionHarnessId} visible={props.visible}
              onCredentialChanged={() => props.onProviderConfigurationChanged?.(subscriptionHarnessId)} />
          )}
          {!props.authOnly && <>
          <TaskSettingsCard conversationId={props.taskConversationId} />
          <SectionLabel label={t('settings.section.appearance')} />
          <SettingCard>
            <SettingHeader
              description={t('settings.theme.description')}
              icon={Palette}
              title={t('settings.theme')}
            />
            <SegmentedControl<ThemeMode>
              options={[
                ['system', t('settings.theme.system')],
                ['light', t('settings.theme.light')],
                ['dark', t('settings.theme.dark')],
              ]}
              selected={preferences.themeMode}
              onSelect={value => update(() => store.setThemeMode(value))}
            />
            <Divider />
            <SettingHeader
              description={t('settings.language.description')}
              icon={Languages}
              title={t('settings.language')}
            />
            <SegmentedControl<LocalePreference>
              options={[
                ['system', t('settings.language.system')],
                ['zh-CN', t('settings.language.zhCN')],
                ['en-US', t('settings.language.enUS')],
              ]}
              selected={preferences.locale}
              onSelect={value => update(() => store.setLocale(value))}
            />
          </SettingCard>

          <SectionLabel
            label={t('settings.section.harness', { harness: props.harnessName })}
          />
          <DshModelCatalogCard model={props.model} disabled={props.busy} visible={props.visible} />
          <ProviderConfigurationCard model={props.model} disabled={props.busy}
            visible={props.visible} onSaved={harness => props.onProviderConfigurationChanged?.(harness)} />
          <SettingCard>
            <View style={styles.credentialHeader}>
              <SettingIcon icon={KeyRound} />
              <View
                style={[
                  styles.statusDot,
                  props.credentialConfigured && styles.statusDotReady,
                ]}
              />
              <View style={styles.flex}>
                <Text style={styles.settingTitle}>
                  {t('settings.apiCredential')}
                </Text>
                <Text style={styles.settingDescription}>
                  {props.credentialConfigured
                    ? t('settings.credential.keychain')
                    : props.runtimeAvailable
                    ? t('settings.credential.notConfigured')
                    : t('settings.credential.adapterUnavailable')}
                </Text>
              </View>
              {props.busy && (
                <ActivityIndicator color={colors.accent} size="small" />
              )}
            </View>
            <Text style={styles.credentialBody}>
              {t('settings.credential.explanation')}
            </Text>
            <View style={styles.buttonRow}>
              <Pressable
                accessibilityLabel={
                  props.credentialConfigured
                    ? t('settings.credential.replaceLabel', { provider: props.providerName })
                    : t('settings.credential.configureLabel', { provider: props.providerName })
                }
                accessibilityRole="button"
                accessibilityState={{
                  busy: props.busy,
                  disabled: props.busy || !props.runtimeAvailable,
                }}
                disabled={props.busy || !props.runtimeAvailable}
                onPress={props.onConfigureCredential}
                style={[
                  styles.primaryButton,
                  !props.runtimeAvailable && styles.disabled,
                ]}
              >
                <AppIcon color={colors.background} icon={KeyRound} size={15} />
                <Text style={styles.primaryText}>
                  {props.runtimeAvailable
                    ? props.credentialConfigured
                      ? t('settings.credential.replace')
                      : t('settings.credential.configure')
                    : t('settings.credential.adapterRequired')}
                </Text>
              </Pressable>
              {props.credentialConfigured && (
                <Pressable
                  accessibilityLabel={t('settings.credential.clearLabel', { provider: props.providerName })}
                  accessibilityRole="button"
                  disabled={props.busy}
                  accessibilityState={{ disabled: props.busy }}
                  onPress={props.onClearCredential}
                  style={[
                    styles.secondaryButton,
                    props.busy && styles.disabled,
                  ]}
                >
                  <AppIcon color={colors.danger} icon={Trash2} size={15} />
                  <Text style={styles.dangerText}>{t('common.clear')}</Text>
                </Pressable>
              )}
            </View>
          </SettingCard>

          <SectionLabel label={t('settings.section.conversation')} />
          <SettingCard>
            <Pressable
              accessibilityLabel={t('settings.chooseDefaultModel')}
              accessibilityRole="button"
              onPress={props.onOpenModelPicker}
              style={styles.linkRow}
            >
              <SettingIcon icon={Bot} />
              <View style={styles.flex}>
                <Text style={styles.settingTitle}>
                  {t('settings.modelForChat')}
                </Text>
                <Text style={styles.settingDescription}>
                  {modelDescription(props.model)}
                </Text>
              </View>
              <Text numberOfLines={1} style={styles.value}>
                {modelName(props.model)}
              </Text>
              <AppIcon color={colors.faint} icon={ChevronRight} size={18} />
            </Pressable>
            <Divider />
            <SettingHeader
              description={t('settings.defaultModel.description')}
              icon={Sparkles}
              title={t('settings.defaultModel')}
            />
            <View style={{gap: 8}}>
              {dshCatalog.models.map(entry => <Pressable key={entry.id} accessibilityRole="radio"
                accessibilityState={{checked: preferences.defaultModel === entry.id}}
                onPress={() => update(() => store.setDefaultModel(entry.id))}
                style={{paddingVertical: 12, paddingHorizontal: 14, borderWidth: 1, borderRadius: 10, borderColor: colors.line}}>
                <Text style={{color: preferences.defaultModel === entry.id ? colors.text : colors.textDim}}>
                  {preferences.defaultModel === entry.id ? '● ' : '○ '}{modelName(entry.id)}
                </Text>
              </Pressable>)}
            </View>
            <Divider />
            <ToggleRow
              description={t('settings.showReasoning.description')}
              icon={BrainCircuit}
              label={t('settings.showReasoning')}
              value={preferences.showReasoning}
              onChange={value => update(() => store.setShowReasoning(value))}
            />
            <Divider />
            <ToggleRow
              description={t('settings.autoExpandTools.description')}
              icon={Wrench}
              label={t('settings.autoExpandTools')}
              value={preferences.autoExpandTools}
              onChange={value => update(() => store.setAutoExpandTools(value))}
            />
          </SettingCard>

          <SectionLabel label={t('settings.section.files')} />
          <SettingCard>
            <SettingHeader
              description={t('settings.gitHttpsProxy.description')}
              icon={GitBranch}
              title={t('settings.gitHttpsProxy')}
            />
            <TextInput
              accessibilityHint={t('settings.gitHttpsProxy.hint')}
              accessibilityLabel={t('settings.gitHttpsProxy.input')}
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="url"
              onChangeText={value => {
                setGitProxyDraft(value);
                setGitProxyError(null);
              }}
              onSubmitEditing={saveGitProxy}
              placeholder={t('settings.gitHttpsProxy.placeholder')}
              placeholderTextColor={colors.faint}
              returnKeyType="done"
              spellCheck={false}
              style={styles.proxyInput}
              value={gitProxyDraft}
            />
            <Text style={styles.proxyHint}>
              {t('settings.gitHttpsProxy.hint')}
            </Text>
            {gitProxyError !== null && (
              <Text
                accessibilityLiveRegion="assertive"
                accessibilityRole="alert"
                style={styles.proxyError}
              >
                {gitProxyError}
              </Text>
            )}
            <View style={styles.buttonRow}>
              <Pressable
                accessibilityLabel={t('settings.gitHttpsProxy.save')}
                accessibilityRole="button"
                onPress={saveGitProxy}
                style={[styles.primaryButton, styles.proxySaveButton]}
              >
                <Text style={styles.primaryText}>
                  {t('settings.gitHttpsProxy.save')}
                </Text>
              </Pressable>
              <Pressable
                accessibilityLabel={t('settings.gitHttpsProxy.clear')}
                accessibilityRole="button"
                onPress={clearGitProxy}
                style={styles.secondaryButton}
              >
                <Text style={styles.secondaryText}>
                  {t('settings.gitHttpsProxy.clear')}
                </Text>
              </Pressable>
            </View>
            <Divider />
            <Pressable
              accessibilityLabel={t('settings.packageMirrors')}
              accessibilityRole="button"
              onPress={props.onOpenMirrors}
              style={styles.linkRow}
            >
              <SettingIcon icon={PackageOpen} />
              <View style={styles.flex}>
                <Text style={styles.settingTitle}>
                  {t('settings.packageMirrors')}
                </Text>
                <Text style={styles.settingDescription}>
                  {t('settings.packageMirrors.description')}
                </Text>
              </View>
              <AppIcon color={colors.faint} icon={ChevronRight} size={18} />
            </Pressable>
            {props.onOpenEnvironments !== undefined && (
              <>
                <Divider />
                <Pressable
                  accessibilityLabel={t('settings.environments')}
                  accessibilityRole="button"
                  onPress={props.onOpenEnvironments}
                  style={styles.linkRow}
                >
                  <SettingIcon icon={PackageOpen} />
                  <View style={styles.flex}>
                    <Text style={styles.settingTitle}>{t('settings.environments')}</Text>
                    <Text style={styles.settingDescription}>{t('settings.environments.description')}</Text>
                  </View>
                  <AppIcon color={colors.faint} icon={ChevronRight} size={18} />
                </Pressable>
              </>
            )}
            <Divider />
            <SettingHeader
              description={t('settings.toolPermission.description')}
              icon={ShieldCheck}
              title={t('settings.toolPermission')}
            />
            <SegmentedControl<ToolPermissionMode>
              options={[
                ['read-only', t('settings.toolPermission.readOnly')],
                [
                  'workspace-write',
                  t('settings.toolPermission.workspaceWrite'),
                ],
              ]}
              selected={preferences.toolPermission}
              onSelect={value => update(() => store.setToolPermission(value))}
            />
            <Divider />
            <ToggleRow
              description={t('settings.confirmDestructiveFiles.description')}
              icon={CircleAlert}
              label={t('settings.confirmDestructiveFiles')}
              value={preferences.confirmDestructiveFileActions}
              onChange={value =>
                update(() => store.setConfirmDestructiveFileActions(value))
              }
            />
          </SettingCard>

          <SectionLabel label={t('settings.section.execution')} />
          <SettingCard>
            <Pressable
              accessibilityLabel={t('settings.openRuntimeEvidence')}
              accessibilityRole="button"
              onPress={props.onOpenRuntime}
              style={styles.linkRow}
            >
              <SettingIcon icon={Activity} />
              <View style={styles.flex}>
                <Text style={styles.settingTitle}>
                  {t('settings.runtimeEvidence')}
                </Text>
                <Text style={styles.settingDescription}>
                  {t('settings.runtimeEvidence.description')}
                </Text>
              </View>
              <View style={styles.localPill}>
                <View
                  style={[
                    styles.localDot,
                    runtimeVerified && styles.localDotReady,
                    props.runtimeStatus === 'failed' && styles.localDotFailed,
                  ]}
                />
                <Text
                  numberOfLines={1}
                  style={[
                    styles.localText,
                    runtimeVerified && styles.localTextReady,
                    props.runtimeStatus === 'failed' && styles.localTextFailed,
                  ]}
                >
                  {runtimePillLabel}
                </Text>
              </View>
              <AppIcon color={colors.faint} icon={ChevronRight} size={18} />
            </Pressable>
            <Divider />
            <View style={styles.boundaryRow}>
              <SettingIcon icon={Smartphone} />
              <View style={styles.flex}>
                <Text style={styles.settingTitle}>
                  {t('settings.localSubstrate')}
                </Text>
                <Text style={styles.settingDescription}>
                  {t('settings.boundaryDescription')}
                </Text>
              </View>
            </View>
          </SettingCard>

          <Pressable
            accessibilityLabel={t('settings.reset')}
            accessibilityRole="button"
            onPress={() => update(() => store.reset())}
            style={styles.resetButton}
          >
            <AppIcon color={colors.danger} icon={RotateCcw} size={17} />
            <Text style={styles.resetText}>{t('settings.reset')}</Text>
          </Pressable>
          </>}
        </ScrollView>
      </View>
    </SlidingSurface>
  );
}

function SectionLabel({ label }: { label: string }) {
  const { colors } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  return <Text style={styles.sectionLabel}>{label}</Text>;
}

function SettingCard({ children }: React.PropsWithChildren) {
  const { colors } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  return <View style={styles.card}>{children}</View>;
}

function SettingHeader({
  icon,
  title,
  description,
}: {
  icon: LucideIcon;
  title: string;
  description: string;
}) {
  const { colors } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  return (
    <View style={styles.settingHeadingRow}>
      <SettingIcon icon={icon} />
      <View style={styles.flex}>
        <Text style={styles.settingTitle}>{title}</Text>
        <Text style={styles.settingDescription}>{description}</Text>
      </View>
    </View>
  );
}

function SettingIcon({ icon }: { icon: LucideIcon }) {
  const { colors } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  return (
    <View style={styles.settingIcon}>
      <AppIcon color={colors.textDim} icon={icon} size={17} />
    </View>
  );
}

function Divider() {
  const { colors } = useAppPresentation();
  const style = useMemo(
    () => ({
      height: StyleSheet.hairlineWidth,
      backgroundColor: colors.line,
      marginVertical: 11,
    }),
    [colors],
  );
  return <View style={style} />;
}

function SegmentedControl<Value extends string>({
  options,
  selected,
  onSelect,
}: {
  options: ReadonlyArray<readonly [Value, string]>;
  selected: Value;
  onSelect: (value: Value) => void;
}) {
  const { colors } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  return (
    <View style={styles.segmented}>
      {options.map(([value, label]) => {
        const active = value === selected;
        return (
          <Pressable
            accessibilityLabel={label}
            accessibilityRole="radio"
            accessibilityState={{ checked: active }}
            key={value}
            onPress={() => onSelect(value)}
            style={[styles.segment, active && styles.segmentActive]}
          >
            <Text
              style={[styles.segmentText, active && styles.segmentTextActive]}
            >
              {label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

function ToggleRow({
  icon,
  label,
  description,
  value,
  onChange,
}: {
  icon: LucideIcon;
  label: string;
  description: string;
  value: boolean;
  onChange: (value: boolean) => void;
}) {
  const { colors } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  return (
    <View style={styles.toggleRow}>
      <SettingIcon icon={icon} />
      <View style={styles.flex}>
        <Text style={styles.settingTitle}>{label}</Text>
        <Text style={styles.settingDescription}>{description}</Text>
      </View>
      <Switch
        accessibilityLabel={label}
        ios_backgroundColor={colors.surfaceRaised}
        onValueChange={onChange}
        thumbColor={value ? colors.text : colors.muted}
        trackColor={{ false: colors.line, true: colors.accent }}
        value={value}
      />
    </View>
  );
}

const createStyles = (colors: ThemePalette) =>
  StyleSheet.create({
    root: {
      flex: 1,
      backgroundColor: colors.background,
      borderTopLeftRadius: 28,
      borderTopRightRadius: 28,
      overflow: 'hidden',
    },
    header: {
      height: 64,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'space-between',
      paddingHorizontal: 16,
      borderBottomWidth: StyleSheet.hairlineWidth,
      borderBottomColor: colors.lineSoft,
    },
    headerSide: { width: 42, height: 42 },
    headerTitle: {
      color: colors.text,
      fontSize: 18,
      fontWeight: '700',
    },
    close: {
      width: 42,
      height: 42,
      borderRadius: 21,
      backgroundColor: colors.surfaceRaised,
      alignItems: 'center',
      justifyContent: 'center',
    },
    content: {
      paddingHorizontal: 16,
      paddingTop: 6,
      paddingBottom: 28,
    },
    sectionLabel: {
      color: colors.muted,
      fontSize: 12,
      fontWeight: '600',
      marginTop: 18,
      marginLeft: 8,
      marginBottom: 7,
    },
    card: {
      borderRadius: 20,
      backgroundColor: colors.surface,
      paddingHorizontal: 15,
      paddingVertical: 13,
    },
    credentialHeader: { flexDirection: 'row', alignItems: 'center' },
    settingHeadingRow: { flexDirection: 'row', alignItems: 'center' },
    settingIcon: {
      width: 30,
      height: 30,
      borderRadius: 10,
      backgroundColor: colors.surfaceRaised,
      alignItems: 'center',
      justifyContent: 'center',
      marginRight: 10,
    },
    statusDot: {
      width: 8,
      height: 8,
      borderRadius: 4,
      backgroundColor: colors.danger,
      marginRight: 10,
    },
    statusDotReady: { backgroundColor: colors.success },
    flex: { flex: 1 },
    settingTitle: { color: colors.text, fontSize: 15, fontWeight: '600' },
    settingDescription: {
      color: colors.muted,
      fontSize: 11,
      lineHeight: 15,
      marginTop: 3,
    },
    credentialBody: {
      color: colors.muted,
      fontSize: 11,
      lineHeight: 16,
      marginTop: 11,
    },
    buttonRow: { flexDirection: 'row', gap: 8, marginTop: 12 },
    primaryButton: {
      minHeight: 40,
      borderRadius: 11,
      backgroundColor: colors.text,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 7,
      paddingHorizontal: 14,
    },
    primaryText: { color: colors.background, fontSize: 11, fontWeight: '800' },
    proxySaveButton: { flex: 1 },
    secondaryButton: {
      minHeight: 40,
      borderRadius: 11,
      backgroundColor: colors.surfaceRaised,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 7,
      paddingHorizontal: 14,
    },
    secondaryText: { color: colors.textDim, fontSize: 11, fontWeight: '800' },
    dangerText: { color: colors.danger, fontSize: 11, fontWeight: '800' },
    disabled: { opacity: 0.38 },
    proxyInput: {
      minHeight: 44,
      borderRadius: 11,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
      backgroundColor: colors.surfaceRaised,
      color: colors.text,
      fontFamily: fonts.mono,
      fontSize: 11,
      marginTop: 12,
      paddingHorizontal: 12,
      paddingVertical: 10,
    },
    proxyHint: {
      color: colors.muted,
      fontSize: 10,
      lineHeight: 15,
      marginTop: 7,
    },
    proxyError: {
      color: colors.danger,
      fontSize: 10,
      lineHeight: 15,
      marginTop: 7,
    },
    linkRow: { minHeight: 52, flexDirection: 'row', alignItems: 'center' },
    // A model name is typed by the person and capped at 80 characters, which
    // at this size outruns the row. Without shrinking it, the row's own title
    // and description are the ones that collapse. See localPill below.
    value: {
      color: colors.textDim,
      fontFamily: fonts.mono,
      fontSize: 9,
      marginLeft: 10,
      maxWidth: 132,
      flexShrink: 1,
    },
    segmented: {
      minHeight: 42,
      borderRadius: 11,
      backgroundColor: colors.surfaceRaised,
      flexDirection: 'row',
      padding: 3,
      marginTop: 11,
    },
    segment: {
      flex: 1,
      minHeight: 36,
      borderRadius: 8,
      alignItems: 'center',
      justifyContent: 'center',
      paddingHorizontal: 5,
    },
    segmentActive: { backgroundColor: colors.text },
    segmentText: { color: colors.muted, fontSize: 10, fontWeight: '700' },
    segmentTextActive: { color: colors.background },
    toggleRow: { minHeight: 54, flexDirection: 'row', alignItems: 'center' },
    localPill: {
      minHeight: 28,
      maxWidth: 112,
      borderRadius: 14,
      paddingHorizontal: 8,
      backgroundColor: colors.surfaceRaised,
      flexDirection: 'row',
      alignItems: 'center',
      marginLeft: 8,
    },
    localDot: {
      width: 6,
      height: 6,
      borderRadius: 3,
      backgroundColor: colors.warning,
      marginRight: 5,
    },
    localDotReady: { backgroundColor: colors.success },
    localDotFailed: { backgroundColor: colors.danger },
    localText: {
      flexShrink: 1,
      color: colors.warning,
      fontSize: 7,
      fontWeight: '800',
      letterSpacing: 0.7,
    },
    localTextReady: { color: colors.success },
    localTextFailed: { color: colors.danger },
    boundaryRow: {
      minHeight: 56,
      flexDirection: 'row',
      alignItems: 'center',
    },
    resetButton: {
      minHeight: 48,
      borderRadius: 18,
      backgroundColor: colors.surface,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'flex-start',
      gap: 9,
      paddingHorizontal: 16,
      marginTop: 18,
    },
    resetText: { color: colors.danger, fontSize: 14, fontWeight: '600' },
  });
