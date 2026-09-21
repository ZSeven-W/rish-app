import { NativeModules } from 'react-native';

import { workspaceRoot } from '../src/native/WorkspaceRoot';

const WORKSPACE_ID = '11111111-1111-4111-8111-111111111111';
const PROJECT_ID = '22222222-2222-4222-8222-222222222222';
const OPERATION_ID = '33333333-3333-4333-8333-333333333333';
const CREDENTIAL_REFERENCE = 'credential-reference';
const REVISION = 'a'.repeat(64);
const OID = 'b'.repeat(40);
const ROOT = workspaceRoot(WORKSPACE_ID, 1, PROJECT_ID);
const FILES_ROOT = workspaceRoot(WORKSPACE_ID, 1, null);
const FILE = {
  path: 'README.md',
  name: 'README.md',
  kind: 'file' as const,
  size: 10,
  modified_at: '2026-08-31T00:00:00.000Z',
  revision: REVISION,
};

const stubWorkspace = {
  listV2: jest.fn(),
  readV2: jest.fn(),
  writeV2: jest.fn(),
};

const stubProjects = {
  attachWorkspaceProject: jest.fn(),
  projectForWorkspaceV2: jest.fn(),
  prepareProjectDetachV1: jest.fn(),
  commitProjectDetachV1: jest.fn(),
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
  fetchV2: jest.fn(),
  pullFastForwardV2: jest.fn(),
  pushReceiptsV2: jest.fn(),
};

(NativeModules as Record<string, unknown>).LocalWorkspace = stubWorkspace;
(NativeModules as Record<string, unknown>).LocalProjects = stubProjects;

const { executeAgentTool, filterAgentToolDefinitions } = jest.requireActual(
  '../src/agent/AgentTools',
) as typeof import('../src/agent/AgentTools');

const CTX = {
  root: ROOT,
  gitHttpsProxyUrl: null,
  toolPermission: 'workspace-write' as const,
  operationId: OPERATION_ID,
  credentialReference: CREDENTIAL_REFERENCE,
};

function status() {
  return {
    schema_version: 2,
    root: ROOT,
    project_id: PROJECT_ID,
    branch: 'main',
    head_oid: OID,
    clean: true,
    has_conflicts: false,
    ahead: 0,
    behind: 0,
    entries: [],
  };
}

function commit() {
  return {
    schema_version: 2,
    root: ROOT,
    project_id: PROJECT_ID,
    oid: OID,
    summary: 'Add X',
    committed_at: '2026-08-31T00:00:00.000Z',
  };
}

function push() {
  return {
    schema_version: 2,
    root: ROOT,
    project_id: PROJECT_ID,
    remote: 'origin' as const,
    branch: 'main',
    oid: OID,
    pushed_at: '2026-08-31T00:00:00.000Z',
  };
}

beforeEach(() => {
  jest.clearAllMocks();
  stubWorkspace.listV2.mockImplementation((request: { path: string }) =>
    Promise.resolve({
      schema_version: 1,
      root: FILES_ROOT,
      path: request.path,
      entries:
        request.path.length === 0
          ? [FILE]
          : [
              {
                ...FILE,
                path: `${request.path}/${FILE.name}`,
              },
            ],
    }),
  );
  stubWorkspace.readV2.mockResolvedValue({
    schema_version: 1,
    root: FILES_ROOT,
    path: FILE.path,
    file: FILE,
    content: 'Hello Rish',
  });
  stubWorkspace.writeV2.mockImplementation((request: { path: string }) =>
    Promise.resolve({
      schema_version: 1,
      root: FILES_ROOT,
      file: {
        ...FILE,
        path: request.path,
        name: request.path.split('/').pop(),
      },
      created: false,
    }),
  );
  stubProjects.statusV2.mockResolvedValue(status());
  stubProjects.stageAllV2.mockResolvedValue(status());
  stubProjects.commitV2.mockResolvedValue(commit());
  stubProjects.pushV2.mockResolvedValue(push());
});

test('invalid roots refuse every tool before native work', async () => {
  const outcome = await executeAgentTool(
    { ...CTX, root: null as never },
    'read_file',
    '{"path":"README.md"}',
  );
  expect(outcome).toEqual({
    ok: false,
    outputDigest: '',
    detail: 'E_AGENT_BAD_ROOT',
  });
  expect(stubWorkspace.readV2).not.toHaveBeenCalled();
});

