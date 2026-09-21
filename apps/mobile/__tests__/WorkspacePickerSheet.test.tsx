const mockNativeLocalWorkspaces = {
  list: jest.fn(),
  resolve: jest.fn(),
  queryOperation: jest.fn(),
  create: jest.fn(),
  bootstrapLegacyProject: jest.fn(),
  presentFolderPicker: jest.fn(),
  importSelection: jest.fn(),
  cancelSelection: jest.fn(),
  presentRegrantPicker: jest.fn(),
  completeRegrant: jest.fn(),
  forget: jest.fn(),
  prepareDeleteOwnedContent: jest.fn(),
  deleteOwnedContent: jest.fn(),
  cancelPicker: jest.fn(),
};

import React from 'react';
import { Modal, StyleSheet } from 'react-native';
import ReactTestRenderer, {
  act,
  type ReactTestInstance,
  type ReactTestRenderer as Renderer,
} from 'react-test-renderer';

import { NativeModules } from 'react-native';

(NativeModules as Record<string, unknown>).LocalWorkspaces =
  mockNativeLocalWorkspaces;
const { WorkspacePickerSheet } = jest.requireActual(
  '../src/components/WorkspacePickerSheet',
) as typeof import('../src/components/WorkspacePickerSheet');

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, right: 0, bottom: 0, left: 0 }),
}));

const activeRoots: ReactTestRenderer.ReactTestRenderer[] = [];

beforeEach(() => {
  jest.resetAllMocks();
  mockNativeLocalWorkspaces.cancelPicker.mockResolvedValue({
    schema_version: 1,
    status: 'already_settled',
  });
  mockNativeLocalWorkspaces.cancelSelection.mockResolvedValue({
    schema_version: 1,
    status: 'cancelled',
  });
});

afterEach(() => {
  act(() => {
    while (activeRoots.length > 0) {
      activeRoots.pop()?.unmount();
    }
  });
});

function descriptor(id: string, name: string, status = 'ok') {
  return {
    schema_version: 2 as const,
    workspace_id: id,
    display_name: name,
    origin: 'rish_created' as const,
    created_at: '2026-08-27T01:00:00.000Z',
    last_opened_at: '2026-08-27T01:00:00.000Z',
    status: status as
      | 'ok'
      | 'stale'
      | 'revoked'
      | 'unavailable'
      | 'not_downloaded',
    binding_revision: 1,
    capabilities: {
      read: false,
      write: false,
      git: false,
      project_context: false,
      files_visible: true,
    },
  };
}

const WORKSPACE_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const WORKSPACE_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const OPERATION_ID = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const CLEARANCE_RECEIPT_ID = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

function presentation(children: React.ReactNode, locale: 'en-US' | 'zh-CN' = 'en-US') {
  const { AppPresentationProvider } = jest.requireActual(
    '../src/presentation/AppPresentation',
  ) as typeof import('../src/presentation/AppPresentation');
  const { createDefaultPreferences, createPreferencesStore } =
    jest.requireActual(
      '../src/preferences',
    ) as typeof import('../src/preferences');
  const store = createPreferencesStore({
    initialPreferences: {
      ...createDefaultPreferences(),
      locale,
    },
  });
  return (
    <AppPresentationProvider store={store}>{children}</AppPresentationProvider>
  );
}

async function renderSheet(
  props: {
    locale?: 'en-US' | 'zh-CN';
    activeWorkspaceId?: string | null;
    onClose?: jest.Mock;
    onSelect?: jest.Mock<void, [string]>;
    forgetAuthorization?: {
      operation_id: string;
      clearance_receipt_id: string;
    };
    onRemove?: jest.Mock;
  } = {},
): Promise<Renderer> {
  let renderer: Renderer | undefined;
  await act(async () => {
    renderer = ReactTestRenderer.create(
      presentation(
        <WorkspacePickerSheet
          activeWorkspaceId={props.activeWorkspaceId ?? null}
          visible
          onClose={props.onClose ?? jest.fn()}
          onSelect={props.onSelect ?? jest.fn()}
          forgetAuthorization={props.forgetAuthorization}
          onRemove={props.onRemove}
        />,
        props.locale,
      ),
    );
  });
  await act(async () => {});
  if (renderer === undefined) throw new Error('renderer was not created');
  activeRoots.push(renderer);
  return renderer;
}

