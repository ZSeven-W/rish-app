import { nativeImplementationAvailable } from './NativeImplementation';
import { NativeModules, TurboModuleRegistry } from 'react-native';

export type WorkspaceStatus =
  | 'ok'
  | 'stale'
  | 'revoked'
  | 'unavailable'
  | 'not_downloaded';

export type WorkspaceOrigin =
  | 'rish_created'
  | 'imported'
  | 'granted_folder'
  | 'legacy_app_owned';

export type WorkspaceCapability =
  | 'read'
  | 'write'
  | 'git'
  | 'project_context';

export type WorkspaceCapabilitiesV1 = {
  read: boolean;
  write: boolean;
  git: boolean;
  project_context: boolean;
  files_visible: boolean;
};

export type WorkspaceCapabilities = WorkspaceCapabilitiesV1;

export type WorkspaceDescriptorV2 = {
  schema_version: 2;
  workspace_id: string;
  display_name: string;
  origin: WorkspaceOrigin;
  status: WorkspaceStatus;
  binding_revision: number;
  capabilities: WorkspaceCapabilitiesV1;
  created_at: string;
  last_opened_at: string;
};

export type WorkspaceDescriptor = WorkspaceDescriptorV2;

export type WorkspaceListingV1 = {
  schema_version: 1;
  workspaces: readonly WorkspaceDescriptorV2[];
};

export type WorkspaceListing = WorkspaceListingV1;

export type WorkspaceResolveRequestV1 = {
  schema_version: 1;
  workspace_id: string;
  expected_binding_revision: number | null;
  required_capabilities: readonly WorkspaceCapability[];
};

export type WorkspaceResolveRequest = WorkspaceResolveRequestV1;

export type WorkspaceResolveResultV1 = {
  schema_version: 1;
  disposition: 'direct' | 'import_required';
  workspace: WorkspaceDescriptorV2;
};

export type WorkspaceResolveResult = WorkspaceResolveResultV1;

export type WorkspaceCreateRequestV1 = {
  schema_version: 1;
  display_name: string;
  operation_id: string;
};

export type WorkspaceCreateRequest = WorkspaceCreateRequestV1;

export type WorkspaceBootstrapLegacyProjectRequestV1 = {
  schema_version: 1;
  operation_id: string;
  project_id: string;
};

export type WorkspaceFolderPickerRequestV1 = {
  schema_version: 1;
  operation_id: string;
  mode: 'grant_or_import' | 'import_only';
};

export type WorkspaceFolderPickerResultV1 =
  | {
      schema_version: 1;
      status: 'selected';
      workspace: WorkspaceDescriptorV2;
    }
  | {
      schema_version: 1;
      status: 'requires_import';
      selection_id: string;
      display_name: string;
      location_class: 'provider_managed' | 'unknown';
    }
  | { schema_version: 1; status: 'cancelled' };

export type WorkspaceImportSelectionRequestV1 = {
  schema_version: 1;
  selection_id: string;
  operation_id: string;
};

export type WorkspaceSelectionCancelRequestV1 = {
  schema_version: 1;
  selection_id: string;
};

export type WorkspaceSelectionCancelResultV1 = {
  schema_version: 1;
  status: 'cancelled' | 'already_settled';
};

export type WorkspaceRegrantPickerRequestV1 = {
  schema_version: 1;
  workspace_id: string;
  expected_binding_revision: number;
  operation_id: string;
};

export type WorkspaceRegrantPickerResultV1 =
  | {
      schema_version: 1;
      status: 'same_root_selected' | 'different_root_selected';
      selection_id: string;
      display_name: string;
    }
  | { schema_version: 1; status: 'cancelled' };

export type WorkspaceCompleteRegrantRequestV1 = {
  schema_version: 1;
  workspace_id: string;
  expected_binding_revision: number;
  selection_id: string;
  operation_id: string;
};

export type WorkspaceCompleteRegrantResultV1 =
  | {
      schema_version: 1;
      status: 'regranted';
      workspace: WorkspaceDescriptorV2;
    }
  | {
      schema_version: 1;
      status: 'different_root';
      new_workspace: WorkspaceDescriptorV2;
    };

export type WorkspaceForgetRequestV1 = {
  schema_version: 1;
  workspace_id: string;
  expected_binding_revision: number;
  operation_id: string;
  clearance_receipt_id: string;
};

export type WorkspacePrepareDeleteRequestV1 = {
  schema_version: 1;
  workspace_id: string;
  expected_binding_revision: number;
  clearance_receipt_id: string;
};

export type WorkspacePrepareDeleteResultV1 = {
  schema_version: 1;
  confirmation_id: string;
  expires_at: string;
};

export type WorkspaceDeleteRequestV1 = {
  schema_version: 1;
  workspace_id: string;
  expected_binding_revision: number;
  operation_id: string;
  clearance_receipt_id: string;
  confirmation_id: string;
};

