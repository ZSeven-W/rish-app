import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {
  ActivityIndicator,
  Animated,
  Easing,
  Modal,
  Keyboard,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  Text,
  TextInput,
  useWindowDimensions,
  View,
} from 'react-native';
import Check from 'lucide-react-native/icons/check';
import FolderInput from 'lucide-react-native/icons/folder-input';
import FolderOpen from 'lucide-react-native/icons/folder-open';
import Plus from 'lucide-react-native/icons/plus';

import { useAppPresentation } from '../presentation/AppPresentation';
import {
  LocalWorkspaces,
  type WorkspaceDescriptor,
} from '../native/LocalWorkspaces';
import { createCompletionRequestId } from '../native/LocalRuntime';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { createWorkspacePickerStyles } from './workspace-picker-sheet-styles';
import {
  WorkspacePickerController,
  type WorkspaceForgetAuthorization,
  type WorkspacePickerSelection,
} from '../workspaces/WorkspacePickerController';
import type {
  WorkspaceRemovalAction,
  WorkspaceRemovalOutcome,
} from '../workspaces/WorkspaceRemoval';
import { AppIcon } from './AppIcon';
import { RecoveryNotice } from './RecoveryNotice';
import { recoveryErrorText } from './recoveryMessage';

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

const OPEN_DURATION_MS = 190;
const CLOSE_DURATION_MS = 150;
// Deterministic snapshots in Jest: skip the entrance/exit animation.
const disableAnimations = process.env.NODE_ENV === 'test';

export type WorkspacePickerSheetProps = {
  visible: boolean;
  activeWorkspaceId: string | null;
  onClose: () => void;
  onSelect: (workspaceId: string) => void;
  /**
   * Native-issued clearance from the session coordinator. The picker never
   * creates either ID and refuses to call native forget without both.
   */
  forgetAuthorization?:
    | WorkspaceForgetAuthorization
    | ((
        workspace: WorkspaceDescriptor,
      ) => WorkspaceForgetAuthorization | null | undefined);
  /**
   * The removal coordinator, when the host has one: it owns the clearance,
   * the native call and the acknowledgement. A granted folder is forgotten
   * (its files stay); an owned workspace is deleted, files and history.
   */
  onRemove?: (
    workspace: WorkspaceDescriptor,
    action: WorkspaceRemovalAction,
  ) => Promise<WorkspaceRemovalOutcome>;
};

/**
 * Restrained bottom sheet that binds a conversation to a workspace. Only
 * opaque ids cross into JavaScript, so every row shows display metadata plus
 * the structured access state reported by native.
 */