function actionByLabel(root: ReactTestInstance, label: string) {
  const action = root
    .findAllByProps({ accessibilityLabel: label })
    .find(instance => typeof instance.props.onPress === 'function');
  if (action === undefined) throw new Error(`no actionable ${label}`);
  return action;
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(nextResolve => {
    resolve = nextResolve;
  });
  return { promise, resolve };
}

test('presents through a modal whose scrim fades instead of sliding', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [],
  });

  const renderer = await renderSheet();

  const modal = renderer.root.findByType(Modal);
  expect(modal.props.animationType).toBe('none');
  expect(modal.props.presentationStyle).toBe('overFullScreen');
  const backdrop = renderer.root.findByProps({
    testID: 'workspace-picker-backdrop',
  });
  const backdropStyle = StyleSheet.flatten(backdrop.props.style);
  // The scrim's opacity is an Animated value, so it fades in place; only the
  // card itself translates. A static sliding modal would not carry opacity.
  expect(backdropStyle.opacity).toBeDefined();
  expect(typeof backdropStyle.backgroundColor).toBe('string');
  expect(backdropStyle.backgroundColor).toContain('rgba');
});

test('lists workspaces with structured access states', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [
      descriptor(WORKSPACE_A, 'Alpha'),
      descriptor(WORKSPACE_B, 'Beta', 'revoked'),
    ],
  });

  const renderer = await renderSheet({ activeWorkspaceId: WORKSPACE_A });

  expect(actionByLabel(renderer.root, 'Use Alpha')).toBeDefined();
  expect(
    actionByLabel(renderer.root, 'Use Beta').props.accessibilityState,
  ).toEqual({ checked: false, disabled: true });
  expect(
    actionByLabel(renderer.root, 'Use Alpha').props.accessibilityState,
  ).toEqual({ checked: true, disabled: false });
});

test('selects a workspace through its row without closing the sheet', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [descriptor(WORKSPACE_A, 'Alpha')],
  });
  const onSelect = jest.fn();
  const renderer = await renderSheet({ onSelect });

  await act(async () => {
    actionByLabel(renderer.root, 'Use Alpha').props.onPress();
  });

  expect(onSelect).toHaveBeenCalledWith(WORKSPACE_A);
  expect(mockNativeLocalWorkspaces.list).toHaveBeenCalledTimes(1);
});

test('creates a named Rish workspace and reloads the registry', async () => {
  mockNativeLocalWorkspaces.list
    .mockResolvedValueOnce({ schema_version: 1, workspaces: [] })
    .mockResolvedValueOnce({
      schema_version: 1,
      workspaces: [descriptor(WORKSPACE_A, 'Scratch')],
    });
  mockNativeLocalWorkspaces.create.mockResolvedValue(
    descriptor(WORKSPACE_A, 'Scratch'),
  );

  const renderer = await renderSheet();
  const input = renderer.root.findByProps({
    accessibilityLabel: 'Workspace name',
  });
  await act(async () => {
    input.props.onChangeText('  Scratch  ');
  });
  await act(async () => {
    actionByLabel(renderer.root, 'New workspace').props.onPress();
  });

  expect(mockNativeLocalWorkspaces.create).toHaveBeenCalledWith({
    schema_version: 1,
    display_name: 'Scratch',
    operation_id: expect.any(String),
  });
  expect(mockNativeLocalWorkspaces.list).toHaveBeenCalledTimes(2);
  expect(actionByLabel(renderer.root, 'Use Scratch')).toBeDefined();
});

test('forgets a workspace by its opaque id and reloads', async () => {
  mockNativeLocalWorkspaces.list
    .mockResolvedValueOnce({
      schema_version: 1,
      workspaces: [descriptor(WORKSPACE_A, 'Alpha')],
    })
    .mockResolvedValueOnce({ schema_version: 1, workspaces: [] });
  mockNativeLocalWorkspaces.forget.mockResolvedValue({
    schema_version: 1,
    status: 'forgotten',
  });

  const renderer = await renderSheet({
    forgetAuthorization: {
      operation_id: OPERATION_ID,
      clearance_receipt_id: CLEARANCE_RECEIPT_ID,
    },
  });
  await act(async () => {
    actionByLabel(renderer.root, 'Forget Alpha').props.onPress();
  });

  expect(mockNativeLocalWorkspaces.forget).toHaveBeenCalledWith({
    schema_version: 1,
    workspace_id: WORKSPACE_A,
    expected_binding_revision: 1,
    operation_id: OPERATION_ID,
    clearance_receipt_id: CLEARANCE_RECEIPT_ID,
  });
  expect(mockNativeLocalWorkspaces.list).toHaveBeenCalledTimes(2);
});