export type WorkspaceOperationReceiptV1 = {
  schema_version: 1;
  operation_id: string;
  workspace_id: string;
  operation:
    | 'create'
    | 'import'
    | 'regrant'
    | 'forget'
    | 'delete_owned'
    | 'bootstrap_legacy';
  binding_revision: number;
  registry_generation: number;
  registry_sha256: string;
  outcome: 'committed' | 'purge_pending';
  committed_at: string;
};

export type WorkspaceQueryOperationRequestV1 = {
  schema_version: 1;
  operation_id: string;
};

export type WorkspaceQueryOperationResultV1 =
  | { schema_version: 1; status: 'not_started' | 'in_progress' }
  | {
      schema_version: 1;
      status: 'committed';
      receipt: WorkspaceOperationReceiptV1;
    };

export type WorkspaceCancelPickerRequestV1 = {
  schema_version: 1;
  operation_id: string;
};

export type WorkspaceCancelPickerResultV1 = WorkspaceSelectionCancelResultV1;

export type LocalWorkspacesNativeV1 = {
  list(): Promise<WorkspaceListingV1>;
  create(request: WorkspaceCreateRequestV1): Promise<WorkspaceDescriptorV2>;
  bootstrapLegacyProject(
    request: WorkspaceBootstrapLegacyProjectRequestV1,
  ): Promise<WorkspaceDescriptorV2>;
  presentFolderPicker(
    request: WorkspaceFolderPickerRequestV1,
  ): Promise<WorkspaceFolderPickerResultV1>;
  importSelection(
    request: WorkspaceImportSelectionRequestV1,
  ): Promise<WorkspaceDescriptorV2>;
  cancelSelection(
    request: WorkspaceSelectionCancelRequestV1,
  ): Promise<WorkspaceSelectionCancelResultV1>;
  presentRegrantPicker(
    request: WorkspaceRegrantPickerRequestV1,
  ): Promise<WorkspaceRegrantPickerResultV1>;
  completeRegrant(
    request: WorkspaceCompleteRegrantRequestV1,
  ): Promise<WorkspaceCompleteRegrantResultV1>;
  resolve(
    request: WorkspaceResolveRequestV1,
  ): Promise<WorkspaceResolveResultV1>;
  forget(
    request: WorkspaceForgetRequestV1,
  ): Promise<{ schema_version: 1; status: 'forgotten' }>;
  prepareDeleteOwnedContent(
    request: WorkspacePrepareDeleteRequestV1,
  ): Promise<WorkspacePrepareDeleteResultV1>;
  deleteOwnedContent(
    request: WorkspaceDeleteRequestV1,
  ): Promise<{ schema_version: 1; status: 'deleted' }>;
  queryOperation(
    request: WorkspaceQueryOperationRequestV1,
  ): Promise<WorkspaceQueryOperationResultV1>;
  cancelPicker(
    request: WorkspaceCancelPickerRequestV1,
  ): Promise<WorkspaceCancelPickerResultV1>;
};

const INVALID_CODE = 'E_WORKSPACE_INVALID';
const STATUSES: readonly WorkspaceStatus[] = [
  'ok',
  'stale',
  'revoked',
  'unavailable',
  'not_downloaded',
];
const ORIGINS: readonly WorkspaceOrigin[] = [
  'rish_created',
  'imported',
  'granted_folder',
  'legacy_app_owned',
];
const CAPABILITIES: readonly WorkspaceCapability[] = [
  'read',
  'write',
  'git',
  'project_context',
];

function invalid(message = 'Workspace request is invalid.'): Error & { code: string } {
  return Object.assign(new Error(message), { code: INVALID_CODE });
}

function invalidResponse(): Error & { code: string } {
  return invalid('Workspace bridge response is invalid.');
}

const SNAPSHOT_INVALID = Symbol('workspace-bridge-snapshot-invalid');

