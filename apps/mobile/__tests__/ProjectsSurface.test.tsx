import React from 'react';
import { Alert } from 'react-native';
import ReactTestRenderer, {
  act,
  type ReactTestInstance,
  type ReactTestRenderer as Renderer,
} from 'react-test-renderer';

import { ProjectsSurface } from '../src/components/ProjectsSurface';
import { SlidingSurface } from '../src/components/SlidingSurface';
import { AppPresentationProvider } from '../src/presentation/AppPresentation';
import {
  createDefaultPreferences,
  createPreferencesStore,
  translate,
} from '../src/preferences';

jest.mock('../src/native/workspaceProjects', () => ({
  listWorkspaceProjects: jest.fn(async () => []),
}));
jest.mock('../src/native/LocalRuntime', () => ({
  LocalRuntime: { createCompletionRequestId: jest.fn(() => 'op-1') },
}));
jest.mock('../src/native/LocalProjects', () => ({
  LocalProjects: {
    isAvailable: jest.fn(),
    isV2Available: jest.fn(),
    list: jest.fn(),
    statusV2: jest.fn(),
    diffV2: jest.fn(),
    stageAllV2: jest.fn(),
    commitV2: jest.fn(),
    pushV2: jest.fn(),
    setRemoteV2: jest.fn(),
    remoteV2: jest.fn(),
    credentialStatusV2: jest.fn(),
    presentCredentialPromptV2: jest.fn(),
    clearCredentialV2: jest.fn(),
    cancelPushV2: jest.fn(),
    create: jest.fn(),
    clone: jest.fn(),
    startClone: jest.fn(),
    cloneStatus: jest.fn(),
    cancelClone: jest.fn(),
    status: jest.fn(),
    diff: jest.fn(),
    diffPage: jest.fn(),
    stageAll: jest.fn(),
    commit: jest.fn(),
    setRemote: jest.fn(),
    credentialStatus: jest.fn(),
    presentCredentialPrompt: jest.fn(),
    clearCredential: jest.fn(),
    beginSSHCredentialImport: jest.fn(),
    sshCredentialStatus: jest.fn(),
    push: jest.fn(),
    pushReceipts: jest.fn(),
    cancelPush: jest.fn(),
  },
}));

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, right: 0, bottom: 0, left: 0 }),
}));

const mockLocalProjects = (
  jest.requireMock('../src/native/LocalProjects') as {
    LocalProjects: Record<string, jest.Mock>;
  }
).LocalProjects;

const project = {
  schema_version: 1 as const,
  id: 'project-1',
  name: 'demo',
  workspace_path: 'projects/project-1/repo',
  created_at: '2026-08-24T00:00:00.000Z',
  updated_at: '2026-08-24T00:00:00.000Z',
  origin_url: 'https://github.com/example/demo.git',
};

function cloneSnapshot(phase: string, cancelRequested = false) {
  return {
    schema_version: 1,
    operation_id: 'clone-1',
    name: 'copy',
    phase,
    cancel_requested: cancelRequested,
    received_objects: 2,
    total_objects: 8,
    received_bytes: 4096,
    completed_files: 0,
    total_files: 0,
    project: phase === 'succeeded' ? project : null,
    error_code: phase === 'failed' ? 'git' : null,
  };
}

const dirtyStatus = {
  project_id: project.id,
  branch: 'main',
  head_oid: '0123456789abcdef',
  clean: false,
  has_conflicts: false,
  ahead: 1,
  behind: 0,
  entries: [
    {
      path: 'README.md',
      index_status: 'added',
      worktree_status: 'unmodified',
      conflicted: false,
    },
    {
      path: 'src/app.ts',
      index_status: 'unmodified',
      worktree_status: 'added',
      conflicted: false,
    },
  ],
};

const diff = {
  project_id: project.id,
  staged: false,
  truncated: false,
  patch: 'diff --git a/README.md b/README.md\n+hello\n',
  files: [
    { path: 'README.md', status: 'modified', additions: 1, deletions: 0 },
  ],
};

async function settle() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

const mountedRenderers = new Set<Renderer>();

afterEach(async () => {
  await act(async () => {
    for (const renderer of mountedRenderers) renderer.unmount();
  });
  mountedRenderers.clear();
  jest.useRealTimers();
});

test('configures SSH credentials before cloning and forwards the matching profile', async () => {
  const renderer = await renderSurface();
  await act(async () => actionByLabel(renderer.root, 'Clone repository').props.onPress());
  await act(async () => inputByLabel(renderer.root, 'Remote URL').props.onChangeText('git@github.com:example/demo.git'));
  await act(async () => { await actionByLabel(renderer.root, 'Configure SSH credential').props.onPress(); await settle(); });
  expect(mockLocalProjects.beginSSHCredentialImport).toHaveBeenCalledWith('rish-ssh-git@github.com-22', 'github.com', 22, 'git');
  await act(async () => actionByLabel(renderer.root, 'Clone').props.onPress());
  expect(mockLocalProjects.startClone).toHaveBeenCalledWith(expect.any(String), undefined, expect.objectContaining({ sshProfileId: 'rish-ssh-git@github.com-22' }));
});

test('switching SSH endpoints discards late status and keeps clone disabled', async () => {
  const late = deferred<any>();
  mockLocalProjects.sshCredentialStatus.mockReturnValueOnce(late.promise).mockResolvedValue(null);
  const renderer = await renderSurface();
  await act(async () => actionByLabel(renderer.root, 'Clone repository').props.onPress());
  await act(async () => inputByLabel(renderer.root, 'Remote URL').props.onChangeText('git@github.com:example/demo.git'));
  await act(async () => inputByLabel(renderer.root, 'Remote URL').props.onChangeText('git@gitlab.com:example/demo.git'));
  await act(async () => late.resolve({ profile_id: 'rish-ssh-git@github.com-22', host: 'github.com', port: 22, username: 'git', configured: true }));
  expect(actionByLabel(renderer.root, 'Clone').props.disabled).toBe(true);
});

test('SSH import failure is visible, retryable, and double click safe', async () => {
  mockLocalProjects.beginSSHCredentialImport.mockRejectedValueOnce(new Error('failed')).mockResolvedValueOnce({ profile_id: 'rish-ssh-git@github.com-22', host: 'github.com', port: 22, username: 'git', configured: true });
  const renderer = await renderSurface();
  await act(async () => actionByLabel(renderer.root, 'Clone repository').props.onPress());
  await act(async () => inputByLabel(renderer.root, 'Remote URL').props.onChangeText('git@github.com:example/demo.git'));
  const configure = actionByLabel(renderer.root, 'Configure SSH credential');
  await act(async () => configure.props.onPress());
  expect(renderer.root.findAllByProps({ children: 'SSH credential setup failed. Try again.' }).length).toBeGreaterThan(0);
  await act(async () => { configure.props.onPress(); configure.props.onPress(); await settle(); });
  expect(mockLocalProjects.beginSSHCredentialImport).toHaveBeenCalledTimes(2);
});

test('remounting an SSH endpoint reloads configured status and permits clone', async () => {
  mockLocalProjects.sshCredentialStatus.mockResolvedValue({ profile_id: 'rish-ssh-git@github.com-22', host: 'github.com', port: 22, username: 'git', configured: true });
  const renderer = await renderSurface();
  await act(async () => actionByLabel(renderer.root, 'Clone repository').props.onPress());
  await act(async () => inputByLabel(renderer.root, 'Remote URL').props.onChangeText('git@github.com:example/demo.git'));
  await settle();
  expect(actionByLabel(renderer.root, 'Clone').props.disabled).toBe(false);
  await act(async () => actionByLabel(renderer.root, 'Clone').props.onPress());
  expect(mockLocalProjects.startClone).toHaveBeenCalledWith(expect.any(String), undefined, expect.objectContaining({ sshProfileId: 'rish-ssh-git@github.com-22' }));
});

