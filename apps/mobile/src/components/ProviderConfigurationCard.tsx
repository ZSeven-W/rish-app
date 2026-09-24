import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from 'react-native';
import {
  CLAUDE_MODEL_IDS,
  CODEX_MODEL_IDS,
  GLM_MODEL_IDS,
  harnessForModel,
  type HarnessModelId,
} from '../harness/types';
import { getDshCatalog } from '../models/catalog';
import { ProviderConfigurations } from '../providers/native';
import type {
  ConfigurableHarness,
  ProviderAuth,
  ProviderConfiguration,
  ProviderProtocol,
} from '../providers/configuration';
import { useAppPresentation } from '../presentation/AppPresentation';
import { localizedModelDetails } from './ModelPicker';

/** The model slots a relay maps for a harness: DSH's are the catalog's. */
function mappedModels(harness: string): readonly string[] {
  if (harness === 'claude-code') return CLAUDE_MODEL_IDS;
  if (harness === 'codex') return CODEX_MODEL_IDS;
  if (harness === 'glm') return GLM_MODEL_IDS;
  return getDshCatalog().models.map(entry => entry.id);
}

export function ProviderConfigurationCard({
  model,
  disabled,
  visible,
  onSaved,
}: {
  model: HarnessModelId;
  disabled: boolean;
  visible: boolean;
  onSaved: (harness: ConfigurableHarness) => void;
}) {
  const { colors, t, locale } = useAppPresentation();
  const zh = locale === 'zh-CN';
  const harness = harnessForModel(model);
  // Every harness can go through a relay: DeepSeek and GLM as much as
  // Claude Code and Codex (2026-09-24, "only Claude works").
  const [configuration, setConfiguration] =
    useState<ProviderConfiguration | null>(null);
  const [custom, setCustom] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState('');
  const epoch = useRef(0);
  const saving = useRef(false);
  const savedConfiguration = useRef<ProviderConfiguration | null>(null);
  const renderEpoch = epoch.current;
  useEffect(() => {
    const current = ++epoch.current;
    setConfiguration(null);
    setCustom(false);
    setNotice('');
    setBusy(false);
    saving.current = false;
    savedConfiguration.current = null;
    if (!visible || !ProviderConfigurations.isAvailable()) return;
    ProviderConfigurations.read(harness)
      .then(value => {
        if (epoch.current !== current) return;
        savedConfiguration.current = value;
        setConfiguration(value);
        setCustom(!value.official);
      })
      .catch(() => {
        if (epoch.current === current) setNotice('E_PROVIDER_CONFIGURATION');
      });
    return () => {
      epoch.current += 1;
    };
  }, [harness, visible]);
  if (!ProviderConfigurations.isAvailable()) return null;
  const locked = disabled || busy;
  const signature = (value: ProviderConfiguration | null) =>
    value === null
      ? ''
      : JSON.stringify([
          value.name.trim(),
          value.endpoint_url.trim(),
          value.protocol,
          value.auth_type,
          value.send_reasoning,
          !!value.full_url,
          Object.entries(value.model_mappings).sort(([a], [b]) =>
            a.localeCompare(b),
          ),
        ]);
  const dirty =
    savedConfiguration.current === null ||
    custom !== !savedConfiguration.current.official ||
    (custom &&
      signature(configuration) !== signature(savedConfiguration.current));
  const set = (patch: Partial<ProviderConfiguration>) => {
    if (!locked && !saving.current && renderEpoch === epoch.current)
      setConfiguration(value => value && { ...value, ...patch });
  };
  const save = async () => {
    if (
      locked ||
      saving.current ||
      !dirty ||
      (custom && !configuration) ||
      renderEpoch !== epoch.current
    )
      return;
    saving.current = true;
    const current = epoch.current;
    setBusy(true);
    setNotice('');
    try {
      const saved =
        custom && configuration
          ? await ProviderConfigurations.save({
              ...configuration,
              name:
                configuration.name.trim() ||
                (zh ? '自定义服务' : 'Custom provider'),
            })
          : await ProviderConfigurations.reset(harness);
      onSaved(harness);
      if (current !== epoch.current) return;
      savedConfiguration.current = saved;
      setConfiguration(saved);
      setCustom(!saved.official);
      setNotice(
        zh
          ? '已保存。请为此服务配置密钥，并重新确认项目上下文。'
          : 'Saved. Configure this provider’s key and confirm project context again.',
      );
    } catch (error) {
      if (current !== epoch.current) return;
      const code = (error as { code?: string }).code;
      setNotice(
        code === 'E_COMPLETION_BUSY'
          ? zh
            ? '请先结束正在运行的任务，再修改服务。'
            : 'Finish the running task before changing providers.'
          : zh
          ? '请检查服务地址和模型名称。地址须为 HTTPS，本机可使用 HTTP。'
          : 'Check the endpoint and model IDs. Use HTTPS, or HTTP for localhost.',
      );
    } finally {
      if (current === epoch.current) {
        setBusy(false);
        saving.current = false;
      }
    }
  };
  const field = (
    label: string,
    value: string,
    onChange: (text: string) => void,
    placeholder?: string,
  ) => (
    <View style={styles.field}>
      <Text style={[styles.label, { color: colors.textDim }]}>{label}</Text>
      <TextInput
        accessibilityLabel={label}
        editable={!locked}
        value={value}
        onChangeText={onChange}
        placeholder={placeholder}
        placeholderTextColor={colors.faint}
        autoCapitalize="none"
        autoCorrect={false}
        style={[styles.input, { color: colors.text, borderColor: colors.line }]}
      />
    </View>
  );
  const choices = <T extends string>(
    label: string,
    values: readonly (readonly [T, string])[],
    selected: T,
    onSelect: (v: T) => void,
  ) => (
    <View style={styles.field}>
      <Text style={[styles.label, { color: colors.textDim }]}>{label}</Text>
      <View style={styles.choices}>
        {values.map(([value, title]) => (
          <Pressable
            key={value}
            accessibilityRole="radio"
            accessibilityLabel={title}
            accessibilityState={{
              checked: selected === value,
              disabled: locked,
            }}
            disabled={locked}
            onPress={() => onSelect(value)}
            style={[
              styles.choice,
              { borderColor: selected === value ? colors.accent : colors.line },
            ]}
          >
            <Text
              style={{
                color: selected === value ? colors.accent : colors.text,
              }}
            >
              {title}
            </Text>
          </Pressable>
        ))}
      </View>
    </View>
  );
  return (
    <View style={[styles.card, { backgroundColor: colors.surfaceRaised }]}>
      <View style={styles.row}>
        <Text style={[styles.title, { color: colors.text }]}>
          {zh ? '自定义服务' : 'Custom provider'}
        </Text>
        <Switch
          accessibilityLabel={zh ? '启用自定义服务' : 'Enable custom provider'}
          disabled={locked || !configuration}
          value={custom}
          onValueChange={value => {
            if (renderEpoch !== epoch.current || saving.current) return;
            setCustom(value);
            if (value && configuration?.official)
              set({ send_reasoning: false });
          }}
        />
      </View>
      <Text style={[styles.help, { color: colors.textDim }]}>
        {zh
          ? '服务地址、模型映射和密钥分别保存。关闭并保存可恢复官方配置，原有密钥会保留。'
          : 'Configure the endpoint and model mapping, then save its key separately. Disable and save to restore the official provider; existing keys are retained.'}
      </Text>
      {configuration && custom && (
        <>
          {field(zh ? '服务名称' : 'Provider name', configuration.name, name =>
            set({ name }),
          )}
          {choices<ProviderProtocol>(
            zh ? '接口协议' : 'API protocol',
            [
              ['messages', 'Messages'],
              ['responses', 'Responses'],
              ['chat-completions', 'Chat Completions'],
            ],
            configuration.protocol,
            protocol =>
              set({
                protocol,
                auth_type: protocol === 'messages' ? 'x-api-key' : 'bearer',
              }),
          )}
          {field(
            zh
              ? '服务地址（Base URL 或完整接口地址）'
              : 'Base URL or full endpoint',
            configuration.endpoint_url,
            endpoint_url => set({ endpoint_url }),
            'https://api.example.com/v1',
          )}
          <View style={styles.row}>
            <Text style={[styles.help, styles.flex, { color: colors.textDim }]}>
              {zh
                ? '使用完整接口地址，不自动追加路径'
                : 'Use full endpoint without appending a path'}
            </Text>
            <Switch
              accessibilityLabel={zh ? '使用完整接口地址' : 'Use full endpoint'}
              value={!!configuration.full_url}
              disabled={locked}
              onValueChange={full_url => set({ full_url })}
            />
          </View>
          {choices<ProviderAuth>(
            zh ? '密钥认证方式' : 'Key authentication',
            [
              ['bearer', 'Bearer'],
              ['x-api-key', 'x-api-key'],
              ['api-key', 'api-key'],
            ],
            configuration.auth_type,
            auth_type => set({ auth_type }),
          )}
          <Text style={[styles.help, { color: colors.textDim }]}>
            {zh
              ? '模型映射：留空则使用原模型 ID。'
              : 'Model mapping: leave blank to use the original model ID.'}
          </Text>
          {mappedModels(harness).map(
            alias => (
              <React.Fragment key={alias}>
                {field(
                  localizedModelDetails(alias, t).name,
                  configuration.model_mappings[alias] ?? '',
                  value => {
                    const mappings = { ...configuration.model_mappings };
                    if (value.trim()) mappings[alias] = value.trim();
                    else delete mappings[alias];
                    set({ model_mappings: mappings });
                  },
                  alias,
                )}
              </React.Fragment>
            ),
          )}
          <View style={styles.row}>
            <Text style={[styles.help, styles.flex, { color: colors.textDim }]}>
              {zh
                ? '发送思考参数（服务支持时启用）'
                : 'Send reasoning settings (when supported)'}
            </Text>
            <Switch
              accessibilityLabel={
                zh ? '发送思考参数' : 'Send reasoning settings'
              }
              value={configuration.send_reasoning}
              disabled={locked}
              onValueChange={send_reasoning => set({ send_reasoning })}
            />
          </View>
        </>
      )}
      {!!notice && (
        <Text
          accessibilityLiveRegion="polite"
          style={[styles.help, { color: colors.textDim }]}
        >
          {notice === 'E_PROVIDER_CONFIGURATION'
            ? zh
              ? '无法读取服务配置，可恢复官方配置。'
              : 'Could not load settings. Restore the official provider to recover.'
            : notice}
        </Text>
      )}
      {busy ? (
        <ActivityIndicator color={colors.accent} />
      ) : (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={zh ? '保存服务配置' : 'Save provider settings'}
          disabled={locked || !dirty}
          onPress={save}
          style={[
            styles.save,
            { backgroundColor: colors.accent },
            (locked || !dirty) && styles.disabled,
          ]}
        >
          <Text style={[styles.saveText, { color: colors.background }]}>
            {zh ? '保存服务配置' : 'Save provider settings'}
          </Text>
        </Pressable>
      )}
    </View>
  );
}
const styles = StyleSheet.create({
  card: { borderRadius: 18, padding: 14, gap: 12 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
  },
  title: { fontSize: 16, fontWeight: '600', flexShrink: 1 },
  label: { fontSize: 12 },
  help: { fontSize: 12, lineHeight: 18 },
  field: { gap: 7 },
  input: {
    minHeight: 44,
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 10,
    paddingVertical: 9,
    fontSize: 14,
  },
  choices: { flexDirection: 'row', flexWrap: 'wrap', gap: 7 },
  choice: {
    minHeight: 44,
    justifyContent: 'center',
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 10,
  },
  disabled: { opacity: 0.5 },
  save: {
    minHeight: 44,
    borderRadius: 12,
    alignItems: 'center',
    justifyContent: 'center',
  },
  saveText: { fontWeight: '600' },
  flex: { flex: 1 },
});