function snapshotData(value: unknown, ancestors = new Set<object>()): unknown {
  if (value === null || typeof value !== 'object') return value;
  if (ancestors.has(value)) return SNAPSHOT_INVALID;
  ancestors.add(value);
  try {
    const descriptors = Object.getOwnPropertyDescriptors(value);
    const descriptorKeys = Reflect.ownKeys(descriptors);
    if (descriptorKeys.some(name => typeof name === 'symbol')) return SNAPSHOT_INVALID;
    const names = descriptorKeys as string[];
    if (Array.isArray(value)) {
      if (Object.getPrototypeOf(value) !== Array.prototype) return SNAPSHOT_INVALID;
      const lengthDescriptor = descriptors.length;
      if (lengthDescriptor === undefined || lengthDescriptor.enumerable ||
          lengthDescriptor.get !== undefined || lengthDescriptor.set !== undefined ||
          typeof lengthDescriptor.value !== 'number' ||
          !Number.isSafeInteger(lengthDescriptor.value) || lengthDescriptor.value < 0) {
        return SNAPSHOT_INVALID;
      }
      const length = lengthDescriptor.value;
      if (names.length !== length + 1 || !names.includes('length')) return SNAPSHOT_INVALID;
      const result: unknown[] = [];
      for (let index = 0; index < length; index += 1) {
        const name = String(index);
        const descriptor = descriptors[name];
        if (descriptor === undefined || !descriptor.enumerable ||
            descriptor.get !== undefined || descriptor.set !== undefined) {
          return SNAPSHOT_INVALID;
        }
        const child = snapshotData(descriptor.value, ancestors);
        if (child === SNAPSHOT_INVALID) return SNAPSHOT_INVALID;
        result.push(child);
      }
      for (const name of names) {
        if (name !== 'length' && !/^(0|[1-9][0-9]*)$/.test(name)) {
          return SNAPSHOT_INVALID;
        }
      }
      return result;
    }
    if (Object.getPrototypeOf(value) !== Object.prototype) return SNAPSHOT_INVALID;
    const result: Record<string, unknown> = {};
    for (const name of names) {
      const descriptor = descriptors[name];
      if (descriptor === undefined || !descriptor.enumerable ||
          descriptor.get !== undefined || descriptor.set !== undefined) {
        return SNAPSHOT_INVALID;
      }
      const child = snapshotData(descriptor.value, ancestors);
      if (child === SNAPSHOT_INVALID) return SNAPSHOT_INVALID;
      result[name] = child;
    }
    return result;
  } catch {
    return SNAPSHOT_INVALID;
  } finally {
    ancestors.delete(value);
  }
}

function snapshotObject(value: unknown): Record<string, unknown> | null {
  const snapshot = snapshotData(value);
  return snapshot !== SNAPSHOT_INVALID &&
      typeof snapshot === 'object' && snapshot !== null &&
      !Array.isArray(snapshot)
    ? snapshot as Record<string, unknown>
    : null;
}

function snapshotExact(
  value: unknown,
  keys: readonly string[],
): Record<string, unknown> | null {
  const snapshot = snapshotObject(value);
  if (snapshot === null) return null;
  const names = Object.keys(snapshot);
  return names.length === keys.length && keys.every(key => names.includes(key))
    ? snapshot
    : null;
}

function isDataArray(value: unknown): value is readonly unknown[] {
  const snapshot = snapshotData(value);
  return snapshot !== SNAPSHOT_INVALID && Array.isArray(snapshot);
}

function isSchemaVersion(value: unknown, expected: number): value is number {
  return typeof value === 'number' && value === expected;
}

function isSafeInteger(value: unknown, allowNull: true): value is number | null;
function isSafeInteger(value: unknown, allowNull?: false): value is number;
function isSafeInteger(value: unknown, allowNull = false): value is number | null {
  return (
    (allowNull && value === null) ||
    (typeof value === 'number' &&
      Number.isSafeInteger(value) &&
      value >= 1 &&
      !Object.is(value, -0))
  );
}

function isNonNegativeSafeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && !Object.is(value, -0) && value >= 0;
}

function isUuid(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)
  );
}

function isDigest(value: unknown): value is string {
  return typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
}

function utf8Bytes(value: string): number {
  let bytes = 0;
  for (const character of value) {
    const codePoint = character.codePointAt(0);
    if (
      codePoint === undefined ||
      (codePoint >= 0xd800 && codePoint <= 0xdfff)
    ) {
      return Number.POSITIVE_INFINITY;
    }
    if (codePoint <= 0x7f) bytes += 1;
    else if (codePoint <= 0x7ff) bytes += 2;
    else if (codePoint <= 0xffff) bytes += 3;
    else bytes += 4;
  }
  return bytes;
}

function isDisplayName(value: unknown): value is string {
  if (typeof value !== 'string' || value.length === 0 || utf8Bytes(value) > 120) {
    return false;
  }
  for (const character of value) {
    const codePoint = character.codePointAt(0);
    if (
      codePoint === undefined ||
      codePoint <= 0x1f ||
      codePoint === 0x7f ||
      character === '/' ||
      character === '\\' ||
      character === ':'
    ) {
      return false;
    }
  }
  const folded = value.toLowerCase();
  return (
    value.normalize('NFC') === value &&
    value.trim() === value &&
    !value.startsWith('.') &&
    folded !== 'rish workspaces' &&
    !folded.startsWith('.rish-')
  );
}

function isCapabilities(value: unknown): value is readonly WorkspaceCapability[] {
  const snapshot = snapshotData(value);
  if (snapshot === SNAPSHOT_INVALID || !Array.isArray(snapshot) ||
      snapshot.length > CAPABILITIES.length) return false;
  let previous = -1;
  for (const item of snapshot) {
    if (typeof item !== 'string') return false;
    const index = CAPABILITIES.indexOf(item as WorkspaceCapability);
    if (index < 0 || index <= previous) return false;
    previous = index;
  }
  return true;
}