async function renderSurface({
  boundProjectId = null,
  gitHttpsProxyUrl = null,
  onChatInProject = jest.fn(),
  onDismiss = jest.fn(),
  onOpenFiles = jest.fn(),
  onUnbindFromChat = jest.fn(),
}: {
  boundProjectId?: string | null;
  gitHttpsProxyUrl?: string | null;
  onChatInProject?: jest.Mock;
  onDismiss?: jest.Mock;
  onOpenFiles?: jest.Mock;
  onUnbindFromChat?: jest.Mock;
} = {}): Promise<Renderer> {
  const store = createPreferencesStore({
    initialPreferences: {
      ...createDefaultPreferences(),
      gitHttpsProxyUrl,
      locale: 'en-US',
    },
  });
  let renderer: Renderer | undefined;
  await act(async () => {
    renderer = ReactTestRenderer.create(
      <AppPresentationProvider store={store}>
        <ProjectsSurface
          boundProjectId={boundProjectId}
          visible
          onChatInProject={onChatInProject}
          onClose={jest.fn()}
          onDismiss={onDismiss}
          onOpenFiles={onOpenFiles}
          onUnbindFromChat={onUnbindFromChat}
        />
      </AppPresentationProvider>,
    );
    await settle();
  });
  if (renderer === undefined) throw new Error('renderer was not created');
  mountedRenderers.add(renderer);
  return renderer;
}

test('forwards dismissal only after the Projects sliding surface finishes', async () => {
  const onDismiss = jest.fn();
  const renderer = await renderSurface({ onDismiss });
  const surface = renderer.root.findByType(SlidingSurface);

  expect(surface.props.onDismiss).toBe(onDismiss);
  await act(async () => surface.props.onDismiss());
  expect(onDismiss).toHaveBeenCalledTimes(1);
});

function actionByLabel(
  root: ReactTestInstance,
  label: string,
): ReactTestInstance {
  const action = root
    .findAllByProps({ accessibilityLabel: label })
    .find(instance => typeof instance.props.onPress === 'function');
  if (action === undefined) throw new Error(`no actionable ${label}`);
  return action;
}

function inputByLabel(
  root: ReactTestInstance,
  label: string,
): ReactTestInstance {
  const input = root
    .findAllByProps({ accessibilityLabel: label })
    .find(instance => typeof instance.props.onChangeText === 'function');
  if (input === undefined) throw new Error(`no input ${label}`);
  return input;
}

async function openProject(renderer: Renderer) {
  await act(async () => {
    actionByLabel(renderer.root, 'Open project demo').props.onPress();
    await settle();
  });
}

const mockWorkspaceProjects = (
  jest.requireMock('../src/native/workspaceProjects') as {
    listWorkspaceProjects: jest.Mock;
  }
).listWorkspaceProjects;

const workspaceRoot = {
  schema_version: 1 as const,
  workspace_id: '11111111-1111-4111-8111-111111111111',
  binding_revision: 1,
  project_id: '22222222-2222-4222-8222-222222222222',
};

const workspaceProject = {
  projectId: workspaceRoot.project_id,
  name: 'Smoke',
  workspaceId: workspaceRoot.workspace_id,
  workspaceName: 'Smoke',
  root: workspaceRoot,
  createdAt: '2026-09-20T00:00:00.000Z',
  lastOpenedAt: '2026-09-20T00:00:00.000Z',
};

beforeEach(() => {
  jest.clearAllMocks();
  mockLocalProjects.isAvailable.mockReturnValue(true);
  mockLocalProjects.isV2Available.mockReturnValue(false);
  mockWorkspaceProjects.mockResolvedValue([]);
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [project],
  });
  mockLocalProjects.create.mockResolvedValue({
    ...project,
    id: 'project-created',
    name: 'created',
    origin_url: null,
  });
  mockLocalProjects.clone.mockResolvedValue(project);
  mockLocalProjects.cloneStatus.mockResolvedValue(null);
  mockLocalProjects.startClone.mockResolvedValue(cloneSnapshot('succeeded'));
  mockLocalProjects.cancelClone.mockResolvedValue(
    cloneSnapshot('receiving', true),
  );
  mockLocalProjects.status.mockResolvedValue(dirtyStatus);
  mockLocalProjects.diff.mockImplementation(
    async (_id: string, options?: { staged?: boolean }) => ({
      ...diff,
      staged: options?.staged ?? false,
    }),
  );
  mockLocalProjects.diffPage.mockResolvedValue({
    ...diff,
    staged: true,
    page_offset: 0,
    next_offset: null,
    snapshot_id: 'a'.repeat(64),
    omitted_paths: [],
  });
  mockLocalProjects.stageAll.mockResolvedValue(dirtyStatus);
  mockLocalProjects.commit.mockResolvedValue({
    project_id: project.id,
    oid: 'abcdef',
    summary: 'Update README',
    committed_at: '2026-08-24T00:00:00.000Z',
  });
  mockLocalProjects.setRemote.mockResolvedValue({
    project_id: project.id,
    name: 'origin',
    url: project.origin_url,
  });
  mockLocalProjects.credentialStatus.mockResolvedValue({
    project_id: project.id,
    host: 'github.com',
    configured: false,
  });
  mockLocalProjects.presentCredentialPrompt.mockResolvedValue({
    project_id: project.id,
    host: 'github.com',
    configured: true,
  });
  mockLocalProjects.clearCredential.mockResolvedValue({
    project_id: project.id,
    host: 'github.com',
    configured: false,
  });
  mockLocalProjects.sshCredentialStatus.mockResolvedValue(null);
  mockLocalProjects.beginSSHCredentialImport.mockResolvedValue({
    profile_id: 'rish-ssh-git@github.com-22', host: 'github.com', port: 22,
    username: 'git', configured: true,
  });
  mockLocalProjects.push.mockResolvedValue({
    project_id: project.id,
    remote: 'origin',
    branch: 'main',
    oid: dirtyStatus.head_oid,
    pushed_at: '2026-08-24T00:00:00.000Z',
  });
  mockLocalProjects.pushReceipts.mockResolvedValue({
    schema_version: 1,
    project_id: project.id,
    receipts: [],
  });
  mockLocalProjects.cancelPush.mockResolvedValue({
    schema_version: 1,
    project_id: project.id,
    cancelled: true,
  });
  mockLocalProjects.remoteV2.mockResolvedValue({
    schema_version: 2, root: workspaceRoot, project_id: workspaceRoot.project_id,
    remote: 'origin', url: null, host: null,
  });
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

const otherProject = {
  ...project,
  id: 'project-2',
  name: 'other',
  origin_url: 'https://example.org/other.git',
};

async function navigateToOther(renderer: Renderer) {
  await act(async () => {
    actionByLabel(renderer.root, 'Back to projects').props.onPress();
    await settle();
  });
  await act(async () => {
    actionByLabel(renderer.root, 'Open project other').props.onPress();
    await settle();
  });
}

async function setVisible(renderer: Renderer, visible: boolean) {
  const presentation = renderer.root.findByType(AppPresentationProvider)
    .props as React.ComponentProps<typeof AppPresentationProvider>;
  const props = renderer.root.findByType(ProjectsSurface)
    .props as React.ComponentProps<typeof ProjectsSurface>;
  await act(async () => {
    renderer.update(
      <AppPresentationProvider {...presentation}>
        <ProjectsSurface {...props} visible={visible} />
      </AppPresentationProvider>,
    );
    await settle();
  });
}

