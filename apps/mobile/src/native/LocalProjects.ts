import { nativeImplementationAvailable } from './NativeImplementation';
import { NativeModules } from 'react-native';

import {
  assertWorkspaceRootRefV1,
  type WorkspaceRootRefV1,
} from './WorkspaceRoot';
import { normalizeGitHttpsProxyUrl } from '../preferences/gitProxy';

export type LocalProject = {
  schema_version: 1;
  id: string;
  name: string;
  workspace_path: `projects/${string}/repo`;
  created_at: string;
  updated_at: string;
  origin_url: string | null;
};

export type LocalProjectListing = {
  schema_version: 1;
  projects: LocalProject[];
};

export type ProjectFileStatus =
  | 'unmodified'
  | 'added'
  | 'modified'
  | 'deleted'
  | 'renamed'
  | 'typechange'
  | 'unreadable';

export type ProjectStatusEntry = {
  path: string;
  index_status: ProjectFileStatus;
  worktree_status: ProjectFileStatus;
  conflicted: boolean;
};

export type ProjectGitStatus = {
  schema_version: 1;
  project_id: string;
  branch: string | null;
  head_oid: string | null;
  clean: boolean;
  has_conflicts: boolean;
  ahead: number;
  behind: number;
  entries: ProjectStatusEntry[];
};

export type ProjectDiffFile = {
  path: string;
  status: ProjectFileStatus;
  additions: number;
  deletions: number;
};

export type ProjectDiff = {
  schema_version: 1;
  project_id: string;
  staged: boolean;
  truncated: boolean;
  patch: string;
  files: ProjectDiffFile[];
};

export type ProjectDiffPage = ProjectDiff & {
  page_offset: number;
  next_offset: number | null;
  snapshot_id: string;
  omitted_paths: string[];
};

export type ProjectDiffOptions = {
  staged?: boolean;
  contextLines?: number;
};

export type ProjectCommitInput = {
  message: string;
  authorName: string;
  authorEmail: string;
};

export type ProjectCommit = {
  schema_version: 1;
  project_id: string;
  oid: string;
  summary: string;
  committed_at: string;
};

export type ProjectRemote = {
  schema_version: 1;
  project_id: string;
  name: 'origin';
  url: string;
};

export type ProjectCredentialStatus = {
  schema_version: 1;
  project_id: string;
  host: string;
  configured: boolean;
  /** Absolute Keychain expiry (unix seconds) when configured. */
  expires_at?: number;
  /** Expiry window chosen at provisioning time, in seconds. */
  expiry_seconds?: number;
};

export type ProjectPushReceipt = {
  schema_version: 1;
  remote: 'origin';
  host: string;
  branch: string;
  local_oid: string;
  remote_oid: string;
  pushed_at: string;
};

export type ProjectPushReceipts = {
  schema_version: 1;
  project_id: string;
  receipts: ProjectPushReceipt[];
};

export type ProjectPushResult = {
  schema_version: 1;
  project_id: string;
  remote: 'origin';
  branch: string;
  oid: string;
  pushed_at: string;
  receipt?: ProjectPushReceipt;
};

export type LocalProjectDescriptorV2 = {
  schema_version: 2;
  project_id: string;
  workspace_id: string;
  workspace_binding_revision: number;
  display_name: string;
  git_topology: 'legacy_embedded' | 'private_split_gitdir';
};

export type AttachWorkspaceProjectRequestV1 = {
  schema_version: 1;
  operation_id: string;
  root: WorkspaceRootRefV1;
  mode: 'open' | 'init';
};

export type AttachWorkspaceProjectResultV1 = {
  schema_version: 1;
  status: 'attached' | 'already_attached';
  project: LocalProjectDescriptorV2;
};

export type ProjectForWorkspaceResultV1 =
  | { schema_version: 1; status: 'none' }
  | { schema_version: 1; status: 'attached'; project: LocalProjectDescriptorV2 };

export type ProjectDetachCheckpointV1 = {
  schema_version: 1;
  checkpoint_id: string;
  project_id: string;
  workspace_id: string;
  binding_revision: number;
  gitdir_sha256: string;
  mode: 'retain_private_gitdir' | 'delete_private_gitdir';
  created_at: string;
};

export type PrepareProjectDetachRequestV1 = {
  schema_version: 1;
  operation_id: string;
  root: WorkspaceRootRefV1;
  mode: ProjectDetachCheckpointV1['mode'];
};

export type CommitProjectDetachRequestV1 = {
  schema_version: 1;
  operation_id: string;
  checkpoint: ProjectDetachCheckpointV1;
  clearance_receipt_id: string;
};

export type GitWorkspaceRequestV1 = {
  schema_version: 1;
  root: WorkspaceRootRefV1;
};

export type GitDiffRequestV1 = GitWorkspaceRequestV1 & {
  max_bytes: number;
  /** The index against HEAD when true; the working tree against the index otherwise. */
  staged: boolean;
};

export type GitCommitRequestV1 = GitWorkspaceRequestV1 & {
  operation_id: string;
  message: string;
  author_name: string;
  author_email: string;
  expected_head_oid: string | null;
};

export type GitPushRequestV1 = GitWorkspaceRequestV1 & {
  operation_id: string;
  remote: 'origin';
  expected_local_oid: string;
  credential_reference: string;
  https_proxy_url: string | null;
};

export type ProjectGitStatusV2 = Omit<ProjectGitStatus, 'schema_version'> & {
  schema_version: 2;
  root: WorkspaceRootRefV1;
};

export type ProjectDiffV2 = Omit<ProjectDiff, 'schema_version'> & {
  schema_version: 2;
  root: WorkspaceRootRefV1;
};

export type ProjectCommitV2 = Omit<ProjectCommit, 'schema_version'> & {
  schema_version: 2;
  root: WorkspaceRootRefV1;
};

export type ProjectPushResultV2 = Omit<ProjectPushResult, 'schema_version'> & {
  schema_version: 2;
  root: WorkspaceRootRefV1;
};

export type GitRemoteRequestV1 = GitWorkspaceRequestV1 & {
  url: string;
};

export type GitCredentialPromptRequestV1 = GitWorkspaceRequestV1 & {
  locale: 'zh-CN' | 'en';
};

export type GitCancelPushRequestV1 = GitWorkspaceRequestV1 & {
  operation_id: string;
};

export type GitFetchRequestV1 = GitWorkspaceRequestV1 & {
  operation_id: string;
  remote: 'origin';
};

export type GitPullRequestV1 = GitWorkspaceRequestV1 & {
  expected_head_oid: string;
};

/**
 * A merge of the upstream the person just fetched into a diverged branch.
 * Bound to what they reviewed: the branch by name, the local tip, and the
 * fetched upstream tip -- two branches can share a commit, and a later
 * fetch can move the upstream.
 */
export type GitMergeRequestV1 = GitWorkspaceRequestV1 & {
  operation_id: string;
  expected_branch: string;
  expected_head_oid: string;
  expected_remote_oid: string;
  author_name: string;
  author_email: string;
};

/** One conflicting entry: each side's path, or null where that side has none. */
export type ProjectMergeConflictV2 = {
  ancestor: string | null;
  ours: string | null;
  theirs: string | null;
};

/**
 * What a merge did. Only `merged` changed anything; the rest leave the
 * branch, index and working tree exactly as they were.
 */
export type ProjectMergeResultV2 = {
  schema_version: 2;
  root: WorkspaceRootRefV1;
  project_id: string;
  branch: string;
  outcome: 'merged' | 'up_to_date' | 'fast_forward_available' | 'conflicts' | 'obstructed';
  oid: string;
  previous_oid: string;
  conflicts: ProjectMergeConflictV2[];
  paths: string[];
};

/** What origin holds for the current branch after a fetch, and where the local branch stands. */
export type ProjectFetchResultV2 = {
  schema_version: 2;
  root: WorkspaceRootRefV1;
  project_id: string;
  remote: 'origin';
  branch: string;
  remote_oid: string | null;
  ahead: number;
  behind: number;
  fetched_at: string;
};

export type ProjectPushReceiptsV2 = {
  schema_version: 2;
  root: WorkspaceRootRefV1;
  project_id: string;
  receipts: ProjectPushReceipt[];
};

export type WorkspaceCloneRequestV1 = {
  schema_version: 1;
  operation_id: string;
  url: string;
  display_name: string;
  /** `prompt`: use the credential typed for this operation id (see presentCloneCredentialPromptV2). */
  credential_reference?: 'prompt';
};

/** What the clone credential prompt answers: never the secret. */
export type WorkspaceCloneCredentialV2 = {
  schema_version: 2;
  operation_id: string;
  host: string;
  expiry_seconds: number;
};

/** A public repository cloned into a new workspace with a project attached. */
export type WorkspaceCloneResultV2 = {
  schema_version: 2;
  root: WorkspaceRootRefV1;
  project: LocalProjectDescriptorV2;
  workspace: { workspace_id: string; display_name: string };
  branch: string;
  oid: string;
};

/** A fast-forward: `updated` is false when the branch was already at origin's tip. */
export type ProjectPullResultV2 = {
  schema_version: 2;
  root: WorkspaceRootRefV1;
  project_id: string;
  branch: string;
  oid: string;
  previous_oid: string;
  updated: boolean;
};

/** The origin of a workspace project: `url` and `host` are null together when none is set. */
export type ProjectRemoteV2 = {
  schema_version: 2;
  root: WorkspaceRootRefV1;
  project_id: string;
  remote: 'origin';
  url: string | null;
  host: string | null;
};

export type ProjectCredentialStatusV2 = Omit<ProjectCredentialStatus, 'schema_version'> & {
  schema_version: 2;
  root: WorkspaceRootRefV1;
};

export type ProjectPushCancellationV2 = {
  schema_version: 2;
  root: WorkspaceRootRefV1;
  project_id: string;
  operation_id: string;
  status: 'cancel_requested' | 'not_running';
};