function isTimestamp(value: unknown): value is string {
  if (
    typeof value !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)
  ) {
    return false;
  }
  const parsed = new Date(value);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString() === value;
}

function cloneCapabilities(value: readonly WorkspaceCapability[]): readonly WorkspaceCapability[] {
  return value.slice();
}

function parseCapabilities(value: unknown): WorkspaceCapabilitiesV1 {
  const keys = ['read', 'write', 'git', 'project_context', 'files_visible'] as const;
  const captured = snapshotExact(value, keys);
  if (
    captured === null ||
    typeof captured.read !== 'boolean' ||
    typeof captured.write !== 'boolean' ||
    typeof captured.git !== 'boolean' ||
    typeof captured.project_context !== 'boolean' ||
    typeof captured.files_visible !== 'boolean'
  ) {
    throw invalidResponse();
  }
  return {
    read: captured.read,
    write: captured.write,
    git: captured.git,
    project_context: captured.project_context,
    files_visible: captured.files_visible,
  };
}

function parseDescriptor(value: unknown): WorkspaceDescriptorV2 {
  const keys = [
    'schema_version',
    'workspace_id',
    'display_name',
    'origin',
    'status',
    'binding_revision',
    'capabilities',
    'created_at',
    'last_opened_at',
  ] as const;
  const captured = snapshotExact(value, keys);
  if (
    captured === null ||
    !isSchemaVersion(captured.schema_version, 2) ||
    !isUuid(captured.workspace_id) ||
    !isDisplayName(captured.display_name) ||
    !ORIGINS.includes(captured.origin as WorkspaceOrigin) ||
    !STATUSES.includes(captured.status as WorkspaceStatus) ||
    !isSafeInteger(captured.binding_revision) ||
    !isTimestamp(captured.created_at) ||
    !isTimestamp(captured.last_opened_at)
  ) {
    throw invalidResponse();
  }
  const capabilities = parseCapabilities(captured.capabilities);
  if (captured.status !== 'ok' &&
      (capabilities.read || capabilities.write || capabilities.git || capabilities.project_context)) {
    throw invalidResponse();
  }
  return {
    schema_version: 2,
    workspace_id: captured.workspace_id,
    display_name: captured.display_name,
    origin: captured.origin as WorkspaceOrigin,
    status: captured.status as WorkspaceStatus,
    binding_revision: captured.binding_revision,
    capabilities,
    created_at: captured.created_at,
    last_opened_at: captured.last_opened_at,
  };
}

function parseListing(value: unknown): WorkspaceListingV1 {
  const captured = snapshotExact(value, ['schema_version', 'workspaces']);
  if (captured === null ||
      !isSchemaVersion(captured.schema_version, 1) ||
      !isDataArray(captured.workspaces)) {
    throw invalidResponse();
  }
  return {
    schema_version: 1,
    workspaces: (captured.workspaces as readonly unknown[]).map(parseDescriptor),
  };
}

function parseFolderPicker(value: unknown): WorkspaceFolderPickerResultV1 {
  const captured = snapshotObject(value);
  if (captured === null || typeof captured.status !== 'string') {
    throw invalidResponse();
  }
  if (captured.status === 'selected') {
    const selected = snapshotExact(captured, ['schema_version', 'status', 'workspace']);
    if (selected === null || !isSchemaVersion(selected.schema_version, 1)) throw invalidResponse();
    return {
      schema_version: 1,
      status: 'selected',
      workspace: parseDescriptor(selected.workspace),
    };
  }
  if (captured.status === 'requires_import') {
    const requiresImport = snapshotExact(captured, [
      'schema_version',
      'status',
      'selection_id',
      'display_name',
      'location_class',
    ]);
    if (requiresImport === null ||
        !isSchemaVersion(requiresImport.schema_version, 1) ||
        !isUuid(requiresImport.selection_id) ||
        !isDisplayName(requiresImport.display_name) ||
        (requiresImport.location_class !== 'provider_managed' && requiresImport.location_class !== 'unknown')) {
      throw invalidResponse();
    }
    return {
      schema_version: 1,
      status: 'requires_import',
      selection_id: requiresImport.selection_id,
      display_name: requiresImport.display_name,
      location_class: requiresImport.location_class,
    };
  }
  const cancelled = snapshotExact(captured, ['schema_version', 'status']);
  if (captured.status === 'cancelled' && cancelled !== null &&
      isSchemaVersion(cancelled.schema_version, 1)) {
    return { schema_version: 1, status: 'cancelled' };
  }
  throw invalidResponse();
}

function parseSelectionCancel(value: unknown): WorkspaceSelectionCancelResultV1 {
  const captured = snapshotExact(value, ['schema_version', 'status']);
  if (captured === null ||
      !isSchemaVersion(captured.schema_version, 1) ||
      (captured.status !== 'cancelled' && captured.status !== 'already_settled')) {
    throw invalidResponse();
  }
  return { schema_version: 1, status: captured.status };
}