test('late project A detail cannot overwrite project B data or remote credentials', async () => {
  const held = deferred<typeof dirtyStatus>();
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [project, otherProject],
  });
  mockLocalProjects.status.mockImplementation((id: string) =>
    id === project.id
      ? held.promise
      : Promise.resolve({
          ...dirtyStatus,
          project_id: id,
          branch: 'other-branch',
        }),
  );
  mockLocalProjects.credentialStatus.mockImplementation(async (id: string) => ({
    project_id: id,
    host: id,
    configured: id === project.id,
  }));
  mockLocalProjects.diff.mockImplementation(async (id: string) => ({
    ...diff,
    project_id: id,
    patch: id === project.id ? 'OLD-A-PATCH' : 'CURRENT-B-PATCH',
  }));
  const renderer = await renderSurface();
  await openProject(renderer);
  await navigateToOther(renderer);
  await act(async () => {
    held.resolve(dirtyStatus);
    await settle();
  });
  expect(inputByLabel(renderer.root, 'Origin HTTPS URL').props.value).toBe(
    otherProject.origin_url,
  );
  expect(
    renderer.root.findAllByProps({ children: 'other-branch' }).length,
  ).toBeGreaterThan(0);
  expect(
    renderer.root.findAllByProps({
      accessibilityLabel: 'Clear remote credential',
    }),
  ).toHaveLength(0);
  await act(async () =>
    actionByLabel(renderer.root, 'Changes').props.onPress(),
  );
  expect(
    renderer.root.findAllByProps({ children: 'OLD-A-PATCH' }),
  ).toHaveLength(0);
  expect(
    renderer.root.findAllByProps({ children: 'CURRENT-B-PATCH' }).length,
  ).toBeGreaterThan(0);
});

test.each(['success', 'failure'] as const)(
  'late A %s cannot unlock or report an error in still-loading B',
  async outcome => {
    const a = deferred<typeof dirtyStatus>();
    const b = deferred<typeof dirtyStatus>();
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [project, otherProject],
    });
    mockLocalProjects.status.mockImplementation((id: string) =>
      id === project.id ? a.promise : b.promise,
    );
    const renderer = await renderSurface();
    await openProject(renderer);
    await navigateToOther(renderer);
    await act(async () => {
      if (outcome === 'success') a.resolve(dirtyStatus);
      else a.reject(new Error('STALE-A-ERROR'));
      await settle();
    });
    expect(
      actionByLabel(renderer.root, 'Refresh project status').props.disabled,
    ).toBe(true);
    expect(JSON.stringify(renderer.toJSON())).not.toContain('STALE-A-ERROR');
    await act(async () => {
      b.resolve({ ...dirtyStatus, project_id: otherProject.id });
      await settle();
    });
    expect(
      actionByLabel(renderer.root, 'Refresh project status').props.disabled,
    ).toBe(false);
  },
);

test('close and reopen invalidates the old detail even for the same project', async () => {
  const held = deferred<typeof dirtyStatus>();
  mockLocalProjects.status
    .mockImplementationOnce(() => held.promise)
    .mockResolvedValue({ ...dirtyStatus, branch: 'reopened-branch' });
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () =>
    renderer.root.findByType(SlidingSurface).props.onClose(),
  );
  await setVisible(renderer, false);
  await setVisible(renderer, true);
  await act(async () => {
    held.resolve({ ...dirtyStatus, branch: 'STALE-CLOSED-BRANCH' });
    await settle();
  });
  expect(JSON.stringify(renderer.toJSON())).not.toContain(
    'STALE-CLOSED-BRANCH',
  );
  expect(
    renderer.root.findAllByProps({ children: 'reopened-branch' }).length,
  ).toBeGreaterThan(0);
});

test('a completed stage operation on A cannot refresh or overwrite B', async () => {
  const held = deferred<typeof dirtyStatus>();
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [project, otherProject],
  });
  mockLocalProjects.stageAll.mockImplementationOnce(() => held.promise);
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () =>
    actionByLabel(renderer.root, 'Changes').props.onPress(),
  );
  await act(async () => {
    actionByLabel(renderer.root, 'Stage all changes').props.onPress();
    await settle();
  });
  await navigateToOther(renderer);
  const before = mockLocalProjects.diff.mock.calls.length;
  await act(async () => {
    held.resolve(dirtyStatus);
    await settle();
  });
  expect(mockLocalProjects.diff.mock.calls).toHaveLength(before);
  expect(inputByLabel(renderer.root, 'Origin HTTPS URL').props.value).toBe(
    otherProject.origin_url,
  );
  expect(JSON.stringify(renderer.toJSON())).not.toContain(
    'All current changes were staged.',
  );
});

test('a push confirmation from an old view cannot dispatch after navigating to another project', async () => {
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [project, otherProject],
  });
  const alert = jest.spyOn(Alert, 'alert');
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () => {
    actionByLabel(renderer.root, 'Push').props.onPress();
  });
  const confirm = alert.mock.calls.at(-1)?.[2]?.[1]?.onPress;
  expect(confirm).toBeDefined();
  await navigateToOther(renderer);
  await act(async () => {
    confirm?.();
    await settle();
  });
  expect(mockLocalProjects.push).not.toHaveBeenCalled();
  alert.mockRestore();
});

test('a late commit cannot clear the current project draft or start an old-project refresh', async () => {
  const held = deferred<unknown>();
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [project, otherProject],
  });
  mockLocalProjects.commit.mockImplementationOnce(() => held.promise);
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () => {
    inputByLabel(renderer.root, 'Commit message').props.onChangeText(
      'commit A',
    );
    inputByLabel(renderer.root, 'Author name').props.onChangeText(
      'Test author',
    );
    inputByLabel(renderer.root, 'Author email').props.onChangeText(
      'test@example.invalid',
    );
  });
  await act(async () => {
    actionByLabel(renderer.root, 'Commit staged changes').props.onPress();
    await settle();
  });
  await navigateToOther(renderer);
  await act(async () => {
    inputByLabel(renderer.root, 'Commit message').props.onChangeText(
      'keep B draft',
    );
  });
  const before = mockLocalProjects.status.mock.calls.length;
  await act(async () => {
    held.resolve({ project_id: project.id });
    await settle();
  });
  expect(mockLocalProjects.status.mock.calls).toHaveLength(before);
  expect(inputByLabel(renderer.root, 'Commit message').props.value).toBe(
    'keep B draft',
  );
});

test.each(['credential', 'remote'] as const)(
  'late %s mutation cannot change B or its credential state',
  async kind => {
    const held = deferred<unknown>();
    mockLocalProjects.list.mockResolvedValue({
      schema_version: 1,
      projects: [project, otherProject],
    });
    if (kind === 'credential')
      mockLocalProjects.presentCredentialPrompt.mockImplementationOnce(
        () => held.promise,
      );
    else mockLocalProjects.setRemote.mockImplementationOnce(() => held.promise);
    const renderer = await renderSurface();
    await openProject(renderer);
    await act(async () => {
      actionByLabel(
        renderer.root,
        kind === 'credential' ? 'Configure remote credential' : 'Save origin',
      ).props.onPress();
      await settle();
    });
    await navigateToOther(renderer);
    const before = mockLocalProjects.credentialStatus.mock.calls.length;
    await act(async () => {
      held.resolve({
        project_id: project.id,
        configured: true,
        host: 'old.example',
        url: 'https://old.example/repo.git',
      });
      await settle();
    });
    expect(mockLocalProjects.credentialStatus.mock.calls).toHaveLength(before);
    expect(inputByLabel(renderer.root, 'Origin HTTPS URL').props.value).toBe(
      otherProject.origin_url,
    );
    expect(
      renderer.root.findAllByProps({
        accessibilityLabel: 'Clear remote credential',
      }),
    ).toHaveLength(0);
  },
);

test('reopening the same project refreshes detail without discarding an unsaved remote draft', async () => {
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () => {
    inputByLabel(renderer.root, 'Origin HTTPS URL').props.onChangeText(
      'https://example.invalid/unsaved.git',
    );
  });
  await setVisible(renderer, false);
  await setVisible(renderer, true);
  expect(inputByLabel(renderer.root, 'Origin HTTPS URL').props.value).toBe(
    'https://example.invalid/unsaved.git',
  );
});