export type ProjectGitTransportOptions = {
  httpsProxyUrl?: string | null;
  sshProfileId?: string | null;
};

export type ProjectSSHCredentialStatus = {
  profile_id: string;
  host: string;
  port: number;
  username: string;
  configured: boolean;
  key_fingerprint?: string;
};

export type ProjectPushOptions = ProjectGitTransportOptions & {
  /** Publish HEAD under this new local branch name instead of the current one. */
  branch?: string;
};

export type ProjectPushCancellation = {
  schema_version: 1;
  project_id: string;
  cancelled: boolean;
};

export type ProjectClonePhase =
  | 'queued'
  | 'connecting'
  | 'receiving'
  | 'checkout'
  | 'validating'
  | 'publishing'
  | 'succeeded'
  | 'failed'
  | 'cancelled';

export type ProjectCloneOperation = {
  schema_version: 1;
  operation_id: string;
  name: string;
  phase: ProjectClonePhase;
  cancel_requested: boolean;
  received_objects: number;
  total_objects: number;
  received_bytes: number;
  completed_files: number;
  total_files: number;
  project: LocalProject | null;
  error_code: 'timeout' | 'git' | null;
};

type NativeLocalProjects = {
  startClone?(
    url: string,
    name: string | null,
    options: ProjectGitTransportOptions,
  ): Promise<unknown>;
  cloneStatus?(operationId: string | null): Promise<unknown>;
  cancelClone?(operationId: string): Promise<unknown>;

  diffPage?(projectId: string, staged: boolean, offset: number, snapshot: string | null): Promise<unknown>;
  list(): Promise<LocalProjectListing>;
  create(name: string): Promise<LocalProject>;
  clone(
    url: string,
    name: string | null,
    options: ProjectGitTransportOptions,
  ): Promise<LocalProject>;
  status(projectId: string): Promise<ProjectGitStatus>;
  diff(
    projectId: string,
    staged: boolean,
    contextLines: number,
  ): Promise<ProjectDiff>;
  stageAll(projectId: string): Promise<ProjectGitStatus>;
  commit(
    projectId: string,
    message: string,
    authorName: string,
    authorEmail: string,
  ): Promise<ProjectCommit>;
  setRemote(projectId: string, url: string): Promise<ProjectRemote>;
  credentialStatus(projectId: string): Promise<ProjectCredentialStatus>;
  presentCredentialPrompt(
    projectId: string,
    locale: string,
  ): Promise<ProjectCredentialStatus>;
  clearCredential(projectId: string): Promise<ProjectCredentialStatus>;
  beginSSHCredentialImport?(profileId: string, host: string, port: number, username: string): Promise<ProjectSSHCredentialStatus>;
  sshCredentialStatus?(profileId: string): Promise<ProjectSSHCredentialStatus | null>;
  push(
    projectId: string,
    options: ProjectPushOptions,
  ): Promise<ProjectPushResult>;
  pushReceipts(projectId: string): Promise<ProjectPushReceipts>;
  cancelPush(projectId: string): Promise<ProjectPushCancellation>;
  attachWorkspaceProject?(
    request: AttachWorkspaceProjectRequestV1,
  ): Promise<unknown>;
  projectForWorkspaceV2?(root: WorkspaceRootRefV1): Promise<unknown>;
  prepareProjectDetachV1?(
    request: PrepareProjectDetachRequestV1,
  ): Promise<unknown>;
  commitProjectDetachV1?(
    request: CommitProjectDetachRequestV1,
  ): Promise<unknown>;
  statusV2?(request: GitWorkspaceRequestV1): Promise<unknown>;
  diffV2?(request: GitDiffRequestV1): Promise<unknown>;
  stageAllV2?(request: GitWorkspaceRequestV1): Promise<unknown>;
  commitV2?(request: GitCommitRequestV1): Promise<unknown>;
  pushV2?(request: GitPushRequestV1): Promise<unknown>;
  setRemoteV2?(request: GitRemoteRequestV1): Promise<unknown>;
  remoteV2?(request: GitWorkspaceRequestV1): Promise<unknown>;
  credentialStatusV2?(request: GitWorkspaceRequestV1): Promise<unknown>;
  presentCredentialPromptV2?(request: GitCredentialPromptRequestV1): Promise<unknown>;
  clearCredentialV2?(request: GitWorkspaceRequestV1): Promise<unknown>;
  cancelPushV2?(request: GitCancelPushRequestV1): Promise<unknown>;
  fetchV2?(request: GitFetchRequestV1): Promise<unknown>;
  pullFastForwardV2?(request: GitPullRequestV1): Promise<unknown>;
  mergeRemoteV2?(request: GitMergeRequestV1): Promise<unknown>;
  pushReceiptsV2?(request: GitWorkspaceRequestV1): Promise<unknown>;
  cloneWorkspaceV2?(request: WorkspaceCloneRequestV1): Promise<unknown>;
  cancelWorkspaceCloneV2?(request: { schema_version: 1; operation_id: string }): Promise<unknown>;
  presentCloneCredentialPromptV2?(request: {
    schema_version: 1; operation_id: string; url: string; locale: 'zh-CN' | 'en';
  }): Promise<unknown>;
};

const native = NativeModules.LocalProjects as unknown;

const projectV2ErrorCodes = new Set([
  'E_PROJECT_REQUEST_INVALID',
  'E_PROJECT_RESULT_INVALID',
  'E_PROJECT_NATIVE',
  'E_PROJECT_BUSY',
  'E_PROJECT_UNAVAILABLE',
  'E_PROJECT_STORAGE_UNSAFE',
  'E_PROJECT_CONFLICT',
  'E_WORKSPACE_INVALID',
  'E_WORKSPACE_NOT_FOUND',
  'E_WORKSPACE_BUSY',
  'E_WORKSPACE_REVISION_STALE',
  'E_WORKSPACE_REVOKED',
  'E_WORKSPACE_UNAVAILABLE',
  'E_WORKSPACE_CAPABILITY',
  'E_WORKSPACE_ROOT_CHANGED',
  'E_WORKSPACE_CONFLICT',
  'E_WORKSPACE_CONFIRMATION',
  'E_WORKSPACE_PERSISTENCE',
  'E_WORKSPACE_IO',
  'E_PROJECT_NON_FAST_FORWARD',
  'E_PROJECT_CREDENTIAL',
  'E_PROJECT_TIMEOUT',
  'E_PROJECT_CANCELLED',
  'E_PROJECT_MERGE_UNSUPPORTED',
  'E_PROJECT_RECOVERY_REQUIRED',
]);

export class ProjectGitBridgeError extends Error {
  readonly code: string;

  constructor(code: string) {
    super(code);
    this.name = 'ProjectGitBridgeError';
    this.code = code;
  }
}

function projectV2Fail(code: string): never {
  throw new ProjectGitBridgeError(code);
}

function projectV2Error(error: unknown): ProjectGitBridgeError {
  try {
    if (typeof error === 'object' && error !== null) {
      const descriptor = Object.getOwnPropertyDescriptor(error, 'code');
      if (
        descriptor !== undefined &&
        'value' in descriptor &&
        typeof descriptor.value === 'string' &&
        projectV2ErrorCodes.has(descriptor.value)
      ) {
        return new ProjectGitBridgeError(descriptor.value);
      }
    }
  } catch {
    // Hostile errors collapse to the value-free project code.
  }
  return new ProjectGitBridgeError('E_PROJECT_NATIVE');
}

type ProjectV2Record = Record<string, unknown>;
const projectV2ObjectPrototype = Object.prototype;
const projectV2ArrayPrototype = Array.prototype;
const projectV2ArrayMap = Array.prototype.map;

function projectV2ExactRecord(
  value: unknown,
  keys: readonly string[],
  code: string,
): ProjectV2Record {
  if (
    typeof value !== 'object' ||
    value === null ||
    Array.isArray(value) ||
    Object.getPrototypeOf(value) !== projectV2ObjectPrototype ||
    Object.getPrototypeOf(projectV2ObjectPrototype) !== null ||
    Object.getPrototypeOf(projectV2ArrayPrototype) !== projectV2ObjectPrototype ||
    Object.prototype.hasOwnProperty.call(projectV2ObjectPrototype, 'toJSON') ||
    Object.prototype.hasOwnProperty.call(projectV2ArrayPrototype, 'toJSON')
  ) {
    return projectV2Fail(code);
  }
  const names = Object.getOwnPropertyNames(value);
  if (names.length !== keys.length || names.some(name => !keys.includes(name))) {
    return projectV2Fail(code);
  }
  if (Object.getOwnPropertySymbols(value).length > 0) return projectV2Fail(code);
  const result = Object.create(null) as ProjectV2Record;
  for (const key of keys) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (
      descriptor === undefined ||
      !('value' in descriptor) ||
      descriptor.enumerable !== true
    ) {
      return projectV2Fail(code);
    }
    result[key] = descriptor.value;
  }
  return result;
}

function projectV2Array(
  value: unknown,
  maximum: number,
  code: string,
): unknown[] {
  if (
    !Array.isArray(value) ||
    Object.getPrototypeOf(value) !== projectV2ArrayPrototype
  ) {
    return projectV2Fail(code);
  }
  const lengthDescriptor = Object.getOwnPropertyDescriptor(value, 'length');
  if (
    lengthDescriptor === undefined ||
    !('value' in lengthDescriptor) ||
    !Number.isSafeInteger(lengthDescriptor.value) ||
    lengthDescriptor.value < 0 ||
    lengthDescriptor.value > maximum ||
    Object.getOwnPropertySymbols(value).length > 0 ||
    Object.getOwnPropertyDescriptor(projectV2ArrayPrototype, 'map')?.value !==
      projectV2ArrayMap ||
    Object.prototype.hasOwnProperty.call(projectV2ArrayPrototype, 'toJSON') ||
    Object.prototype.hasOwnProperty.call(projectV2ObjectPrototype, 'toJSON')
  ) {
    return projectV2Fail(code);
  }
  const length = lengthDescriptor.value as number;
  const result: unknown[] = [];
  const allowed = new Set(['length']);
  for (let index = 0; index < length; index += 1) {
    const key = String(index);
    allowed.add(key);
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (
      descriptor === undefined ||
      !('value' in descriptor) ||
      descriptor.enumerable !== true
    ) {
      return projectV2Fail(code);
    }
    result[index] = descriptor.value;
  }
  if (Object.getOwnPropertyNames(value).some(name => !allowed.has(name))) {
    return projectV2Fail(code);
  }
  return result;
}