function parseRegrantPicker(value: unknown): WorkspaceRegrantPickerResultV1 {
  const captured = snapshotObject(value);
  if (captured === null || typeof captured.status !== 'string') {
    throw invalidResponse();
  }
  if (captured.status === 'cancelled') {
    const cancelled = snapshotExact(captured, ['schema_version', 'status']);
    if (cancelled === null || !isSchemaVersion(cancelled.schema_version, 1)) throw invalidResponse();
    return { schema_version: 1, status: 'cancelled' };
  }
  const selected = snapshotExact(captured, ['schema_version', 'status', 'selection_id', 'display_name']);
  if ((captured.status === 'same_root_selected' || captured.status === 'different_root_selected') &&
      selected !== null &&
      isSchemaVersion(selected.schema_version, 1) &&
      isUuid(selected.selection_id) &&
      isDisplayName(selected.display_name)) {
    return {
      schema_version: 1,
      status: captured.status,
      selection_id: selected.selection_id,
      display_name: selected.display_name,
    };
  }
  throw invalidResponse();
}

function parseCompleteRegrant(value: unknown): WorkspaceCompleteRegrantResultV1 {
  const captured = snapshotObject(value);
  if (captured === null || typeof captured.status !== 'string') {
    throw invalidResponse();
  }
  const regranted = snapshotExact(captured, ['schema_version', 'status', 'workspace']);
  if (captured.status === 'regranted' &&
      regranted !== null &&
      isSchemaVersion(regranted.schema_version, 1)) {
    return { schema_version: 1, status: 'regranted', workspace: parseDescriptor(regranted.workspace) };
  }
  const differentRoot = snapshotExact(captured, ['schema_version', 'status', 'new_workspace']);
  if (captured.status === 'different_root' &&
      differentRoot !== null &&
      isSchemaVersion(differentRoot.schema_version, 1)) {
    return {
      schema_version: 1,
      status: 'different_root',
      new_workspace: parseDescriptor(differentRoot.new_workspace),
    };
  }
  throw invalidResponse();
}

function parseResolve(value: unknown): WorkspaceResolveResultV1 {
  const captured = snapshotExact(value, ['schema_version', 'disposition', 'workspace']);
  if (captured === null ||
      !isSchemaVersion(captured.schema_version, 1) ||
      (captured.disposition !== 'direct' && captured.disposition !== 'import_required')) {
    throw invalidResponse();
  }
  return {
    schema_version: 1,
    disposition: captured.disposition,
    workspace: parseDescriptor(captured.workspace),
  };
}

function hasOperationalCapabilities(value: WorkspaceDescriptorV2): boolean {
  return value.capabilities.read || value.capabilities.write ||
      value.capabilities.git || value.capabilities.project_context;
}

function parseForget(value: unknown): { schema_version: 1; status: 'forgotten' } {
  const captured = snapshotExact(value, ['schema_version', 'status']);
  if (captured === null ||
      !isSchemaVersion(captured.schema_version, 1) ||
      captured.status !== 'forgotten') throw invalidResponse();
  return { schema_version: 1, status: 'forgotten' };
}

function parsePrepareDelete(value: unknown): WorkspacePrepareDeleteResultV1 {
  const captured = snapshotExact(value, ['schema_version', 'confirmation_id', 'expires_at']);
  if (captured === null ||
      !isSchemaVersion(captured.schema_version, 1) ||
      !isUuid(captured.confirmation_id) ||
      !isTimestamp(captured.expires_at)) throw invalidResponse();
  return {
    schema_version: 1,
    confirmation_id: captured.confirmation_id,
    expires_at: captured.expires_at,
  };
}

function parseDelete(value: unknown): { schema_version: 1; status: 'deleted' } {
  const captured = snapshotExact(value, ['schema_version', 'status']);
  if (captured === null ||
      !isSchemaVersion(captured.schema_version, 1) ||
      captured.status !== 'deleted') throw invalidResponse();
  return { schema_version: 1, status: 'deleted' };
}

function parseReceipt(value: unknown): WorkspaceOperationReceiptV1 {
  const keys = [
    'schema_version',
    'operation_id',
    'workspace_id',
    'operation',
    'binding_revision',
    'registry_generation',
    'registry_sha256',
    'outcome',
    'committed_at',
  ] as const;
  const operations = ['create', 'import', 'regrant', 'forget', 'delete_owned', 'bootstrap_legacy'] as const;
  const captured = snapshotExact(value, keys);
  if (captured === null ||
      !isSchemaVersion(captured.schema_version, 1) ||
      !isUuid(captured.operation_id) ||
      !isUuid(captured.workspace_id) ||
      !operations.includes(captured.operation as (typeof operations)[number]) ||
      !isSafeInteger(captured.binding_revision) ||
      !isNonNegativeSafeInteger(captured.registry_generation) ||
      !isDigest(captured.registry_sha256) ||
      (captured.outcome !== 'committed' && captured.outcome !== 'purge_pending') ||
      !isTimestamp(captured.committed_at)) {
    throw invalidResponse();
  }
  return {
    schema_version: 1,
    operation_id: captured.operation_id,
    workspace_id: captured.workspace_id,
    operation: captured.operation as WorkspaceOperationReceiptV1['operation'],
    binding_revision: captured.binding_revision,
    registry_generation: captured.registry_generation,
    registry_sha256: captured.registry_sha256,
    outcome: captured.outcome,
    committed_at: captured.committed_at,
  };
}