test('returning to a still-mutating project keeps its lock and refreshes after native completion', async () => {
  const held = deferred<typeof dirtyStatus>();
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [project, otherProject],
  });
  mockLocalProjects.stageAll.mockImplementationOnce(() => held.promise);
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () => {
    actionByLabel(renderer.root, 'Changes').props.onPress();
  });
  await act(async () => {
    actionByLabel(renderer.root, 'Stage all changes').props.onPress();
    await settle();
  });
  await navigateToOther(renderer);
  await act(async () => {
    actionByLabel(renderer.root, 'Back to projects').props.onPress();
    await settle();
  });
  await openProject(renderer);
  expect(
    actionByLabel(renderer.root, 'Refresh project status').props.disabled,
  ).toBe(true);
  mockLocalProjects.status.mockResolvedValue({
    ...dirtyStatus,
    branch: 'settled-A',
  });
  await act(async () => {
    held.resolve(dirtyStatus);
    await settle();
  });
  expect(
    actionByLabel(renderer.root, 'Refresh project status').props.disabled,
  ).toBe(false);
  expect(
    renderer.root.findAllByProps({ children: 'settled-A' }).length,
  ).toBeGreaterThan(0);
});

test('creates an isolated local project and opens its real detail response', async () => {
  const renderer = await renderSurface();

  await act(async () =>
    actionByLabel(renderer.root, 'New project').props.onPress(),
  );
  await act(async () =>
    inputByLabel(renderer.root, 'Project name').props.onChangeText('created'),
  );
  await act(async () => {
    actionByLabel(renderer.root, 'Create project').props.onPress();
    await settle();
  });

  expect(mockLocalProjects.create).toHaveBeenCalledWith('created');
  expect(mockLocalProjects.status).toHaveBeenCalledWith('project-created');
  expect(mockLocalProjects.credentialStatus).not.toHaveBeenCalled();
  expect(renderer.root.findByProps({ children: 'created' })).toBeDefined();
});

test('clones only through the native API and surfaces a native failure', async () => {
  const gitHttpsProxyUrl = 'http://127.0.0.1:7890/';
  mockLocalProjects.startClone.mockRejectedValueOnce(new Error('TLS failed'));
  const renderer = await renderSurface({ gitHttpsProxyUrl });

  await act(async () =>
    actionByLabel(renderer.root, 'Clone repository').props.onPress(),
  );
  await act(async () => {
    inputByLabel(renderer.root, 'Project name').props.onChangeText('copy');
    inputByLabel(renderer.root, 'Remote URL').props.onChangeText(
      'https://github.com/example/demo.git',
    );
  });
  await act(async () => {
    actionByLabel(renderer.root, 'Clone').props.onPress();
    await settle();
  });

  expect(mockLocalProjects.startClone).toHaveBeenCalledWith(
    'https://github.com/example/demo.git',
    'copy',
    { httpsProxyUrl: gitHttpsProxyUrl },
  );
  expect(
    renderer.root.findByProps({
      children: 'Git operation failed: TLS failed',
    }),
  ).toBeDefined();
  expect(
    renderer.root.findAllByProps({ children: 'Repository cloned locally.' }),
  ).toHaveLength(0);
});

test('passes an explicit null proxy when no HTTPS proxy is configured', async () => {
  const renderer = await renderSurface();

  await act(async () =>
    actionByLabel(renderer.root, 'Clone repository').props.onPress(),
  );
  await act(async () =>
    inputByLabel(renderer.root, 'Remote URL').props.onChangeText(
      'https://github.com/example/demo.git',
    ),
  );
  await act(async () => {
    actionByLabel(renderer.root, 'Clone').props.onPress();
    await settle();
  });

  expect(mockLocalProjects.startClone).toHaveBeenCalledWith(
    'https://github.com/example/demo.git',
    undefined,
    { httpsProxyUrl: null },
  );
});

test('opens only the selected project worktree in Files', async () => {
  const onOpenFiles = jest.fn();
  const renderer = await renderSurface({ onOpenFiles });
  await openProject(renderer);

  await act(async () =>
    actionByLabel(renderer.root, 'Open project files').props.onPress(),
  );

  expect(onOpenFiles).toHaveBeenCalledWith(project, expect.any(Function));
  expect(
    renderer.root.findByProps({ children: project.workspace_path }),
  ).toBeDefined();
});

test('binds and unbinds the selected project through explicit chat actions', async () => {
  const onChatInProject = jest.fn();
  const first = await renderSurface({ onChatInProject });
  await openProject(first);
  await act(async () =>
    actionByLabel(first.root, 'Chat in this project').props.onPress(),
  );
  expect(onChatInProject).toHaveBeenCalledWith(project);

  const onUnbindFromChat = jest.fn();
  const second = await renderSurface({
    boundProjectId: project.id,
    onUnbindFromChat,
  });
  await openProject(second);
  await act(async () =>
    actionByLabel(second.root, 'Remove from this chat').props.onPress(),
  );
  expect(onUnbindFromChat).toHaveBeenCalledTimes(1);
});

test('shows a real diff, stages all, and commits with explicit author fields', async () => {
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () =>
    actionByLabel(renderer.root, 'Changes').props.onPress(),
  );

  expect(renderer.root.findByProps({ children: diff.patch })).toBeDefined();
  expect(
    renderer.root.findByProps({ children: 'Staged: Added' }),
  ).toBeDefined();
  expect(
    renderer.root.findAllByProps({ children: 'Working tree: Added' }),
  ).toHaveLength(0);
  await act(async () =>
    actionByLabel(renderer.root, 'Unstaged').props.onPress(),
  );
  expect(
    renderer.root.findByProps({ children: 'Working tree: Added' }),
  ).toBeDefined();
  await act(async () => {
    actionByLabel(renderer.root, 'Stage all changes').props.onPress();
    await settle();
  });
  expect(mockLocalProjects.stageAll).toHaveBeenCalledWith(project.id);
  expect(mockLocalProjects.diff).toHaveBeenLastCalledWith(project.id, {
    staged: true,
  });

  await act(async () => {
    inputByLabel(renderer.root, 'Commit message').props.onChangeText(
      'Update README',
    );
    inputByLabel(renderer.root, 'Author name').props.onChangeText('Fini');
    inputByLabel(renderer.root, 'Author email').props.onChangeText(
      'fini@example.com',
    );
  });
  await act(async () => {
    actionByLabel(renderer.root, 'Commit staged changes').props.onPress();
    await settle();
  });

  expect(mockLocalProjects.commit).toHaveBeenCalledWith(project.id, {
    message: 'Update README',
    authorName: 'Fini',
    authorEmail: 'fini@example.com',
  });
});

test('uses a wide changed-file rail beside the diff and keeps the narrow stack intact', async () => {
  const renderer = await renderSurface();
  await openProject(renderer);
  const layout = renderer.root
    .findAll(instance => typeof instance.props.onLayout === 'function')[0];
  expect(layout).toBeDefined();
  await act(async () => {
    layout?.props.onLayout({ nativeEvent: { layout: { width: 1024 } } });
    await settle();
  });
  expect(renderer.root.findByProps({ testID: 'projects-wide-change-list' })).toBeDefined();
  expect(renderer.root.findAllByProps({ children: 'README.md' }).length).toBeGreaterThan(0);
  await act(async () => {
    layout?.props.onLayout({ nativeEvent: { layout: { width: 600 } } });
    await settle();
  });
  expect(renderer.root.findAllByProps({ testID: 'projects-wide-change-list' })).toHaveLength(0);
  expect(actionByLabel(renderer.root, 'Changes')).toBeDefined();
});