function projectV2UUID(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value)
  );
}

function projectV2Digest(value: unknown): value is string {
  return typeof value === 'string' && /^[0-9a-f]{64}$/u.test(value);
}

function projectV2OID(value: unknown, nullable = false): value is string | null {
  return value === null && nullable ||
    typeof value === 'string' && /^[0-9a-f]{40}$/u.test(value);
}

function projectV2Timestamp(value: unknown): value is string {
  if (
    typeof value !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/u.test(value)
  ) {
    return false;
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed);
}

function projectV2SafeInteger(value: unknown, minimum = 0): value is number {
  return (
    typeof value === 'number' &&
    Number.isSafeInteger(value) &&
    !Object.is(value, -0) &&
    value >= minimum
  );
}

function projectV2UTF8Bytes(value: string): number | null {
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit <= 0x7f) bytes += 1;
    else if (unit <= 0x7ff) bytes += 2;
    else if (unit >= 0xd800 && unit <= 0xdbff) {
      const low = value.charCodeAt(index + 1);
      if (low < 0xdc00 || low > 0xdfff) return null;
      bytes += 4;
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return null;
    } else bytes += 3;
  }
  return bytes;
}

function projectV2String(value: unknown, maximum: number, allowEmpty = false): value is string {
  if (typeof value !== 'string' || (!allowEmpty && value.length === 0)) return false;
  const bytes = projectV2UTF8Bytes(value);
  if (bytes === null || bytes > maximum) return false;
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit <= 0x1f || (unit >= 0x7f && unit <= 0x9f)) return false;
  }
  return true;
}

function projectV2Text(value: unknown, maximum: number, allowEmpty = false): value is string {
  if (typeof value !== 'string' || (!allowEmpty && value.length === 0)) return false;
  const bytes = projectV2UTF8Bytes(value);
  if (bytes === null || bytes > maximum) return false;
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if ((unit <= 0x1f && unit !== 0x09 && unit !== 0x0a && unit !== 0x0d) ||
        (unit >= 0x7f && unit <= 0x9f)) return false;
  }
  return true;
}

function projectV2Email(value: unknown): value is string {
  if (!projectV2String(value, 254)) return false;
  const parts = value.split('@');
  return (
    parts.length === 2 &&
    parts[0] !== undefined &&
    parts[1] !== undefined &&
    parts[0].length > 0 &&
    parts[1].length > 0 &&
    !value.includes(' ') &&
    !value.includes('<') &&
    !value.includes('>')
  );
}

function projectV2ProxyURL(value: unknown): string | null {
  if (value === null) return null;
  const normalized = normalizeGitHttpsProxyUrl(value);
  if (normalized === null) return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  return normalized;
}

function projectV2ResultRoot(value: unknown): WorkspaceRootRefV1 {
  try {
    const root = assertWorkspaceRootRefV1(value);
    if (root.project_id === null) return projectV2Fail('E_PROJECT_RESULT_INVALID');
    return root;
  } catch {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
}

function projectV2SameRoot(left: WorkspaceRootRefV1, right: WorkspaceRootRefV1): boolean {
  return left.workspace_id === right.workspace_id &&
    left.binding_revision === right.binding_revision &&
    left.project_id === right.project_id;
}

function projectV2DisplayName(value: unknown): value is string {
  return (
    projectV2String(value, 120) &&
    value.trim() === value &&
    value !== '.' &&
    value !== '..' &&
    !value.includes('/') &&
    !value.includes('\\')
  );
}

function projectV2Branch(value: unknown): value is string | null {
  if (value === null) return true;
  if (!projectV2String(value, 1024)) return false;
  return (
    value !== '@' &&
    !value.includes('..') &&
    !value.includes(' ') &&
    !value.startsWith('/') &&
    !value.endsWith('/') &&
    !value.startsWith('.') &&
    !value.endsWith('.') &&
    !value.includes('@{') &&
    !value.includes('~') &&
    !value.includes('^') &&
    !value.includes(':') &&
    !value.includes('?') &&
    !value.includes('*') &&
    !value.includes('[') &&
    value.split('/').every(part => part.length > 0 && !part.endsWith('.lock'))
  );
}

function projectV2Descriptor(
  value: unknown,
  expectedRoot?: WorkspaceRootRefV1,
): LocalProjectDescriptorV2 {
  const row = projectV2ExactRecord(value, [
    'schema_version',
    'project_id',
    'workspace_id',
    'workspace_binding_revision',
    'display_name',
    'git_topology',
  ], 'E_PROJECT_RESULT_INVALID');
  if (
    row.schema_version !== 2 ||
    !projectV2UUID(row.project_id) ||
    !projectV2UUID(row.workspace_id) ||
    !projectV2SafeInteger(row.workspace_binding_revision, 1) ||
    !projectV2DisplayName(row.display_name) ||
    (row.git_topology !== 'legacy_embedded' &&
      row.git_topology !== 'private_split_gitdir') ||
    (expectedRoot !== undefined &&
      (row.workspace_id !== expectedRoot.workspace_id ||
        row.workspace_binding_revision !== expectedRoot.binding_revision ||
        (expectedRoot.project_id !== null &&
          row.project_id !== expectedRoot.project_id)))
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 2,
    project_id: row.project_id,
    workspace_id: row.workspace_id,
    workspace_binding_revision: row.workspace_binding_revision,
    display_name: row.display_name,
    git_topology: row.git_topology,
  };
}

function projectV2Candidate(value: unknown): ProjectStatusEntry {
  const row = projectV2ExactRecord(value, [
    'path',
    'index_status',
    'worktree_status',
    'conflicted',
  ], 'E_PROJECT_RESULT_INVALID');
  if (
    !projectV2String(row.path, 4096) ||
    row.path.startsWith('/') ||
    row.path.includes('\\') ||
    row.path.split('/').some(part => part === '' || part === '.' || part === '..') ||
    typeof row.index_status !== 'string' ||
    typeof row.worktree_status !== 'string' ||
    typeof row.conflicted !== 'boolean'
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  const statuses: readonly string[] = [
    'unmodified', 'added', 'modified', 'deleted', 'renamed', 'typechange', 'unreadable',
  ];
  if (!statuses.includes(row.index_status) || !statuses.includes(row.worktree_status)) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    path: row.path,
    index_status: row.index_status as ProjectFileStatus,
    worktree_status: row.worktree_status as ProjectFileStatus,
    conflicted: row.conflicted,
  };
}

function projectV2RootResult(
  value: unknown,
  expected?: WorkspaceRootRefV1,
): WorkspaceRootRefV1 {
  const root = projectV2ResultRoot(value);
  if (expected !== undefined && !projectV2SameRoot(root, expected)) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return root;
}

function projectV2Status(
  value: unknown,
  expectedRoot: WorkspaceRootRefV1,
): ProjectGitStatusV2 {
  const row = projectV2ExactRecord(value, [
    'schema_version',
    'root',
    'project_id',
    'branch',
    'head_oid',
    'clean',
    'has_conflicts',
    'ahead',
    'behind',
    'entries',
  ], 'E_PROJECT_RESULT_INVALID');
  const root = projectV2RootResult(row.root, expectedRoot);
  const branch = projectV2Branch(row.branch)
    ? row.branch as string | null
    : projectV2Fail('E_PROJECT_RESULT_INVALID');
  if (
    row.schema_version !== 2 ||
    row.project_id !== expectedRoot.project_id ||
    !projectV2OID(row.head_oid, true) ||
    typeof row.clean !== 'boolean' ||
    typeof row.has_conflicts !== 'boolean' ||
    !projectV2SafeInteger(row.ahead) ||
    !projectV2SafeInteger(row.behind)
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  const entries = projectV2Array(row.entries, 10000, 'E_PROJECT_RESULT_INVALID').map(
    projectV2Candidate,
  );
  return {
    schema_version: 2,
    root,
    project_id: expectedRoot.project_id as string,
    branch,
    head_oid: row.head_oid as string | null,
    clean: row.clean,
    has_conflicts: row.has_conflicts,
    ahead: row.ahead,
    behind: row.behind,
    entries,
  };
}

function projectV2DiffFile(value: unknown): ProjectDiffFile {
  const row = projectV2ExactRecord(value, [
    'path', 'status', 'additions', 'deletions',
  ], 'E_PROJECT_RESULT_INVALID');
  const statuses: readonly string[] = [
    'unmodified', 'added', 'modified', 'deleted', 'renamed', 'typechange', 'unreadable',
  ];
  if (
    !projectV2String(row.path, 4096) ||
    row.path.startsWith('/') ||
    row.path.includes('\\') ||
    row.path.split('/').some(part => part === '' || part === '.' || part === '..') ||
    typeof row.status !== 'string' ||
    !statuses.includes(row.status) ||
    !projectV2SafeInteger(row.additions) ||
    !projectV2SafeInteger(row.deletions)
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    path: row.path,
    status: row.status as ProjectFileStatus,
    additions: row.additions,
    deletions: row.deletions,
  };
}

function projectV2Diff(
  value: unknown,
  expectedRoot: WorkspaceRootRefV1,
): ProjectDiffV2 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'project_id', 'staged', 'truncated', 'patch', 'files',
  ], 'E_PROJECT_RESULT_INVALID');
  const root = projectV2RootResult(row.root, expectedRoot);
  if (
    row.schema_version !== 2 ||
    row.project_id !== expectedRoot.project_id ||
    typeof row.staged !== 'boolean' ||
    typeof row.truncated !== 'boolean' ||
    !projectV2Text(row.patch, 1024 * 1024, true)
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  const files = projectV2Array(row.files, 1000, 'E_PROJECT_RESULT_INVALID').map(
    projectV2DiffFile,
  );
  return {
    schema_version: 2,
    root,
    project_id: expectedRoot.project_id as string,
    staged: row.staged,
    truncated: row.truncated,
    patch: row.patch,
    files,
  };
}