function parseQuery(value: unknown): WorkspaceQueryOperationResultV1 {
  const captured = snapshotObject(value);
  if (captured === null || typeof captured.status !== 'string') {
    throw invalidResponse();
  }
  const basic = snapshotExact(captured, ['schema_version', 'status']);
  if ((captured.status === 'not_started' || captured.status === 'in_progress') &&
      basic !== null &&
      isSchemaVersion(basic.schema_version, 1)) {
    return { schema_version: 1, status: captured.status };
  }
  const committed = snapshotExact(captured, ['schema_version', 'status', 'receipt']);
  if (captured.status === 'committed' &&
      committed !== null &&
      isSchemaVersion(committed.schema_version, 1)) {
    return { schema_version: 1, status: 'committed', receipt: parseReceipt(committed.receipt) };
  }
  throw invalidResponse();
}

function parseRequest<T>(
  value: unknown,
  keys: readonly string[],
  check: (value: Record<string, unknown>) => boolean,
  copy: (value: Record<string, unknown>) => T,
): T {
  const captured = snapshotExact(value, keys);
  if (captured === null || !check(captured)) throw invalid();
  return copy(captured);
}

function currentNative(): unknown {
  try {
    const turbo = TurboModuleRegistry.get('LocalWorkspaces');
    if (typeof turbo === 'object' && turbo !== null) return turbo;
  } catch {
    // Fall through to the legacy NativeModules bridge.
  }
  try {
    const legacy = Reflect.get(NativeModules, 'LocalWorkspaces') as unknown;
    return typeof legacy === 'object' && legacy !== null ? legacy : null;
  } catch {
    return null;
  }
}

function requiredNative(): LocalWorkspacesNativeV1 {
  const value = currentNative();
  if (!isNative(value)) {
    throw Object.assign(new Error('LocalWorkspaces native module is not linked'), {
      code: 'E_WORKSPACE_UNAVAILABLE',
    });
  }
  return value;
}

function isNative(value: unknown): value is LocalWorkspacesNativeV1 {
  if (!nativeImplementationAvailable(value)) return false;
  if (typeof value !== 'object' || value === null) return false;
  try {
    // React Native may expose this object through a HostObject. Capability
    // discovery must therefore use property reads only: prototype walking and
    // own-key enumeration are not portable across bridge implementations.
    const requiredMethods: readonly (keyof LocalWorkspacesNativeV1)[] = [
      'list',
      'create',
      'bootstrapLegacyProject',
      'presentFolderPicker',
      'importSelection',
      'cancelSelection',
      'presentRegrantPicker',
      'completeRegrant',
      'resolve',
      'forget',
      'prepareDeleteOwnedContent',
      'deleteOwnedContent',
      'queryOperation',
      'cancelPicker',
    ];
    const candidate = value as Partial<Record<keyof LocalWorkspacesNativeV1, unknown>>;
    const forbiddenAliases = [
      'resolveMetadata',
      'grantFolder',
      'importFolder',
    ] as const;
    return (
      requiredMethods.every(name => typeof Reflect.get(candidate, name) === 'function') &&
      forbiddenAliases.every(name => Reflect.get(candidate, name) === undefined)
    );
  } catch {
    return false;
  }
}