test('keeps long diff lines horizontally scrollable', async () => {
  const longLine = 'x'.repeat(2048);
  mockLocalProjects.diff.mockResolvedValue({
    ...diff,
    patch: `diff --git a/long.txt b/long.txt\n+${longLine}\n`,
  });
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () => actionByLabel(renderer.root, 'Changes').props.onPress());
  expect(renderer.root.findAllByProps({ horizontal: true }).length).toBeGreaterThan(0);
  expect(renderer.root.findAllByProps({ children: `+${longLine}` }).length).toBeGreaterThan(0);
});

test('selecting a changed file shows its own diff and survives rotation to narrow layout', async () => {
  const renderer = await renderSurface();
  await openProject(renderer);
  const layout = renderer.root
    .findAll(instance => typeof instance.props.onLayout === 'function')[0];
  await act(async () => {
    layout?.props.onLayout({ nativeEvent: { layout: { width: 1024 } } });
    await settle();
  });
  await act(async () => actionByLabel(renderer.root, 'README.md').props.onPress());
  expect(renderer.root.findAllByProps({ children: 'diff --git a/README.md b/README.md\n+hello\n' }).length).toBeGreaterThan(0);
  await act(async () => {
    layout?.props.onLayout({ nativeEvent: { layout: { width: 600 } } });
    await settle();
  });
  expect(renderer.root.findAllByProps({ testID: 'projects-wide-change-list' })).toHaveLength(0);
  expect(renderer.root.findAllByProps({ children: 'diff --git a/README.md b/README.md\n+hello\n' }).length).toBeGreaterThan(0);
});

test('reports when a selected file is absent from the current diff page', async () => {
  mockLocalProjects.diff.mockResolvedValue({
    ...diff,
    files: [{ path: 'image.bin', status: 'modified', additions: 0, deletions: 0 }],
    patch: 'diff --git a/image.bin b/image.bin\n',
  });
  mockLocalProjects.diffPage.mockResolvedValue({
    ...diff,
    patch: 'PAGE-WITHOUT-SELECTED-FILE',
    files: [],
    truncated: true,
    page_offset: 0,
    next_offset: null,
    snapshot_id: 'b'.repeat(64),
    omitted_paths: ['image.bin'],
  });
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () => actionByLabel(renderer.root, 'Changes').props.onPress());
  await act(async () => actionByLabel(renderer.root, 'image.bin').props.onPress());
  await act(async () => {
    actionByLabel(renderer.root, 'Review diff in pages').props.onPress();
    await settle();
  });
  expect(renderer.root.findAllByProps({ children: 'This file’s diff is not on the current page. Load another page to continue.' }).length).toBeGreaterThan(0);
  expect(renderer.root.findAllByProps({ children: 'PAGE-WITHOUT-SELECTED-FILE' })).toHaveLength(0);
});

test('locates quoted unicode and spaced paths in rename style diff headers', async () => {
  const path = 'docs/中 space.md';
  const quotedPatch = 'diff --git "a/docs/\\344\\270\\255 space.md" "b/docs/\\344\\270\\255 space.md"\n--- a/docs/\\344\\270\\255 space.md\n+++ b/docs/\\344\\270\\255 space.md\n+changed\n';
  mockLocalProjects.diff.mockResolvedValue({
    ...diff,
    patch: quotedPatch,
    files: [{ path, status: 'renamed', additions: 1, deletions: 0 }],
  });
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () => actionByLabel(renderer.root, 'Changes').props.onPress());
  await act(async () => actionByLabel(renderer.root, path).props.onPress());
  expect(renderer.root.findAllByProps({ children: quotedPatch }).length).toBeGreaterThan(0);
});

test('matches exact changed paths instead of directory or filename prefixes', async () => {
  const exact = 'diff --git a/foo.ts b/foo.ts\n+EXACT\n';
  const prefix = 'diff --git a/foobar.ts b/foobar.ts\n+PREFIX\n';
  mockLocalProjects.diff.mockResolvedValue({
    ...diff,
    patch: `${exact}${prefix}`,
    files: [
      { path: 'foo.ts', status: 'modified', additions: 1, deletions: 0 },
      { path: 'foobar.ts', status: 'modified', additions: 1, deletions: 0 },
    ],
  });
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () => actionByLabel(renderer.root, 'Changes').props.onPress());
  await act(async () => actionByLabel(renderer.root, 'foo.ts').props.onPress());
  expect(JSON.stringify(renderer.toJSON())).toContain('EXACT');
  expect(JSON.stringify(renderer.toJSON())).not.toContain('PREFIX');
});

test('localizes readable index and working-tree status labels', () => {
  expect(
    translate('zh-CN', 'projects.change.staged', {
      status: translate('zh-CN', 'projects.fileStatus.added'),
    }),
  ).toBe('已暂存：新增');
  expect(
    translate('zh-CN', 'projects.change.worktree', {
      status: translate('zh-CN', 'projects.fileStatus.modified'),
    }),
  ).toBe('工作区：已修改');
});

test('stores credentials natively and never pushes before confirmation', async () => {
  const gitHttpsProxyUrl = 'http://127.0.0.1:7890/';
  const alert = jest.spyOn(Alert, 'alert').mockImplementation(() => undefined);
  const renderer = await renderSurface({ gitHttpsProxyUrl });
  await openProject(renderer);

  await act(async () => {
    actionByLabel(renderer.root, 'Configure remote credential').props.onPress();
    await settle();
  });
  expect(mockLocalProjects.presentCredentialPrompt).toHaveBeenCalledWith(
    project.id,
    'en',
  );
  expect(
    renderer.root.findByProps({ children: 'Credential stored in Keychain' }),
  ).toBeDefined();
  await act(async () => {
    actionByLabel(renderer.root, 'Clear remote credential').props.onPress();
    await settle();
  });
  expect(mockLocalProjects.clearCredential).toHaveBeenCalledWith(project.id);

  await act(async () => actionByLabel(renderer.root, 'Push').props.onPress());
  expect(mockLocalProjects.push).not.toHaveBeenCalled();
  expect(alert).toHaveBeenCalledWith(
    'Push this branch?',
    expect.stringContaining('main'),
    expect.any(Array),
  );

  const buttons = alert.mock.calls[0]?.[2];
  const confirm = Array.isArray(buttons)
    ? buttons.find(button => button.text === 'Push now')
    : undefined;
  await act(async () => {
    confirm?.onPress?.();
    await settle();
  });
  expect(mockLocalProjects.push).toHaveBeenCalledWith(project.id, {
    httpsProxyUrl: gitHttpsProxyUrl,
  });
});

test('shows the non-fast-forward message and pushes a named new branch', async () => {
  const alert = jest.spyOn(Alert, 'alert').mockImplementation(() => undefined);
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () => {
    inputByLabel(
      renderer.root,
      'Push as new branch (optional)',
    ).props.onChangeText('feature/g2');
    await settle();
  });
  mockLocalProjects.push.mockRejectedValueOnce(
    Object.assign(new Error('non-fast-forward'), { code: 'non-fast-forward' }),
  );
  await act(async () => actionByLabel(renderer.root, 'Push').props.onPress());
  expect(alert).toHaveBeenCalledWith(
    'Push this branch?',
    expect.stringContaining('new branch feature/g2 on github.com'),
    expect.any(Array),
  );
  const buttons = alert.mock.calls[0]?.[2];
  const confirm = Array.isArray(buttons)
    ? buttons.find(button => button.text === 'Push now')
    : undefined;
  await act(async () => {
    confirm?.onPress?.();
    await settle();
  });
  expect(mockLocalProjects.push).toHaveBeenCalledWith(project.id, {
    httpsProxyUrl: null,
    branch: 'feature/g2',
  });
  expect(
    renderer.root.findAllByProps({
      children: translate('en-US', 'projects.pushNonFastForward'),
    }).length,
  ).toBeGreaterThan(0);
  expect(mockLocalProjects.cancelPush).not.toHaveBeenCalled();
});