function projectV2Commit(
  value: unknown,
  expectedRoot: WorkspaceRootRefV1,
): ProjectCommitV2 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'project_id', 'oid', 'summary', 'committed_at',
  ], 'E_PROJECT_RESULT_INVALID');
  const root = projectV2RootResult(row.root, expectedRoot);
  if (
    row.schema_version !== 2 ||
    row.project_id !== expectedRoot.project_id ||
    !projectV2OID(row.oid) ||
    !projectV2String(row.summary, 500, true) ||
    !projectV2Timestamp(row.committed_at)
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 2,
    root,
    project_id: expectedRoot.project_id as string,
    oid: row.oid as string,
    summary: row.summary,
    committed_at: row.committed_at,
  };
}

function projectV2Push(
  value: unknown,
  expectedRoot: WorkspaceRootRefV1,
): ProjectPushResultV2 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'project_id', 'remote', 'branch', 'oid', 'pushed_at',
  ], 'E_PROJECT_RESULT_INVALID');
  const root = projectV2RootResult(row.root, expectedRoot);
  if (
    row.schema_version !== 2 ||
    row.project_id !== expectedRoot.project_id ||
    row.remote !== 'origin' ||
    typeof row.branch !== 'string' ||
    !projectV2Branch(row.branch) ||
    !projectV2OID(row.oid) ||
    !projectV2Timestamp(row.pushed_at)
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 2,
    root,
    project_id: expectedRoot.project_id as string,
    remote: 'origin',
    branch: row.branch as string,
    oid: row.oid as string,
    pushed_at: row.pushed_at,
  };
}

function projectV2Attach(
  value: unknown,
  expectedRoot: WorkspaceRootRefV1,
): AttachWorkspaceProjectResultV1 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'status', 'project',
  ], 'E_PROJECT_RESULT_INVALID');
  if (
    row.schema_version !== 1 ||
    (row.status !== 'attached' && row.status !== 'already_attached')
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 1,
    status: row.status,
    project: projectV2Descriptor(row.project, expectedRoot),
  };
}

function projectV2ForWorkspace(
  value: unknown,
  expectedRoot?: WorkspaceRootRefV1,
): ProjectForWorkspaceResultV1 {
  if (
    typeof value !== 'object' ||
    value === null ||
    Array.isArray(value) ||
    Object.getPrototypeOf(value) !== projectV2ObjectPrototype ||
    Object.getOwnPropertySymbols(value).length > 0
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  const names = Object.getOwnPropertyNames(value);
  const hasProject = names.includes('project');
  const row = projectV2ExactRecord(
    value,
    hasProject ? ['schema_version', 'status', 'project'] : ['schema_version', 'status'],
    'E_PROJECT_RESULT_INVALID',
  );
  if (row.schema_version !== 1 || row.status === 'none') {
    if (row.schema_version === 1 && row.status === 'none' && !hasProject) {
      return { schema_version: 1, status: 'none' };
    }
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  if (row.status !== 'attached' || !hasProject) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 1,
    status: 'attached',
    project: projectV2Descriptor(row.project, expectedRoot),
  };
}

function projectV2Checkpoint(
  value: unknown,
  code = 'E_PROJECT_RESULT_INVALID',
): ProjectDetachCheckpointV1 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'checkpoint_id', 'project_id', 'workspace_id',
    'binding_revision', 'gitdir_sha256', 'mode', 'created_at',
  ], code);
  if (
    row.schema_version !== 1 ||
    !projectV2UUID(row.checkpoint_id) ||
    !projectV2UUID(row.project_id) ||
    !projectV2UUID(row.workspace_id) ||
    !projectV2SafeInteger(row.binding_revision, 1) ||
    !projectV2Digest(row.gitdir_sha256) ||
    (row.mode !== 'retain_private_gitdir' && row.mode !== 'delete_private_gitdir') ||
    !projectV2Timestamp(row.created_at)
  ) {
    return projectV2Fail(code);
  }
  return {
    schema_version: 1,
    checkpoint_id: row.checkpoint_id,
    project_id: row.project_id,
    workspace_id: row.workspace_id,
    binding_revision: row.binding_revision,
    gitdir_sha256: row.gitdir_sha256,
    mode: row.mode,
    created_at: row.created_at,
  };
}

function projectV2PrepareDetach(value: unknown): ProjectDetachCheckpointV1 {
  return projectV2Checkpoint(value);
}

function projectV2CommitDetach(value: unknown): { schema_version: 1; status: 'detached' } {
  const row = projectV2ExactRecord(value, ['schema_version', 'status'], 'E_PROJECT_RESULT_INVALID');
  if (row.schema_version !== 1 || row.status !== 'detached') {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return { schema_version: 1, status: 'detached' };
}

function projectV2OperationId(value: unknown): string {
  if (!projectV2UUID(value)) return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  return value;
}

function projectV2Bounded(value: unknown, maximum: number, allowEmpty = false): string {
  if (!projectV2String(value, maximum, allowEmpty)) {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
  return value;
}

function projectV2RequestRoot(value: unknown): WorkspaceRootRefV1 {
  try {
    const root = assertWorkspaceRootRefV1(value);
    if (root.project_id === null) return projectV2Fail('E_PROJECT_REQUEST_INVALID');
    return {
      schema_version: 1,
      workspace_id: root.workspace_id,
      binding_revision: root.binding_revision,
      project_id: root.project_id,
    };
  } catch {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
}

function projectV2DiffMaxBytes(value: unknown): number {
  if (!projectV2SafeInteger(value, 1) || value > 1024 * 1024) {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
  return value;
}

function projectV2ExpectedHead(value: unknown): string | null {
  if (value === null) return null;
  if (!projectV2OID(value)) return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  return value;
}

function projectV2CommitRequest(value: unknown): GitCommitRequestV1 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'operation_id', 'message', 'author_name',
    'author_email', 'expected_head_oid',
  ], 'E_PROJECT_REQUEST_INVALID');
  if (
    row.schema_version !== 1 ||
    !projectV2Text(row.message, 500) ||
    !projectV2String(row.author_name, 120) ||
    !projectV2Email(row.author_email)
  ) {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
  return {
    schema_version: 1,
    root: projectV2RequestRoot(row.root),
    operation_id: projectV2OperationId(row.operation_id),
    message: row.message as string,
    author_name: projectV2Bounded(row.author_name, 120),
    author_email: row.author_email as string,
    expected_head_oid: projectV2ExpectedHead(row.expected_head_oid),
  };
}

function projectV2PushRequest(value: unknown): GitPushRequestV1 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'operation_id', 'remote',
    'expected_local_oid', 'credential_reference', 'https_proxy_url',
  ], 'E_PROJECT_REQUEST_INVALID');
  if (
    row.schema_version !== 1 ||
    row.remote !== 'origin' ||
    !projectV2OID(row.expected_local_oid) ||
    !projectV2String(row.credential_reference, 256) ||
    (row.https_proxy_url !== null &&
      !projectV2String(row.https_proxy_url, 2048))
  ) {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
  return {
    schema_version: 1,
    root: projectV2RequestRoot(row.root),
    operation_id: projectV2OperationId(row.operation_id),
    remote: 'origin',
    expected_local_oid: row.expected_local_oid as string,
    credential_reference: row.credential_reference as string,
    https_proxy_url: projectV2ProxyURL(row.https_proxy_url),
  };
}