export const LocalWorkspaces = {
  isAvailable: () => isNative(currentNative()),

  /**
   * Whether forgetting a workspace and deleting its owned content are real
   * on this platform. The native module says so with a constant; a module
   * that only stubs the methods says nothing, and nothing is refused before
   * any state changes rather than after the session has been cleared.
   */
  isRemovalAvailable: (): boolean => {
    const value = currentNative();
    if (!isNative(value)) return false;
    try {
      return Reflect.get(value as object, 'removal') === true;
    } catch {
      return false;
    }
  },

  list: async (): Promise<WorkspaceListingV1> => parseListing(await requiredNative().list()),

  create: async (request: WorkspaceCreateRequestV1): Promise<WorkspaceDescriptorV2> => {
    const parsed = parseRequest<WorkspaceCreateRequestV1>(
      request,
      ['schema_version', 'display_name', 'operation_id'],
      value =>
        isSchemaVersion(value.schema_version, 1) &&
        isDisplayName(value.display_name) &&
        isUuid(value.operation_id),
      value => ({
        schema_version: 1,
        display_name: value.display_name as string,
        operation_id: value.operation_id as string,
      }),
    );
    return parseDescriptor(await requiredNative().create(parsed));
  },

  bootstrapLegacyProject: async (
    request: WorkspaceBootstrapLegacyProjectRequestV1,
  ): Promise<WorkspaceDescriptorV2> => {
    const parsed = parseRequest<WorkspaceBootstrapLegacyProjectRequestV1>(
      request,
      ['schema_version', 'operation_id', 'project_id'],
      value =>
        isSchemaVersion(value.schema_version, 1) &&
        isUuid(value.operation_id) &&
        isUuid(value.project_id),
      value => ({
        schema_version: 1,
        operation_id: value.operation_id as string,
        project_id: value.project_id as string,
      }),
    );
    return parseDescriptor(
      await requiredNative().bootstrapLegacyProject(parsed),
    );
  },

  presentFolderPicker: async (
    request: WorkspaceFolderPickerRequestV1,
  ): Promise<WorkspaceFolderPickerResultV1> => {
    const parsed = parseRequest<WorkspaceFolderPickerRequestV1>(
      request,
      ['schema_version', 'operation_id', 'mode'],
      value =>
        isSchemaVersion(value.schema_version, 1) &&
        isUuid(value.operation_id) &&
        (value.mode === 'grant_or_import' || value.mode === 'import_only'),
      value => ({
        schema_version: 1,
        operation_id: value.operation_id as string,
        mode: value.mode as WorkspaceFolderPickerRequestV1['mode'],
      }),
    );
    return parseFolderPicker(await requiredNative().presentFolderPicker(parsed));
  },

  importSelection: async (
    request: WorkspaceImportSelectionRequestV1,
  ): Promise<WorkspaceDescriptorV2> => {
    const parsed = parseRequest<WorkspaceImportSelectionRequestV1>(
      request,
      ['schema_version', 'selection_id', 'operation_id'],
      value =>
        isSchemaVersion(value.schema_version, 1) &&
        isUuid(value.selection_id) &&
        isUuid(value.operation_id),
      value => ({
        schema_version: 1,
        selection_id: value.selection_id as string,
        operation_id: value.operation_id as string,
      }),
    );
    return parseDescriptor(await requiredNative().importSelection(parsed));
  },

  cancelSelection: async (
    request: WorkspaceSelectionCancelRequestV1,
  ): Promise<WorkspaceSelectionCancelResultV1> => {
    const parsed = parseRequest<WorkspaceSelectionCancelRequestV1>(
      request,
      ['schema_version', 'selection_id'],
      value => isSchemaVersion(value.schema_version, 1) && isUuid(value.selection_id),
      value => ({ schema_version: 1, selection_id: value.selection_id as string }),
    );
    return parseSelectionCancel(await requiredNative().cancelSelection(parsed));
  },

  presentRegrantPicker: async (
    request: WorkspaceRegrantPickerRequestV1,
  ): Promise<WorkspaceRegrantPickerResultV1> => {
    const parsed = parseRequest<WorkspaceRegrantPickerRequestV1>(
      request,
      ['schema_version', 'workspace_id', 'expected_binding_revision', 'operation_id'],
      value =>
        isSchemaVersion(value.schema_version, 1) &&
        isUuid(value.workspace_id) &&
        isSafeInteger(value.expected_binding_revision) &&
        isUuid(value.operation_id),
      value => ({
        schema_version: 1,
        workspace_id: value.workspace_id as string,
        expected_binding_revision: value.expected_binding_revision as number,
        operation_id: value.operation_id as string,
      }),
    );
    return parseRegrantPicker(await requiredNative().presentRegrantPicker(parsed));
  },

  completeRegrant: async (
    request: WorkspaceCompleteRegrantRequestV1,
  ): Promise<WorkspaceCompleteRegrantResultV1> => {
    const parsed = parseRequest<WorkspaceCompleteRegrantRequestV1>(
      request,
      ['schema_version', 'workspace_id', 'expected_binding_revision', 'selection_id', 'operation_id'],
      value =>
        isSchemaVersion(value.schema_version, 1) &&
        isUuid(value.workspace_id) &&
        isSafeInteger(value.expected_binding_revision) &&
        isUuid(value.selection_id) &&
        isUuid(value.operation_id),
      value => ({
        schema_version: 1,
        workspace_id: value.workspace_id as string,
        expected_binding_revision: value.expected_binding_revision as number,
        selection_id: value.selection_id as string,
        operation_id: value.operation_id as string,
      }),
    );
    return parseCompleteRegrant(await requiredNative().completeRegrant(parsed));
  },

  resolve: async (
    request: WorkspaceResolveRequestV1,
  ): Promise<WorkspaceResolveResultV1> => {
    const parsed = parseRequest<WorkspaceResolveRequestV1>(
      request,
      ['schema_version', 'workspace_id', 'expected_binding_revision', 'required_capabilities'],
      value =>
        isSchemaVersion(value.schema_version, 1) &&
        isUuid(value.workspace_id) &&
        isSafeInteger(value.expected_binding_revision, true) &&
        isCapabilities(value.required_capabilities),
      value => ({
        schema_version: 1,
        workspace_id: value.workspace_id as string,
        expected_binding_revision: value.expected_binding_revision as number | null,
        required_capabilities: cloneCapabilities(value.required_capabilities as readonly WorkspaceCapability[]),
      }),
    );
    const result = parseResolve(await requiredNative().resolve(parsed));
    if (parsed.expected_binding_revision === null &&
        hasOperationalCapabilities(result.workspace)) {
      throw invalidResponse();
    }
    return result;
  },

  forget: async (
    request: WorkspaceForgetRequestV1,
  ): Promise<{ schema_version: 1; status: 'forgotten' }> => {
    const parsed = parseRequest<WorkspaceForgetRequestV1>(
      request,
      ['schema_version', 'workspace_id', 'expected_binding_revision', 'operation_id', 'clearance_receipt_id'],
      value =>
        isSchemaVersion(value.schema_version, 1) &&
        isUuid(value.workspace_id) &&
        isSafeInteger(value.expected_binding_revision) &&
        isUuid(value.operation_id) &&
        isUuid(value.clearance_receipt_id),
      value => ({
        schema_version: 1,
        workspace_id: value.workspace_id as string,
        expected_binding_revision: value.expected_binding_revision as number,
        operation_id: value.operation_id as string,
        clearance_receipt_id: value.clearance_receipt_id as string,
      }),
    );
    return parseForget(await requiredNative().forget(parsed));
  },

  prepareDeleteOwnedContent: async (
    request: WorkspacePrepareDeleteRequestV1,
  ): Promise<WorkspacePrepareDeleteResultV1> => {
    const parsed = parseRequest<WorkspacePrepareDeleteRequestV1>(
      request,
      ['schema_version', 'workspace_id', 'expected_binding_revision', 'clearance_receipt_id'],
      value =>
        isSchemaVersion(value.schema_version, 1) &&
        isUuid(value.workspace_id) &&
        isSafeInteger(value.expected_binding_revision) &&
        isUuid(value.clearance_receipt_id),
      value => ({
        schema_version: 1,
        workspace_id: value.workspace_id as string,
        expected_binding_revision: value.expected_binding_revision as number,
        clearance_receipt_id: value.clearance_receipt_id as string,
      }),
    );
    return parsePrepareDelete(await requiredNative().prepareDeleteOwnedContent(parsed));
  },

  deleteOwnedContent: async (
    request: WorkspaceDeleteRequestV1,
  ): Promise<{ schema_version: 1; status: 'deleted' }> => {
    const parsed = parseRequest<WorkspaceDeleteRequestV1>(
      request,
      [
        'schema_version',
        'workspace_id',
        'expected_binding_revision',
        'operation_id',
        'clearance_receipt_id',
        'confirmation_id',
      ],
      value =>
        isSchemaVersion(value.schema_version, 1) &&
        isUuid(value.workspace_id) &&
        isSafeInteger(value.expected_binding_revision) &&
        isUuid(value.operation_id) &&
        isUuid(value.clearance_receipt_id) &&
        isUuid(value.confirmation_id),
      value => ({
        schema_version: 1,
        workspace_id: value.workspace_id as string,
        expected_binding_revision: value.expected_binding_revision as number,
        operation_id: value.operation_id as string,
        clearance_receipt_id: value.clearance_receipt_id as string,
        confirmation_id: value.confirmation_id as string,
      }),
    );
    return parseDelete(await requiredNative().deleteOwnedContent(parsed));
  },

  queryOperation: async (
    request: WorkspaceQueryOperationRequestV1,
  ): Promise<WorkspaceQueryOperationResultV1> => {
    const parsed = parseRequest<WorkspaceQueryOperationRequestV1>(
      request,
      ['schema_version', 'operation_id'],
      value => isSchemaVersion(value.schema_version, 1) && isUuid(value.operation_id),
      value => ({ schema_version: 1, operation_id: value.operation_id as string }),
    );
    return parseQuery(await requiredNative().queryOperation(parsed));
  },

  cancelPicker: async (
    request: WorkspaceCancelPickerRequestV1,
  ): Promise<WorkspaceCancelPickerResultV1> => {
    const parsed = parseRequest<WorkspaceCancelPickerRequestV1>(
      request,
      ['schema_version', 'operation_id'],
      value => isSchemaVersion(value.schema_version, 1) && isUuid(value.operation_id),
      value => ({ schema_version: 1, operation_id: value.operation_id as string }),
    );
    return parseSelectionCancel(await requiredNative().cancelPicker(parsed));
  },
};

export type LocalWorkspacesNative = LocalWorkspacesNativeV1;