test('renders the native push receipt after a successful push', async () => {
  const alert = jest.spyOn(Alert, 'alert').mockImplementation(() => undefined);
  const renderer = await renderSurface();
  await openProject(renderer);
  expect(
    renderer.root.findAllByProps({ children: 'No push receipt recorded yet.' })
      .length,
  ).toBeGreaterThan(0);
  const receipt = {
    schema_version: 1,
    remote: 'origin',
    host: 'github.com',
    branch: 'main',
    local_oid: '0123456789abcdef0123456789abcdef01234567',
    remote_oid: '0123456789abcdef0123456789abcdef01234567',
    pushed_at: '2026-09-03T12:00:00.000Z',
  };
  mockLocalProjects.push.mockResolvedValueOnce({
    schema_version: 1,
    project_id: project.id,
    remote: 'origin',
    branch: 'main',
    oid: receipt.local_oid,
    pushed_at: receipt.pushed_at,
    receipt,
  });
  mockLocalProjects.pushReceipts.mockResolvedValue({
    schema_version: 1,
    project_id: project.id,
    receipts: [receipt],
  });
  await act(async () => actionByLabel(renderer.root, 'Push').props.onPress());
  const buttons = alert.mock.calls[0]?.[2];
  const confirm = Array.isArray(buttons)
    ? buttons.find(button => button.text === 'Push now')
    : undefined;
  await act(async () => {
    confirm?.onPress?.();
    await settle();
  });
  const rendered = renderer.root.findAll(
    node =>
      typeof node.props.children === 'string' &&
      node.props.children.startsWith('main → github.com · local 0123456789ab'),
  );
  expect(rendered.length).toBeGreaterThan(0);
  expect(
    renderer.root.findAllByProps({ children: 'Branch pushed successfully.' })
      .length,
  ).toBeGreaterThan(0);
});

async function startTestClone(renderer: Renderer) {
  await act(async () =>
    actionByLabel(renderer.root, 'Clone repository').props.onPress(),
  );
  await act(async () =>
    inputByLabel(renderer.root, 'Remote URL').props.onChangeText(
      'https://example.com/copy.git',
    ),
  );
  await act(async () => {
    actionByLabel(renderer.root, 'Clone').props.onPress();
    await settle();
  });
}

async function pollClone() {
  await act(async () => {
    jest.advanceTimersByTime(400);
    await settle();
  });
}

test('shows native transfer progress and waits for real cancellation before retry', async () => {
  jest.useFakeTimers();
  mockLocalProjects.startClone.mockResolvedValue(cloneSnapshot('receiving'));
  const renderer = await renderSurface();
  await startTestClone(renderer);
  expect(
    renderer.root.findAllByProps({ children: '2/8 objects · 4 KiB received' })
      .length,
  ).toBeGreaterThan(0);
  await act(async () => {
    renderer.root
      .findByProps({ testID: 'projects-clone-operation-cancel' })
      .props.onPress();
    await settle();
  });
  expect(mockLocalProjects.cancelClone).toHaveBeenCalledWith('clone-1');
  expect(actionByLabel(renderer.root, 'Clone').props.disabled).toBe(true);
  expect(
    renderer.root.findAllByProps({
      children:
        'Cancelling… Waiting for the current network call to stop (up to 30 seconds).',
    }).length,
  ).toBeGreaterThan(0);
  mockLocalProjects.cloneStatus.mockResolvedValue(
    cloneSnapshot('cancelled', true),
  );
  await pollClone();
  expect(actionByLabel(renderer.root, 'Clone').props.disabled).toBe(false);
  expect(
    renderer.root.findAllByProps({
      children: 'Clone cancelled. No project was published.',
    }).length,
  ).toBeGreaterThan(0);
  expect(mockLocalProjects.status).not.toHaveBeenCalled();
});

test('reopens the same native operation without restarting or navigating on late success', async () => {
  jest.useFakeTimers();
  mockLocalProjects.startClone.mockResolvedValue(cloneSnapshot('connecting'));
  const renderer = await renderSurface();
  await startTestClone(renderer);
  await setVisible(renderer, false);
  mockLocalProjects.cloneStatus.mockResolvedValue(cloneSnapshot('receiving'));
  await setVisible(renderer, true);
  expect(
    renderer.root.findAllByProps({ children: 'Receiving objects…' }).length,
  ).toBeGreaterThan(0);
  mockLocalProjects.cloneStatus.mockResolvedValue(cloneSnapshot('succeeded'));
  await pollClone();
  expect(mockLocalProjects.startClone).toHaveBeenCalledTimes(1);
  expect(mockLocalProjects.status).not.toHaveBeenCalled();
  expect(actionByLabel(renderer.root, 'Open project demo')).toBeDefined();
});

test('cancel arriving after publication reports success without stealing navigation', async () => {
  jest.useFakeTimers();
  mockLocalProjects.startClone.mockResolvedValue(cloneSnapshot('validating'));
  mockLocalProjects.cancelClone.mockResolvedValue(cloneSnapshot('succeeded'));
  const renderer = await renderSurface();
  await startTestClone(renderer);
  await act(async () => {
    renderer.root
      .findByProps({ testID: 'projects-clone-operation-cancel' })
      .props.onPress();
    await settle();
  });
  expect(mockLocalProjects.status).not.toHaveBeenCalled();
  expect(
    renderer.root.findAllByProps({ children: 'Repository cloned locally.' })
      .length,
  ).toBeGreaterThan(0);
  expect(
    renderer.root.findAllByProps({
      children: 'Clone cancelled. No project was published.',
    }),
  ).toHaveLength(0);
});

test('a query from before start cannot overwrite the new clone operation', async () => {
  jest.useFakeTimers();
  const held = deferred<ReturnType<typeof cloneSnapshot>>();
  mockLocalProjects.cloneStatus.mockReturnValueOnce(held.promise);
  mockLocalProjects.startClone.mockResolvedValue(cloneSnapshot('receiving'));
  const renderer = await renderSurface();
  await startTestClone(renderer);
  await act(async () => {
    held.resolve({ ...cloneSnapshot('failed'), operation_id: 'old' });
    await settle();
  });
  expect(
    renderer.root.findAllByProps({ children: 'Receiving objects…' }).length,
  ).toBeGreaterThan(0);
  expect(actionByLabel(renderer.root, 'Clone').props.disabled).toBe(true);
});

test('a transport failure has a retryable terminal state', async () => {
  jest.useFakeTimers();
  mockLocalProjects.startClone.mockResolvedValue(cloneSnapshot('connecting'));
  const renderer = await renderSurface();
  await startTestClone(renderer);
  mockLocalProjects.cloneStatus.mockResolvedValue({
    ...cloneSnapshot('failed'),
    error_code: 'timeout',
  });
  await pollClone();
  expect(actionByLabel(renderer.root, 'Clone').props.disabled).toBe(false);
  expect(
    renderer.root.findAllByProps({
      children: 'The server took too long. Check the connection and try again.',
    }).length,
  ).toBeGreaterThan(0);
});

test('cancel before the native start reply is forwarded once identity arrives', async () => {
  jest.useFakeTimers();
  const held = deferred<ReturnType<typeof cloneSnapshot>>();
  mockLocalProjects.startClone.mockReturnValue(held.promise);
  const renderer = await renderSurface();
  await startTestClone(renderer);
  await act(async () =>
    renderer.root
      .findByProps({ testID: 'projects-clone-cancel' })
      .props.onPress(),
  );
  expect(mockLocalProjects.cancelClone).not.toHaveBeenCalled();
  await act(async () => {
    held.resolve(cloneSnapshot('queued'));
    await settle();
  });
  expect(mockLocalProjects.cancelClone).toHaveBeenCalledWith('clone-1');
  expect(mockLocalProjects.status).not.toHaveBeenCalled();
});