function projectV2RemoteRequest(value: unknown): GitRemoteRequestV1 {
  const row = projectV2ExactRecord(value, ['schema_version', 'root', 'url'], 'E_PROJECT_REQUEST_INVALID');
  if (row.schema_version !== 1 || !projectV2String(row.url, 2048)) {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
  return { schema_version: 1, root: projectV2RequestRoot(row.root), url: row.url };
}

function projectV2CredentialPromptRequest(value: unknown): GitCredentialPromptRequestV1 {
  const row = projectV2ExactRecord(value, ['schema_version', 'root', 'locale'], 'E_PROJECT_REQUEST_INVALID');
  if (row.schema_version !== 1 || (row.locale !== 'zh-CN' && row.locale !== 'en')) {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
  return { schema_version: 1, root: projectV2RequestRoot(row.root), locale: row.locale };
}

function projectV2FetchRequest(value: unknown): GitFetchRequestV1 {
  const row = projectV2ExactRecord(value, ['schema_version', 'root', 'operation_id', 'remote'], 'E_PROJECT_REQUEST_INVALID');
  if (row.schema_version !== 1 || row.remote !== 'origin') return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  return {
    schema_version: 1,
    root: projectV2RequestRoot(row.root),
    operation_id: projectV2OperationId(row.operation_id),
    remote: 'origin',
  };
}

function projectV2PullRequest(value: unknown): GitPullRequestV1 {
  const row = projectV2ExactRecord(value, ['schema_version', 'root', 'expected_head_oid'], 'E_PROJECT_REQUEST_INVALID');
  if (row.schema_version !== 1 || !projectV2OID(row.expected_head_oid)) {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
  return {
    schema_version: 1,
    root: projectV2RequestRoot(row.root),
    expected_head_oid: row.expected_head_oid as string,
  };
}

function projectV2MergeRequest(value: unknown): GitMergeRequestV1 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'operation_id', 'expected_branch', 'expected_head_oid',
    'expected_remote_oid', 'author_name', 'author_email',
  ], 'E_PROJECT_REQUEST_INVALID');
  if (
    row.schema_version !== 1 ||
    typeof row.expected_branch !== 'string' ||
    !projectV2Branch(row.expected_branch) ||
    !projectV2OID(row.expected_head_oid) ||
    !projectV2OID(row.expected_remote_oid) ||
    !projectV2String(row.author_name, 120) ||
    !projectV2Email(row.author_email)
  ) {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
  return {
    schema_version: 1,
    root: projectV2RequestRoot(row.root),
    operation_id: projectV2OperationId(row.operation_id),
    expected_branch: row.expected_branch,
    expected_head_oid: row.expected_head_oid as string,
    expected_remote_oid: row.expected_remote_oid as string,
    author_name: projectV2Bounded(row.author_name, 120),
    author_email: row.author_email as string,
  };
}

const MERGE_OUTCOMES = ['merged', 'up_to_date', 'fast_forward_available', 'conflicts', 'obstructed'] as const;

function projectV2MergePath(value: unknown): value is string | null {
  return value === null || projectV2String(value, 4096);
}

function projectV2Merge(
  value: unknown,
  request: GitMergeRequestV1,
): ProjectMergeResultV2 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'project_id', 'branch', 'outcome', 'oid', 'previous_oid', 'conflicts', 'paths',
  ], 'E_PROJECT_RESULT_INVALID');
  const root = projectV2RootResult(row.root, request.root);
  const outcome = row.outcome as ProjectMergeResultV2['outcome'];
  if (
    row.schema_version !== 2 ||
    row.project_id !== request.root.project_id ||
    row.branch !== request.expected_branch ||
    !(MERGE_OUTCOMES as readonly string[]).includes(outcome) ||
    !projectV2OID(row.oid) ||
    row.previous_oid !== request.expected_head_oid ||
    // Only a merge moves the branch; every other outcome is a promise that
    // nothing did, and a result that says otherwise is not believed.
    (outcome === 'merged') === (row.oid === row.previous_oid) ||
    !Array.isArray(row.conflicts) || row.conflicts.length > 64 ||
    !Array.isArray(row.paths) || row.paths.length > 64 ||
    (outcome !== 'conflicts' && row.conflicts.length > 0) ||
    (outcome !== 'obstructed' && row.paths.length > 0)
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  const conflicts = row.conflicts.map(entry => {
    const conflict = projectV2ExactRecord(entry, ['ancestor', 'ours', 'theirs'], 'E_PROJECT_RESULT_INVALID');
    if (
      !projectV2MergePath(conflict.ancestor) ||
      !projectV2MergePath(conflict.ours) ||
      !projectV2MergePath(conflict.theirs)
    ) {
      return projectV2Fail('E_PROJECT_RESULT_INVALID');
    }
    return {
      ancestor: conflict.ancestor as string | null,
      ours: conflict.ours as string | null,
      theirs: conflict.theirs as string | null,
    };
  });
  const paths = row.paths.map(path =>
    projectV2String(path, 4096) ? path : projectV2Fail('E_PROJECT_RESULT_INVALID'),
  );
  return {
    schema_version: 2,
    root,
    project_id: request.root.project_id as string,
    branch: request.expected_branch,
    outcome,
    oid: row.oid as string,
    previous_oid: row.previous_oid as string,
    conflicts,
    paths,
  };
}

function projectV2Fetch(
  value: unknown,
  expectedRoot: WorkspaceRootRefV1,
): ProjectFetchResultV2 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'project_id', 'remote', 'branch', 'remote_oid', 'ahead', 'behind', 'fetched_at',
  ], 'E_PROJECT_RESULT_INVALID');
  const root = projectV2RootResult(row.root, expectedRoot);
  if (
    row.schema_version !== 2 ||
    row.project_id !== expectedRoot.project_id ||
    row.remote !== 'origin' ||
    typeof row.branch !== 'string' ||
    !projectV2Branch(row.branch) ||
    !projectV2OID(row.remote_oid, true) ||
    !projectV2SafeInteger(row.ahead) ||
    !projectV2SafeInteger(row.behind) ||
    !projectV2Timestamp(row.fetched_at)
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 2,
    root,
    project_id: expectedRoot.project_id as string,
    remote: 'origin',
    branch: row.branch as string,
    remote_oid: row.remote_oid as string | null,
    ahead: row.ahead as number,
    behind: row.behind as number,
    fetched_at: row.fetched_at,
  };
}

function projectV2Pull(
  value: unknown,
  expectedRoot: WorkspaceRootRefV1,
): ProjectPullResultV2 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'project_id', 'branch', 'oid', 'previous_oid', 'updated',
  ], 'E_PROJECT_RESULT_INVALID');
  const root = projectV2RootResult(row.root, expectedRoot);
  if (
    row.schema_version !== 2 ||
    row.project_id !== expectedRoot.project_id ||
    typeof row.branch !== 'string' ||
    !projectV2Branch(row.branch) ||
    !projectV2OID(row.oid) ||
    !projectV2OID(row.previous_oid) ||
    typeof row.updated !== 'boolean' ||
    (row.updated === false) !== (row.oid === row.previous_oid)
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 2,
    root,
    project_id: expectedRoot.project_id as string,
    branch: row.branch as string,
    oid: row.oid as string,
    previous_oid: row.previous_oid as string,
    updated: row.updated,
  };
}

function projectV2Receipt(value: unknown): ProjectPushReceipt {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'remote', 'host', 'branch', 'local_oid', 'remote_oid', 'pushed_at',
  ], 'E_PROJECT_RESULT_INVALID');
  if (
    row.schema_version !== 1 ||
    row.remote !== 'origin' ||
    !projectV2Host(row.host) ||
    typeof row.branch !== 'string' ||
    !projectV2Branch(row.branch) ||
    !projectV2OID(row.local_oid) ||
    !projectV2OID(row.remote_oid) ||
    !projectV2Timestamp(row.pushed_at)
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 1,
    remote: 'origin',
    host: row.host,
    branch: row.branch as string,
    local_oid: row.local_oid as string,
    remote_oid: row.remote_oid as string,
    pushed_at: row.pushed_at,
  };
}

function projectV2Receipts(
  value: unknown,
  expectedRoot: WorkspaceRootRefV1,
): ProjectPushReceiptsV2 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'project_id', 'receipts',
  ], 'E_PROJECT_RESULT_INVALID');
  const root = projectV2RootResult(row.root, expectedRoot);
  if (
    row.schema_version !== 2 ||
    row.project_id !== expectedRoot.project_id ||
    !Array.isArray(row.receipts) ||
    row.receipts.length > 25
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 2,
    root,
    project_id: expectedRoot.project_id as string,
    receipts: projectV2ArrayMap.call(row.receipts, projectV2Receipt) as ProjectPushReceipt[],
  };
}

function projectV2WorkspaceCloneRequest(value: unknown): WorkspaceCloneRequestV1 {
  const record = value as { credential_reference?: unknown } | null;
  const withCredential = typeof record === 'object' && record !== null && 'credential_reference' in record;
  const row = projectV2ExactRecord(
    value,
    withCredential
      ? ['schema_version', 'operation_id', 'url', 'display_name', 'credential_reference']
      : ['schema_version', 'operation_id', 'url', 'display_name'],
    'E_PROJECT_REQUEST_INVALID',
  );
  if (row.schema_version !== 1 || !projectV2String(row.url, 2048) || !projectV2String(row.display_name, 120) ||
      (withCredential && row.credential_reference !== 'prompt')) {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
  return {
    schema_version: 1,
    operation_id: projectV2OperationId(row.operation_id),
    url: row.url,
    display_name: row.display_name,
    ...(withCredential ? { credential_reference: 'prompt' as const } : {}),
  };
}

function projectV2WorkspaceClone(value: unknown): WorkspaceCloneResultV2 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'project', 'workspace', 'branch', 'oid',
  ], 'E_PROJECT_RESULT_INVALID');
  const root = projectV2RootResult(row.root);
  const workspace = projectV2ExactRecord(row.workspace, ['workspace_id', 'display_name'], 'E_PROJECT_RESULT_INVALID');
  const project = projectV2Descriptor(row.project);
  if (
    row.schema_version !== 2 ||
    root.project_id !== project.project_id ||
    root.workspace_id !== project.workspace_id ||
    workspace.workspace_id !== root.workspace_id ||
    !projectV2String(workspace.display_name, 120) ||
    typeof row.branch !== 'string' ||
    !projectV2Branch(row.branch) ||
    !projectV2OID(row.oid)
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 2,
    root,
    project,
    workspace: { workspace_id: workspace.workspace_id as string, display_name: workspace.display_name },
    branch: row.branch as string,
    oid: row.oid as string,
  };
}

function projectV2CancelPushRequest(value: unknown): GitCancelPushRequestV1 {
  const row = projectV2ExactRecord(value, ['schema_version', 'root', 'operation_id'], 'E_PROJECT_REQUEST_INVALID');
  if (row.schema_version !== 1) return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  return {
    schema_version: 1,
    root: projectV2RequestRoot(row.root),
    operation_id: projectV2OperationId(row.operation_id),
  };
}

function projectV2Host(value: unknown): value is string {
  return typeof value === 'string' && /^[a-z0-9.:\-\[\]]{1,253}$/u.test(value);
}

function projectV2Remote(
  value: unknown,
  expectedRoot: WorkspaceRootRefV1,
): ProjectRemoteV2 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'project_id', 'remote', 'url', 'host',
  ], 'E_PROJECT_RESULT_INVALID');
  const root = projectV2RootResult(row.root, expectedRoot);
  const unset = row.url === null && row.host === null;
  const set = projectV2String(row.url, 2048) && projectV2Host(row.host);
  if (
    row.schema_version !== 2 ||
    row.project_id !== expectedRoot.project_id ||
    row.remote !== 'origin' ||
    !(unset || set)
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 2,
    root,
    project_id: expectedRoot.project_id as string,
    remote: 'origin',
    url: row.url as string | null,
    host: row.host as string | null,
  };
}