test('surfaces revoked folders instead of hiding them', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [descriptor(WORKSPACE_B, 'Beta', 'revoked')],
  });

  const renderer = await renderSheet();

  expect(
    renderer.root.findByProps({ children: 'Access revoked' }),
  ).toBeDefined();
  expect(actionByLabel(renderer.root, 'Use Beta').props.disabled).toBe(true);
});

test('routes open and import actions through the exact picker contract', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [],
  });
  mockNativeLocalWorkspaces.presentFolderPicker
    .mockResolvedValueOnce({
      schema_version: 1,
      status: 'selected',
      workspace: descriptor(WORKSPACE_A, 'Alpha'),
    })
    .mockResolvedValueOnce({ schema_version: 1, status: 'cancelled' });
  const onSelect = jest.fn();
  const renderer = await renderSheet({ onSelect });

  await act(async () => {
    actionByLabel(renderer.root, 'Open folder…').props.onPress();
    await Promise.resolve();
  });
  expect(mockNativeLocalWorkspaces.presentFolderPicker).toHaveBeenNthCalledWith(
    1,
    {
      schema_version: 1,
      operation_id: expect.any(String),
      mode: 'grant_or_import',
    },
  );
  expect(onSelect).toHaveBeenCalledWith(WORKSPACE_A);

  await act(async () => {
    actionByLabel(renderer.root, 'Import folder…').props.onPress();
    await Promise.resolve();
  });
  expect(mockNativeLocalWorkspaces.presentFolderPicker).toHaveBeenNthCalledWith(
    2,
    {
      schema_version: 1,
      operation_id: expect.any(String),
      mode: 'import_only',
    },
  );
  expect(
    mockNativeLocalWorkspaces.presentFolderPicker.mock.calls[0][0].operation_id,
  ).not.toBe(
    mockNativeLocalWorkspaces.presentFolderPicker.mock.calls[1][0].operation_id,
  );
});

test('holds an import selection for confirmation and supports cancellation', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [],
  });
  mockNativeLocalWorkspaces.presentFolderPicker.mockResolvedValue({
    schema_version: 1,
    status: 'requires_import',
    selection_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    display_name: 'External',
    location_class: 'unknown',
  });
  mockNativeLocalWorkspaces.importSelection.mockResolvedValue(
    descriptor(WORKSPACE_A, 'External'),
  );
  const renderer = await renderSheet({ onSelect: jest.fn() });

  await act(async () => {
    actionByLabel(renderer.root, 'Import folder…').props.onPress();
    await Promise.resolve();
  });
  expect(
    renderer.root.findByProps({ testID: 'workspace-picker-selection-prompt' }),
  ).toBeDefined();
  expect(mockNativeLocalWorkspaces.importSelection).not.toHaveBeenCalled();

  await act(async () => {
    renderer.root
      .findByProps({ testID: 'workspace-picker-cancel-selection' })
      .props.onPress();
    await Promise.resolve();
  });
  expect(mockNativeLocalWorkspaces.cancelSelection).toHaveBeenCalledWith({
    schema_version: 1,
    selection_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  });
  expect(
    renderer.root.findAllByProps({
      testID: 'workspace-picker-selection-prompt',
    }),
  ).toHaveLength(0);
});

test('imports after confirmation with the same one-shot operation id', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [],
  });
  mockNativeLocalWorkspaces.presentFolderPicker.mockResolvedValue({
    schema_version: 1,
    status: 'requires_import',
    selection_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    display_name: 'External',
    location_class: 'provider_managed',
  });
  mockNativeLocalWorkspaces.importSelection.mockResolvedValue(
    descriptor(WORKSPACE_A, 'External'),
  );
  const onSelect = jest.fn();
  const renderer = await renderSheet({ onSelect });

  await act(async () => {
    actionByLabel(renderer.root, 'Open folder…').props.onPress();
    await Promise.resolve();
  });
  const operationId =
    mockNativeLocalWorkspaces.presentFolderPicker.mock.calls[0][0].operation_id;
  await act(async () => {
    renderer.root
      .findByProps({ testID: 'workspace-picker-confirm-selection' })
      .props.onPress();
    await Promise.resolve();
  });

  expect(mockNativeLocalWorkspaces.importSelection).toHaveBeenCalledWith({
    schema_version: 1,
    selection_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    operation_id: operationId,
  });
  expect(onSelect).toHaveBeenCalledWith(WORKSPACE_A);
});