test('unknown tool names fail safe', async () => {
  const outcome = await executeAgentTool(CTX, 'deploy_prod', '{}');
  expect(outcome.ok).toBe(false);
  expect(outcome.detail).toBe('E_AGENT_UNKNOWN_TOOL');
});

test('malformed argument JSON fails with a structured code', async () => {
  const outcome = await executeAgentTool(CTX, 'read_file', '{broken');
  expect(outcome.ok).toBe(false);
  expect(outcome.detail).toBe('E_AGENT_BAD_ARGUMENTS');
});

test.each([['/etc/passwd'], ['../../secrets'], ['a/../b'], ['.git/config']])(
  'refuses unsafe path %s',
  async badPath => {
    const outcome = await executeAgentTool(
      CTX,
      'read_file',
      JSON.stringify({ path: badPath }),
    );
    expect(outcome.ok).toBe(false);
    expect(outcome.detail).toBe('E_AGENT_BAD_PATH');
  },
);

test('list_dir sends the workspace-only root and a bounded V2 request', async () => {
  const outcome = await executeAgentTool(
    CTX,
    'list_dir',
    JSON.stringify({ path: 'src' }),
  );

  expect(outcome.ok).toBe(true);
  expect(outcome.outputDigest).toContain('1');
  expect(stubWorkspace.listV2).toHaveBeenCalledWith({
    schema_version: 1,
    root: FILES_ROOT,
    path: 'src',
    max_entries: 1000,
  });
});

test('read_file returns a byte-count digest without leaking content', async () => {
  const outcome = await executeAgentTool(
    CTX,
    'read_file',
    JSON.stringify({ path: 'README.md' }),
  );

  expect(outcome.ok).toBe(true);
  expect(outcome.outputDigest).toMatch(/^bytes:10:sha1:[0-9a-f]{8}$/);
  expect(JSON.stringify(outcome)).not.toContain('Hello Rish');
  expect(stubWorkspace.readV2).toHaveBeenCalledWith({
    schema_version: 1,
    root: FILES_ROOT,
    path: 'README.md',
    max_bytes: 1024 * 1024,
  });
});

test('write_file requires an explicit absent or known revision', async () => {
  const missing = await executeAgentTool(
    CTX,
    'write_file',
    JSON.stringify({ path: 'NOTES.md', content: 'Rulof' }),
  );
  expect(missing).toMatchObject({
    ok: false,
    detail: 'E_AGENT_EXPECTED_REVISION_REQUIRED',
  });
  expect(stubWorkspace.writeV2).not.toHaveBeenCalled();

  const absent = await executeAgentTool(
    CTX,
    'write_file',
    JSON.stringify({
      path: 'NOTES.md',
      content: 'Rulof',
      expected_revision: null,
    }),
  );
  expect(absent.ok).toBe(true);
  expect(stubWorkspace.writeV2).toHaveBeenCalledWith({
    schema_version: 1,
    root: FILES_ROOT,
    path: 'NOTES.md',
    content: 'Rulof',
    expected_revision: null,
    create_only: true,
  });

  const known = await executeAgentTool(
    CTX,
    'write_file',
    JSON.stringify({
      path: 'NOTES.md',
      content: 'Rulof',
      expected_revision: REVISION,
    }),
  );
  expect(known.ok).toBe(true);
  expect(stubWorkspace.writeV2).toHaveBeenLastCalledWith({
    schema_version: 1,
    root: FILES_ROOT,
    path: 'NOTES.md',
    content: 'Rulof',
    expected_revision: REVISION,
    create_only: false,
  });
});

test('read-only execution refuses every mutating tool', async () => {
  const readOnly = { ...CTX, toolPermission: 'read-only' as const };
  for (const [name, args] of [
    ['write_file', { path: 'a', content: 'x', expected_revision: null }],
    ['git_commit', { message: 'commit' }],
    ['git_push', {}],
  ] as const) {
    const outcome = await executeAgentTool(
      readOnly,
      name,
      JSON.stringify(args),
    );
    expect(outcome).toMatchObject({ ok: false, detail: 'E_AGENT_READ_ONLY' });
  }
  expect(stubWorkspace.writeV2).not.toHaveBeenCalled();
  expect(stubProjects.commitV2).not.toHaveBeenCalled();
  expect(stubProjects.pushV2).not.toHaveBeenCalled();
});