function projectV2CredentialStatus(
  value: unknown,
  expectedRoot: WorkspaceRootRefV1,
): ProjectCredentialStatusV2 {
  // A configured credential carries its expiry; an absent one carries nothing
  // else. Either way the answer never holds a username or a token.
  const configured =
    typeof value === 'object' && value !== null &&
    Object.prototype.hasOwnProperty.call(value, 'expires_at');
  const row = projectV2ExactRecord(value, configured
    ? ['schema_version', 'root', 'project_id', 'host', 'configured', 'expires_at', 'expiry_seconds']
    : ['schema_version', 'root', 'project_id', 'host', 'configured'],
  'E_PROJECT_RESULT_INVALID');
  const root = projectV2RootResult(row.root, expectedRoot);
  if (
    row.schema_version !== 2 ||
    row.project_id !== expectedRoot.project_id ||
    !projectV2Host(row.host) ||
    row.configured !== configured ||
    (configured &&
      (!projectV2SafeInteger(row.expires_at, 1) ||
        !projectV2SafeInteger(row.expiry_seconds, 1)))
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  const status: ProjectCredentialStatusV2 = {
    schema_version: 2,
    root,
    project_id: expectedRoot.project_id as string,
    host: row.host,
    configured,
  };
  if (configured) {
    status.expires_at = row.expires_at as number;
    status.expiry_seconds = row.expiry_seconds as number;
  }
  return status;
}

function projectV2PushCancellation(
  value: unknown,
  expectedRoot: WorkspaceRootRefV1,
  expectedOperationId: string,
): ProjectPushCancellationV2 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'root', 'project_id', 'operation_id', 'status',
  ], 'E_PROJECT_RESULT_INVALID');
  const root = projectV2RootResult(row.root, expectedRoot);
  if (
    row.schema_version !== 2 ||
    row.project_id !== expectedRoot.project_id ||
    row.operation_id !== expectedOperationId ||
    (row.status !== 'cancel_requested' && row.status !== 'not_running')
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 2,
    root,
    project_id: expectedRoot.project_id as string,
    operation_id: expectedOperationId,
    status: row.status,
  };
}

function projectV2WorkspaceRequest(value: unknown): GitWorkspaceRequestV1 {
  const row = projectV2ExactRecord(value, ['schema_version', 'root'], 'E_PROJECT_REQUEST_INVALID');
  if (row.schema_version !== 1) return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  return { schema_version: 1, root: projectV2RequestRoot(row.root) };
}

function projectV2DiffRequest(value: unknown): GitDiffRequestV1 {
  // `staged` may be left out by callers that only ever wanted the working
  // tree; the request that reaches native always carries it.
  const hasStaged =
    typeof value === 'object' && value !== null &&
    Object.prototype.hasOwnProperty.call(value, 'staged');
  const row = projectV2ExactRecord(
    value,
    hasStaged
      ? ['schema_version', 'root', 'max_bytes', 'staged']
      : ['schema_version', 'root', 'max_bytes'],
    'E_PROJECT_REQUEST_INVALID',
  );
  if (row.schema_version !== 1 || (hasStaged && typeof row.staged !== 'boolean')) {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
  return {
    schema_version: 1,
    root: projectV2RequestRoot(row.root),
    max_bytes: projectV2DiffMaxBytes(row.max_bytes),
    staged: hasStaged ? (row.staged as boolean) : false,
  };
}

function projectV2AttachRequest(value: unknown): AttachWorkspaceProjectRequestV1 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'operation_id', 'root', 'mode',
  ], 'E_PROJECT_REQUEST_INVALID');
  if (
    row.schema_version !== 1 ||
    (row.mode !== 'open' && row.mode !== 'init')
  ) {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
  try {
    const root = assertWorkspaceRootRefV1(row.root);
    return {
      schema_version: 1,
      operation_id: projectV2OperationId(row.operation_id),
      root: {
        schema_version: 1,
        workspace_id: root.workspace_id,
        binding_revision: root.binding_revision,
        project_id: root.project_id,
      },
      mode: row.mode,
    };
  } catch {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
}

function projectV2ProjectForWorkspaceRequest(value: unknown): WorkspaceRootRefV1 {
  try {
    const root = assertWorkspaceRootRefV1(value);
    return {
      schema_version: 1,
      workspace_id: root.workspace_id,
      binding_revision: root.binding_revision,
      project_id: root.project_id,
    };
  } catch {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
}

function projectV2PrepareDetachRequest(value: unknown): PrepareProjectDetachRequestV1 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'operation_id', 'root', 'mode',
  ], 'E_PROJECT_REQUEST_INVALID');
  if (
    row.schema_version !== 1 ||
    (row.mode !== 'retain_private_gitdir' && row.mode !== 'delete_private_gitdir')
  ) {
    return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  }
  return {
    schema_version: 1,
    operation_id: projectV2OperationId(row.operation_id),
    root: projectV2RequestRoot(row.root),
    mode: row.mode,
  };
}

function projectV2CommitDetachRequest(value: unknown): CommitProjectDetachRequestV1 {
  const row = projectV2ExactRecord(value, [
    'schema_version', 'operation_id', 'checkpoint', 'clearance_receipt_id',
  ], 'E_PROJECT_REQUEST_INVALID');
  if (row.schema_version !== 1) return projectV2Fail('E_PROJECT_REQUEST_INVALID');
  const checkpoint = projectV2Checkpoint(row.checkpoint, 'E_PROJECT_REQUEST_INVALID');
  return {
    schema_version: 1,
    operation_id: projectV2OperationId(row.operation_id),
    checkpoint,
    clearance_receipt_id: projectV2OperationId(row.clearance_receipt_id),
  };
}

function legacyProjectTimestamp(value: unknown): value is string {
  if (
    typeof value !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value)
  ) {
    return false;
  }
  const parsed = new Date(value);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString() === value;
}

function legacyProjectOriginURL(value: unknown): value is string | null {
  if (value === null) return true;
  if (
    !projectV2String(value, 4096) ||
    value.trim() !== value ||
    value.includes('\\') ||
    value.includes('?') ||
    value.includes('#')
  ) {
    return false;
  }
  // Mirrors the native remote policy: credential-free HTTPS on a DNS host,
  // or plain HTTP only to a loopback / RFC 1918 / link-local / ULA literal
  // (the LAN test remote), optionally with a port.
  const httpsMatch = /^https:\/\/([^/:]+)(?::(443))?(\/.*)$/u.exec(value);
  const privateLiteral =
    '(?:localhost|127\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}|10\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}' +
    '|192\\.168\\.\\d{1,3}\\.\\d{1,3}|172\\.(?:1[6-9]|2\\d|3[01])\\.\\d{1,3}\\.\\d{1,3}' +
    '|169\\.254\\.\\d{1,3}\\.\\d{1,3}|\\[(?:::1|fe80:[0-9a-f:.%]*|f[cd][0-9a-f]{2}:[0-9a-f:]*)\\])';
  const httpMatch = new RegExp(
    `^http:\\/\\/(${privateLiteral})(?::(\\d{1,5}))?(\\/.*)$`,
    'u',
  ).exec(value);
  const match = httpsMatch ?? httpMatch;
  if (match === null) return false;
  const host = match[1];
  const path = match[3];
  if (
    host === undefined ||
    path === undefined ||
    host !== host.toLowerCase() ||
    host.length > 253 ||
    path.length <= 1 ||
    projectV2UTF8Bytes(path) === null ||
    (projectV2UTF8Bytes(path) ?? Number.POSITIVE_INFINITY) > 2048
  ) {
    return false;
  }
  if (httpsMatch === null) {
    const port = match[2] === undefined ? 80 : Number(match[2]);
    if (!Number.isInteger(port) || port < 1 || port > 65535) return false;
  } else {
    const labels = host.split('.');
    if (
      labels.length < 2 ||
      labels.some(
        label =>
          label.length === 0 ||
          label.length > 63 ||
          !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/u.test(label),
      )
    ) {
      return false;
    }
  }
  return path.split('/').every(component => {
    if (component === '') return true;
    try {
      const decoded = decodeURIComponent(component);
      return decoded !== '.' && decoded !== '..';
    } catch {
      return false;
    }
  });
}

function legacyProject(value: unknown): LocalProject {
  const row = projectV2ExactRecord(
    value,
    [
      'schema_version',
      'id',
      'name',
      'workspace_path',
      'created_at',
      'updated_at',
      'origin_url',
    ],
    'E_PROJECT_RESULT_INVALID',
  );
  if (
    row.schema_version !== 1 ||
    !projectV2UUID(row.id) ||
    !projectV2DisplayName(row.name) ||
    row.workspace_path !== `projects/${row.id}/repo` ||
    !legacyProjectTimestamp(row.created_at) ||
    !legacyProjectTimestamp(row.updated_at) ||
    row.updated_at < row.created_at ||
    !legacyProjectOriginURL(row.origin_url)
  ) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  return {
    schema_version: 1,
    id: row.id,
    name: row.name,
    workspace_path: `projects/${row.id}/repo`,
    created_at: row.created_at,
    updated_at: row.updated_at,
    origin_url: row.origin_url,
  };
}

function legacyProjectListing(value: unknown): LocalProjectListing {
  const row = projectV2ExactRecord(
    value,
    ['schema_version', 'projects'],
    'E_PROJECT_RESULT_INVALID',
  );
  if (row.schema_version !== 1) {
    return projectV2Fail('E_PROJECT_RESULT_INVALID');
  }
  const projects = projectV2Array(
    row.projects,
    4096,
    'E_PROJECT_RESULT_INVALID',
  ).map(legacyProject);
  return { schema_version: 1, projects };
}