test.each(['en-US', 'zh-CN'] as const)('regrants a revoked folder with localized controls in %s and preserves the captured revision', async locale => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [
      {
        ...descriptor(WORKSPACE_B, 'Beta', 'revoked'),
        origin: 'granted_folder' as const,
      },
    ],
  });
  mockNativeLocalWorkspaces.presentRegrantPicker.mockResolvedValue({
    schema_version: 1,
    status: 'same_root_selected',
    selection_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    display_name: 'Beta',
  });
  mockNativeLocalWorkspaces.completeRegrant.mockResolvedValue({
    schema_version: 1,
    status: 'regranted',
    workspace: {
      ...descriptor(WORKSPACE_B, 'Beta'),
      origin: 'granted_folder' as const,
      binding_revision: 2,
    },
  });
  const onSelect = jest.fn();
  const renderer = await renderSheet({ onSelect, locale });

  await act(async () => {
    actionByLabel(renderer.root, locale === 'zh-CN' ? '重新授权Beta' : 'Grant access to Beta again').props.onPress();
    await Promise.resolve();
  });
  expect(actionByLabel(renderer.root, locale === 'zh-CN' ? '确认Beta' : 'Confirm Beta')).toBeDefined();
  expect(actionByLabel(renderer.root, locale === 'zh-CN' ? '取消Beta' : 'Cancel Beta')).toBeDefined();
  const operationId =
    mockNativeLocalWorkspaces.presentRegrantPicker.mock.calls[0][0]
      .operation_id;
  await act(async () => {
    renderer.root
      .findByProps({ testID: 'workspace-picker-confirm-selection' })
      .props.onPress();
    await Promise.resolve();
  });

  expect(mockNativeLocalWorkspaces.presentRegrantPicker).toHaveBeenCalledWith({
    schema_version: 1,
    workspace_id: WORKSPACE_B,
    expected_binding_revision: 1,
    operation_id: operationId,
  });
  expect(mockNativeLocalWorkspaces.completeRegrant).toHaveBeenCalledWith({
    schema_version: 1,
    workspace_id: WORKSPACE_B,
    expected_binding_revision: 1,
    selection_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    operation_id: operationId,
  });
  expect(onSelect).toHaveBeenCalledWith(WORKSPACE_B);
});

test('fails closed instead of inventing forget clearance', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [descriptor(WORKSPACE_A, 'Alpha')],
  });
  const renderer = await renderSheet();

  await act(async () => {
    actionByLabel(renderer.root, 'Forget Alpha').props.onPress();
    await Promise.resolve();
  });

  expect(mockNativeLocalWorkspaces.forget).not.toHaveBeenCalled();
  expect(
    renderer.root.findByProps({ accessibilityRole: 'alert' }),
  ).toBeDefined();
});

test('ignores a late picker result after the sheet generation is closed', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [],
  });
  const picker = deferred<{
    schema_version: 1;
    status: 'selected';
    workspace: ReturnType<typeof descriptor>;
  }>();
  mockNativeLocalWorkspaces.presentFolderPicker.mockReturnValue(picker.promise);
  const onSelect = jest.fn();
  const renderer = await renderSheet({ onSelect });

  await act(async () => {
    actionByLabel(renderer.root, 'Open folder…').props.onPress();
    await Promise.resolve();
  });
  await act(async () => {
    renderer.root
      .findByProps({ testID: 'workspace-picker-backdrop' })
      .props.onPress();
  });
  picker.resolve({
    schema_version: 1,
    status: 'selected',
    workspace: descriptor(WORKSPACE_A, 'Alpha'),
  });
  await act(async () => {
    await Promise.resolve();
  });

  expect(onSelect).not.toHaveBeenCalled();
  expect(mockNativeLocalWorkspaces.cancelPicker).toHaveBeenCalledWith({
    schema_version: 1,
    operation_id:
      mockNativeLocalWorkspaces.presentFolderPicker.mock.calls[0][0]
        .operation_id,
  });
});

