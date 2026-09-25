import type { TranslationKey } from '../preferences';
import React, { useMemo } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Circle from 'lucide-react-native/icons/circle';
import CircleCheck from 'lucide-react-native/icons/circle-check';
import X from 'lucide-react-native/icons/x';

import type { HarnessManifest } from '../harness';
import { useAppPresentation } from '../presentation/AppPresentation';
import { fonts, type ThemePalette } from '../theme';
import { AppIcon } from './AppIcon';
import { HarnessLogo } from './HarnessLogo';
import { SlidingPanel } from './SlidingPanel';

const BUILTIN_DESCRIPTION_KEYS: Readonly<Record<string, TranslationKey>> = {
  dsh: 'harness.adapter.dsh', 'claude-code': 'harness.adapter.claude', codex: 'harness.adapter.codex', glm: 'harness.adapter.glm',
};

export function HarnessPicker({
  disabled = false,
  notice = null,
  manifests,
  selectedId,
  visible,
  onClose,
  onSelect,
}: {
  disabled?: boolean;
  /** Why a switch is not possible right now; tapping a card did nothing, silently. */
  notice?: string | null;
  manifests: readonly HarnessManifest[];
  selectedId: string;
  visible: boolean;
  onClose: () => void;
  onSelect: (id: string) => void;
}) {
  const insets = useSafeAreaInsets();
  const { colors, t } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);

  return (
    <SlidingPanel
      accessibilityLabel={t('harness.title')}
      closeAccessibilityLabel={t('harness.close')}
      onClose={onClose}
      visible={visible}
    >
      <View
        style={[
          styles.root,
          { paddingTop: insets.top + 10, paddingBottom: insets.bottom + 12 },
        ]}
      >
        <View style={styles.header}>
          <View style={styles.flex}>
            <Text style={styles.eyebrow}>{t('harness.eyebrow')}</Text>
            <Text accessibilityRole="header" style={styles.title}>
              {t('harness.title')}
            </Text>
          </View>
          <Pressable
            accessibilityLabel={t('harness.close')}
            accessibilityRole="button"
            onPress={onClose}
            style={styles.close}
          >
            <AppIcon color={colors.text} icon={X} size={21} />
          </Pressable>
        </View>

        <ScrollView contentContainerStyle={styles.content}>
          <Text style={styles.description}>{t('harness.description')}</Text>
          {notice !== null && (
            <Text accessibilityRole="alert" style={styles.notice}>{notice}</Text>
          )}
          {manifests.map(manifest => {
            const descriptionKey = manifest.builtin ? BUILTIN_DESCRIPTION_KEYS[manifest.id] : undefined;
            const selected = manifest.id === selectedId;
            const runtimeLabel =
              manifest.runtime.kind === 'native-adapter'
                ? t('harness.runtime.native')
                : t('harness.runtime.guest');
            return (
              <Pressable
                accessibilityLabel={t('harness.use', {
                  harness: manifest.name,
                })}
                accessibilityRole="radio"
                accessibilityState={{ checked: selected, disabled }}
                disabled={disabled}
                key={manifest.id}
                onPress={() => onSelect(manifest.id)}
                style={({ pressed }) => [
                  styles.card,
                  selected && styles.cardSelected,
                  pressed && styles.pressed,
                ]}
              >
                <View style={styles.cardHeader}>
                  <View style={styles.harnessIcon}>
                    <HarnessLogo harnessId={manifest.id} name={manifest.name} />
                  </View>
                  <View style={styles.flex}>
                    <View style={styles.nameRow}>
                      <Text style={styles.name}>{manifest.name}</Text>
                      {manifest.builtin && (
                        <Text style={styles.builtin}>
                          {t('harness.builtin')}
                        </Text>
                      )}
                    </View>
                    <Text style={styles.runtime}>{runtimeLabel}</Text>
                  </View>
                  <AppIcon
                    color={selected ? colors.accent : colors.faint}
                    icon={selected ? CircleCheck : Circle}
                    size={21}
                  />
                </View>
                <Text style={styles.cardDescription}>
                  {descriptionKey === undefined ? manifest.description : t(descriptionKey)}
                </Text>
                <View style={styles.capabilities}>
                  {manifest.capabilities.map(capability => (
                    <Text key={capability} style={styles.capability}>
                      {capability}
                    </Text>
                  ))}
                </View>
                {selected && (
                  <Text style={styles.selected}>{t('harness.selected')}</Text>
                )}
              </Pressable>
            );
          })}

          <View style={styles.manifestCard}>
            <Text style={styles.manifestTitle}>
              {t('harness.manifestTitle')}
            </Text>
            <Text style={styles.manifestDescription}>
              {t('harness.manifestDescription')}
            </Text>
            <Text style={styles.manifestCode}>native-adapter | rish-guest</Text>
          </View>
        </ScrollView>
      </View>
    </SlidingPanel>
  );
}