test('reopening and refreshing preserves a real staged review separate from worktree changes', async () => {
  mockLocalProjects.diff.mockImplementation(
    async (_id: string, options: { staged: boolean }) => ({
      ...diff,
      staged: options.staged,
      patch: options.staged ? '+INDEX-ONLY' : '+WORKTREE-ONLY',
    }),
  );
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () =>
    actionByLabel(renderer.root, 'Review staged changes').props.onPress(),
  );
  expect(renderer.root.findByProps({ children: '+INDEX-ONLY' })).toBeDefined();
  expect(
    renderer.root.findAllByProps({ children: '+WORKTREE-ONLY' }),
  ).toHaveLength(0);
  await setVisible(renderer, false);
  await setVisible(renderer, true);
  expect(renderer.root.findByProps({ children: '+INDEX-ONLY' })).toBeDefined();
  await act(async () =>
    actionByLabel(renderer.root, 'Unstaged').props.onPress(),
  );
  expect(
    renderer.root.findByProps({ children: '+WORKTREE-ONLY' }),
  ).toBeDefined();
  await setVisible(renderer, false);
  await setVisible(renderer, true);
  expect(
    renderer.root.findByProps({ children: '+WORKTREE-ONLY' }),
  ).toBeDefined();
});

test('truncated diff offers snapshot-bound pages and mode switches discard old page replies', async () => {
  mockLocalProjects.diff.mockResolvedValue({ ...diff, truncated: true });
  const page = {
    ...diff,
    staged: true,
    patch: 'FIRST-PAGE',
    truncated: true,
    page_offset: 0,
    next_offset: 10,
    snapshot_id: 'a'.repeat(64),
    omitted_paths: [],
  };
  mockLocalProjects.diffPage.mockResolvedValue(page);
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () =>
    actionByLabel(renderer.root, 'Changes').props.onPress(),
  );
  expect(
    renderer.root.findAllByProps({
      children:
        'Partial preview: this diff exceeds the preview limit. Review it in pages to continue.',
    }).length,
  ).toBeGreaterThan(0);
  await act(async () => {
    actionByLabel(renderer.root, 'Review diff in pages').props.onPress();
    await settle();
  });
  expect(mockLocalProjects.diffPage).toHaveBeenLastCalledWith(
    project.id,
    true,
    0,
    null,
  );
  const held = deferred<typeof page>();
  mockLocalProjects.diffPage.mockReturnValueOnce(held.promise);
  await act(async () => {
    actionByLabel(renderer.root, 'Next page').props.onPress();
    await settle();
  });
  expect(mockLocalProjects.diffPage).toHaveBeenLastCalledWith(
    project.id,
    true,
    10,
    'a'.repeat(64),
  );
  await act(async () =>
    actionByLabel(renderer.root, 'Unstaged').props.onPress(),
  );
  await act(async () => {
    held.resolve({ ...page, patch: 'STALE-INDEX-PAGE' });
    await settle();
  });
  expect(
    renderer.root.findAllByProps({ children: 'STALE-INDEX-PAGE' }),
  ).toHaveLength(0);
  expect(renderer.root.findAllByProps({ children: 'FIRST-PAGE' })).toHaveLength(
    0,
  );
});

test('binary omissions are visible and a changed diff restarts paged review', async () => {
  mockLocalProjects.diffPage.mockResolvedValue({
    ...diff,
    staged: true,
    patch: 'PAGE',
    truncated: true,
    page_offset: 0,
    next_offset: 4,
    snapshot_id: 'a'.repeat(64),
    omitted_paths: ['image.bin'],
  });
  const renderer = await renderSurface();
  await openProject(renderer);
  await act(async () =>
    actionByLabel(renderer.root, 'Changes').props.onPress(),
  );
  await act(async () => {
    actionByLabel(renderer.root, 'Review diff in pages').props.onPress();
    await settle();
  });
  expect(
    renderer.root.findAllByProps({
      children:
        'Text is unavailable for binary, non-UTF-8, or oversized files: image.bin. Their contents are not shown.',
    }).length,
  ).toBeGreaterThan(0);
  mockLocalProjects.diffPage.mockRejectedValueOnce(
    new Error('Diff changed; restart the review'),
  );
  await act(async () => {
    actionByLabel(renderer.root, 'Next page').props.onPress();
    await settle();
  });
  expect(renderer.root.findAllByProps({ children: 'PAGE' })).toHaveLength(0);
  expect(actionByLabel(renderer.root, 'Review diff in pages')).toBeDefined();
});


test('invalidates a pending Files opener when the selected project changes', async () => {
  const held = deferred<void>();
  const onOpenFiles = jest.fn(
    (_project: unknown, _isCurrent?: () => boolean) => held.promise,
  );
  mockLocalProjects.list.mockResolvedValue({
    schema_version: 1,
    projects: [project, otherProject],
  });
  const renderer = await renderSurface({ onOpenFiles });
  await openProject(renderer);
  await act(async () => {
    actionByLabel(renderer.root, 'Open project files').props.onPress();
    await settle();
  });
  const isCurrent = onOpenFiles.mock.calls[0]?.[1] as unknown as () => boolean;
  expect(isCurrent()).toBe(true);
  await navigateToOther(renderer);
  expect(isCurrent()).toBe(false);
  await act(async () => {
    held.resolve();
    await settle();
  });
  expect(
    renderer.root.findByProps({ children: otherProject.workspace_path }),
  ).toBeDefined();
});

test('shows a Files root error on the project surface and permits retry', async () => {
  const onOpenFiles = jest
    .fn()
    .mockRejectedValue(new Error('E_WORKSPACE_UNAVAILABLE'));
  const renderer = await renderSurface({ onOpenFiles });
  await openProject(renderer);
  await act(async () => {
    actionByLabel(renderer.root, 'Open project files').props.onPress();
    await settle();
  });
  expect(
    renderer.root.findByProps({
      children: 'Git operation failed: E_WORKSPACE_UNAVAILABLE',
    }),
  ).toBeDefined();
  expect(
    actionByLabel(renderer.root, 'Open project files').props.disabled,
  ).toBe(false);
});

test('lists a workspace-attached project when the legacy listing is refused, and drives it through V2', async () => {
  // Android: the v1 module refuses everything, the V2 root API is complete.
  mockLocalProjects.isV2Available.mockReturnValue(true);
  mockLocalProjects.list.mockRejectedValue(Object.assign(new Error('E_PROJECT_NATIVE'), { code: 'E_PROJECT_NATIVE' }));
  mockWorkspaceProjects.mockResolvedValue([workspaceProject]);
  const v2Status = { ...dirtyStatus, schema_version: 2, root: workspaceRoot, project_id: workspaceRoot.project_id };
  mockLocalProjects.statusV2.mockResolvedValue(v2Status);
  mockLocalProjects.diffV2.mockImplementation(async (request: { staged: boolean }) => ({
    ...diff, schema_version: 2, root: workspaceRoot, project_id: workspaceRoot.project_id, staged: request.staged,
  }));
  mockLocalProjects.stageAllV2.mockResolvedValue(v2Status);
  mockLocalProjects.commitV2.mockResolvedValue({
    schema_version: 2, root: workspaceRoot, project_id: workspaceRoot.project_id,
    oid: 'abcdef0123456789', summary: 'initial', committed_at: '2026-09-20T00:00:00.000Z',
  });
  const onChatInProject = jest.fn();
  const renderer = await renderSurface({ onChatInProject });
  // No banner for the refused legacy listing; the workspace project is a row.
  expect(renderer.root.findAllByProps({ children: 'Workspace · Smoke' }).length).toBeGreaterThan(0);
  const row = renderer.root.findByProps({ testID: 'projects-row-Smoke' });
  await act(async () => { row.props.onPress(); await settle(); });
  expect(mockLocalProjects.statusV2).toHaveBeenCalledWith({ schema_version: 1, root: workspaceRoot });
  expect(mockLocalProjects.diffV2).toHaveBeenCalledWith(expect.objectContaining({ root: workspaceRoot, staged: false }));
  expect(mockLocalProjects.diffV2).toHaveBeenCalledWith(expect.objectContaining({ root: workspaceRoot, staged: true }));
  expect(mockLocalProjects.status).not.toHaveBeenCalled();
  // The origin is read by root; without one there is nothing to push to.
  expect(mockLocalProjects.remoteV2).toHaveBeenCalledWith({ schema_version: 1, root: workspaceRoot });
  expect(mockLocalProjects.credentialStatusV2).not.toHaveBeenCalled();
  expect(renderer.root.findAllByProps({ accessibilityLabel: 'Save origin' }).length).toBeGreaterThan(0);
  expect(renderer.root.findAllByProps({ accessibilityLabel: 'Push' }).length).toBe(0);

  await act(async () => actionByLabel(renderer.root, 'Changes').props.onPress());
  await act(async () => { actionByLabel(renderer.root, 'Stage all changes').props.onPress(); await settle(); });
  expect(mockLocalProjects.stageAllV2).toHaveBeenCalledWith({ schema_version: 1, root: workspaceRoot });
  expect(mockLocalProjects.stageAll).not.toHaveBeenCalled();

  await act(async () => inputByLabel(renderer.root, 'Commit message').props.onChangeText('initial'));
  await act(async () => inputByLabel(renderer.root, 'Author name').props.onChangeText('Rish'));
  await act(async () => inputByLabel(renderer.root, 'Author email').props.onChangeText('rish@example.invalid'));
  await act(async () => { actionByLabel(renderer.root, 'Commit staged changes').props.onPress(); await settle(); });
  expect(mockLocalProjects.commitV2).toHaveBeenCalledWith({
    schema_version: 1,
    root: workspaceRoot,
    operation_id: 'op-1',
    message: 'initial',
    author_name: 'Rish',
    author_email: 'rish@example.invalid',
    expected_head_oid: dirtyStatus.head_oid,
  });
  expect(mockLocalProjects.commit).not.toHaveBeenCalled();
});

