const mockNativeLocalAttachments = {
  present: jest.fn(),
  discard: jest.fn(),
  prune: jest.fn(),
  preview: jest.fn(),
  presentPreview: jest.fn(),
};

import { NativeModules } from 'react-native';

(NativeModules as Record<string, unknown>).LocalAttachments =
  mockNativeLocalAttachments;
const { LocalAttachments } = jest.requireActual(
  '../src/native/LocalAttachments',
) as typeof import('../src/native/LocalAttachments');

beforeEach(() => {
  jest.clearAllMocks();
});

test('links only when the complete attachment API exists', () => {
  expect(LocalAttachments.isAvailable()).toBe(true);
});

test.each(['camera', 'photos', 'files'] as const)(
  'passes the %s source to native',
  async source => {
    mockNativeLocalAttachments.present.mockResolvedValue({
      schema_version: 1,
      status: 'cancelled',
      attachments: [],
    });

    await LocalAttachments.present(source);

    expect(mockNativeLocalAttachments.present).toHaveBeenCalledWith(source);
  },
);

test('passes only opaque identifiers to lifecycle methods', async () => {
  mockNativeLocalAttachments.discard.mockResolvedValue({
    schema_version: 1,
    discarded_count: 2,
  });
  mockNativeLocalAttachments.prune.mockResolvedValue({
    schema_version: 1,
    removed_count: 1,
  });
  mockNativeLocalAttachments.preview.mockResolvedValue({
    schema_version: 1,
    id: 'a5a4fabc-e00e-42c9-984a-d11178526586',
    thumbnail_data_url: null,
  });
  mockNativeLocalAttachments.presentPreview.mockResolvedValue({
    schema_version: 1,
    status: 'closed',
  });

  const ids = [
    'a5a4fabc-e00e-42c9-984a-d11178526586',
    '6b8d46bc-4f2d-43cc-bf24-5f8ad227f4c2',
  ];
  await LocalAttachments.discard(ids);
  await LocalAttachments.prune(ids.slice(0, 1));
  await LocalAttachments.preview(ids[0]);
  await LocalAttachments.presentPreview(ids[0]);

  expect(mockNativeLocalAttachments.discard).toHaveBeenCalledWith(ids);
  expect(mockNativeLocalAttachments.prune).toHaveBeenCalledWith(
    ids.slice(0, 1),
  );
  expect(mockNativeLocalAttachments.preview).toHaveBeenCalledWith(ids[0]);
  expect(mockNativeLocalAttachments.presentPreview).toHaveBeenCalledWith(
    ids[0],
  );
});

test('a platform names which kinds need a model that reads images; without a list only images do', () => {
  const native = mockNativeLocalAttachments as Record<string, unknown>;
  // iOS exports nothing: it reads a PDF's text, so only an image needs vision.
  expect(LocalAttachments.kindNeedsVision('image')).toBe(true);
  expect(LocalAttachments.kindNeedsVision('pdf')).toBe(false);
  expect(LocalAttachments.kindNeedsVision('text')).toBe(false);
  // Android sends a PDF's pages as pictures.
  native.model_vision_kinds = ['image', 'pdf'];
  native.model_delivery = ['image', 'text', 'pdf'];
  try {
    expect(LocalAttachments.kindNeedsVision('pdf')).toBe(true);
    expect(LocalAttachments.kindNeedsVision('text')).toBe(false);
    expect(LocalAttachments.isKindDeliverable('pdf')).toBe(true);
    // An image needs vision whatever a platform's list forgets to say.
    native.model_vision_kinds = ['pdf'];
    expect(LocalAttachments.kindNeedsVision('image')).toBe(true);
    native.model_vision_kinds = 'pdf';
    expect(LocalAttachments.kindNeedsVision('pdf')).toBe(false);
  } finally {
    delete native.model_vision_kinds;
    delete native.model_delivery;
  }
});