test('invalidates a picker result when its workspace owner is replaced while visible', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [],
  });
  const picker = deferred<{
    schema_version: 1;
    status: 'selected';
    workspace: ReturnType<typeof descriptor>;
  }>();
  mockNativeLocalWorkspaces.presentFolderPicker.mockReturnValue(picker.promise);
  const onSelect = jest.fn();
  const renderer = await renderSheet({
    activeWorkspaceId: WORKSPACE_A,
    onSelect,
  });

  await act(async () => {
    actionByLabel(renderer.root, 'Open folder…').props.onPress();
    await Promise.resolve();
  });
  await act(async () => {
    renderer.update(
      presentation(
        <WorkspacePickerSheet
          activeWorkspaceId={WORKSPACE_B}
          visible
          onClose={jest.fn()}
          onSelect={onSelect}
        />,
      ),
    );
  });
  picker.resolve({
    schema_version: 1,
    status: 'selected',
    workspace: descriptor(WORKSPACE_A, 'Alpha'),
  });
  await act(async () => {
    await Promise.resolve();
  });

  expect(onSelect).not.toHaveBeenCalled();
  expect(mockNativeLocalWorkspaces.cancelPicker).toHaveBeenCalledWith({
    schema_version: 1,
    operation_id:
      mockNativeLocalWorkspaces.presentFolderPicker.mock.calls[0][0]
        .operation_id,
  });
});

test('invalidates an in-flight import when its workspace owner is replaced', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [],
  });
  mockNativeLocalWorkspaces.presentFolderPicker.mockResolvedValue({
    schema_version: 1,
    status: 'requires_import',
    selection_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    display_name: 'External',
    location_class: 'unknown',
  });
  const imported = deferred<ReturnType<typeof descriptor>>();
  mockNativeLocalWorkspaces.importSelection.mockReturnValue(imported.promise);
  const onSelect = jest.fn();
  const renderer = await renderSheet({
    activeWorkspaceId: WORKSPACE_A,
    onSelect,
  });

  await act(async () => {
    actionByLabel(renderer.root, 'Open folder…').props.onPress();
    await Promise.resolve();
  });
  await act(async () => {
    renderer.root
      .findByProps({ testID: 'workspace-picker-confirm-selection' })
      .props.onPress();
    await Promise.resolve();
  });
  await act(async () => {
    renderer.update(
      presentation(
        <WorkspacePickerSheet
          activeWorkspaceId={WORKSPACE_B}
          visible
          onClose={jest.fn()}
          onSelect={onSelect}
        />,
      ),
    );
  });
  imported.resolve(descriptor(WORKSPACE_A, 'External'));
  await act(async () => {
    await Promise.resolve();
  });

  expect(onSelect).not.toHaveBeenCalled();
});

test('invalidates an in-flight regrant when its workspace owner is replaced', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [
      {
        ...descriptor(WORKSPACE_A, 'Alpha', 'revoked'),
        origin: 'granted_folder' as const,
      },
    ],
  });
  mockNativeLocalWorkspaces.presentRegrantPicker.mockResolvedValue({
    schema_version: 1,
    status: 'same_root_selected',
    selection_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    display_name: 'Alpha',
  });
  const regranted = deferred<{
    schema_version: 1;
    status: 'regranted';
    workspace: ReturnType<typeof descriptor>;
  }>();
  mockNativeLocalWorkspaces.completeRegrant.mockReturnValue(regranted.promise);
  const onSelect = jest.fn();
  const renderer = await renderSheet({
    activeWorkspaceId: WORKSPACE_A,
    onSelect,
  });

  await act(async () => {
    actionByLabel(renderer.root, 'Grant access to Alpha again').props.onPress();
    await Promise.resolve();
  });
  await act(async () => {
    renderer.root
      .findByProps({ testID: 'workspace-picker-confirm-selection' })
      .props.onPress();
    await Promise.resolve();
  });
  await act(async () => {
    renderer.update(
      presentation(
        <WorkspacePickerSheet
          activeWorkspaceId={WORKSPACE_B}
          visible
          onClose={jest.fn()}
          onSelect={onSelect}
        />,
      ),
    );
  });
  regranted.resolve({
    schema_version: 1,
    status: 'regranted',
    workspace: descriptor(WORKSPACE_A, 'Alpha', 'ok'),
  });
  await act(async () => {
    await Promise.resolve();
  });

  expect(onSelect).not.toHaveBeenCalled();
});