test('a workspace project sets its origin, provisions a credential natively and pushes by root', async () => {
  mockLocalProjects.isV2Available.mockReturnValue(true);
  mockLocalProjects.list.mockRejectedValue(Object.assign(new Error('E_PROJECT_NATIVE'), { code: 'E_PROJECT_NATIVE' }));
  mockWorkspaceProjects.mockResolvedValue([workspaceProject]);
  const v2Status = { ...dirtyStatus, schema_version: 2, root: workspaceRoot, project_id: workspaceRoot.project_id };
  mockLocalProjects.statusV2.mockResolvedValue(v2Status);
  mockLocalProjects.diffV2.mockImplementation(async (request: { staged: boolean }) => ({
    ...diff, schema_version: 2, root: workspaceRoot, project_id: workspaceRoot.project_id, staged: request.staged,
  }));
  const url = 'https://github.com/example/demo.git';
  const remote = {
    schema_version: 2, root: workspaceRoot, project_id: workspaceRoot.project_id, remote: 'origin', url, host: 'github.com',
  };
  const absent = { schema_version: 2, root: workspaceRoot, project_id: workspaceRoot.project_id, host: 'github.com', configured: false };
  const present = { ...absent, configured: true, expires_at: 1_800_000_000, expiry_seconds: 3600 };
  mockLocalProjects.setRemoteV2.mockResolvedValue(remote);
  mockLocalProjects.credentialStatusV2.mockResolvedValue(absent);
  mockLocalProjects.presentCredentialPromptV2.mockResolvedValue(present);
  mockLocalProjects.clearCredentialV2.mockResolvedValue(absent);
  mockLocalProjects.pushV2.mockResolvedValue({
    schema_version: 2, root: workspaceRoot, project_id: workspaceRoot.project_id,
    remote: 'origin', branch: 'main', oid: dirtyStatus.head_oid, pushed_at: '2026-09-20T00:00:00.000Z',
  });
  const alert = jest.spyOn(Alert, 'alert').mockImplementation(() => undefined);
  const renderer = await renderSurface();
  const row = renderer.root.findByProps({ testID: 'projects-row-Smoke' });
  await act(async () => { row.props.onPress(); await settle(); });

  await act(async () => inputByLabel(renderer.root, 'Origin HTTPS URL').props.onChangeText(url));
  // Once saved, every reload reads the origin back and the credential with it.
  mockLocalProjects.remoteV2.mockResolvedValue(remote);
  await act(async () => { actionByLabel(renderer.root, 'Save origin').props.onPress(); await settle(); });
  expect(mockLocalProjects.setRemoteV2).toHaveBeenCalledWith({ schema_version: 1, root: workspaceRoot, url });
  expect(mockLocalProjects.setRemote).not.toHaveBeenCalled();
  expect(mockLocalProjects.credentialStatusV2).toHaveBeenCalledWith({ schema_version: 1, root: workspaceRoot });
  // The saved origin re-reads the detail; let that settle before provisioning.
  await act(async () => { await settle(); await settle(); });

  await act(async () => { actionByLabel(renderer.root, 'Configure remote credential').props.onPress(); await settle(); });
  expect(mockLocalProjects.presentCredentialPromptV2).toHaveBeenCalledWith({
    schema_version: 1, root: workspaceRoot, locale: 'en',
  });
  expect(mockLocalProjects.presentCredentialPrompt).not.toHaveBeenCalled();
  expect(renderer.root.findAllByProps({ accessibilityLabel: 'Clear remote credential' }).length).toBeGreaterThan(0);
  // From here on the store answers what the prompt provisioned.
  mockLocalProjects.credentialStatusV2.mockResolvedValue(present);
  // No branch field for a workspace project: V2 pushes the current branch.
  expect(renderer.root.findAllByProps({ accessibilityLabel: 'Push as new branch (optional)' }).length).toBe(0);

  await act(async () => actionByLabel(renderer.root, 'Push').props.onPress());
  expect(mockLocalProjects.pushV2).not.toHaveBeenCalled();
  const buttons = alert.mock.calls[alert.mock.calls.length - 1]?.[2];
  const confirm = Array.isArray(buttons) ? buttons.find(button => button.text === 'Push now') : undefined;
  await act(async () => { confirm?.onPress?.(); await settle(); });
  expect(mockLocalProjects.pushV2).toHaveBeenCalledWith({
    schema_version: 1,
    root: workspaceRoot,
    operation_id: 'op-1',
    remote: 'origin',
    expected_local_oid: dirtyStatus.head_oid,
    credential_reference: 'panel',
    https_proxy_url: null,
  });
  expect(mockLocalProjects.push).not.toHaveBeenCalled();
  expect(renderer.root.findAllByProps({ children: 'Branch pushed successfully.' }).length).toBeGreaterThan(0);

  // A V2 refusal reads as the same message the legacy path shows.
  mockLocalProjects.pushV2.mockRejectedValueOnce(
    Object.assign(new Error('E_PROJECT_NON_FAST_FORWARD'), { code: 'E_PROJECT_NON_FAST_FORWARD' }),
  );
  await act(async () => actionByLabel(renderer.root, 'Push').props.onPress());
  const again = alert.mock.calls[alert.mock.calls.length - 1]?.[2];
  const confirmAgain = Array.isArray(again) ? again.find(button => button.text === 'Push now') : undefined;
  await act(async () => { confirmAgain?.onPress?.(); await settle(); });
  expect(renderer.root.findAllByProps({ accessibilityRole: 'alert' }).length).toBeGreaterThan(0);
  expect(
    renderer.root.findAll(instance => typeof instance.props.children === 'string' &&
      instance.props.children.startsWith('The remote rejected the push: the branch is not fast-forward')).length,
  ).toBeGreaterThan(0);

  await act(async () => { actionByLabel(renderer.root, 'Clear remote credential').props.onPress(); await settle(); });
  expect(mockLocalProjects.clearCredentialV2).toHaveBeenCalledWith({ schema_version: 1, root: workspaceRoot });
  alert.mockRestore();
});