function hasNativeCapabilities(value: unknown): value is NativeLocalProjects {
  if (!nativeImplementationAvailable(value)) return false;
  if (typeof value !== 'object' || value === null) return false;
  const candidate = value as Partial<
    Record<keyof NativeLocalProjects, unknown>
  >;
  return (
    typeof candidate.list === 'function' &&
    typeof candidate.create === 'function' &&
    typeof candidate.clone === 'function' &&
    typeof candidate.status === 'function' &&
    typeof candidate.diff === 'function' &&
    typeof candidate.stageAll === 'function' &&
    typeof candidate.commit === 'function' &&
    typeof candidate.setRemote === 'function' &&
    typeof candidate.credentialStatus === 'function' &&
    typeof candidate.presentCredentialPrompt === 'function' &&
    typeof candidate.clearCredential === 'function' &&
    typeof candidate.push === 'function'
  );
}

function required(): NativeLocalProjects {
  if (!hasNativeCapabilities(native)) {
    throw new Error('LocalProjects native module is not linked');
  }
  return native;
}

function hasV2Capabilities(value: unknown): value is NativeLocalProjects {
  if (!nativeImplementationAvailable(value)) return false;
  try {
    if (typeof value !== 'object' || value === null) return false;
    const row = value as Partial<NativeLocalProjects>;
    return (
      typeof row.attachWorkspaceProject === 'function' &&
      typeof row.projectForWorkspaceV2 === 'function' &&
      typeof row.prepareProjectDetachV1 === 'function' &&
      typeof row.commitProjectDetachV1 === 'function' &&
      typeof row.statusV2 === 'function' &&
      typeof row.diffV2 === 'function' &&
      typeof row.stageAllV2 === 'function' &&
      typeof row.commitV2 === 'function' &&
      typeof row.pushV2 === 'function' &&
      typeof row.setRemoteV2 === 'function' &&
      typeof row.remoteV2 === 'function' &&
      typeof row.credentialStatusV2 === 'function' &&
      typeof row.presentCredentialPromptV2 === 'function' &&
      typeof row.clearCredentialV2 === 'function' &&
      typeof row.cancelPushV2 === 'function' &&
      typeof row.fetchV2 === 'function' &&
      typeof row.pullFastForwardV2 === 'function' &&
      typeof row.pushReceiptsV2 === 'function'
    );
  } catch {
    return false;
  }
}

function requiredV2(): NativeLocalProjects {
  if (!hasV2Capabilities(native)) projectV2Fail('E_PROJECT_NATIVE');
  return native;
}

async function projectV2Boundary<T>(
  operation: () => Promise<unknown>,
  project: (value: unknown) => T,
): Promise<T> {
  try {
    return project(await operation());
  } catch (error) {
    throw projectV2Error(error);
  }
}

function cloneOperation(value: unknown): ProjectCloneOperation {
  const code = 'E_PROJECT_RESULT_INVALID';
  const row = projectV2ExactRecord(
    value,
    [
      'schema_version',
      'operation_id',
      'name',
      'phase',
      'cancel_requested',
      'received_objects',
      'total_objects',
      'received_bytes',
      'completed_files',
      'total_files',
      'project',
      'error_code',
    ],
    code,
  );
  const phases: readonly unknown[] = [
    'queued',
    'connecting',
    'receiving',
    'checkout',
    'validating',
    'publishing',
    'succeeded',
    'failed',
    'cancelled',
  ];
  if (
    row.schema_version !== 1 ||
    !projectV2UUID(row.operation_id) ||
    !projectV2DisplayName(row.name) ||
    !phases.includes(row.phase) ||
    typeof row.cancel_requested !== 'boolean' ||
    ![null, 'timeout', 'git'].includes(row.error_code as string | null)
  )
    projectV2Fail(code);
  for (const key of [
    'received_objects',
    'total_objects',
    'received_bytes',
    'completed_files',
    'total_files',
  ]) {
    if (!Number.isSafeInteger(row[key]) || (row[key] as number) < 0)
      projectV2Fail(code);
  }
  const project = row.project === null ? null : legacyProject(row.project);
  if (
    (row.phase === 'succeeded') !== (project !== null) ||
    (row.phase === 'failed') !== (row.error_code !== null)
  )
    projectV2Fail(code);
  return { ...row, project } as ProjectCloneOperation;
}

function reviewPage(value: unknown, projectId: string, staged: boolean, offset: number, snapshot: string | null): ProjectDiffPage {
  const code = 'E_PROJECT_RESULT_INVALID';
  const row = projectV2ExactRecord(value, ['schema_version', 'project_id', 'staged', 'truncated', 'patch', 'files',
    'page_offset', 'next_offset', 'snapshot_id', 'omitted_paths'], code);
  if (row.schema_version !== 1 || row.project_id !== projectId || row.staged !== staged ||
      typeof row.truncated !== 'boolean' || typeof row.patch !== 'string' ||
      (projectV2UTF8Bytes(row.patch) ?? Infinity) > 65536 || row.page_offset !== offset ||
      !projectV2Digest(row.snapshot_id) || (snapshot !== null && row.snapshot_id !== snapshot) ||
      (row.next_offset !== null && (!Number.isSafeInteger(row.next_offset) ||
        row.next_offset !== offset + (projectV2UTF8Bytes(row.patch) ?? 0) ||
        (row.next_offset as number) <= offset)) || row.truncated !== (row.next_offset !== null)) projectV2Fail(code);
  const files = projectV2Array(row.files, 1000, code).map(item => {
    const file = projectV2ExactRecord(item, ['path', 'status', 'additions', 'deletions'], code);
    if (!projectV2String(file.path, 4096) || !projectV2String(file.status, 40) ||
        !Number.isSafeInteger(file.additions) || (file.additions as number) < 0 ||
        !Number.isSafeInteger(file.deletions) || (file.deletions as number) < 0) projectV2Fail(code);
    return file;
  });
  const omitted = projectV2Array(row.omitted_paths, 1000, code);
  if (omitted.some(path => !files.some(file => file.path === path))) projectV2Fail(code);
  return { ...row, files, omitted_paths: omitted } as ProjectDiffPage;
}