test('advertisement removes mutating tools in read-only mode', () => {
  const definitions = [
    { name: 'list_dir' },
    { name: 'read_file' },
    { name: 'write_file' },
    { name: 'git_status' },
    { name: 'git_commit' },
    { name: 'git_push' },
    { name: 'ask_user' },
  ];
  expect(
    filterAgentToolDefinitions(definitions, 'read-only', ROOT).map(
      tool => (tool as { name: string }).name,
    ),
  ).toEqual(['list_dir', 'read_file', 'git_status', 'ask_user']);
  expect(
    filterAgentToolDefinitions(definitions, 'workspace-write', ROOT).map(
      tool => (tool as { name: string }).name,
    ),
  ).toEqual(definitions.map(tool => tool.name));
});

test('git_status uses the project-bound V2 root', async () => {
  const outcome = await executeAgentTool(CTX, 'git_status', '{}');

  expect(outcome.ok).toBe(true);
  expect(outcome.outputDigest).toBe('main@bbbbbbb clean');
  expect(stubProjects.statusV2).toHaveBeenCalledWith({
    schema_version: 1,
    root: ROOT,
  });
});

test('git_commit stages and commits with an explicit HEAD precondition', async () => {
  const outcome = await executeAgentTool(
    CTX,
    'git_commit',
    JSON.stringify({ message: 'Add X' }),
  );

  expect(outcome.ok).toBe(true);
  expect(outcome.outputDigest).toBe('commit:bbbbbbbbbbbb');
  expect(stubProjects.stageAllV2).toHaveBeenCalledWith({
    schema_version: 1,
    root: ROOT,
  });
  expect(stubProjects.commitV2).toHaveBeenCalledWith({
    schema_version: 1,
    root: ROOT,
    operation_id: OPERATION_ID,
    message: 'Add X',
    author_name: 'Rish Agent',
    author_email: 'agent@rish.local',
    expected_head_oid: OID,
  });
});

test('git_push preserves the injected proxy context and uses V2 Git', async () => {
  const gitHttpsProxyUrl = 'http://127.0.0.1:7890/';
  const outcome = await executeAgentTool(
    { ...CTX, gitHttpsProxyUrl },
    'git_push',
    '{}',
  );

  expect(outcome.ok).toBe(true);
  expect(outcome.outputDigest).toBe('pushed main@bbbbbbbbbbbb');
  expect(stubProjects.pushV2).toHaveBeenCalledWith({
    schema_version: 1,
    root: ROOT,
    operation_id: OPERATION_ID,
    remote: 'origin',
    expected_local_oid: OID,
    credential_reference: CREDENTIAL_REFERENCE,
    https_proxy_url: gitHttpsProxyUrl,
  });
});

test('native rejections map to the transport error text', async () => {
  stubProjects.pushV2.mockRejectedValue(
    new Error('credential missing for github.com'),
  );

  const outcome = await executeAgentTool(CTX, 'git_push', '{}');

  expect(outcome.ok).toBe(false);
  expect(outcome.detail).toBe('E_PROJECT_NATIVE');
  expect(stubProjects.pushV2).toHaveBeenCalledWith({
    schema_version: 1,
    root: ROOT,
    operation_id: OPERATION_ID,
    remote: 'origin',
    expected_local_oid: OID,
    credential_reference: CREDENTIAL_REFERENCE,
    https_proxy_url: null,
  });
});

test('legacy AgentTools never advertises or executes guest CGI tools', async () => {
  const definitions = [
    { name: 'start_guest_cgi', parameters: {} },
    { name: 'stop_guest_cgi', parameters: {} },
    { name: 'read_file', parameters: {} },
  ];
  expect(
    filterAgentToolDefinitions(definitions, 'workspace-write').map(
      tool => (tool as { name: string }).name,
    ),
  ).toEqual(['read_file']);

  await expect(
    executeAgentTool(CTX, 'start_guest_cgi', '{}'),
  ).resolves.toMatchObject({
    ok: false,
    detail: 'E_AGENT_UNKNOWN_TOOL',
  });
  await expect(
    executeAgentTool(CTX, 'stop_guest_cgi', '{}'),
  ).resolves.toMatchObject({
    ok: false,
    detail: 'E_AGENT_UNKNOWN_TOOL',
  });
});