export function WorkspacePickerSheet({
  visible,
  activeWorkspaceId,
  onClose,
  onSelect,
  forgetAuthorization,
  onRemove,
}: WorkspacePickerSheetProps) {
  const { colors, t } = useAppPresentation();
  // Choosing a folder outside the app is not something every platform can
  // do; where it cannot, the two actions are not offered at all rather than
  // refusing when tapped.
  const folderPickerAvailable = useMemo(
    () => LocalWorkspaces.isFolderPickerAvailable(),
    [],
  );
  const { height: windowHeight } = useWindowDimensions();
  const insets = useSafeAreaInsets();
  const styles = useMemo(() => createWorkspacePickerStyles(colors), [colors]);
  const scroll = useRef<React.ComponentRef<typeof ScrollView>>(null);
  const nameFocused = useRef(false);
  const keyboardVisible = useRef(Keyboard.isVisible());
  const revealFrame = useRef<number | null>(null);
  const revealCreation = useCallback(() => {
    if (!visible || !nameFocused.current || !keyboardVisible.current) return;
    if (revealFrame.current !== null) cancelAnimationFrame(revealFrame.current);
    revealFrame.current = requestAnimationFrame(() => {
      revealFrame.current = null;
      if (nameFocused.current && keyboardVisible.current)
        scroll.current?.scrollToEnd({ animated: false });
    });
  }, [visible]);
  useEffect(() => {
    if (!visible) return;
    // A keyboard inherited from the underlying screen predates this Modal's
    // KeyboardAvoidingView subscriptions. Start with a fresh focus transition.
    Keyboard.dismiss();
    keyboardVisible.current = Keyboard.isVisible();
    const show = () => {
      keyboardVisible.current = true;
      revealCreation();
    };
    const willShow = Keyboard.addListener('keyboardWillShow', show);
    const didShow = Keyboard.addListener('keyboardDidShow', show);
    const hide = Keyboard.addListener('keyboardDidHide', () => {
      keyboardVisible.current = false;
    });
    return () => {
      willShow.remove();
      didShow.remove();
      hide.remove();
      nameFocused.current = false;
      if (revealFrame.current !== null) {
        cancelAnimationFrame(revealFrame.current);
        revealFrame.current = null;
      }
    };
  }, [revealCreation, visible]);
  const progress = useRef(new Animated.Value(0)).current;
  const [presented, setPresented] = useState(visible);
  const presentedRef = useRef(visible);
  const [rows, setRows] = useState<readonly WorkspaceDescriptor[] | null>(null);
  const [notice, setNotice] = useState<{
    readonly kind: 'load' | 'action';
    readonly error: string;
  } | null>(null);
  const [busy, setBusy] = useState(false);
  const [draftName, setDraftName] = useState('');
  const [pendingSelection, setPendingSelection] =
    useState<WorkspacePickerSelection | null>(null);
  const mountedRef = useRef(true);
  const visibleRef = useRef(visible);
  visibleRef.current = visible;
  const ownerWorkspaceRef = useRef(activeWorkspaceId);
  const ownerGenerationRef = useRef(0);
  if (ownerWorkspaceRef.current !== activeWorkspaceId) {
    ownerWorkspaceRef.current = activeWorkspaceId;
    ownerGenerationRef.current += 1;
  }
  const surfaceGenerationRef = useRef(0);
  const busyRef = useRef(false);
  const selectionOwnerGenerationRef = useRef(ownerGenerationRef.current);
  const controllerRef = useRef<WorkspacePickerController | null>(null);
  if (controllerRef.current === null) {
    controllerRef.current = new WorkspacePickerController({
      native: LocalWorkspaces,
      createOperationId: createCompletionRequestId,
      onSelectionChanged: selection => {
        if (!mountedRef.current) return;
        if (
          selection !== null &&
          selectionOwnerGenerationRef.current !== ownerGenerationRef.current
        ) {
          return;
        }
        setPendingSelection(selection);
      },
    });
  }
  const controller = controllerRef.current;

  const reload = useCallback(
    async (
      expectedGeneration = surfaceGenerationRef.current,
      expectedOwnerGeneration = ownerGenerationRef.current,
    ) => {
      try {
        const listing = await LocalWorkspaces.list();
        if (
          !mountedRef.current ||
          !visibleRef.current ||
          surfaceGenerationRef.current !== expectedGeneration ||
          ownerGenerationRef.current !== expectedOwnerGeneration
        ) {
          return;
        }
        setRows(listing.workspaces);
        setNotice(null);
      } catch (error) {
        if (
          !mountedRef.current ||
          !visibleRef.current ||
          surfaceGenerationRef.current !== expectedGeneration ||
          ownerGenerationRef.current !== expectedOwnerGeneration
        ) {
          return;
        }
        setRows([]);
        setNotice({
          kind: 'load',
          error: recoveryErrorText(error),
        });
      }
    },
    [],
  );

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      controller.dispose();
    };
  }, [controller]);

  useEffect(() => {
    surfaceGenerationRef.current += 1;
    controller.invalidate();
    setPendingSelection(null);
    if (visible) {
      setRows(null);
      setDraftName('');
      setNotice(null);
      const expectedGeneration = surfaceGenerationRef.current;
      reload(expectedGeneration).catch(() => undefined);
    }
  }, [activeWorkspaceId, controller, reload, visible]);

  useEffect(() => {
    if (visible) {
      if (presentedRef.current) return undefined;
      presentedRef.current = true;
      setPresented(true);
      if (disableAnimations) {
        progress.setValue(1);
        return undefined;
      }
      progress.setValue(0);
      const frame = requestAnimationFrame(() => {
        Animated.timing(progress, {
          duration: OPEN_DURATION_MS,
          easing: Easing.out(Easing.cubic),
          toValue: 1,
          useNativeDriver: true,
        }).start();
      });
      return () => cancelAnimationFrame(frame);
    }
    if (!presentedRef.current) return undefined;
    presentedRef.current = false;
    if (disableAnimations) {
      progress.setValue(0);
      setPresented(false);
      return undefined;
    }
    Animated.timing(progress, {
      duration: CLOSE_DURATION_MS,
      easing: Easing.in(Easing.cubic),
      toValue: 0,
      useNativeDriver: true,
    }).start(({ finished }) => {
      if (finished) setPresented(false);
    });
    return undefined;
  }, [visible, progress]);

  const runAction = useCallback(
    async (action: () => Promise<boolean>) => {
      if (busyRef.current) return;
      const expectedGeneration = surfaceGenerationRef.current;
      const expectedOwnerGeneration = ownerGenerationRef.current;
      busyRef.current = true;
      setBusy(true);
      try {
        const shouldReload = await action();
        if (
          !mountedRef.current ||
          !visibleRef.current ||
          surfaceGenerationRef.current !== expectedGeneration ||
          ownerGenerationRef.current !== expectedOwnerGeneration
        ) {
          return;
        }
        setNotice(null);
        if (shouldReload) await reload(expectedGeneration);
      } catch (error) {
        if (
          mountedRef.current &&
          visibleRef.current &&
          surfaceGenerationRef.current === expectedGeneration &&
          ownerGenerationRef.current === expectedOwnerGeneration
        ) {
          setNotice({
            kind: 'action',
            error: recoveryErrorText(error),
          });
        }
      } finally {
        busyRef.current = false;
        if (mountedRef.current) setBusy(false);
      }
    },
    [reload],
  );

  const createWorkspace = useCallback((): Promise<void> => {
    const name = draftName.trim();
    if (name.length === 0) return Promise.resolve();
    const expectedGeneration = surfaceGenerationRef.current;
    const expectedOwnerGeneration = ownerGenerationRef.current;
    return runAction(async () => {
      await LocalWorkspaces.create({
        schema_version: 1,
        display_name: name,
        operation_id: createCompletionRequestId(),
      });
      if (
        mountedRef.current &&
        visibleRef.current &&
        surfaceGenerationRef.current === expectedGeneration &&
        ownerGenerationRef.current === expectedOwnerGeneration
      ) {
        setDraftName('');
      }
      return true;
    });
  }, [draftName, runAction]);

  const closeSurface = useCallback(() => {
    Keyboard.dismiss();
    surfaceGenerationRef.current += 1;
    controller.invalidate();
    if (mountedRef.current) setPendingSelection(null);
    onClose();
  }, [controller, onClose]);

  const isCurrentAction = useCallback(
    (expectedGeneration: number, expectedOwnerGeneration: number) =>
      mountedRef.current &&
      visibleRef.current &&
      surfaceGenerationRef.current === expectedGeneration &&
      ownerGenerationRef.current === expectedOwnerGeneration,
    [],
  );

  const selectWorkspace = useCallback(
    (workspaceId: string) => {
      if (!mountedRef.current || !visibleRef.current) return;
      // A direct row selection is an owner transition too. Invalidate native
      // picker/import/regrant callbacks before handing control to Home.
      surfaceGenerationRef.current += 1;
      controller.invalidate();
      onSelect(workspaceId);
    },
    [controller, onSelect],
  );

  const presentFolderPicker = useCallback(
    (mode: 'grant_or_import' | 'import_only') => {
      const expectedGeneration = surfaceGenerationRef.current;
      const expectedOwnerGeneration = ownerGenerationRef.current;
      selectionOwnerGenerationRef.current = expectedOwnerGeneration;
      return runAction(async () => {
        const result = await controller.presentFolderPicker(mode);
        if (
          result.status === 'selected' &&
          isCurrentAction(expectedGeneration, expectedOwnerGeneration)
        ) {
          selectWorkspace(result.workspace.workspace_id);
          return true;
        }
        return false;
      });
    },
    [controller, isCurrentAction, runAction, selectWorkspace],
  );

  const confirmSelection = useCallback(() => {
    const expectedGeneration = surfaceGenerationRef.current;
    const expectedOwnerGeneration = ownerGenerationRef.current;
    return runAction(async () => {
      const result = await controller.confirmSelection();
      if (
        (result.status === 'imported' ||
          result.status === 'regranted' ||
          result.status === 'different_root') &&
        isCurrentAction(expectedGeneration, expectedOwnerGeneration)
      ) {
        selectWorkspace(result.workspace.workspace_id);
        return true;
      }
      return false;
    });
  }, [controller, isCurrentAction, runAction, selectWorkspace]);

  const cancelSelection = useCallback(
    () =>
      runAction(async () => {
        await controller.cancelSelection();
        return false;
      }),
    [controller, runAction],
  );

  const presentRegrantPicker = useCallback(
    (workspace: WorkspaceDescriptor) => {
      const expectedOwnerGeneration = ownerGenerationRef.current;
      selectionOwnerGenerationRef.current = expectedOwnerGeneration;
      return runAction(async () => {
        await controller.presentRegrantPicker(workspace);
        return false;
      });
    },
    [controller, runAction],
  );

  const resolveForgetAuthorization = useCallback(
    (workspace: WorkspaceDescriptor): WorkspaceForgetAuthorization | null => {
      const authorization =
        typeof forgetAuthorization === 'function'
          ? forgetAuthorization(workspace)
          : forgetAuthorization;
      return authorization ?? null;
    },
    [forgetAuthorization],
  );

  const forgetWorkspace = useCallback(
    (workspace: WorkspaceDescriptor) =>
      runAction(async () => {
        const result = await controller.forgetWorkspace(
          workspace,
          resolveForgetAuthorization(workspace),
        );
        if (result.status === 'not_authorized') {
          throw new Error('E_WORKSPACE_CLEARANCE_UNAVAILABLE');
        }
        return result.status === 'forgotten';
      }),
    [controller, resolveForgetAuthorization, runAction],
  );

  const removeWorkspace = useCallback(
    (workspace: WorkspaceDescriptor, action: WorkspaceRemovalAction) =>
      runAction(async () => {
        if (onRemove === undefined) throw new Error('E_WORKSPACE_UNAVAILABLE');
        const outcome = await onRemove(workspace, action);
        switch (outcome.status) {
          case 'forgotten':
          case 'deleted':
            // Removing the active workspace unbinds the conversation, which
            // changes this sheet's owner; the list is reloaded against the
            // owner as it is now rather than skipped as stale.
            await reload(surfaceGenerationRef.current, ownerGenerationRef.current);
            return false;
          case 'cancelled':
            return false;
          case 'blocked':
            throw new Error('E_WORKSPACE_CLEARANCE_UNAVAILABLE');
          case 'unavailable':
            throw new Error('E_WORKSPACE_UNAVAILABLE');
          case 'pending':
            throw new Error('E_WORKSPACE_REMOVAL_PENDING');
          case 'retired':
            throw new Error(outcome.code);
        }
      }),
    [onRemove, reload, runAction],
  );

  return (
    <Modal
      animationType="none"
      hardwareAccelerated
      onRequestClose={closeSurface}
      presentationStyle="overFullScreen"
      statusBarTranslucent
      transparent
      visible={presented}
    >
      <View accessibilityViewIsModal style={styles.overlay}>
        <AnimatedPressable
          accessibilityLabel={t('workspaces.close')}
          accessibilityRole="button"
          onPress={closeSurface}
          style={[styles.backdrop, { opacity: progress }]}
          testID="workspace-picker-backdrop"
        />
        <KeyboardAvoidingView
          behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
          pointerEvents="box-none"
          style={[
            styles.keyboardAvoider,
            { paddingTop: Math.max(insets.top, 12) },
          ]}
        >
          <Animated.View
            style={[
              styles.cardAnchor,
              { maxHeight: Math.round(windowHeight * 0.78) },
              {
                transform: [
                  {
                    translateY: progress.interpolate({
                      inputRange: [0, 1],
                      outputRange: [windowHeight, 0],
                    }),
                  },
                ],
              },
            ]}
          >
            <ScrollView
              ref={scroll}
              accessibilityLabel={t('workspaces.title')}
              role="dialog"
              style={styles.sheet}
              contentContainerStyle={[
                styles.sheetContent,
                { paddingBottom: Math.max(insets.bottom, 16) },
              ]}
              keyboardShouldPersistTaps="handled"
              keyboardDismissMode="interactive"
              onLayout={revealCreation}
              onContentSizeChange={revealCreation}
              testID="workspace-picker-sheet"
            >
              <Text style={styles.title}>{t('workspaces.title')}</Text>
              {pendingSelection !== null && (
                <View
                  accessibilityLabel={pendingSelection.display_name}
                  style={styles.selectionPrompt}
                  testID="workspace-picker-selection-prompt"
                >
                  <Text style={styles.selectionPromptText}>
                    {pendingSelection.kind === 'import'
                      ? t('workspaces.importFolder')
                      : t('workspaces.openFolder')}{' '}
                    {pendingSelection.display_name}
                  </Text>
                  <View style={styles.selectionPromptActions}>
                    <Pressable
                      accessibilityLabel={t('workspaces.confirmSelection', {
                        name: pendingSelection.display_name,
                      })}
                      accessibilityRole="button"
                      disabled={busy}
                      onPress={() => {
                        confirmSelection().catch(() => undefined);
                      }}
                      style={({ pressed }) => [
                        styles.actionChip,
                        pressed && styles.pressed,
                      ]}
                      testID="workspace-picker-confirm-selection"
                    >
                      <Text style={styles.actionText}>
                        {pendingSelection.kind === 'import'
                          ? t('workspaces.importFolder')
                          : t('workspaces.openFolder')}
                      </Text>
                    </Pressable>
                    <Pressable
                      accessibilityLabel={t('workspaces.cancelSelection', {
                        name: pendingSelection.display_name,
                      })}
                      accessibilityRole="button"
                      disabled={busy}
                      onPress={() => {
                        cancelSelection().catch(() => undefined);
                      }}
                      style={({ pressed }) => [
                        styles.footerAction,
                        pressed && styles.pressed,
                      ]}
                      testID="workspace-picker-cancel-selection"
                    >
                      <Text style={styles.footerActionText}>
                        {t('common.cancel')}
                      </Text>
                    </Pressable>
                  </View>
                </View>
              )}
              {notice !== null && <RecoveryNotice error={notice.error} />}
              <View
                accessibilityLabel={t('workspaces.list')}
                style={styles.listContent}
                testID="workspace-picker-list"
              >
                {rows === null ? (
                  <View style={styles.loading}>
                    <ActivityIndicator color={colors.accent} size="small" />
                  </View>
                ) : rows.length === 0 ? (
                  <Text style={styles.empty}>{t('workspaces.empty')}</Text>
                ) : (
                  rows.map(row => {
                    const isActive = row.workspace_id === activeWorkspaceId;
                    return (
                      <View key={row.workspace_id} style={styles.rowShell}>
                        <View style={styles.row}>
                          <Pressable
                            accessibilityLabel={t('workspaces.select', {
                              name: row.display_name,
                            })}
                            accessibilityRole="radio"
                            accessibilityState={{
                              checked: isActive,
                              disabled: row.status !== 'ok',
                            }}
                            disabled={busy || row.status !== 'ok'}
                            onPress={() => selectWorkspace(row.workspace_id)}
                            style={({ pressed }) => [
                              styles.rowSelect,
                              row.status !== 'ok' && styles.disabledRow,
                              pressed && styles.pressed,
                            ]}
                            testID={`workspace-picker-row-${row.workspace_id}`}
                          >
                            <View style={styles.check}>
                              {isActive && (
                                <AppIcon
                                  color={colors.accent}
                                  icon={Check}
                                  size={18}
                                />
                              )}
                            </View>
                            <View style={styles.rowCopy}>
                              <Text numberOfLines={1} style={styles.rowTitle}>
                                {row.display_name}
                              </Text>
                              <Text style={styles.rowStatus}>
                                {row.origin === 'granted_folder'
                                  ? `${t(
                                      `workspaces.status.${row.status}`,
                                    )} · ${t('workspaces.onDevice')}`
                                  : t(`workspaces.status.${row.status}`)}
                              </Text>
                            </View>
                          </Pressable>
                          <View style={styles.rowActions}>
                            {row.origin === 'granted_folder' &&
                              row.status !== 'ok' && (
                                <Pressable
                                  accessibilityLabel={t(
                                    'workspaces.regrantNamed',
                                    { name: row.display_name },
                                  )}
                                  accessibilityRole="button"
                                  disabled={busy}
                                  onPress={() => {
                                    presentRegrantPicker(row).catch(
                                      () => undefined,
                                    );
                                  }}
                                  style={({ pressed }) => [
                                    styles.forgetButton,
                                    pressed && styles.pressed,
                                  ]}
                                  testID={`workspace-picker-regrant-${row.workspace_id}`}
                                >
                                  <Text style={styles.forgetText}>
                                    {t('workspaces.regrant')}
                                  </Text>
                                </Pressable>
                              )}
                            {onRemove !== undefined && row.origin !== 'granted_folder' ? (
                              <Pressable
                                accessibilityLabel={t('workspaces.delete', {
                                  name: row.display_name,
                                })}
                                accessibilityRole="button"
                                disabled={busy}
                                onPress={() => {
                                  removeWorkspace(row, 'delete_owned').catch(() => undefined);
                                }}
                                style={({ pressed }) => [
                                  styles.forgetButton,
                                  pressed && styles.pressed,
                                ]}
                                testID={`workspace-picker-delete-${row.workspace_id}`}
                              >
                                <Text style={styles.forgetText}>
                                  {t('common.delete')}
                                </Text>
                              </Pressable>
                            ) : (
                              <Pressable
                                accessibilityLabel={t('workspaces.forget', {
                                  name: row.display_name,
                                })}
                                accessibilityRole="button"
                                disabled={busy}
                                onPress={() => {
                                  if (onRemove !== undefined) {
                                    removeWorkspace(row, 'forget').catch(() => undefined);
                                  } else {
                                    forgetWorkspace(row).catch(() => undefined);
                                  }
                                }}
                                style={({ pressed }) => [
                                  styles.forgetButton,
                                  pressed && styles.pressed,
                                ]}
                                testID={`workspace-picker-forget-${row.workspace_id}`}
                              >
                                <Text style={styles.forgetText}>
                                  {t('common.forget')}
                                </Text>
                              </Pressable>
                            )}
                          </View>
                        </View>
                      </View>
                    );
                  })
                )}
              </View>
              <View style={styles.newRow}>
                <TextInput
                  accessibilityLabel={t('workspaces.namePlaceholder')}
                  onChangeText={setDraftName}
                  onFocus={() => {
                    nameFocused.current = true;
                    revealCreation();
                  }}
                  onBlur={() => {
                    nameFocused.current = false;
                  }}
                  returnKeyType="done"
                  onSubmitEditing={() => {
                    createWorkspace().catch(() => undefined);
                  }}
                  placeholder={t('workspaces.namePlaceholder')}
                  placeholderTextColor={colors.faint}
                  style={styles.input}
                  testID="workspace-picker-name-input"
                  value={draftName}
                />
                <Pressable
                  accessibilityLabel={t('workspaces.new')}
                  accessibilityRole="button"
                  disabled={draftName.trim().length === 0 || busy}
                  onPress={() => {
                    createWorkspace().catch(() => undefined);
                  }}
                  style={({ pressed }) => [
                    styles.actionChip,
                    draftName.trim().length === 0 && styles.actionDisabled,
                    pressed && styles.pressed,
                  ]}
                  testID="workspace-picker-new"
                >
                  {busy ? (
                    <ActivityIndicator color={colors.text} size="small" />
                  ) : (
                    <>
                      <AppIcon color={colors.text} icon={Plus} size={16} />
                      <Text style={styles.actionText}>
                        {t('workspaces.new')}
                      </Text>
                    </>
                  )}
                </Pressable>
              </View>
              {folderPickerAvailable && (
                <View style={styles.footerRow}>
                  <Pressable
                    accessibilityLabel={t('workspaces.openFolder')}
                    accessibilityRole="button"
                    disabled={busy || pendingSelection !== null}
                    onPress={() => {
                      presentFolderPicker('grant_or_import').catch(
                        () => undefined,
                      );
                    }}
                    style={({ pressed }) => [
                      styles.footerAction,
                      pressed && styles.pressed,
                    ]}
                  >
                    <AppIcon color={colors.accent} icon={FolderOpen} size={17} />
                    <Text style={styles.footerActionText}>
                      {t('workspaces.openFolder')}
                    </Text>
                  </Pressable>
                  <Pressable
                    accessibilityLabel={t('workspaces.importFolder')}
                    accessibilityRole="button"
                    disabled={busy || pendingSelection !== null}
                    onPress={() => {
                      presentFolderPicker('import_only').catch(() => undefined);
                    }}
                    style={({ pressed }) => [
                      styles.footerAction,
                      pressed && styles.pressed,
                    ]}
                  >
                    <AppIcon color={colors.accent} icon={FolderInput} size={17} />
                    <Text style={styles.footerActionText}>
                      {t('workspaces.importFolder')}
                    </Text>
                  </Pressable>
                </View>
              )}
            </ScrollView>
          </Animated.View>
        </KeyboardAvoidingView>
      </View>
    </Modal>
  );
}
