import React, {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import ChevronLeft from 'lucide-react-native/icons/chevron-left';
import ChevronRight from 'lucide-react-native/icons/chevron-right';
import FolderDown from 'lucide-react-native/icons/folder-down';
import FolderGit2 from 'lucide-react-native/icons/folder-git-2';
import FolderOpen from 'lucide-react-native/icons/folder-open';
import FolderPlus from 'lucide-react-native/icons/folder-plus';
import GitBranch from 'lucide-react-native/icons/git-branch';
import GitCompare from 'lucide-react-native/icons/git-compare';
import RefreshCw from 'lucide-react-native/icons/refresh-cw';
import X from 'lucide-react-native/icons/x';
import {
  ActivityIndicator,
  Alert,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  LocalProjects,
  type LocalProject,
  type ProjectCredentialStatus,
  type ProjectDiff,
  type ProjectDiffPage,
  type ProjectFileStatus,
  type ProjectGitStatus,
  type ProjectPushReceipt,
  type ProjectStatusEntry,
} from '../native/LocalProjects';
import { LocalRuntime } from '../native/LocalRuntime';
import { listWorkspaceProjects } from '../native/workspaceProjects';
import type { WorkspaceRootRefV1 } from '../native/WorkspaceRoot';
import { useAppPresentation } from '../presentation/AppPresentation';
import { fonts, hitSlop, type ThemePalette } from '../theme';
import { AppIcon } from './AppIcon';
import { SlidingSurface } from './SlidingSurface';
import { ProjectViewTasks, type ProjectViewTask } from './projectViewTasks';
import type { ProjectCloneOperation } from '../native/LocalProjects';
import { type ProjectSSHCredentialStatus } from '../native/LocalProjects';

export function sshEndpoint(value: string): { host: string; port: number; username: string } | null {
  const text = value.trim();
  if (/[^\x20-\x7e]/.test(text)) return null;
  try {
    const url = /^ssh:\/\//iu.test(text) ? new URL(text) : null;
    if (url) {
      if (url.protocol.toLowerCase() !== 'ssh:' || url.password || url.search || url.hash || !url.hostname || url.username.length === 0) return null;
      const port = Number(url.port || 22); if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
      return { host: url.hostname.toLowerCase(), port, username: decodeURIComponent(url.username) };
    }
    if (/^[a-z][a-z0-9+.-]*:\/\//iu.test(text)) return null;
    const match = /^([^@/:\s]+)@([^/:\s]+):(.+)$/.exec(text);
    if (!match || match[3]!.length === 0 || /[?#]/.test(match[3]!)) return null;
    return { host: match[2]!.toLowerCase(), port: 22, username: match[1]! };
  } catch { return null; }
}
function sshProfileId(endpoint: { host: string; port: number; username: string }): string { return `rish-ssh-${endpoint.username}@${endpoint.host}-${endpoint.port}`; }

function cloneIsActive(operation: ProjectCloneOperation | null) {
  return (
    operation !== null &&
    !['succeeded', 'failed', 'cancelled'].includes(operation.phase)
  );
}

type CreateMode = 'create' | 'clone' | null;
type ProjectTab = 'files' | 'changes';
type DiffMode = 'staged' | 'unstaged';

/**
 * A row of the list: a legacy project (`root === null`, the v1 API by
 * project id) or a project attached to a workspace (`root` set, the V2 API
 * by workspace root -- the only kind Android has).
 */
type ProjectRow = LocalProject & {
  readonly root: WorkspaceRootRefV1 | null;
  readonly workspaceName: string | null;
};

const WORKSPACE_DIFF_MAX_BYTES = 512 * 1024;

/** A legacy project as a row: the v1 API by id, no workspace root. */
function legacyRow(project: LocalProject): ProjectRow {
  return { ...project, root: null, workspaceName: null };
}

/** The row as the callers outside this surface know a project: without the row's own fields. */
function projectOf(row: ProjectRow): LocalProject {
  const { root: _root, workspaceName: _workspaceName, ...project } = row;
  return project;
}

/** A V2 answer in the v1 shape the panel renders; the root is the row's. */
function legacyShaped<T extends { schema_version: 2; root: WorkspaceRootRefV1 }>(
  value: T,
): Omit<T, 'schema_version' | 'root'> & { schema_version: 1 } {
  const { root: _root, schema_version: _version, ...rest } = value;
  return { ...rest, schema_version: 1 };
}

export type ProjectReviewPreviewProps = {
  status: ProjectGitStatus | null;
  diff: ProjectDiff;
  diffPage?: ProjectDiffPage | null;
  diffMode?: DiffMode;
};

/** A workspace name from a repository URL: its last path segment without `.git`. */
function workspaceNameFromUrl(url: string): string {
  const segment = url.replace(/\/+$/u, '').split('/').pop() ?? '';
  const name = segment.replace(/\.git$/iu, '').trim();
  return name.length === 0 ? 'Repository' : name.slice(0, 120);
}

/** The stable code a bridge rejection carries, or an empty string. */
function errorCode(error: unknown): string {
  return typeof error === 'object' && error !== null && 'code' in error
    ? String((error as { code?: unknown }).code)
    : '';
}

/**
 * A workspace project's origin and credential, in the panel's v1 shape with
 * the origin URL alongside: null when no origin is set. The origin is read
 * first because the credential is scoped to its host.
 */
async function workspaceCredential(
  root: WorkspaceRootRefV1,
): Promise<(ProjectCredentialStatus & { origin_url: string }) | null> {
  const remote = await LocalProjects.remoteV2({ schema_version: 1, root });
  if (remote.url === null) return null;
  const status = legacyShaped(
    await LocalProjects.credentialStatusV2({ schema_version: 1, root }),
  );
  return { ...status, origin_url: remote.url };
}

/** A workspace project's push receipts in the panel's v1 shape, or null when it has no origin to have pushed to. */
async function workspaceReceipts(
  root: WorkspaceRootRefV1,
): Promise<{ schema_version: 1; project_id: string; receipts: ProjectPushReceipt[] } | null> {
  const remote = await LocalProjects.remoteV2({ schema_version: 1, root });
  if (remote.url === null) return null;
  const receipts = await LocalProjects.pushReceiptsV2({ schema_version: 1, root });
  return { schema_version: 1, project_id: receipts.project_id, receipts: receipts.receipts };
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function hasStatus(value: string): boolean {
  const normalized = value.trim().toLocaleLowerCase();
  return !['', '.', 'unmodified', 'current', 'none'].includes(normalized);
}

function gitPathHeaderVariants(path: string): string[] {
  const bytes: number[] = [];
  try {
    const encoded = encodeURIComponent(path);
    for (let index = 0; index < encoded.length; index += 1) {
      if (encoded[index] === '%') {
        bytes.push(Number.parseInt(encoded.slice(index + 1, index + 3), 16));
        index += 2;
      } else bytes.push(encoded.charCodeAt(index));
    }
  } catch {
    return [`a/${path}`, `b/${path}`];
  }
  let quoted = '"';
  for (const byte of bytes) {
    if (byte === 0x22 || byte === 0x5c) quoted += `\\${String.fromCharCode(byte)}`;
    else if (byte >= 0x20 && byte <= 0x7e) quoted += String.fromCharCode(byte);
    else quoted += `\\${byte.toString(8).padStart(3, '0')}`;
  }
  quoted += '"';
  return [`a/${path}`, `b/${path}`, `"a/${quoted.slice(1)}`, `"b/${quoted.slice(1)}`];
}

function patchSectionMatchesPath(section: string, path: string): boolean {
  const header = section.split('\n', 1)[0] ?? '';
  const rest = header.startsWith('diff --git ')
    ? header.slice('diff --git '.length)
    : '';
  const tokens: string[] = [];
  for (let index = 0; index < rest.length;) {
    while (/\s/u.test(rest[index] ?? '')) index += 1;
    if (index >= rest.length) break;
    const start = index;
    if (rest[index] === '"') {
      index += 1;
      let escaped = false;
      while (index < rest.length) {
        const character = rest[index] ?? '';
        index += 1;
        if (escaped) escaped = false;
        else if (character === '\\') escaped = true;
        else if (character === '"') break;
      }
    } else {
      while (index < rest.length && !/\s/u.test(rest[index] ?? '')) index += 1;
    }
    tokens.push(rest.slice(start, index));
  }
  return gitPathHeaderVariants(path).some(variant => tokens.includes(variant));
}

function patchForPath(patch: string, path: string): string | null {
  const lines = patch.split('\n');
  let start = -1;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] ?? '';
    if (!line.startsWith('diff --git ')) continue;
    if (start !== -1) {
      const section = lines.slice(start, index).join('\n');
      if (patchSectionMatchesPath(section, path)) return section;
    }
    start = index;
  }
  if (start === -1) return null;
  const section = lines.slice(start).join('\n');
  return patchSectionMatchesPath(section, path) ? section : null;
}

function hasStagedChanges(status: ProjectGitStatus | null): boolean {
  return status?.entries.some(entry => hasStatus(entry.index_status)) ?? false;
}

function statusSummary(
  status: ProjectGitStatus | null,
  t: ReturnType<typeof useAppPresentation>['t'],
): string {
  if (status === null) return t('projects.loading');
  if (status.clean) return t('projects.clean');
  return t('projects.dirty', { count: status.entries.length });
}

function fileStatusLabel(
  status: ProjectFileStatus,
  t: ReturnType<typeof useAppPresentation>['t'],
): string {
  switch (status) {
    case 'added':
      return t('projects.fileStatus.added');
    case 'modified':
      return t('projects.fileStatus.modified');
    case 'deleted':
      return t('projects.fileStatus.deleted');
    case 'renamed':
      return t('projects.fileStatus.renamed');
    case 'typechange':
      return t('projects.fileStatus.typechange');
    case 'unreadable':
      return t('projects.fileStatus.unreadable');
    case 'unmodified':
      return t('projects.fileStatus.unmodified');
  }
}

function changeLabels(
  entry: ProjectStatusEntry,
  t: ReturnType<typeof useAppPresentation>['t'],
): string[] {
  const labels: string[] = [];
  if (entry.index_status !== 'unmodified') {
    labels.push(
      t('projects.change.staged', {
        status: fileStatusLabel(entry.index_status, t),
      }),
    );
  }
  if (entry.worktree_status !== 'unmodified') {
    labels.push(
      t('projects.change.worktree', {
        status: fileStatusLabel(entry.worktree_status, t),
      }),
    );
  }
  if (entry.conflicted) labels.push(t('projects.change.conflict'));
  if (labels.length === 0) labels.push(t('projects.fileStatus.unmodified'));
  return labels;
}

type Props = {
  boundProjectId?: string | null;
  covered?: boolean;
  refreshToken?: number;
  visible: boolean;
  onChatInProject?: (project: LocalProject) => void;
  onClose: () => void;
  onDismiss?: () => void;
  onOpenFiles: (
    project: LocalProject,
    isCurrent?: () => boolean,
  ) => void | Promise<void>;
  onUnbindFromChat?: () => void;
};

/** Host shown in the push confirmation; the full URL is still displayed. */
function remoteHost(url: string): string {
  const match = /^[a-z]+:\/\/([^/]+)/iu.exec(url);
  return match?.[1] ?? url;
}

export function ProjectsSurface({
  boundProjectId = null,
  covered = false,
  refreshToken = 0,
  visible,
  onChatInProject,
  onClose,
  onDismiss,
  onOpenFiles,
  onUnbindFromChat,
}: Props) {
  const insets = useSafeAreaInsets();
  const [containerWidth, setContainerWidth] = useState(0);
  const wideLayout = containerWidth >= 900;
  const { colors, locale, preferences, t } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const [projects, setProjects] = useState<ProjectRow[]>([]);
  const [selected, setSelected] = useState<ProjectRow | null>(null);
  const [status, setStatus] = useState<ProjectGitStatus | null>(null);
  const [diffs, setDiffs] = useState<{
    staged: ProjectDiff | null;
    unstaged: ProjectDiff | null;
  }>({ staged: null, unstaged: null });
  const [diffMode, setDiffMode] = useState<DiffMode>('unstaged');
  const diffModeRef = useRef<DiffMode | null>(null);
  const [diffPage, setDiffPage] = useState<ProjectDiffPage | null>(null);
  const [pageHistory, setPageHistory] = useState<number[]>([]);
  const [selectedDiffPath, setSelectedDiffPath] = useState<string | null>(null);
  const diffRevision = useRef(0);
  const diff = diffs[diffMode];
  // A legacy project shows the path Rish owns; a workspace project has no
  // such path -- its worktree is the workspace itself.
  const worktreeLabel =
    selected === null
      ? ''
      : selected.root !== null
        ? t('projects.workspaceProject', { workspace: selected.workspaceName ?? '' })
        : selected.workspace_path;
  const [credential, setCredential] = useState<ProjectCredentialStatus | null>(
    null,
  );
  const [tab, setTab] = useState<ProjectTab>('files');
  const detailScroll = useRef<React.ComponentRef<typeof ScrollView>>(null);
  const [createMode, setCreateMode] = useState<CreateMode>(null);
  const [name, setName] = useState('');
  const [cloneUrl, setCloneUrl] = useState('');
  const [sshCredential, setSshCredential] = useState<ProjectSSHCredentialStatus | null>(null);
  const sshCredentialBusy = useRef(false);
  const [sshCredentialBusyState, setSshCredentialBusyState] = useState(false);
  const sshCredentialEpoch = useRef(0);
  const [sshCredentialError, setSshCredentialError] = useState<string | null>(null);
  useEffect(() => {
    const endpoint = sshEndpoint(cloneUrl);
    const epoch = ++sshCredentialEpoch.current;
    setSshCredential(null); setSshCredentialError(null);
    if (!endpoint) return () => { sshCredentialEpoch.current += 1; };
    if (typeof LocalProjects.sshCredentialStatus !== 'function') return;
    LocalProjects.sshCredentialStatus(sshProfileId(endpoint)).then(next => { if (epoch === sshCredentialEpoch.current && next !== null && next.profile_id === sshProfileId(endpoint) && next.host === endpoint.host && next.port === endpoint.port && next.username === endpoint.username) setSshCredential(next); }).catch(() => undefined);
    return () => { sshCredentialEpoch.current += 1; };
  }, [cloneUrl]);
  const [cloneOperation, setCloneOperation] =
    useState<ProjectCloneOperation | null>(null);
  const cloneOperationRef = useRef<ProjectCloneOperation | null>(null);
  const cloneOwner = useRef<ProjectViewTask | null>(null);
  const [startingClone, setStartingClone] = useState(false);
  const cloneStarting = useRef(false);
  const cloneCancelOnStart = useRef(false);
  const clonePollVersion = useRef(0);
  const handledClone = useRef<string | null>(null);
  const [commitMessage, setCommitMessage] = useState('');
  const [authorName, setAuthorName] = useState('');
  const [authorEmail, setAuthorEmail] = useState('');
  const [remoteUrl, setRemoteUrl] = useState('');
  const [busy, setBusy] = useState(false);
  const [pushing, setPushing] = useState(false);
  const pushOperationId = useRef<string | null>(null);
  /** A clone into a new workspace (Android): its operation id while the network runs. */
  const [workspaceClone, setWorkspaceClone] = useState<{ operationId: string; url: string } | null>(null);
  const workspaceCloneRef = useRef<string | null>(null);
  const [pushBranch, setPushBranch] = useState('');
  const [receipt, setReceipt] = useState<ProjectPushReceipt | null>(null);
  /**
   * What the last fetch of this view saw upstream. A merge is bound to it:
   * the person merges what they fetched, and a later fetch that moved the
   * upstream makes the native side refuse rather than merge something unseen.
   */
  const [fetched, setFetched] = useState<{ projectId: string; branch: string; remoteOid: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [tasks] = useState(() => new ProjectViewTasks());
  const selectedRef = useRef<ProjectRow | null>(null);
  const remoteDraftDirty = useRef(false);
  const remoteDraftRevision = useRef(0);
  const reloadCurrentRef = useRef<(() => void) | null>(null);
  const syncBusy = useCallback(() => {
    setBusy(tasks.busy);
    setPushing(tasks.pushing);
  }, [tasks]);
  const beginTask = useCallback(
    (kind: ProjectViewTask['kind']) => {
      const task = tasks.begin(kind);
      syncBusy();
      return task;
    },
    [syncBusy, tasks],
  );
  const finishTask = useCallback(
    (task: ProjectViewTask) => {
      tasks.finish(task);
      if (tasks.visible) {
        syncBusy();
        // A native mutation may outlive navigation. If its project is open again,
        // refresh that new view; never publish the old view's captured payload.
        if (
          (task.kind === 'mutation' || task.kind === 'push') &&
          task.projectId === (selectedRef.current?.id ?? null) &&
          !tasks.owns(task)
        ) {
          reloadCurrentRef.current?.();
        }
      }
    },
    [syncBusy, tasks],
  );
  const selectView = useCallback(
    (project: ProjectRow | null) => {
      tasks.invalidate(project?.id ?? null);
      selectedRef.current = project;
      remoteDraftDirty.current = false;
      remoteDraftRevision.current += 1;
      setSelected(project);
      setStatus(null);
      setDiffs({ staged: null, unstaged: null });
      diffModeRef.current = null;
      setDiffMode('unstaged');
      diffRevision.current += 1;
      setDiffPage(null);
      setPageHistory([]);
      setSelectedDiffPath(null);
      setCredential(null);
      setReceipt(null);
      setFetched(null);
      setRemoteUrl(project?.origin_url ?? '');
      setError(null);
      setNotice(null);
      syncBusy();
    },
    [syncBusy, tasks],
  );
  const closeSurface = useCallback(() => {
    tasks.visible = false;
    tasks.invalidate();
    onClose();
  }, [onClose, tasks]);
  useLayoutEffect(() => {
    tasks.visible = visible;
    tasks.invalidate();
    syncBusy();
    return () => {
      tasks.visible = false;
      tasks.invalidate();
    };
  }, [syncBusy, tasks, visible]);

  const loadProjects = useCallback(async () => {
    if (!tasks.visible) return;
    const legacyAvailable = LocalProjects.isAvailable();
    const workspaceAvailable = LocalProjects.isV2Available();
    if (!legacyAvailable && !workspaceAvailable) {
      setError(t('projects.unavailable'));
      return;
    }
    const task = beginTask('list');
    setError(null);
    try {
      // The legacy listing and the workspace-attached projects are two
      // sources. A build with only the second (Android) answers the first
      // with a refusal, which is not an error worth a banner.
      let legacyFailure: unknown = null;
      const [legacy, attached] = await Promise.all([
        legacyAvailable
          ? LocalProjects.list().catch((caught: unknown) => {
              legacyFailure = caught;
              return { schema_version: 1 as const, projects: [] as LocalProject[] };
            })
          : Promise.resolve({ schema_version: 1 as const, projects: [] as LocalProject[] }),
        workspaceAvailable ? listWorkspaceProjects() : Promise.resolve([]),
      ]);
      if (!tasks.owns(task)) return;
      if (legacyFailure !== null && !workspaceAvailable) throw legacyFailure;
      const legacyIds = new Set(legacy.projects.map(row => row.id));
      const rows: ProjectRow[] = [
        ...legacy.projects.map(legacyRow),
        ...[...attached]
          .filter(row => !legacyIds.has(row.projectId))
          .sort((left, right) => right.lastOpenedAt.localeCompare(left.lastOpenedAt))
          .map(row => ({
            schema_version: 1 as const,
            id: row.projectId,
            name: row.name,
            workspace_path: `projects/${row.projectId}/repo` as const,
            created_at: row.createdAt,
            updated_at: row.lastOpenedAt,
            origin_url: null,
            root: row.root,
            workspaceName: row.workspaceName,
          })),
      ];
      const listing = { projects: rows };
      setProjects(rows);
      const previous = selectedRef.current;
      if (previous !== null) {
        const next =
          listing.projects.find(project => project.id === previous.id) ?? null;
        if (next === null) selectView(null);
        else {
          selectedRef.current = next;
          setSelected(next);
        }
      }
    } catch (caught) {
      if (!tasks.owns(task)) return;
      setError(t('projects.operationFailed', { error: errorText(caught) }));
    } finally {
      finishTask(task);
    }
  }, [beginTask, finishTask, selectView, t, tasks]);

  const loadDetail = useCallback(
    async (project: ProjectRow) => {
      if (!tasks.visible || selectedRef.current?.id !== project.id) return;
      diffRevision.current += 1;
      setDiffPage(null);
      setPageHistory([]);
      setSelectedDiffPath(null);
      const task = beginTask('detail');
      setError(null);
      try {
        const [
          nextStatus,
          unstagedDiff,
          stagedDiff,
          nextCredential,
          nextReceipts,
        ] = project.root !== null
          ? await Promise.all([
              LocalProjects.statusV2({ schema_version: 1, root: project.root }).then(legacyShaped),
              LocalProjects.diffV2({
                schema_version: 1,
                root: project.root,
                max_bytes: WORKSPACE_DIFF_MAX_BYTES,
                staged: false,
              }).then(legacyShaped),
              LocalProjects.diffV2({
                schema_version: 1,
                root: project.root,
                max_bytes: WORKSPACE_DIFF_MAX_BYTES,
                staged: true,
              }).then(legacyShaped),
              workspaceCredential(project.root),
              workspaceReceipts(project.root),
            ])
          : await Promise.all([
              LocalProjects.status(project.id),
              LocalProjects.diff(project.id, { staged: false }),
              LocalProjects.diff(project.id, { staged: true }),
              project.origin_url === null
                ? Promise.resolve(null)
                : LocalProjects.credentialStatus(project.id),
              project.origin_url === null
                ? Promise.resolve(null)
                : LocalProjects.pushReceipts(project.id),
            ]);
        if (!tasks.owns(task)) return;
        // A workspace project's origin lives in its git config, not in a
        // listing: the credential status names it, or says there is none.
        if (project.root !== null) {
          let originUrl: string | null = null;
          if (
            nextCredential !== null &&
            'origin_url' in nextCredential &&
            typeof nextCredential.origin_url === 'string'
          ) {
            originUrl = nextCredential.origin_url;
          }
          if (originUrl !== project.origin_url) {
            const updated = { ...project, origin_url: originUrl };
            selectedRef.current = updated;
            setSelected(updated);
            setProjects(previous =>
              previous.map(row => (row.id === updated.id ? updated : row)),
            );
            project = updated;
          }
        }
        setStatus(nextStatus);
        setDiffs({ unstaged: unstagedDiff, staged: stagedDiff });
        const mode =
          diffModeRef.current ??
          (hasStagedChanges(nextStatus) ? 'staged' : 'unstaged');
        diffModeRef.current = mode;
        setDiffMode(mode);
        setCredential(nextCredential);
        setReceipt(
          nextReceipts === null || nextReceipts.receipts.length === 0
            ? null
            : nextReceipts.receipts[nextReceipts.receipts.length - 1],
        );
        if (!remoteDraftDirty.current) setRemoteUrl(project.origin_url ?? '');
      } catch (caught) {
        if (!tasks.owns(task)) return;
        setError(t('projects.operationFailed', { error: errorText(caught) }));
      } finally {
        finishTask(task);
      }
    },
    [beginTask, finishTask, t, tasks],
  );

  useEffect(() => {
    if (visible) loadProjects().catch(() => undefined);
  }, [loadProjects, visible]);

  useLayoutEffect(() => {
    reloadCurrentRef.current = () => {
      const project = selectedRef.current;
      (project === null ? loadProjects() : loadDetail(project)).catch(
        () => undefined,
      );
    };
    return () => {
      reloadCurrentRef.current = null;
    };
  }, [loadDetail, loadProjects]);

  useEffect(() => {
    if (visible && selected !== null)
      loadDetail(selected).catch(() => undefined);
  }, [loadDetail, refreshToken, selected, visible]);

  const openProject = useCallback(
    (project: ProjectRow) => {
      if (!tasks.visible || selectedRef.current !== null) return;
      selectView(project);
      setTab(wideLayout ? 'changes' : 'files');
      setNotice(null);
      setStatus(null);
      setDiffs({ staged: null, unstaged: null });
      setCredential(null);
      setRemoteUrl(project.origin_url ?? '');
    },
    [selectView, tasks, wideLayout],
  );

  const applyCloneSnapshot = useCallback(
    (operation: ProjectCloneOperation) => {
      const current = cloneOperationRef.current;
      if (
        current?.operation_id === operation.operation_id &&
        ((!cloneIsActive(current) && cloneIsActive(operation)) ||
          (current.cancel_requested &&
            !operation.cancel_requested &&
            cloneIsActive(operation)))
      )
        return;
      cloneOperationRef.current = operation;
      setCloneOperation(operation);
      if (
        cloneIsActive(operation) ||
        handledClone.current === operation.operation_id
      )
        return;
      handledClone.current = operation.operation_id;
      const owner = cloneOwner.current;
      cloneOwner.current = null;
      if (operation.phase === 'succeeded' && operation.project !== null) {
        const project = legacyRow(operation.project);
        setProjects(previous => [
          project,
          ...previous.filter(item => item.id !== project.id),
        ]);
        if (owner !== null && tasks.owns(owner)) {
          setCreateMode(null);
          setName('');
          setCloneUrl('');
          selectView(project);
          setTab(wideLayout ? 'changes' : 'files');
          setNotice(t('projects.clonedSuccess'));
        }
      }
      if (owner !== null) finishTask(owner);
    },
    [finishTask, selectView, t, tasks, wideLayout],
  );

  useEffect(() => {
    if (!visible) return;
    let disposed = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const poll = async () => {
      const version = clonePollVersion.current;
      try {
        const operation = await LocalProjects.cloneStatus();
        if (
          !disposed &&
          version === clonePollVersion.current &&
          operation !== null &&
          !cloneStarting.current
        )
          applyCloneSnapshot(operation);
      } catch {
        // Retain the last known operation; a failed poll must not imply completion.
      }
      if (!disposed && cloneIsActive(cloneOperationRef.current))
        timer = setTimeout(() => {
          poll().catch(() => undefined);
        }, 400);
    };
    poll().catch(() => undefined);
    return () => {
      disposed = true;
      if (timer !== undefined) clearTimeout(timer);
    };
  }, [applyCloneSnapshot, visible, cloneOperation?.operation_id]);

  const cancelWorkspaceClone = useCallback(() => {
    const operationId = workspaceCloneRef.current;
    if (operationId === null) return;
    LocalProjects.cancelWorkspaceCloneV2(operationId).catch(() => undefined);
  }, []);

  const cancelClone = useCallback(async () => {
    const operation = cloneOperationRef.current;
    if (!cloneIsActive(operation) || operation === null) return;
    // Cancel navigation ownership immediately; the native result may already be publishing.
    if (cloneOwner.current !== null) {
      tasks.invalidate();
      syncBusy();
    }
    try {
      const next = await LocalProjects.cancelClone(operation.operation_id);
      if (
        tasks.visible &&
        cloneOperationRef.current?.operation_id === next.operation_id
      )
        applyCloneSnapshot(next);
    } catch (caught) {
      if (tasks.visible)
        setError(t('projects.operationFailed', { error: errorText(caught) }));
    }
  }, [applyCloneSnapshot, syncBusy, t, tasks]);

  const finishCreation = useCallback(
    async (kind: Exclude<CreateMode, null>) => {
      if (
        !tasks.visible ||
        tasks.busy ||
        cloneStarting.current ||
        cloneIsActive(cloneOperationRef.current)
      )
        return;
      const trimmedName = name.trim();
      const trimmedUrl = cloneUrl.trim();
      if (kind === 'create' && trimmedName.length === 0) return;
      if (kind === 'clone' && trimmedUrl.length === 0) return;
      const task = beginTask('mutation');
      setError(null);
      setNotice(null);
      try {
        if (kind === 'clone' && !LocalProjects.isLegacyCloneAvailable() && LocalProjects.isWorkspaceCloneAvailable()) {
          // No legacy clone on this build: the repository becomes a new
          // workspace with its project attached, and the row appears in the
          // list the way any workspace project does.
          const operationId = LocalRuntime.createCompletionRequestId();
          workspaceCloneRef.current = operationId;
          setWorkspaceClone({ operationId, url: trimmedUrl });
          const cloneRequest = {
            schema_version: 1 as const,
            operation_id: operationId,
            url: trimmedUrl,
            display_name: trimmedName.length === 0 ? workspaceNameFromUrl(trimmedUrl) : trimmedName,
            https_proxy_url: preferences.gitHttpsProxyUrl,
          };
          try {
            let cloned;
            try {
              cloned = await LocalProjects.cloneWorkspaceV2(cloneRequest);
            } catch (first) {
              // A repository that asks for a credential gets one chance: the
              // native dialog, then the same clone again with what was typed.
              // The secret never comes through here.
              if (!tasks.owns(task) || errorCode(first) !== 'E_PROJECT_CREDENTIAL' ||
                  !LocalProjects.isCloneCredentialPromptAvailable() || workspaceCloneRef.current !== operationId) {
                throw first;
              }
              await LocalProjects.presentCloneCredentialPromptV2({
                schema_version: 1,
                operation_id: operationId,
                url: trimmedUrl,
                locale: locale === 'zh-CN' ? 'zh-CN' : 'en',
              });
              if (!tasks.owns(task) || workspaceCloneRef.current !== operationId) return;
              try {
                cloned = await LocalProjects.cloneWorkspaceV2({ ...cloneRequest, credential_reference: 'prompt' });
              } catch (second) {
                if (errorCode(second) === 'E_PROJECT_CREDENTIAL') {
                  throw Object.assign(new Error('E_PROJECT_CREDENTIAL_REJECTED'), { code: 'E_PROJECT_CREDENTIAL_REJECTED' });
                }
                throw second;
              }
            }
            if (!tasks.owns(task)) return;
            setCreateMode(null);
            setName('');
            setCloneUrl('');
            const row: ProjectRow = {
              schema_version: 1,
              id: cloned.project.project_id,
              name: cloned.project.display_name,
              workspace_path: `projects/${cloned.project.project_id}/repo`,
              origin_url: trimmedUrl,
              created_at: new Date().toISOString(),
              updated_at: new Date().toISOString(),
              root: cloned.root,
              workspaceName: cloned.workspace.display_name,
            };
            setProjects(previous => [row, ...previous.filter(item => item.id !== row.id)]);
            selectView(row);
            setNotice(t('projects.clonedSuccess'));
            setTab('files');
          } catch (caught) {
            if (!tasks.owns(task)) return;
            const code = errorCode(caught);
            if (code === 'E_PROJECT_CANCELLED') setNotice(t('projects.cloneCancelled'));
            else if (code === 'E_PROJECT_PROXY') setError(t('projects.proxyFailed', { proxy: preferences.gitHttpsProxyUrl ?? '' }));
            else if (code === 'E_PROJECT_CREDENTIAL') setError(t('projects.cloneAuthRequired'));
            else if (code === 'E_PROJECT_CREDENTIAL_REJECTED') setError(t('projects.cloneCredentialRejected'));
            else if (code === 'E_PROJECT_TIMEOUT') setError(t('projects.cloneTimeout'));
            else if (code === 'E_PROJECT_REQUEST_INVALID') setError(t('projects.cloneUrlInvalid'));
            else setError(t('projects.operationFailed', { error: errorText(caught) }));
          } finally {
            if (workspaceCloneRef.current === operationId) {
              workspaceCloneRef.current = null;
              setWorkspaceClone(null);
            }
          }
          return;
        }
        if (kind === 'clone') {
          cloneStarting.current = true;
          setStartingClone(true);
          cloneCancelOnStart.current = false;
          clonePollVersion.current += 1;
          cloneOwner.current = task;
          handledClone.current = null;
          let operation = await LocalProjects.startClone(
            trimmedUrl,
            trimmedName.length === 0 ? undefined : trimmedName,
            { httpsProxyUrl: preferences.gitHttpsProxyUrl, ...(sshEndpoint(trimmedUrl) ? { sshProfileId: sshProfileId(sshEndpoint(trimmedUrl)!) } : {}) },
          );
          cloneOperationRef.current = operation;
          if (tasks.visible) applyCloneSnapshot(operation);
          if (cloneCancelOnStart.current && cloneIsActive(operation)) {
            operation = await LocalProjects.cancelClone(operation.operation_id);
            cloneOperationRef.current = operation;
            if (tasks.visible) applyCloneSnapshot(operation);
          }
          return;
        }
        const project = legacyRow(await LocalProjects.create(trimmedName));
        if (!tasks.owns(task)) return;
        setProjects(previous => [
          project,
          ...previous.filter(item => item.id !== project.id),
        ]);
        setCreateMode(null);
        setName('');
        setCloneUrl('');
        selectView(project);
        setNotice(t('projects.created'));
        setTab('files');
        setRemoteUrl(project.origin_url ?? '');
      } catch (caught) {
        if (!tasks.owns(task)) return;
        setError(t('projects.operationFailed', { error: errorText(caught) }));
      } finally {
        cloneStarting.current = false;
        setStartingClone(false);
        finishTask(task);
      }
    },
    [
      applyCloneSnapshot,
      beginTask,
      cloneUrl,
      finishTask,
      name,
      preferences.gitHttpsProxyUrl,
      selectView,
      t,
      tasks,
    ],
  );

  const refresh = useCallback(async () => {
    if (selected === null) return;
    await loadDetail(selected);
  }, [loadDetail, selected]);

  const stageAll = useCallback(async () => {
    if (
      selected === null ||
      selectedRef.current?.id !== selected.id ||
      !tasks.visible ||
      tasks.busy ||
      status?.entries.length === 0
    )
      return;
    const task = beginTask('mutation');
    setError(null);
    setNotice(null);
    try {
      const nextStatus =
        selected.root !== null
          ? legacyShaped(await LocalProjects.stageAllV2({ schema_version: 1, root: selected.root }))
          : await LocalProjects.stageAll(selected.id);
      if (!tasks.owns(task)) return;
      diffModeRef.current = 'staged';
      setDiffMode('staged');
      setStatus(nextStatus);
      await loadDetail(selected);
      if (!tasks.owns(task)) return;
      setNotice(t('projects.stagedSuccess'));
    } catch (caught) {
      if (!tasks.owns(task)) return;
      setError(t('projects.operationFailed', { error: errorText(caught) }));
    } finally {
      finishTask(task);
    }
  }, [
    beginTask,
    finishTask,
    loadDetail,
    selected,
    status?.entries.length,
    t,
    tasks,
  ]);

  const chooseDiffMode = useCallback((mode: DiffMode) => {
    diffModeRef.current = mode;
    setDiffMode(mode);
    diffRevision.current += 1;
    setDiffPage(null);
    setPageHistory([]);
    setSelectedDiffPath(null);
  }, []);

  const reviewDiffPage = useCallback(
    async (offset: number, snapshot: string | null, history: number[]) => {
      const project = selectedRef.current;
      if (project === null || project.root !== null || !tasks.visible) return;
      const mode = diffModeRef.current ?? 'unstaged';
      const revision = diffRevision.current;
      const task = beginTask('diff');
      setError(null);
      try {
        const page = await LocalProjects.diffPage(
          project.id,
          mode === 'staged',
          offset,
          snapshot,
        );
        if (!tasks.owns(task) || revision !== diffRevision.current) return;
        setDiffPage(page);
        setPageHistory(history);
      } catch (caught) {
        if (!tasks.owns(task) || revision !== diffRevision.current) return;
        setDiffPage(null);
        setPageHistory([]);
        setError(t('projects.operationFailed', { error: errorText(caught) }));
      } finally {
        finishTask(task);
      }
    },
    [beginTask, finishTask, t, tasks],
  );

  const openFiles = useCallback(async () => {
    const project = selectedRef.current;
    if (project === null || !tasks.visible || tasks.busy) return;
    const task = beginTask('files');
    setError(null);
    try {
      await onOpenFiles(projectOf(project), () => tasks.owns(task));
    } catch (caught) {
      if (tasks.owns(task))
        setError(t('projects.operationFailed', { error: errorText(caught) }));
    } finally {
      finishTask(task);
    }
  }, [beginTask, finishTask, onOpenFiles, t, tasks]);

  const commit = useCallback(async () => {
    if (
      selected === null ||
      selectedRef.current?.id !== selected.id ||
      !tasks.visible ||
      tasks.busy ||
      commitMessage.trim().length === 0 ||
      authorName.trim().length === 0 ||
      authorEmail.trim().length === 0 ||
      !hasStagedChanges(status)
    )
      return;
    const task = beginTask('mutation');
    setError(null);
    setNotice(null);
    try {
      if (selected.root !== null) {
        // The V2 commit is guarded by the head the person reviewed: a
        // repository that moved under them refuses rather than committing
        // on top of something they never saw.
        await LocalProjects.commitV2({
          schema_version: 1,
          root: selected.root,
          operation_id: LocalRuntime.createCompletionRequestId(),
          message: commitMessage.trim(),
          author_name: authorName.trim(),
          author_email: authorEmail.trim(),
          expected_head_oid: status?.head_oid ?? null,
        });
      } else {
        await LocalProjects.commit(selected.id, {
          message: commitMessage.trim(),
          authorName: authorName.trim(),
          authorEmail: authorEmail.trim(),
        });
      }
      if (!tasks.owns(task)) return;
      setCommitMessage(current => (current === commitMessage ? '' : current));
      setNotice(t('projects.committedSuccess'));
      await loadDetail(selected);
    } catch (caught) {
      if (!tasks.owns(task)) return;
      setError(t('projects.operationFailed', { error: errorText(caught) }));
    } finally {
      finishTask(task);
    }
  }, [
    authorEmail,
    authorName,
    beginTask,
    finishTask,
    commitMessage,
    loadDetail,
    selected,
    status,
    t,
    tasks,
  ]);

  const saveRemote = useCallback(async () => {
    if (
      selected === null ||
      selectedRef.current?.id !== selected.id ||
      !tasks.visible ||
      tasks.busy ||
      remoteUrl.trim().length === 0
    )
      return;
    const task = beginTask('mutation');
    const draftRevision = remoteDraftRevision.current;
    setError(null);
    setNotice(null);
    try {
      const remote =
        selected.root !== null
          ? await LocalProjects.setRemoteV2({
              schema_version: 1,
              root: selected.root,
              url: remoteUrl.trim(),
            })
          : await LocalProjects.setRemote(selected.id, remoteUrl.trim());
      if (!tasks.owns(task)) return;
      // A set origin is never null; the union only says the read-back can be.
      const originUrl = remote.url ?? remoteUrl.trim();
      const updated = { ...selected, origin_url: originUrl };
      if (remoteDraftRevision.current === draftRevision) {
        remoteDraftDirty.current = false;
        setRemoteUrl(originUrl);
      }
      selectedRef.current = updated;
      setSelected(updated);
      setProjects(previous =>
        previous.map(project =>
          project.id === updated.id ? updated : project,
        ),
      );
      const nextCredential =
        selected.root !== null
          ? await LocalProjects.credentialStatusV2({
              schema_version: 1,
              root: selected.root,
            }).then(legacyShaped)
          : await LocalProjects.credentialStatus(selected.id);
      if (!tasks.owns(task)) return;
      setCredential(nextCredential);
      setNotice(t('projects.remoteSaved'));
    } catch (caught) {
      if (!tasks.owns(task)) return;
      setError(t('projects.operationFailed', { error: errorText(caught) }));
    } finally {
      finishTask(task);
    }
  }, [beginTask, finishTask, remoteUrl, selected, t, tasks]);

  const configureCredential = useCallback(async () => {
    if (
      selected === null ||
      selectedRef.current?.id !== selected.id ||
      selected.origin_url === null ||
      !tasks.visible ||
      tasks.busy
    )
      return;
    const task = beginTask('mutation');
    setError(null);
    setNotice(null);
    try {
      const promptLocale = locale === 'zh-CN' ? 'zh-CN' : 'en';
      const nextCredential =
        selected.root !== null
          ? await LocalProjects.presentCredentialPromptV2({
              schema_version: 1,
              root: selected.root,
              locale: promptLocale,
            }).then(legacyShaped)
          : await LocalProjects.presentCredentialPrompt(selected.id, promptLocale);
      if (!tasks.owns(task)) return;
      setCredential(nextCredential);
    } catch (caught) {
      if (!tasks.owns(task)) return;
      // Dismissing the native prompt is not a failure.
      if (errorCode(caught) === 'E_PROJECT_CANCELLED') return;
      setError(t('projects.operationFailed', { error: errorText(caught) }));
    } finally {
      finishTask(task);
    }
  }, [beginTask, finishTask, locale, selected, t, tasks]);

  const clearCredential = useCallback(async () => {
    if (
      selected === null ||
      selectedRef.current?.id !== selected.id ||
      !credential?.configured ||
      !tasks.visible ||
      tasks.busy
    )
      return;
    const task = beginTask('mutation');
    setError(null);
    setNotice(null);
    try {
      const nextCredential =
        selected.root !== null
          ? await LocalProjects.clearCredentialV2({
              schema_version: 1,
              root: selected.root,
            }).then(legacyShaped)
          : await LocalProjects.clearCredential(selected.id);
      if (!tasks.owns(task)) return;
      setCredential(nextCredential);
      setNotice(t('projects.credentialCleared'));
    } catch (caught) {
      if (!tasks.owns(task)) return;
      setError(t('projects.operationFailed', { error: errorText(caught) }));
    } finally {
      finishTask(task);
    }
  }, [beginTask, credential?.configured, finishTask, selected, t, tasks]);

  const push = useCallback(() => {
    if (
      selected === null ||
      selectedRef.current?.id !== selected.id ||
      selected.origin_url === null ||
      status === null ||
      status.branch === null ||
      status.branch.length === 0 ||
      status.head_oid === null ||
      !tasks.visible ||
      tasks.busy
    )
      return;
    const target = selected.root !== null ? '' : pushBranch.trim();
    const host = remoteHost(selected.origin_url);
    const newBranch = target.length > 0 && target !== status.branch;
    // A confirmation belongs to this exact view and target, not a later visit.
    const confirmation = tasks.begin('push');
    tasks.finish(confirmation);
    Alert.alert(
      t('projects.pushTitle'),
      newBranch
        ? t('projects.pushBodyNewBranch', {
            branch: status.branch,
            target,
            host,
            remote: selected.origin_url,
          })
        : t('projects.pushBody', {
            branch: status.branch,
            host,
            remote: selected.origin_url,
          }),
      [
        { text: t('common.cancel'), style: 'cancel' },
        {
          text: t('projects.confirmPush'),
          onPress: () => {
            if (
              !tasks.owns(confirmation) ||
              tasks.busy ||
              selectedRef.current?.origin_url !== selected.origin_url
            )
              return;
            const task = beginTask('push');
            setError(null);
            setNotice(null);
            const operationId = LocalRuntime.createCompletionRequestId();
            pushOperationId.current = operationId;
            const pushed =
              selected.root !== null
                ? LocalProjects.pushV2({
                    schema_version: 1,
                    root: selected.root,
                    operation_id: operationId,
                    remote: 'origin',
                    expected_local_oid: status.head_oid,
                    credential_reference: 'panel',
                    https_proxy_url: preferences.gitHttpsProxyUrl,
                  }).then(result => ({ ...legacyShaped(result), receipt: undefined }))
                : LocalProjects.push(selected.id, {
                    httpsProxyUrl: preferences.gitHttpsProxyUrl,
                    ...(newBranch ? { branch: target } : {}),
                  });
            pushed
              .then(result => {
                if (!tasks.owns(task)) return;
                setNotice(t('projects.pushSuccess'));
                setPushBranch(current =>
                  current.trim() === target ? '' : current,
                );
                if (result.receipt !== undefined) {
                  setReceipt(result.receipt);
                }
                return loadDetail(selected);
              })
              .catch(caught => {
                if (!tasks.owns(task)) return;
                const code = errorCode(caught);
                if (code === 'non-fast-forward' || code === 'E_PROJECT_NON_FAST_FORWARD') {
                  setError(t('projects.pushNonFastForward'));
                } else if (code === 'E_PROJECT_PROXY') {
                  setError(t('projects.proxyFailed', { proxy: preferences.gitHttpsProxyUrl ?? '' }));
                } else if (code === 'rejected' || code === 'E_PROJECT_CREDENTIAL') {
                  setError(t('projects.pushRejected'));
                } else if (code === 'conflict') {
                  setError(t('projects.pushBranchConflict'));
                } else if (code === 'timeout' || code === 'E_PROJECT_TIMEOUT') {
                  setError(t('projects.pushTimeout'));
                } else if (code === 'cancelled' || code === 'E_PROJECT_CANCELLED') {
                  setError(t('projects.pushCancelled'));
                } else if (code === 'E_PROJECT_UNAVAILABLE' && selected.root !== null) {
                  setError(t('projects.pushCredentialMissing'));
                } else if (code === 'E_PROJECT_CONFLICT' && selected.root !== null) {
                  setError(t('projects.pushHeadChanged'));
                } else {
                  setError(
                    t('projects.operationFailed', {
                      error: errorText(caught),
                    }),
                  );
                }
              })
              .finally(() => {
                if (pushOperationId.current === operationId) {
                  pushOperationId.current = null;
                }
                finishTask(task);
              });
          },
        },
      ],
    );
  }, [
    beginTask,
    finishTask,
    loadDetail,
    preferences.gitHttpsProxyUrl,
    pushBranch,
    selected,
    status,
    t,
    tasks,
  ]);

  /** `git fetch origin` for a workspace project: what the remote holds now, and how far behind the branch is. */
  const fetchRemote = useCallback(async () => {
    if (
      selected === null ||
      selected.root === null ||
      selectedRef.current?.id !== selected.id ||
      selected.origin_url === null ||
      !tasks.visible ||
      tasks.busy
    )
      return;
    const task = beginTask('push');
    const operationId = LocalRuntime.createCompletionRequestId();
    pushOperationId.current = operationId;
    setError(null);
    setNotice(null);
    try {
      const result = await LocalProjects.fetchV2({
        schema_version: 1,
        root: selected.root,
        operation_id: operationId,
        remote: 'origin',
        https_proxy_url: preferences.gitHttpsProxyUrl,
      });
      if (!tasks.owns(task)) return;
      setFetched(
        result.remote_oid === null
          ? null
          : { projectId: selected.id, branch: result.branch, remoteOid: result.remote_oid },
      );
      setNotice(
        result.remote_oid === null
          ? t('projects.fetchedNothing')
          : t('projects.fetched', { ahead: result.ahead, behind: result.behind }),
      );
      await loadDetail(selected);
    } catch (caught) {
      if (!tasks.owns(task)) return;
      const code = errorCode(caught);
      if (code === 'E_PROJECT_PROXY') setError(t('projects.proxyFailed', { proxy: preferences.gitHttpsProxyUrl ?? '' }));
      else if (code === 'E_PROJECT_CREDENTIAL') setError(t('projects.pushRejected'));
      else if (code === 'E_PROJECT_TIMEOUT') setError(t('projects.pushTimeout'));
      else if (code === 'E_PROJECT_CANCELLED') setError(t('projects.pushCancelled'));
      else setError(t('projects.operationFailed', { error: errorText(caught) }));
    } finally {
      if (pushOperationId.current === operationId) pushOperationId.current = null;
      finishTask(task);
    }
  }, [beginTask, finishTask, loadDetail, preferences.gitHttpsProxyUrl, selected, t, tasks]);

  /** Moves the branch to origin's tip only as a fast-forward over an unchanged tree. */
  const pullFastForward = useCallback(async () => {
    if (
      selected === null ||
      selected.root === null ||
      selectedRef.current?.id !== selected.id ||
      status === null ||
      status.head_oid === null ||
      !tasks.visible ||
      tasks.busy
    )
      return;
    const task = beginTask('mutation');
    setError(null);
    setNotice(null);
    try {
      const pulled = await LocalProjects.pullFastForwardV2({
        schema_version: 1,
        root: selected.root,
        expected_head_oid: status.head_oid,
      });
      if (!tasks.owns(task)) return;
      setNotice(
        pulled.updated
          ? t('projects.pulled', { oid: pulled.oid.slice(0, 12) })
          : t('projects.pullUpToDate'),
      );
      await loadDetail(selected);
    } catch (caught) {
      if (!tasks.owns(task)) return;
      const code = errorCode(caught);
      if (code === 'E_PROJECT_NON_FAST_FORWARD')
        setError(t(LocalProjects.isMergeAvailable() ? 'projects.pullDivergedMerge' : 'projects.pullDiverged'));
      else if (code === 'E_PROJECT_CONFLICT') setError(t('projects.pullDirty'));
      else if (code === 'E_WORKSPACE_CONFIRMATION') setError(t('projects.pullNothingFetched'));
      else setError(t('projects.operationFailed', { error: errorText(caught) }));
    } finally {
      finishTask(task);
    }
  }, [beginTask, finishTask, loadDetail, selected, status, t, tasks]);

  /** Whether the fetched upstream can be merged into this diverged branch from here. */
  const mergeable =
    selected !== null &&
    selected.root !== null &&
    status !== null &&
    status.head_oid !== null &&
    status.branch !== null &&
    status.ahead > 0 &&
    status.behind > 0 &&
    fetched !== null &&
    fetched.projectId === selected.id &&
    fetched.branch === status.branch &&
    LocalProjects.isMergeAvailable();

  /**
   * Merges what the person fetched into a diverged branch, only when the
   * merge is clean: a conflict, or a file in the way, is reported and
   * nothing is written.
   */
  const mergeRemote = useCallback(() => {
    if (
      !mergeable ||
      selected === null ||
      selected.root === null ||
      status === null ||
      status.head_oid === null ||
      status.branch === null ||
      fetched === null ||
      !tasks.visible ||
      tasks.busy
    )
      return;
    if (authorName.trim().length === 0 || authorEmail.trim().length === 0) {
      setError(t('projects.mergeNeedsAuthor'));
      return;
    }
    const root = selected.root;
    const branch = status.branch;
    const head = status.head_oid;
    const theirs = fetched.remoteOid;
    const signedName = authorName.trim();
    const signedEmail = authorEmail.trim();
    const confirmation = tasks.begin('mutation');
    tasks.finish(confirmation);
    Alert.alert(
      t('projects.mergeTitle'),
      t('projects.mergeBody', { branch }),
      [
        { text: t('common.cancel'), style: 'cancel' },
        {
          text: t('projects.mergeConfirm'),
          onPress: () => {
            if (!tasks.owns(confirmation) || tasks.busy) return;
            const task = beginTask('mutation');
            setError(null);
            setNotice(null);
            LocalProjects.mergeRemoteV2({
              schema_version: 1,
              root,
              operation_id: LocalRuntime.createCompletionRequestId(),
              expected_branch: branch,
              expected_head_oid: head,
              expected_remote_oid: theirs,
              author_name: signedName,
              author_email: signedEmail,
            })
              .then(async merged => {
                if (!tasks.owns(task)) return;
                const listed = (paths: string[]) => paths.slice(0, 8).join(', ') +
                  (paths.length > 8 ? ` +${paths.length - 8}` : '');
                // Only a merge changed anything; the refusals leave the view
                // as it was, so their message is not wiped by a reload.
                if (merged.outcome === 'merged') {
                  await loadDetail(selected);
                  if (!tasks.owns(task)) return;
                  setNotice(t('projects.merged', { oid: merged.oid.slice(0, 12) }));
                } else if (merged.outcome === 'up_to_date') {
                  setNotice(t('projects.pullUpToDate'));
                } else if (merged.outcome === 'fast_forward_available') {
                  setNotice(t('projects.mergeFastForward'));
                } else if (merged.outcome === 'conflicts') {
                  setError(t('projects.mergeConflicts', {
                    paths: listed(merged.conflicts.map(entry => entry.ours ?? entry.theirs ?? entry.ancestor ?? '')),
                  }));
                } else {
                  setError(t('projects.mergeObstructed', { paths: listed(merged.paths) }));
                }
              })
              .catch(caught => {
                if (!tasks.owns(task)) return;
                const code = errorCode(caught);
                if (code === 'E_PROJECT_CONFLICT') setError(t('projects.pullDirty'));
                else if (code === 'E_WORKSPACE_CONFIRMATION') setError(t('projects.mergeStale'));
                else if (code === 'E_PROJECT_MERGE_UNSUPPORTED') setError(t('projects.mergeUnsupported'));
                else if (code === 'E_PROJECT_RECOVERY_REQUIRED') setError(t('projects.mergeRecovery'));
                else setError(t('projects.operationFailed', { error: errorText(caught) }));
              })
              .finally(() => finishTask(task));
          },
        },
      ],
    );
  }, [
    authorEmail,
    authorName,
    beginTask,
    fetched,
    finishTask,
    loadDetail,
    mergeable,
    selected,
    status,
    t,
    tasks,
  ]);

  const cancelPush = useCallback(() => {
    if (selected === null || !pushing) return;
    const operationId = pushOperationId.current;
    if (selected.root !== null) {
      if (operationId === null) return;
      LocalProjects.cancelPushV2({
        schema_version: 1,
        root: selected.root,
        operation_id: operationId,
      }).catch(() => undefined);
      return;
    }
    LocalProjects.cancelPush(selected.id).catch(() => undefined);
  }, [pushing, selected]);

  const title = selected?.name ?? t('projects.title');

  return (
    <SlidingSurface
      accessibilityHidden={covered}
      accessibilityLabel={title}
      closeAccessibilityLabel={t('projects.close')}
      onClose={closeSurface}
      onDismiss={onDismiss}
      scrim={false}
      side="right"
      visible={visible}
      widthRatio={1}
    >
      <View
        onLayout={event => setContainerWidth(event.nativeEvent.layout.width)}
        style={[
          styles.root,
          { paddingTop: insets.top + 8, paddingBottom: insets.bottom + 10 },
        ]}
      >
        <View style={styles.header}>
          {selected === null ? (
            <View style={styles.headerSpacer} />
          ) : (
            <Pressable
              accessibilityLabel={t('projects.back')}
              accessibilityRole="button"
              hitSlop={hitSlop}
              onPress={() => {
                selectView(null);
                setError(null);
                setNotice(null);
                loadProjects().catch(() => undefined);
              }}
              style={({ pressed }) => [
                styles.headerButton,
                pressed && styles.pressed,
              ]}
              testID="projects-back"
            >
              <AppIcon color={colors.text} icon={ChevronLeft} size={21} />
            </Pressable>
          )}
          <View style={styles.headerTitleWrap} testID="projects-detail-title">
            <Text numberOfLines={1} style={styles.headerTitle}>
              {title}
            </Text>
            <View style={styles.headerCaptionRow}>
              {selected !== null && (
                <AppIcon color={colors.faint} icon={GitBranch} size={11} />
              )}
              <Text numberOfLines={1} style={styles.headerCaption}>
                {selected === null
                  ? t('projects.onDevice')
                  : status === null
                  ? t('projects.loading')
                  : status.branch ?? t('projects.unbornBranch')}
              </Text>
            </View>
          </View>
          <Pressable
            accessibilityLabel={t('projects.close')}
            accessibilityRole="button"
            hitSlop={hitSlop}
            onPress={closeSurface}
            style={({ pressed }) => [
              styles.headerButton,
              pressed && styles.pressed,
            ]}
          >
            <AppIcon color={colors.text} icon={X} size={21} />
          </Pressable>
        </View>

        <View
          style={selected !== null && wideLayout ? styles.wideBody : styles.body}
        >
          {selected !== null && wideLayout && (
            <View style={styles.wideSidebar} testID="projects-wide-change-list">
              <Text style={styles.wideSidebarTitle}>{t('projects.changes')}</Text>
              <ScrollView contentContainerStyle={styles.wideSidebarList}>
                {(diff?.files ?? []).length === 0 ? (
                  <Text style={styles.cardBody}>{t('projects.diffUnavailable')}</Text>
                ) : (
                  (diff?.files ?? []).map(file => (
                    <Pressable
                      key={file.path}
                      accessibilityRole="button"
                      accessibilityLabel={file.path}
                      accessibilityState={{ selected: selectedDiffPath === file.path }}
                      onPress={() => {
                        setSelectedDiffPath(file.path);
                        setTab('changes');
                      }}
                      style={styles.wideSidebarRow}
                    >
                      <Text numberOfLines={2} style={styles.wideSidebarPath}>
                        {file.path}
                      </Text>
                      <Text style={styles.additions}>+{file.additions}</Text>
                      <Text style={styles.deletions}>−{file.deletions}</Text>
                    </Pressable>
                  ))
                )}
              </ScrollView>
            </View>
          )}
          <View style={selected !== null && wideLayout ? styles.wideDetail : undefined}>
        {selected === null ? (
          <ProjectList
            busy={busy || startingClone || cloneIsActive(cloneOperation)}
            cloneUrl={cloneUrl}
            sshCredential={sshCredential}
            sshCredentialBusy={sshCredentialBusyState}
            sshCredentialError={sshCredentialError}
            sshReady={!sshEndpoint(cloneUrl) || sshCredential?.configured === true}
            onConfigureSSH={async () => { const endpoint = sshEndpoint(cloneUrl); if (!endpoint || sshCredentialBusy.current || typeof LocalProjects.beginSSHCredentialImport !== 'function') return; const profileId = sshProfileId(endpoint); const epoch = ++sshCredentialEpoch.current; sshCredentialBusy.current = true; setSshCredentialBusyState(true); setSshCredentialError(null); try { const next = await LocalProjects.beginSSHCredentialImport(profileId, endpoint.host, endpoint.port, endpoint.username); if (epoch === sshCredentialEpoch.current) setSshCredential(next); } catch { if (epoch === sshCredentialEpoch.current) setSshCredentialError(t('projects.sshCredentialError')); } finally { sshCredentialBusy.current = false; setSshCredentialBusyState(false); } }}
            createMode={createMode}
            cloneOperation={cloneOperation}
            onCancelClone={cancelClone}
            workspaceClone={workspaceClone}
            onCancelWorkspaceClone={cancelWorkspaceClone}
            name={name}
            projects={projects}
            styles={styles}
            onChangeCloneUrl={setCloneUrl}
            onChangeName={setName}
            onChooseMode={mode => {
              if (mode === null && cloneStarting.current) {
                cloneCancelOnStart.current = true;
                tasks.invalidate();
                syncBusy();
                return;
              }
              if (mode === null && cloneIsActive(cloneOperationRef.current)) {
                cancelClone().catch(() => undefined);
                return;
              }
              if (mode !== null && cloneIsActive(cloneOperationRef.current))
                return;
              tasks.invalidate();
              syncBusy();
              setCreateMode(mode);
              setError(null);
              setNotice(null);
              setName('');
              setCloneUrl('');
            }}
            onOpenProject={openProject}
            onSubmit={finishCreation}
          />
        ) : diffPage !== null ? (
          <ScrollView contentContainerStyle={styles.detailContent}>
            <ChangesPanel
              busy={busy}
              diff={diff}
              diffMode={diffMode}
              diffPage={diffPage}
              pageHistory={pageHistory}
              onChooseDiffMode={chooseDiffMode}
              selectedPath={selectedDiffPath}
              onSelectPath={setSelectedDiffPath}
              onReviewPage={reviewDiffPage}
              pagingAvailable={selected.root === null}
              status={status}
              styles={styles}
              onStageAll={stageAll}
            />
          </ScrollView>
        ) : (
          <ScrollView
            ref={detailScroll}
            contentContainerStyle={styles.detailContent}
            keyboardDismissMode="interactive"
            keyboardShouldPersistTaps="handled"
          >
            <View style={styles.statusCard}>
              <View style={styles.statusMain}>
                <View
                  style={[
                    styles.statusDot,
                    status?.clean && styles.statusDotClean,
                    status?.has_conflicts && styles.statusDotConflict,
                  ]}
                />
                <View style={styles.flex}>
                  <Text style={styles.statusTitle}>
                    {statusSummary(status, t)}
                  </Text>
                  <Text numberOfLines={1} style={styles.statusMeta}>
                    {status === null
                      ? worktreeLabel
                      : `${status.branch ?? t('projects.unbornBranch')} · ${t(
                          'projects.aheadBehind',
                          {
                            ahead: status.ahead,
                            behind: status.behind,
                          },
                        )}`}
                  </Text>
                </View>
              </View>
              <Pressable
                accessibilityLabel={t('projects.refresh')}
                accessibilityRole="button"
                disabled={busy}
                onPress={() => refresh().catch(() => undefined)}
                style={({ pressed }) => [
                  styles.iconButton,
                  pressed && styles.pressed,
                ]}
              >
                <AppIcon color={colors.textDim} icon={RefreshCw} size={18} />
              </Pressable>
            </View>

            <View style={styles.tabs}>
              {(['files', 'changes'] as const).map(value => {
                const TabIcon = value === 'files' ? FolderOpen : GitCompare;
                const selectedTab = tab === value;
                return (
                  <Pressable
                    accessibilityLabel={t(`projects.${value}`)}
                    accessibilityRole="tab"
                    accessibilityState={{ selected: selectedTab }}
                    key={value}
                    onPress={() => setTab(value)}
                    style={[styles.tab, selectedTab && styles.tabSelected]}
                  >
                    <AppIcon
                      color={selectedTab ? colors.background : colors.muted}
                      icon={TabIcon}
                      size={15}
                    />
                    <Text
                      style={[
                        styles.tabText,
                        selectedTab && styles.tabTextSelected,
                      ]}
                    >
                      {t(`projects.${value}`)}
                    </Text>
                  </Pressable>
                );
              })}
            </View>

            {tab === 'files' ? (
              <View style={styles.card}>
                <Text style={styles.cardTitle}>{t('projects.root')}</Text>
                <Text style={styles.mono}>{worktreeLabel}</Text>
                <Text style={styles.cardBody}>{t('projects.scopedFiles')}</Text>
                <Pressable
                  accessibilityLabel={
                    boundProjectId === selected.id
                      ? t('projects.removeFromChat')
                      : t('projects.chatInProject')
                  }
                  accessibilityRole="button"
                  onPress={
                    boundProjectId === selected.id
                      ? onUnbindFromChat
                      : () => onChatInProject?.(projectOf(selected))
                  }
                  style={({ pressed }) => [
                    styles.primaryButton,
                    pressed && styles.pressed,
                  ]}
                >
                  <Text style={styles.primaryButtonText}>
                    {boundProjectId === selected.id
                      ? t('projects.boundToChat')
                      : t('projects.chatInProject')}
                  </Text>
                </Pressable>
                <Pressable
                  accessibilityLabel={t('projects.openFiles')}
                  accessibilityRole="button"
                  disabled={busy}
                  accessibilityState={{ disabled: busy }}
                  onPress={() => openFiles().catch(() => undefined)}
                  style={({ pressed }) => [
                    styles.secondaryButton,
                    pressed && styles.pressed,
                  ]}
                >
                  <Text style={styles.secondaryButtonText}>
                    {t('projects.openFiles')}
                  </Text>
                </Pressable>
              </View>
            ) : (
              <ChangesPanel
                busy={busy}
                diff={diff}
                diffMode={diffMode}
                diffPage={diffPage}
                pageHistory={pageHistory}
                onChooseDiffMode={chooseDiffMode}
                selectedPath={selectedDiffPath}
                onSelectPath={setSelectedDiffPath}
                onReviewPage={reviewDiffPage}
                pagingAvailable={selected.root === null}
                status={status}
                styles={styles}
                onStageAll={stageAll}
              />
            )}

            <SectionLabel label={t('projects.commitSection')} styles={styles} />
            <View style={styles.card}>
              {hasStagedChanges(status) && (
                <Pressable
                  accessibilityRole="button"
                  accessibilityLabel={t('projects.reviewStaged')}
                  onPress={() => {
                    setTab('changes');
                    chooseDiffMode('staged');
                    detailScroll.current?.scrollTo({ y: 0, animated: true });
                  }}
                  style={styles.secondaryButton}
                >
                  <Text style={styles.secondaryButtonText}>
                    {t('projects.reviewStaged')}
                  </Text>
                </Pressable>
              )}
              <Field
                label={t('projects.commitMessage')}
                multiline
                placeholder={t('projects.commitMessagePlaceholder')}
                styles={styles}
                value={commitMessage}
                onChangeText={setCommitMessage}
              />
              <View style={styles.fieldGap} />
              <Field
                autoCapitalize="words"
                label={t('projects.authorName')}
                placeholder={t('projects.authorName')}
                styles={styles}
                value={authorName}
                onChangeText={setAuthorName}
              />
              <View style={styles.fieldGap} />
              <Field
                autoCapitalize="none"
                keyboardType="email-address"
                label={t('projects.authorEmail')}
                placeholder="name@example.com"
                styles={styles}
                value={authorEmail}
                onChangeText={setAuthorEmail}
              />
              <Pressable
                accessibilityLabel={t('projects.commit')}
                accessibilityRole="button"
                accessibilityState={{
                  disabled:
                    busy ||
                    commitMessage.trim().length === 0 ||
                    authorName.trim().length === 0 ||
                    authorEmail.trim().length === 0 ||
                    !hasStagedChanges(status),
                }}
                disabled={
                  busy ||
                  commitMessage.trim().length === 0 ||
                  authorName.trim().length === 0 ||
                  authorEmail.trim().length === 0 ||
                  !hasStagedChanges(status)
                }
                onPress={() => commit().catch(() => undefined)}
                style={({ pressed }) => [
                  styles.primaryButton,
                  (busy || !hasStagedChanges(status)) && styles.disabled,
                  pressed && styles.pressed,
                ]}
              >
                <Text style={styles.primaryButtonText}>
                  {t('projects.commit')}
                </Text>
              </Pressable>
            </View>

            <SectionLabel label={t('projects.remoteSection')} styles={styles} />
            <View style={styles.card}>
              <Field
                autoCapitalize="none"
                label={t('projects.originUrl')}
                placeholder={t('projects.remoteUrlPlaceholder')}
                styles={styles}
                value={remoteUrl}
                onChangeText={value => {
                  remoteDraftRevision.current += 1;
                  remoteDraftDirty.current =
                    value !== (selectedRef.current?.origin_url ?? '');
                  setRemoteUrl(value);
                }}
              />
              <Pressable
                accessibilityLabel={t('projects.saveRemote')}
                accessibilityRole="button"
                accessibilityState={{
                  disabled: busy || remoteUrl.trim().length === 0,
                }}
                disabled={busy || remoteUrl.trim().length === 0}
                onPress={() => saveRemote().catch(() => undefined)}
                style={({ pressed }) => [
                  styles.secondaryButton,
                  (busy || remoteUrl.trim().length === 0) && styles.disabled,
                  pressed && styles.pressed,
                ]}
              >
                <Text style={styles.secondaryButtonText}>
                  {t('projects.saveRemote')}
                </Text>
              </Pressable>
              {selected.origin_url !== null && (
                <>
                  <View style={styles.credentialRow}>
                    <View style={styles.flex}>
                      <Text style={styles.cardTitle}>
                        {credential?.configured
                          ? credential.expires_at !== undefined
                            ? t('projects.credentialExpires', {
                                time: new Date(
                                  credential.expires_at * 1000,
                                ).toLocaleString(),
                              })
                            : t('projects.credentialStored')
                          : t('projects.configureCredential')}
                      </Text>
                      <Text style={styles.cardBody}>
                        {t('projects.credentialBody')}
                      </Text>
                    </View>
                    <View
                      style={[
                        styles.credentialDot,
                        credential?.configured && styles.statusDotClean,
                      ]}
                    />
                  </View>
                  <Pressable
                    accessibilityLabel={t('projects.configureCredential')}
                    accessibilityRole="button"
                    disabled={busy}
                    onPress={() => configureCredential().catch(() => undefined)}
                    style={({ pressed }) => [
                      styles.secondaryButton,
                      busy && styles.disabled,
                      pressed && styles.pressed,
                    ]}
                  >
                    <Text style={styles.secondaryButtonText}>
                      {t('projects.configureCredential')}
                    </Text>
                  </Pressable>
                  {credential?.configured && (
                    <Pressable
                      accessibilityLabel={t('projects.clearCredential')}
                      accessibilityRole="button"
                      disabled={busy}
                      onPress={() => clearCredential().catch(() => undefined)}
                      style={({ pressed }) => [
                        styles.textButton,
                        busy && styles.disabled,
                        pressed && styles.pressed,
                      ]}
                    >
                      <Text style={styles.textButtonDanger}>
                        {t('projects.clearCredential')}
                      </Text>
                    </Pressable>
                  )}
                  {selected.root === null && (
                    <Field
                      autoCapitalize="none"
                      autoCorrect={false}
                      label={t('projects.pushBranchLabel')}
                      placeholder={t('projects.pushBranchPlaceholder')}
                      styles={styles}
                      value={pushBranch}
                      onChangeText={setPushBranch}
                    />
                  )}
                  {selected.root !== null && (
                    <View style={styles.actionRow}>
                      <Pressable
                        accessibilityLabel={t('projects.fetch')}
                        accessibilityRole="button"
                        accessibilityState={{ disabled: busy }}
                        disabled={busy}
                        onPress={() => fetchRemote().catch(() => undefined)}
                        style={({ pressed }) => [
                          styles.secondaryButton,
                          styles.flex,
                          busy && styles.disabled,
                          pressed && styles.pressed,
                        ]}
                      >
                        <Text style={styles.secondaryButtonText}>
                          {t('projects.fetch')}
                        </Text>
                      </Pressable>
                      <Pressable
                        accessibilityLabel={t('projects.pull')}
                        accessibilityRole="button"
                        accessibilityState={{
                          disabled: busy || status === null || status.head_oid === null || status.behind === 0,
                        }}
                        disabled={busy || status === null || status.head_oid === null || status.behind === 0}
                        onPress={() => pullFastForward().catch(() => undefined)}
                        style={({ pressed }) => [
                          styles.secondaryButton,
                          styles.flex,
                          (busy || status === null || status.head_oid === null || status.behind === 0) &&
                            styles.disabled,
                          pressed && styles.pressed,
                        ]}
                      >
                        <Text style={styles.secondaryButtonText}>
                          {t('projects.pull')}
                        </Text>
                      </Pressable>
                    </View>
                  )}
                  {mergeable && (
                    <Pressable
                      accessibilityLabel={t('projects.merge')}
                      accessibilityRole="button"
                      accessibilityState={{ disabled: busy }}
                      disabled={busy}
                      onPress={mergeRemote}
                      style={({ pressed }) => [
                        styles.secondaryButton,
                        busy && styles.disabled,
                        pressed && styles.pressed,
                      ]}
                    >
                      <Text style={styles.secondaryButtonText}>
                        {t('projects.merge')}
                      </Text>
                    </Pressable>
                  )}
                  <Pressable
                    accessibilityLabel={t('projects.push')}
                    accessibilityRole="button"
                    accessibilityState={{
                      disabled:
                        busy || status === null || status.head_oid === null,
                    }}
                    disabled={
                      busy || status === null || status.head_oid === null
                    }
                    onPress={push}
                    style={({ pressed }) => [
                      styles.primaryButton,
                      (busy || status === null || status.head_oid === null) &&
                        styles.disabled,
                      pressed && styles.pressed,
                    ]}
                  >
                    <Text style={styles.primaryButtonText}>
                      {t('projects.push')}
                    </Text>
                  </Pressable>
                </>
              )}
            </View>

            {selected.origin_url !== null && (
              <View style={styles.card}>
                <Text style={styles.cardTitle}>
                  {t('projects.pushReceiptTitle')}
                </Text>
                {receipt === null ? (
                  <Text style={styles.cardBody}>
                    {t('projects.pushReceiptNone')}
                  </Text>
                ) : (
                  <Text
                    accessibilityLabel={t('projects.pushReceiptBody', {
                      branch: receipt.branch,
                      host: receipt.host,
                      local: receipt.local_oid.slice(0, 12),
                      remote: receipt.remote_oid.slice(0, 12),
                      time: new Date(receipt.pushed_at).toLocaleString(),
                    })}
                    style={styles.mono}
                  >
                    {t('projects.pushReceiptBody', {
                      branch: receipt.branch,
                      host: receipt.host,
                      local: receipt.local_oid.slice(0, 12),
                      remote: receipt.remote_oid.slice(0, 12),
                      time: new Date(receipt.pushed_at).toLocaleString(),
                    })}
                  </Text>
                )}
              </View>
            )}
          </ScrollView>
        )}
          </View>
        </View>

        {(busy || error !== null || notice !== null) && (
          <View
            accessibilityLiveRegion="polite"
            style={[styles.toast, error !== null && styles.toastError]}
          >
            {busy && <ActivityIndicator color={colors.accent} size="small" />}
            <Text
              accessibilityRole={error === null ? undefined : 'alert'}
              numberOfLines={3}
              style={[
                styles.toastText,
                error !== null && styles.toastErrorText,
              ]}
            >
              {error ?? notice ?? t('projects.loading')}
            </Text>
            {pushing && (
              <Pressable
                accessibilityLabel={t('projects.cancelPush')}
                accessibilityRole="button"
                onPress={cancelPush}
                style={({ pressed }) => [
                  styles.toastCancel,
                  pressed && styles.pressed,
                ]}
              >
                <Text style={styles.toastCancelText}>
                  {t('projects.cancelPush')}
                </Text>
              </Pressable>
            )}
          </View>
        )}
      </View>
    </SlidingSurface>
  );
}

function ProjectList({
  cloneOperation,
  onCancelClone,
  busy,
  cloneUrl,
  sshCredential,
  sshCredentialBusy,
  sshCredentialError,
  sshReady,
  onConfigureSSH,
  createMode,
  name,
  projects,
  styles,
  onChangeCloneUrl,
  onChangeName,
  onChooseMode,
  onOpenProject,
  onSubmit,
  workspaceClone,
  onCancelWorkspaceClone,
}: {
  cloneOperation: ProjectCloneOperation | null;
  workspaceClone: { operationId: string; url: string } | null;
  onCancelWorkspaceClone: () => void;
  onCancelClone: () => Promise<void>;
  busy: boolean;
  cloneUrl: string;
  sshCredential: ProjectSSHCredentialStatus | null;
  sshCredentialBusy: boolean;
  sshCredentialError: string | null;
  sshReady: boolean;
  onConfigureSSH: () => Promise<void>;
  createMode: CreateMode;
  name: string;
  projects: ProjectRow[];
  styles: ReturnType<typeof createStyles>;
  onChangeCloneUrl: (value: string) => void;
  onChangeName: (value: string) => void;
  onChooseMode: (mode: CreateMode) => void;
  onOpenProject: (project: ProjectRow) => void;
  onSubmit: (mode: Exclude<CreateMode, null>) => Promise<void>;
}) {
  const { colors, t } = useAppPresentation();
  return (
    <ScrollView
      contentContainerStyle={styles.listContent}
      keyboardDismissMode="interactive"
      keyboardShouldPersistTaps="handled"
    >
      <Text style={styles.lead}>{t('projects.description')}</Text>
      <View style={styles.creationActions}>
        <Pressable
          accessibilityLabel={t('projects.newProject')}
          accessibilityRole="button"
          onPress={() => onChooseMode('create')}
          style={({ pressed }) => [
            styles.creationButton,
            pressed && styles.pressed,
          ]}
          testID="projects-new-project"
        >
          <AppIcon color={colors.accent} icon={FolderPlus} size={23} />
          <Text style={styles.creationTitle}>{t('projects.newProject')}</Text>
        </Pressable>
        <Pressable
          accessibilityLabel={t('projects.cloneRepository')}
          accessibilityRole="button"
          onPress={() => onChooseMode('clone')}
          style={({ pressed }) => [
            styles.creationButton,
            pressed && styles.pressed,
          ]}
          testID="projects-clone-repository"
        >
          <AppIcon color={colors.accent} icon={FolderDown} size={23} />
          <Text style={styles.creationTitle}>
            {t('projects.cloneRepository')}
          </Text>
        </Pressable>
      </View>

      {cloneOperation !== null && (
        <View
          style={styles.formCard}
          testID="projects-clone-progress"
          accessibilityLiveRegion="polite"
        >
          <Text style={styles.formHint}>{cloneOperation.name}</Text>
                <Text style={styles.formHint}>
            {cloneOperation.cancel_requested && cloneIsActive(cloneOperation)
              ? t('projects.cloneCancelling')
              : t(`projects.clonePhase.${cloneOperation.phase}`)}
          </Text>
          {cloneOperation.received_bytes > 0 && (
            <Text style={styles.mono}>
              {t('projects.cloneTransfer', {
                received: cloneOperation.received_objects,
                total: cloneOperation.total_objects,
                kib: Math.ceil(cloneOperation.received_bytes / 1024),
              })}
            </Text>
          )}
          {cloneOperation.total_files > 0 && (
            <Text style={styles.mono}>
              {t('projects.cloneCheckout', {
                completed: cloneOperation.completed_files,
                total: cloneOperation.total_files,
              })}
            </Text>
          )}
          {cloneOperation.error_code === 'timeout' && (
            <Text style={styles.formHint}>{t('projects.cloneTimeout')}</Text>
          )}
          {cloneIsActive(cloneOperation) &&
            !cloneOperation.cancel_requested &&
            cloneOperation.phase !== 'publishing' && (
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={t('projects.cancelClone')}
                onPress={() => {
                  onCancelClone().catch(() => undefined);
                }}
                style={styles.formCancel}
                testID="projects-clone-operation-cancel"
              >
                <Text style={styles.formCancelText}>{t('common.cancel')}</Text>
              </Pressable>
            )}
        </View>
      )}

      {createMode !== null && (
        <View style={styles.formCard}>
          <Field
            autoCapitalize="none"
            label={t('projects.name')}
            placeholder={t('projects.namePlaceholder')}
            styles={styles}
            testID="projects-name-input"
            value={name}
            onChangeText={onChangeName}
          />
          {workspaceClone !== null && (
            <View style={styles.card} testID="projects-workspace-clone">
              <Text style={styles.cardTitle}>{t('projects.cloningWorkspace')}</Text>
              <Text style={styles.cardBody}>{workspaceClone.url}</Text>
              <Pressable
                accessibilityLabel={t('projects.cancelClone')}
                accessibilityRole="button"
                onPress={onCancelWorkspaceClone}
                style={({ pressed }) => [styles.textButton, pressed && styles.pressed]}
              >
                <Text style={styles.textButtonDanger}>{t('common.cancel')}</Text>
              </Pressable>
            </View>
          )}
          {createMode === 'clone' && (
            <>
              <View style={styles.fieldGap} />
              <Field
                autoCapitalize="none"
                label={t('projects.remoteUrl')}
                placeholder={t('projects.remoteUrlPlaceholder')}
                styles={styles}
                testID="projects-remote-url-input"
                value={cloneUrl}
                onChangeText={onChangeCloneUrl}
              />
              <Text style={styles.formHint}>
                {sshEndpoint(cloneUrl) ? t('projects.sshCredentialHint') : t('projects.publicHttpsOnly')}
              </Text>
              {sshEndpoint(cloneUrl) && (
                <Pressable accessibilityRole="button" accessibilityLabel={t('projects.configureSSH')} disabled={sshCredentialBusy} onPress={() => onConfigureSSH().catch(() => undefined)} style={styles.formCancel}>
                  <Text style={styles.formCancelText}>{sshCredentialBusy ? t('projects.sshConfiguring') : sshCredential?.configured ? t('projects.replaceSSH') : t('projects.configureSSH')}</Text>
                </Pressable>
              )}
              {sshCredentialError !== null && <Text style={styles.formHint}>{sshCredentialError}</Text>}
            </>
          )}
          <View style={styles.formActions}>
            <Pressable
              accessibilityLabel={
                createMode === 'clone'
                  ? t('projects.cancelClone')
                  : t('projects.cancelCreate')
              }
              accessibilityRole="button"
              onPress={() => onChooseMode(null)}
              style={styles.formCancel}
              testID="projects-clone-cancel"
            >
              <Text style={styles.formCancelText}>{t('common.cancel')}</Text>
            </Pressable>
            <Pressable
              accessibilityLabel={
                createMode === 'clone'
                  ? t('projects.clone')
                  : t('projects.create')
              }
              accessibilityRole="button"
              accessibilityState={{
                disabled:
                  busy ||
                  (createMode === 'create'
                    ? name.trim().length === 0
                    : cloneUrl.trim().length === 0 || !sshReady),
              }}
              disabled={
                busy ||
                  (createMode === 'create'
                    ? name.trim().length === 0
                    : cloneUrl.trim().length === 0 || !sshReady)
              }
              onPress={() => onSubmit(createMode).catch(() => undefined)}
              style={({ pressed }) => [
                styles.formSubmit,
                busy && styles.disabled,
                pressed && styles.pressed,
              ]}
              testID="projects-clone-submit"
            >
              <Text style={styles.formSubmitText}>
                {createMode === 'clone'
                  ? t('projects.clone')
                  : t('projects.create')}
              </Text>
            </Pressable>
          </View>
        </View>
      )}

      {projects.length === 0 && !busy ? (
        <View style={styles.empty}>
          <Text style={styles.emptyTitle}>{t('projects.emptyTitle')}</Text>
          <Text style={styles.emptyBody}>{t('projects.emptyBody')}</Text>
        </View>
      ) : (
        <View style={styles.projectList}>
          {projects.map(project => (
            <Pressable
              accessibilityLabel={t('projects.open', { name: project.name })}
              accessibilityRole="button"
              key={project.id}
              onPress={() => onOpenProject(project)}
              style={({ pressed }) => [
                styles.projectRow,
                pressed && styles.pressed,
              ]}
              testID={`projects-row-${project.name}`}
            >
              <View style={styles.projectIcon}>
                <AppIcon color={colors.accent} icon={FolderGit2} size={18} />
              </View>
              <View style={styles.flex}>
                <Text numberOfLines={1} style={styles.projectName}>
                  {project.name}
                </Text>
                <Text numberOfLines={1} style={styles.projectMeta}>
                  {project.root !== null
                    ? t('projects.workspaceProject', {
                        workspace: project.workspaceName ?? '',
                      })
                    : project.origin_url === null
                      ? t('projects.local')
                      : project.origin_url}
                </Text>
              </View>
              <AppIcon
                color={colors.faint}
                icon={ChevronRight}
                size={18}
                style={styles.rowChevron}
              />
            </Pressable>
          ))}
        </View>
      )}
      {busy && projects.length === 0 && (
        <View style={styles.loadingCenter}>
          <ActivityIndicator color={colors.accent} />
          <Text style={styles.loadingText}>{t('projects.loading')}</Text>
        </View>
      )}
    </ScrollView>
  );
}

function ChangesPanel({
  diffMode,
  diffPage,
  pageHistory,
  selectedPath,
  onSelectPath,
  onChooseDiffMode,
  onReviewPage,
  busy,
  diff,
  status,
  styles,
  onStageAll,
  readOnly = false,
  pagingAvailable = true,
}: {
  diffMode: DiffMode;
  diffPage: ProjectDiffPage | null;
  pageHistory: number[];
  selectedPath: string | null;
  onSelectPath: (path: string | null) => void;
  onChooseDiffMode: (mode: DiffMode) => void;
  onReviewPage: (
    offset: number,
    snapshot: string | null,
    history: number[],
  ) => Promise<void>;
  /** Paged review is a v1 (legacy project) call; a workspace project's diff is already bounded. */
  pagingAvailable?: boolean;
  busy: boolean;
  diff: ProjectDiff | null;
  status: ProjectGitStatus | null;
  styles: ReturnType<typeof createStyles>;
  onStageAll: () => Promise<void>;
  readOnly?: boolean;
}) {
  const { t } = useAppPresentation();
  if (status?.clean) {
    return (
      <View style={styles.emptyInline}>
        <Text style={styles.emptyTitle}>{t('projects.noChanges')}</Text>
        <Text style={styles.emptyBody}>{t('projects.noChangesBody')}</Text>
      </View>
    );
  }
  const entries = (status?.entries ?? []).filter(entry =>
    hasStatus(
      diffMode === 'staged' ? entry.index_status : entry.worktree_status,
    ),
  );
  const shown = diffPage ?? diff;
  const previewClipped = diffPage === null && (diff?.patch.length ?? 0) > 16000;
  let patch = shown?.patch ?? '';
  if (previewClipped) {
    patch = patch.slice(0, 16000);
    if (/[\uD800-\uDBFF]$/u.test(patch)) patch = patch.slice(0, -1);
  }
  return (
    <View style={styles.card}>
      {!readOnly && diffPage !== null && (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={t('projects.backToChanges')}
          onPress={() => onChooseDiffMode(diffMode)}
          style={styles.formCancel}
        >
          <Text style={styles.formCancelText}>
            {t('projects.backToChanges')}
          </Text>
        </Pressable>
      )}
      <View style={styles.tabs}>
        {(['staged', 'unstaged'] as const).map(mode => (
          <Pressable
            key={mode}
            accessibilityRole="tab"
            accessibilityLabel={t(`projects.diffMode.${mode}`)}
            accessibilityState={{ selected: diffMode === mode }}
            onPress={() => onChooseDiffMode(mode)}
            style={[styles.tab, diffMode === mode && styles.tabSelected]}
          >
            <Text
              style={[
                styles.tabText,
                diffMode === mode && styles.tabTextSelected,
              ]}
            >
              {t(`projects.diffMode.${mode}`)}
            </Text>
          </Pressable>
        ))}
      </View>
      <Text style={styles.cardBody}>{t(`projects.diffScope.${diffMode}`)}</Text>
      {(diffPage === null ? entries : []).map(entry => (
        <Pressable
          key={entry.path}
          accessibilityRole="button"
          accessibilityLabel={entry.path}
          onPress={() => onSelectPath(entry.path)}
          style={[
            styles.changeRow,
            selectedPath === entry.path && styles.changeRowSelected,
          ]}
        >
          <View style={styles.flex}>
            <Text numberOfLines={1} style={styles.changePath}>
              {entry.path}
            </Text>
            <View style={styles.changeLabels}>
              {changeLabels(
                {
                  ...entry,
                  index_status:
                    diffMode === 'staged' ? entry.index_status : 'unmodified',
                  worktree_status:
                    diffMode === 'unstaged'
                      ? entry.worktree_status
                      : 'unmodified',
                },
                t,
              ).map(label => (
                <Text key={label} style={styles.changeKind}>
                  {label}
                </Text>
              ))}
            </View>
          </View>
        </Pressable>
      ))}
      {shown !== null && shown.files.length > 0 && (
        <View style={styles.diffSummary}>
          {shown.files.map(file => (
            <Pressable
              key={file.path}
              accessibilityRole="button"
              accessibilityLabel={file.path}
              onPress={() => onSelectPath(file.path)}
              style={[
                styles.diffFileRow,
                selectedPath === file.path && styles.changeRowSelected,
              ]}
            >
              <Text numberOfLines={1} style={styles.diffFilePath}>
                {file.path}
              </Text>
              <Text style={styles.additions}>+{file.additions}</Text>
              <Text style={styles.deletions}>−{file.deletions}</Text>
            </Pressable>
          ))}
        </View>
      )}
      {(diff?.truncated || previewClipped) && diffPage === null && (
        <Text accessibilityRole="alert" style={styles.cardBody}>
          {t('projects.diffTruncated')}
        </Text>
      )}
      {diffPage !== null && (
        <Text style={styles.cardBody}>
          {t('projects.diffPageNumber', { page: pageHistory.length + 1 })}
        </Text>
      )}
      {diffPage !== null && diffPage.omitted_paths.length > 0 && (
        <Text accessibilityRole="alert" style={styles.cardBody}>
          {t('projects.diffOmitted', {
            paths: diffPage.omitted_paths.join(', '),
          })}
        </Text>
      )}
      {!readOnly && diffPage !== null && (
        <View style={styles.formActions}>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={t('projects.diffPrevious')}
            disabled={busy || pageHistory.length === 0}
            accessibilityState={{ disabled: busy || pageHistory.length === 0 }}
            onPress={() =>
              onReviewPage(
                pageHistory[pageHistory.length - 1] ?? 0,
                diffPage.snapshot_id,
                pageHistory.slice(0, -1),
              ).catch(() => undefined)
            }
            style={[
              styles.formCancel,
              (busy || pageHistory.length === 0) && styles.disabled,
            ]}
          >
            <Text style={styles.formCancelText}>
              {t('projects.diffPrevious')}
            </Text>
          </Pressable>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={t('projects.diffNext')}
            disabled={busy || diffPage.next_offset === null}
            accessibilityState={{
              disabled: busy || diffPage.next_offset === null,
            }}
            onPress={() => {
              if (diffPage.next_offset !== null)
                onReviewPage(diffPage.next_offset, diffPage.snapshot_id, [
                  ...pageHistory,
                  diffPage.page_offset,
                ]).catch(() => undefined);
            }}
            style={[
              styles.formSubmit,
              (busy || diffPage.next_offset === null) && styles.disabled,
            ]}
          >
            <Text style={styles.formSubmitText}>{t('projects.diffNext')}</Text>
          </Pressable>
        </View>
      )}
      {!readOnly && pagingAvailable && diffPage === null && (diff?.files.length ?? 0) > 0 && (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={t('projects.reviewDiffPages')}
          disabled={busy}
          onPress={() => onReviewPage(0, null, []).catch(() => undefined)}
          style={styles.secondaryButton}
        >
          <Text style={styles.secondaryButtonText}>
            {t('projects.reviewDiffPages')}
          </Text>
        </Pressable>
      )}
      <DiffPatch
        key={`${diffMode}:${diffPage?.snapshot_id ?? 'preview'}:${
          diffPage?.page_offset ?? 0
        }`}
        patch={
          selectedPath !== null
            ? patchForPath(patch, selectedPath) ??
              t('projects.diffPageMissing')
            : patch ||
              t(
                diffMode === 'staged'
                  ? 'projects.noStagedDiff'
                  : 'projects.noUnstagedDiff',
              )
        }
        styles={styles}
      />
      {!readOnly && <Pressable
        accessibilityLabel={t('projects.stageAll')}
        accessibilityRole="button"
        accessibilityState={{
          disabled:
            busy ||
            !(
              status?.entries.some(entry => hasStatus(entry.worktree_status)) ??
              false
            ),
        }}
        disabled={
          busy ||
          !(
            status?.entries.some(entry => hasStatus(entry.worktree_status)) ??
            false
          )
        }
        onPress={() => onStageAll().catch(() => undefined)}
        style={({ pressed }) => [
          styles.secondaryButton,
          (busy ||
            !(
              status?.entries.some(entry => hasStatus(entry.worktree_status)) ??
              false
            )) &&
            styles.disabled,
          pressed && styles.pressed,
        ]}
      >
        <Text style={styles.secondaryButtonText}>{t('projects.stageAll')}</Text>
      </Pressable>}
    </View>
  );
}

/** Read-only review fixture used by iPad visual QA; it has no native bridge. */
export function ProjectReviewPreview({
  status,
  diff,
  diffPage = null,
  diffMode: initialMode = 'unstaged',
}: ProjectReviewPreviewProps) {
  const { colors } = useAppPresentation();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const [containerWidth, setContainerWidth] = useState(0);
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const wide = containerWidth >= 900;
  const [mode, setMode] = useState<DiffMode>(initialMode);
  return (
    <View
      onLayout={event => setContainerWidth(event.nativeEvent.layout.width)}
      style={[styles.root, styles.previewRoot]}
    >
      {wide && (
        <View style={styles.wideSidebar} testID="projects-review-preview-file-list">
          <Text style={styles.wideSidebarTitle}>Changed files</Text>
          <ScrollView contentContainerStyle={styles.wideSidebarList}>
            {diff.files.length === 0 ? (
              <Text style={styles.cardBody}>No changed files.</Text>
            ) : (
              diff.files.map(file => (
                <Pressable
                  key={file.path}
                  accessibilityRole="button"
                  accessibilityLabel={file.path}
                  accessibilityState={{ selected: selectedPath === file.path }}
                  onPress={() => setSelectedPath(file.path)}
                  style={[
                    styles.wideSidebarRow,
                    selectedPath === file.path && styles.changeRowSelected,
                  ]}
                >
                  <Text numberOfLines={2} style={styles.wideSidebarPath}>
                    {file.path}
                  </Text>
                  <Text style={styles.additions}>+{file.additions}</Text>
                  <Text style={styles.deletions}>−{file.deletions}</Text>
                </Pressable>
              ))
            )}
          </ScrollView>
        </View>
      )}
      <View style={wide ? styles.wideDetail : styles.previewDetail}>
        <ScrollView contentContainerStyle={styles.detailContent}>
          <ChangesPanel
            busy={false}
            diff={diff}
            diffMode={mode}
            diffPage={diffPage}
            onChooseDiffMode={next => {
              setMode(next);
              setSelectedPath(null);
            }}
            onReviewPage={async () => undefined}
            onSelectPath={setSelectedPath}
            onStageAll={async () => undefined}
            pageHistory={[]}
            readOnly
            selectedPath={selectedPath}
            status={status}
            styles={styles}
          />
        </ScrollView>
      </View>
    </View>
  );
}

function DiffPatch({
  patch,
  styles,
}: {
  patch: string;
  styles: ReturnType<typeof createStyles>;
}) {
  // Keep each source line intact so long lines can be inspected horizontally;
  // the parent surface owns vertical scrolling and page bounds the payload.
  const lines = useMemo(() => patch.split('\n'), [patch]);
  const compact = patch.length <= 4096 && lines.every(line => line.length <= 1024);
  return (
    <ScrollView
      horizontal
      nestedScrollEnabled
      showsHorizontalScrollIndicator
      style={styles.patchScroller}
      contentContainerStyle={styles.patchHorizontal}
    >
      {compact ? (
        <Text selectable style={styles.patch}>{patch}</Text>
      ) : (
        <View>
          {lines.map((line, index) => (
            <View key={index} style={styles.patchLine}>
              {(line.match(/.{1,8192}/gu) ?? ['']).map((part, partIndex) => (
                <Text key={partIndex} selectable style={styles.patch}>
                  {part || ' '}
                </Text>
              ))}
            </View>
          ))}
        </View>
      )}
    </ScrollView>
  );
}

function Field({
  label,
  styles,
  ...props
}: {
  label: string;
  styles: ReturnType<typeof createStyles>;
} & React.ComponentProps<typeof TextInput>) {
  const { colors } = useAppPresentation();
  return (
    <View>
      <Text style={styles.fieldLabel}>{label}</Text>
      <TextInput
        accessibilityLabel={label}
        placeholderTextColor={colors.faint}
        style={[styles.input, props.multiline && styles.multilineInput]}
        textAlignVertical={props.multiline ? 'top' : 'center'}
        {...props}
      />
    </View>
  );
}

function SectionLabel({
  label,
  styles,
}: {
  label: string;
  styles: ReturnType<typeof createStyles>;
}) {
  return <Text style={styles.sectionLabel}>{label.toLocaleUpperCase()}</Text>;
}

const createStyles = (colors: ThemePalette) =>
  StyleSheet.create({
    root: {
      flex: 1,
      backgroundColor: colors.background,
      paddingHorizontal: 18,
    },
    flex: { flex: 1, minWidth: 0 },
    actionRow: { flexDirection: 'row', gap: 8, marginTop: 8 },
    header: {
      height: 58,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'space-between',
    },
    headerSpacer: { width: 42, height: 42 },
    headerTitleWrap: {
      flex: 1,
      minWidth: 0,
      alignItems: 'center',
      paddingHorizontal: 8,
    },
    headerTitle: { color: colors.text, fontSize: 16, fontWeight: '700' },
    headerCaption: {
      flexShrink: 1,
      color: colors.faint,
      fontFamily: fonts.mono,
      fontSize: 8,
      letterSpacing: 1.2,
      textTransform: 'uppercase',
    },
    headerCaptionRow: {
      flexDirection: 'row',
      alignItems: 'center',
      gap: 4,
      marginTop: 3,
      maxWidth: '100%',
    },
    headerButton: {
      width: 42,
      height: 42,
      borderRadius: 21,
      backgroundColor: colors.surface,
      alignItems: 'center',
      justifyContent: 'center',
    },
    listContent: { paddingTop: 12, paddingBottom: 110 },
    body: { flex: 1, minHeight: 0 },
    wideBody: { flex: 1, minHeight: 0, flexDirection: 'row', gap: 14 },
    wideSidebar: {
      width: '32%',
      maxWidth: 340,
      minWidth: 250,
      borderRadius: 18,
      backgroundColor: colors.surface,
      padding: 14,
    },
    wideSidebarTitle: { color: colors.text, fontSize: 13, fontWeight: '800' },
    wideSidebarList: { paddingTop: 10, paddingBottom: 20 },
    wideSidebarRow: {
      minHeight: 44,
      borderBottomWidth: StyleSheet.hairlineWidth,
      borderBottomColor: colors.line,
      flexDirection: 'row',
      alignItems: 'center',
      gap: 8,
    },
    wideSidebarPath: {
      flex: 1,
      minWidth: 0,
      color: colors.textDim,
      fontFamily: fonts.mono,
      fontSize: 12,
    },
    wideDetail: { flex: 1, minWidth: 0 },
    previewRoot: {
      paddingTop: 12,
      paddingBottom: 12,
      flexDirection: 'row',
      gap: 14,
    },
    previewDetail: { flex: 1, minWidth: 0 },
    lead: { color: colors.muted, fontSize: 12, lineHeight: 18 },
    creationActions: { flexDirection: 'row', gap: 10, marginTop: 16 },
    creationButton: {
      flex: 1,
      minHeight: 82,
      borderRadius: 18,
      backgroundColor: colors.surface,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
      padding: 14,
      justifyContent: 'space-between',
    },
    creationTitle: { color: colors.text, fontSize: 13, fontWeight: '700' },
    formCard: {
      borderRadius: 19,
      backgroundColor: colors.surface,
      padding: 14,
      marginTop: 12,
    },
    fieldLabel: {
      color: colors.textDim,
      fontSize: 10,
      fontWeight: '700',
      marginBottom: 7,
    },
    input: {
      minHeight: 44,
      borderRadius: 12,
      backgroundColor: colors.background,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
      color: colors.text,
      fontSize: 13,
      paddingHorizontal: 12,
      paddingVertical: 10,
    },
    multilineInput: { minHeight: 78 },
    fieldGap: { height: 11 },
    formHint: {
      color: colors.muted,
      fontSize: 10,
      lineHeight: 15,
      marginTop: 9,
    },
    formActions: {
      flexDirection: 'row',
      justifyContent: 'flex-end',
      gap: 8,
      marginTop: 12,
    },
    formCancel: {
      minHeight: 44,
      borderRadius: 12,
      backgroundColor: colors.surfaceRaised,
      paddingHorizontal: 15,
      alignItems: 'center',
      justifyContent: 'center',
    },
    formCancelText: { color: colors.textDim, fontSize: 12, fontWeight: '700' },
    formSubmit: {
      minHeight: 44,
      borderRadius: 12,
      backgroundColor: colors.text,
      paddingHorizontal: 16,
      alignItems: 'center',
      justifyContent: 'center',
    },
    formSubmitText: {
      color: colors.background,
      fontSize: 12,
      fontWeight: '800',
    },
    projectList: {
      borderRadius: 19,
      backgroundColor: colors.surface,
      marginTop: 16,
      overflow: 'hidden',
    },
    projectRow: {
      minHeight: 68,
      flexDirection: 'row',
      alignItems: 'center',
      borderBottomWidth: StyleSheet.hairlineWidth,
      borderBottomColor: colors.line,
      paddingHorizontal: 13,
    },
    projectIcon: {
      width: 40,
      height: 40,
      borderRadius: 12,
      backgroundColor: colors.surfaceRaised,
      alignItems: 'center',
      justifyContent: 'center',
      marginRight: 11,
    },
    projectName: { color: colors.text, fontSize: 14, fontWeight: '700' },
    projectMeta: {
      color: colors.muted,
      fontFamily: fonts.mono,
      fontSize: 8,
      marginTop: 4,
    },
    rowChevron: { marginLeft: 10 },
    empty: { alignItems: 'center', paddingVertical: 56, paddingHorizontal: 28 },
    emptyInline: {
      alignItems: 'center',
      borderRadius: 18,
      backgroundColor: colors.surface,
      padding: 28,
    },
    emptyTitle: { color: colors.text, fontSize: 15, fontWeight: '700' },
    emptyBody: {
      color: colors.muted,
      fontSize: 11,
      lineHeight: 17,
      marginTop: 7,
      textAlign: 'center',
    },
    loadingCenter: { alignItems: 'center', paddingVertical: 42, gap: 10 },
    loadingText: { color: colors.muted, fontSize: 11 },
    detailContent: { paddingTop: 8, paddingBottom: 110 },
    statusCard: {
      minHeight: 68,
      borderRadius: 18,
      backgroundColor: colors.surface,
      flexDirection: 'row',
      alignItems: 'center',
      padding: 12,
    },
    statusMain: { flex: 1, flexDirection: 'row', alignItems: 'center' },
    statusDot: {
      width: 9,
      height: 9,
      borderRadius: 5,
      backgroundColor: colors.warning,
      marginRight: 10,
    },
    statusDotClean: { backgroundColor: colors.success },
    statusDotConflict: { backgroundColor: colors.danger },
    statusTitle: { color: colors.text, fontSize: 13, fontWeight: '700' },
    statusMeta: {
      color: colors.muted,
      fontFamily: fonts.mono,
      fontSize: 8,
      marginTop: 4,
    },
    iconButton: {
      width: 40,
      height: 40,
      borderRadius: 12,
      backgroundColor: colors.surfaceRaised,
      alignItems: 'center',
      justifyContent: 'center',
      marginLeft: 9,
    },
    tabs: {
      height: 42,
      borderRadius: 13,
      backgroundColor: colors.surface,
      flexDirection: 'row',
      padding: 4,
      marginTop: 11,
      marginBottom: 11,
    },
    tab: {
      flex: 1,
      borderRadius: 10,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 6,
    },
    tabSelected: { backgroundColor: colors.text },
    tabText: { color: colors.muted, fontSize: 11, fontWeight: '700' },
    tabTextSelected: { color: colors.background },
    card: { borderRadius: 18, backgroundColor: colors.surface, padding: 14 },
    cardTitle: { color: colors.text, fontSize: 13, fontWeight: '700' },
    cardBody: {
      color: colors.muted,
      fontSize: 10,
      lineHeight: 15,
      marginTop: 6,
    },
    mono: {
      color: colors.accent,
      fontFamily: fonts.mono,
      fontSize: 9,
      marginTop: 7,
    },
    primaryButton: {
      minHeight: 44,
      borderRadius: 12,
      backgroundColor: colors.text,
      alignItems: 'center',
      justifyContent: 'center',
      paddingHorizontal: 14,
      marginTop: 13,
    },
    primaryButtonText: {
      color: colors.background,
      fontSize: 12,
      fontWeight: '800',
    },
    secondaryButton: {
      minHeight: 44,
      borderRadius: 12,
      backgroundColor: colors.surfaceRaised,
      alignItems: 'center',
      justifyContent: 'center',
      paddingHorizontal: 14,
      marginTop: 11,
    },
    secondaryButtonText: {
      color: colors.textDim,
      fontSize: 12,
      fontWeight: '700',
    },
    textButton: {
      minHeight: 40,
      alignItems: 'center',
      justifyContent: 'center',
      marginTop: 3,
    },
    textButtonDanger: { color: colors.danger, fontSize: 11, fontWeight: '700' },
    sectionLabel: {
      color: colors.faint,
      fontSize: 9,
      fontWeight: '800',
      letterSpacing: 1.6,
      marginTop: 22,
      marginBottom: 8,
      marginLeft: 4,
    },
    changeRow: {
      minHeight: 50,
      flexDirection: 'row',
      alignItems: 'center',
      borderBottomWidth: StyleSheet.hairlineWidth,
      borderBottomColor: colors.line,
    },
    changeRowSelected: { backgroundColor: colors.surfaceRaised },
    changePath: { color: colors.text, fontFamily: fonts.mono, fontSize: 10 },
    changeLabels: {
      flexDirection: 'row',
      flexWrap: 'wrap',
      gap: 7,
      marginTop: 4,
    },
    changeKind: { color: colors.muted, fontSize: 9 },
    diffSummary: { marginTop: 10 },
    diffFileRow: { flexDirection: 'row', alignItems: 'center', minHeight: 26 },
    diffFilePath: { flex: 1, color: colors.textDim, fontSize: 10 },
    additions: { color: colors.success, fontFamily: fonts.mono, fontSize: 9 },
    deletions: {
      color: colors.danger,
      fontFamily: fonts.mono,
      fontSize: 9,
      marginLeft: 8,
    },
    patchScroller: {
      borderRadius: 12,
      backgroundColor: colors.background,
      marginTop: 10,
    },
    patchHorizontal: { padding: 12 },
    patchLine: { flexDirection: 'row' },
    patch: {
      color: colors.textDim,
      fontFamily: fonts.mono,
      fontSize: 9,
      lineHeight: 14,
      flexShrink: 0,
    },
    credentialRow: {
      flexDirection: 'row',
      alignItems: 'center',
      borderTopWidth: StyleSheet.hairlineWidth,
      borderTopColor: colors.line,
      marginTop: 14,
      paddingTop: 14,
    },
    credentialDot: {
      width: 9,
      height: 9,
      borderRadius: 5,
      backgroundColor: colors.faint,
      marginLeft: 12,
    },
    toast: {
      position: 'absolute',
      left: 18,
      right: 18,
      bottom: 14,
      minHeight: 44,
      borderRadius: 14,
      backgroundColor: colors.surfaceRaised,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
      flexDirection: 'row',
      alignItems: 'center',
      gap: 9,
      paddingHorizontal: 12,
      paddingVertical: 9,
    },
    toastError: {
      backgroundColor: colors.surfaceWarm,
      borderColor: colors.danger,
    },
    toastText: { flex: 1, color: colors.textDim, fontSize: 10, lineHeight: 15 },
    toastErrorText: { color: colors.danger },
    toastCancel: {
      borderRadius: 10,
      backgroundColor: colors.surface,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.line,
      paddingHorizontal: 10,
      paddingVertical: 7,
    },
    toastCancelText: { color: colors.textDim, fontSize: 10, fontWeight: '700' },
    disabled: { opacity: 0.42 },
    pressed: { opacity: 0.62, transform: [{ scale: 0.99 }] },
  });