test('onSelect invalidates an in-flight picker before owner handoff', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [descriptor(WORKSPACE_A, 'Alpha')],
  });
  const picker = deferred<{
    schema_version: 1;
    status: 'selected';
    workspace: ReturnType<typeof descriptor>;
  }>();
  mockNativeLocalWorkspaces.presentFolderPicker.mockReturnValue(picker.promise);
  const onSelect = jest.fn();
  const renderer = await renderSheet({ onSelect });
  const row = actionByLabel(renderer.root, 'Use Alpha');

  await act(async () => {
    actionByLabel(renderer.root, 'Open folder…').props.onPress();
    await Promise.resolve();
  });
  await act(async () => {
    row.props.onPress();
  });
  picker.resolve({
    schema_version: 1,
    status: 'selected',
    workspace: descriptor(WORKSPACE_B, 'Beta'),
  });
  await act(async () => {
    await Promise.resolve();
  });

  expect(onSelect).toHaveBeenCalledTimes(1);
  expect(onSelect).toHaveBeenCalledWith(WORKSPACE_A);
});

test('with a removal coordinator an owned workspace is deleted, a granted folder forgotten', async () => {
  mockNativeLocalWorkspaces.list
    .mockResolvedValueOnce({
      schema_version: 1,
      workspaces: [
        descriptor(WORKSPACE_A, 'Alpha'),
        { ...descriptor(WORKSPACE_B, 'Beta'), origin: 'granted_folder' as const },
      ],
    })
    .mockResolvedValue({ schema_version: 1, workspaces: [] });
  const onRemove = jest.fn().mockResolvedValue({ status: 'deleted' });
  const renderer = await renderSheet({ onRemove });

  expect(() => actionByLabel(renderer.root, 'Forget Alpha')).toThrow();
  await act(async () => {
    actionByLabel(renderer.root, 'Delete Alpha').props.onPress();
  });
  expect(onRemove).toHaveBeenCalledWith(
    expect.objectContaining({ workspace_id: WORKSPACE_A }),
    'delete_owned',
  );
  expect(mockNativeLocalWorkspaces.forget).not.toHaveBeenCalled();
  expect(mockNativeLocalWorkspaces.deleteOwnedContent).not.toHaveBeenCalled();
  // Reloaded after the removal.
  expect(mockNativeLocalWorkspaces.list).toHaveBeenCalledTimes(2);

  onRemove.mockResolvedValue({ status: 'forgotten' });
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [{ ...descriptor(WORKSPACE_B, 'Beta'), origin: 'granted_folder' as const }],
  });
  const second = await renderSheet({ onRemove });
  expect(() => actionByLabel(second.root, 'Delete Beta')).toThrow();
  await act(async () => {
    actionByLabel(second.root, 'Forget Beta').props.onPress();
  });
  expect(onRemove).toHaveBeenLastCalledWith(
    expect.objectContaining({ workspace_id: WORKSPACE_B }),
    'forget',
  );
});

test('a blocked or retired removal is shown, a cancelled one is not', async () => {
  mockNativeLocalWorkspaces.list.mockResolvedValue({
    schema_version: 1,
    workspaces: [descriptor(WORKSPACE_A, 'Alpha')],
  });
  const onRemove = jest.fn().mockResolvedValue({ status: 'blocked' });
  const renderer = await renderSheet({ onRemove });
  await act(async () => {
    actionByLabel(renderer.root, 'Delete Alpha').props.onPress();
    await Promise.resolve();
  });
  expect(renderer.root.findByProps({ accessibilityRole: 'alert' })).toBeDefined();
  expect(mockNativeLocalWorkspaces.list).toHaveBeenCalledTimes(1);

  onRemove.mockResolvedValue({ status: 'cancelled' });
  const cancelled = await renderSheet({ onRemove });
  await act(async () => {
    actionByLabel(cancelled.root, 'Delete Alpha').props.onPress();
    await Promise.resolve();
  });
  expect(cancelled.root.findAllByProps({ accessibilityRole: 'alert' })).toHaveLength(0);
});