const createStyles = (colors: ThemePalette) =>
  StyleSheet.create({
    root: {
      flex: 1,
      backgroundColor: colors.background,
      paddingHorizontal: 18,
    },
    flex: { flex: 1 },
    header: {
      height: 64,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'space-between',
    },
    eyebrow: {
      color: colors.accent,
      fontSize: 8,
      fontWeight: '800',
      letterSpacing: 1.7,
    },
    title: {
      color: colors.text,
      fontFamily: fonts.display,
      fontSize: 27,
      marginTop: 4,
    },
    close: {
      width: 44,
      height: 44,
      borderRadius: 22,
      backgroundColor: colors.surface,
      alignItems: 'center',
      justifyContent: 'center',
    },
    content: { paddingTop: 8, paddingBottom: 34 },
    description: { color: colors.muted, fontSize: 13, lineHeight: 19 },
    notice: { color: colors.danger, fontSize: 13, lineHeight: 19 },
    card: {
      borderRadius: 20,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
      backgroundColor: colors.surface,
      padding: 15,
      marginTop: 14,
    },
    cardSelected: {
      borderColor: colors.accentSoft,
      backgroundColor: colors.surfaceWarm,
    },
    cardHeader: { flexDirection: 'row', alignItems: 'center' },
    harnessIcon: {
      width: 44,
      height: 44,
      borderRadius: 14,
      backgroundColor: '#F7F7F5',
      alignItems: 'center',
      justifyContent: 'center',
      marginRight: 12,
    },
    nameRow: { flexDirection: 'row', alignItems: 'center', gap: 7 },
    name: { color: colors.text, fontSize: 18, fontWeight: '700' },
    builtin: {
      color: colors.accent,
      fontSize: 8,
      fontWeight: '800',
      backgroundColor: colors.surfaceWarm,
      borderRadius: 7,
      paddingHorizontal: 6,
      paddingVertical: 3,
    },
    runtime: { color: colors.muted, fontSize: 10, marginTop: 4 },
    cardDescription: {
      color: colors.textDim,
      fontSize: 12,
      lineHeight: 18,
      marginTop: 13,
    },
    capabilities: {
      flexDirection: 'row',
      flexWrap: 'wrap',
      gap: 6,
      marginTop: 12,
    },
    capability: {
      color: colors.muted,
      fontFamily: fonts.mono,
      fontSize: 8,
      backgroundColor: colors.surfaceRaised,
      borderRadius: 8,
      paddingHorizontal: 7,
      paddingVertical: 4,
    },
    selected: {
      color: colors.success,
      fontSize: 10,
      fontWeight: '800',
      marginTop: 12,
    },
    manifestCard: {
      borderRadius: 18,
      backgroundColor: colors.surfaceRaised,
      padding: 15,
      marginTop: 14,
    },
    manifestTitle: { color: colors.text, fontSize: 14, fontWeight: '700' },
    manifestDescription: {
      color: colors.muted,
      fontSize: 11,
      lineHeight: 17,
      marginTop: 7,
    },
    manifestCode: {
      color: colors.accent,
      fontFamily: fonts.mono,
      fontSize: 10,
      marginTop: 10,
    },
    pressed: { opacity: 0.62, transform: [{ scale: 0.99 }] },
  });