export const LocalProjects = {
  isAvailable: () => hasNativeCapabilities(native),
  /** Whether the legacy clone controls exist here (they do not on Android, whose module stubs the rest). */
  isLegacyCloneAvailable: (): boolean => {
    try {
      const row = native as Partial<NativeLocalProjects> | null;
      return hasNativeCapabilities(native) && typeof row?.startClone === 'function' &&
        typeof row?.cancelClone === 'function';
    } catch {
      return false;
    }
  },
  startClone: async (
    url: string,
    name?: string,
    options: ProjectGitTransportOptions = {},
  ) => {
    const api = required();
    if (!api.startClone) throw new Error('Clone controls are unavailable');
    return cloneOperation(await api.startClone(url, name ?? null, options));
  },
  cloneStatus: async (operationId: string | null = null) => {
    const api = required();
    if (!api.cloneStatus) return null;
    const result = await api.cloneStatus(operationId);
    if (result === null && operationId === null) return null;
    const operation = cloneOperation(result);
    if (operationId !== null && operation.operation_id !== operationId)
      projectV2Fail('E_PROJECT_RESULT_INVALID');
    return operation;
  },
  cancelClone: async (operationId: string) => {
    const api = required();
    if (!api.cancelClone) throw new Error('Clone controls are unavailable');
    const operation = cloneOperation(await api.cancelClone(operationId));
    if (operation.operation_id !== operationId)
      projectV2Fail('E_PROJECT_RESULT_INVALID');
    return operation;
  },
  list: async () => legacyProjectListing(await required().list()),
  create: (name: string) => required().create(name),
  clone: (
    url: string,
    name?: string,
    options: ProjectGitTransportOptions = {},
  ) => required().clone(url, name ?? null, options),
  status: (projectId: string) => required().status(projectId),
  diffPage: async (projectId: string, staged: boolean, offset = 0, snapshot: string | null = null) => {
    const api = required();
    if (!api.diffPage) throw new Error('Paged diff review is unavailable');
    return reviewPage(await api.diffPage(projectId, staged, offset, snapshot), projectId, staged, offset, snapshot);
  },
  diff: (projectId: string, options: ProjectDiffOptions = {}) =>
    required().diff(
      projectId,
      options.staged ?? false,
      options.contextLines ?? 3,
    ),
  stageAll: (projectId: string) => required().stageAll(projectId),
  commit: (projectId: string, input: ProjectCommitInput) =>
    required().commit(
      projectId,
      input.message,
      input.authorName,
      input.authorEmail,
    ),
  setRemote: (projectId: string, url: string) =>
    required().setRemote(projectId, url),
  credentialStatus: (projectId: string) =>
    required().credentialStatus(projectId),
  presentCredentialPrompt: (projectId: string, locale: 'zh-CN' | 'en' = 'en') =>
    required().presentCredentialPrompt(projectId, locale),
  clearCredential: (projectId: string) => required().clearCredential(projectId),
  beginSSHCredentialImport: (profileId: string, host: string, port: number, username: string) => {
    const api = required();
    if (!api.beginSSHCredentialImport) throw new Error('SSH credential setup is unavailable');
    return api.beginSSHCredentialImport(profileId, host, port, username);
  },
  sshCredentialStatus: (profileId: string) => {
    const api = required();
    if (!api.sshCredentialStatus) throw new Error('SSH credential status is unavailable');
    return api.sshCredentialStatus(profileId);
  },
  push: (projectId: string, options: ProjectPushOptions = {}) =>
    required().push(projectId, options),
  pushReceipts: (projectId: string) => required().pushReceipts(projectId),
  cancelPush: (projectId: string) => required().cancelPush(projectId),
  isV2Available: () => hasV2Capabilities(native),
  attachWorkspaceProject: async (
    requestValue: unknown,
  ): Promise<AttachWorkspaceProjectResultV1> => {
    try {
      const request = projectV2AttachRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().attachWorkspaceProject!(request),
        raw => projectV2Attach(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  projectForWorkspaceV2: async (
    rootValue: unknown,
  ): Promise<ProjectForWorkspaceResultV1> => {
    try {
      const root = projectV2ProjectForWorkspaceRequest(rootValue);
      return await projectV2Boundary(
        () => requiredV2().projectForWorkspaceV2!(root),
        raw => projectV2ForWorkspace(raw, root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  prepareProjectDetachV1: async (
    requestValue: unknown,
  ): Promise<ProjectDetachCheckpointV1> => {
    try {
      const request = projectV2PrepareDetachRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().prepareProjectDetachV1!(request),
        raw => {
          const checkpoint = projectV2PrepareDetach(raw);
          if (
            checkpoint.project_id !== request.root.project_id ||
            checkpoint.workspace_id !== request.root.workspace_id ||
            checkpoint.binding_revision !== request.root.binding_revision ||
            checkpoint.mode !== request.mode
          ) {
            return projectV2Fail('E_PROJECT_RESULT_INVALID');
          }
          return checkpoint;
        },
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  commitProjectDetachV1: async (
    requestValue: unknown,
  ): Promise<{ schema_version: 1; status: 'detached' }> => {
    try {
      const request = projectV2CommitDetachRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().commitProjectDetachV1!(request),
        projectV2CommitDetach,
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  statusV2: async (
    requestValue: unknown,
  ): Promise<ProjectGitStatusV2> => {
    try {
      const request = projectV2WorkspaceRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().statusV2!(request),
        raw => projectV2Status(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  diffV2: async (requestValue: unknown): Promise<ProjectDiffV2> => {
    try {
      const request = projectV2DiffRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().diffV2!(request),
        raw => projectV2Diff(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  stageAllV2: async (
    requestValue: unknown,
  ): Promise<ProjectGitStatusV2> => {
    try {
      const request = projectV2WorkspaceRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().stageAllV2!(request),
        raw => projectV2Status(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  commitV2: async (
    requestValue: unknown,
  ): Promise<ProjectCommitV2> => {
    try {
      const request = projectV2CommitRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().commitV2!(request),
        raw => projectV2Commit(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  pushV2: async (
    requestValue: unknown,
  ): Promise<ProjectPushResultV2> => {
    try {
      const request = projectV2PushRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().pushV2!(request),
        raw => projectV2Push(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  setRemoteV2: async (requestValue: unknown): Promise<ProjectRemoteV2> => {
    try {
      const request = projectV2RemoteRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().setRemoteV2!(request),
        raw => projectV2Remote(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  remoteV2: async (requestValue: unknown): Promise<ProjectRemoteV2> => {
    try {
      const request = projectV2WorkspaceRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().remoteV2!(request),
        raw => projectV2Remote(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  credentialStatusV2: async (
    requestValue: unknown,
  ): Promise<ProjectCredentialStatusV2> => {
    try {
      const request = projectV2WorkspaceRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().credentialStatusV2!(request),
        raw => projectV2CredentialStatus(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  /** The native prompt takes the username and token; JS only ever sees the status. */
  presentCredentialPromptV2: async (
    requestValue: unknown,
  ): Promise<ProjectCredentialStatusV2> => {
    try {
      const request = projectV2CredentialPromptRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().presentCredentialPromptV2!(request),
        raw => projectV2CredentialStatus(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  clearCredentialV2: async (
    requestValue: unknown,
  ): Promise<ProjectCredentialStatusV2> => {
    try {
      const request = projectV2WorkspaceRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().clearCredentialV2!(request),
        raw => projectV2CredentialStatus(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  /** Whether this build clones a public repository into a new workspace (Android). */
  isWorkspaceCloneAvailable: (): boolean => {
    try {
      const row = native as Partial<NativeLocalProjects> | null;
      return hasV2Capabilities(native) && typeof row?.cloneWorkspaceV2 === 'function' &&
        typeof row?.cancelWorkspaceCloneV2 === 'function';
    } catch {
      return false;
    }
  },
  /** A public HTTPS repository into a new workspace with its project attached; the network runs before anything is made. */
  cloneWorkspaceV2: async (requestValue: unknown): Promise<WorkspaceCloneResultV2> => {
    try {
      const request = projectV2WorkspaceCloneRequest(requestValue);
      const row = native as Partial<NativeLocalProjects> | null;
      if (!hasV2Capabilities(native) || typeof row?.cloneWorkspaceV2 !== 'function') projectV2Fail('E_PROJECT_NATIVE');
      return await projectV2Boundary(
        () => row!.cloneWorkspaceV2!(request),
        projectV2WorkspaceClone,
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  /** Whether a clone that asks for a credential can be given one here (Android). */
  isCloneCredentialPromptAvailable: (): boolean => {
    try {
      const row = native as Partial<NativeLocalProjects> | null;
      return LocalProjects.isWorkspaceCloneAvailable() && typeof row?.presentCloneCredentialPromptV2 === 'function';
    } catch {
      return false;
    }
  },
  /**
   * The native credential dialog for one clone. The secret stays native,
   * keyed by the operation id; the clone that names it with
   * `credential_reference: 'prompt'` uses it, and a clone that succeeds keeps
   * it for the new project. Dismissing the dialog rejects E_PROJECT_CANCELLED.
   */
  presentCloneCredentialPromptV2: async (requestValue: unknown): Promise<WorkspaceCloneCredentialV2> => {
    try {
      const row = projectV2ExactRecord(requestValue, ['schema_version', 'operation_id', 'url', 'locale'], 'E_PROJECT_REQUEST_INVALID');
      if (row.schema_version !== 1 || !projectV2String(row.url, 2048) || (row.locale !== 'zh-CN' && row.locale !== 'en')) {
        return projectV2Fail('E_PROJECT_REQUEST_INVALID');
      }
      const request = {
        schema_version: 1 as const,
        operation_id: projectV2OperationId(row.operation_id),
        url: row.url,
        locale: row.locale as 'zh-CN' | 'en',
      };
      const native_ = native as Partial<NativeLocalProjects> | null;
      if (!hasV2Capabilities(native) || typeof native_?.presentCloneCredentialPromptV2 !== 'function') projectV2Fail('E_PROJECT_NATIVE');
      return await projectV2Boundary(
        () => native_!.presentCloneCredentialPromptV2!(request),
        raw => {
          const answer = projectV2ExactRecord(raw, ['schema_version', 'operation_id', 'host', 'expiry_seconds'], 'E_PROJECT_RESULT_INVALID');
          if (answer.schema_version !== 2 || answer.operation_id !== request.operation_id ||
              !projectV2String(answer.host, 253) || typeof answer.expiry_seconds !== 'number' ||
              !Number.isSafeInteger(answer.expiry_seconds) || answer.expiry_seconds <= 0) {
            return projectV2Fail('E_PROJECT_RESULT_INVALID');
          }
          return {
            schema_version: 2 as const,
            operation_id: answer.operation_id,
            host: answer.host,
            expiry_seconds: answer.expiry_seconds,
          };
        },
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  cancelWorkspaceCloneV2: async (operationIdValue: unknown): Promise<'cancel_requested' | 'not_running'> => {
    try {
      const operationId = projectV2OperationId(operationIdValue);
      const row = native as Partial<NativeLocalProjects> | null;
      if (!hasV2Capabilities(native) || typeof row?.cancelWorkspaceCloneV2 !== 'function') projectV2Fail('E_PROJECT_NATIVE');
      return await projectV2Boundary(
        () => row!.cancelWorkspaceCloneV2!({ schema_version: 1, operation_id: operationId }),
        raw => {
          const answer = projectV2ExactRecord(raw, ['schema_version', 'operation_id', 'status'], 'E_PROJECT_RESULT_INVALID');
          if (answer.schema_version !== 2 || answer.operation_id !== operationId ||
              (answer.status !== 'cancel_requested' && answer.status !== 'not_running')) {
            return projectV2Fail('E_PROJECT_RESULT_INVALID');
          }
          return answer.status;
        },
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  /** What every recorded push of a workspace project proved, oldest first. */
  pushReceiptsV2: async (requestValue: unknown): Promise<ProjectPushReceiptsV2> => {
    try {
      const request = projectV2WorkspaceRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().pushReceiptsV2!(request),
        raw => projectV2Receipts(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  /** `git fetch origin` for a workspace project; cancelled through cancelPushV2 with the same operation id. */
  fetchV2: async (requestValue: unknown): Promise<ProjectFetchResultV2> => {
    try {
      const request = projectV2FetchRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().fetchV2!(request),
        raw => projectV2Fetch(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  /** Moves the current branch to origin's tip only as a fast-forward over an unchanged tree; fetch first. */
  pullFastForwardV2: async (requestValue: unknown): Promise<ProjectPullResultV2> => {
    try {
      const request = projectV2PullRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().pullFastForwardV2!(request),
        raw => projectV2Pull(raw, request.root),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  /**
   * Whether this platform can merge a diverged branch. Separate from the V2
   * set on purpose: a platform without it keeps everything else.
   */
  isMergeAvailable: (): boolean => {
    try {
      return hasV2Capabilities(native) &&
        typeof (native as NativeLocalProjects).mergeRemoteV2 === 'function';
    } catch {
      return false;
    }
  },
  /** Merges the fetched upstream into a diverged branch, only when the merge is clean. */
  mergeRemoteV2: async (requestValue: unknown): Promise<ProjectMergeResultV2> => {
    try {
      const request = projectV2MergeRequest(requestValue);
      const module = requiredV2();
      if (typeof module.mergeRemoteV2 !== 'function') projectV2Fail('E_PROJECT_NATIVE');
      return await projectV2Boundary(
        () => module.mergeRemoteV2!(request),
        raw => projectV2Merge(raw, request),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
  cancelPushV2: async (
    requestValue: unknown,
  ): Promise<ProjectPushCancellationV2> => {
    try {
      const request = projectV2CancelPushRequest(requestValue);
      return await projectV2Boundary(
        () => requiredV2().cancelPushV2!(request),
        raw => projectV2PushCancellation(raw, request.root, request.operation_id),
      );
    } catch (error) {
      throw projectV2Error(error);
    }
  },
};
