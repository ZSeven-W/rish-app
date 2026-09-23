import { nativeImplementationAvailable } from './NativeImplementation';
import { NativeModules } from 'react-native';

export type AttachmentSource = 'camera' | 'photos' | 'files';
export type AttachmentKind = 'image' | 'text' | 'pdf';

export type AttachmentDescriptor = {
  schema_version: 1;
  id: string;
  kind: AttachmentKind;
  name: string;
  mime_type: string;
  size: number;
  thumbnail_data_url?: string;
};

export type AttachmentSelectionResult = {
  schema_version: 1;
  status: 'selected' | 'cancelled';
  attachments: AttachmentDescriptor[];
};

export type AttachmentDiscardResult = {
  schema_version: 1;
  discarded_count: number;
};

export type AttachmentPruneResult = {
  schema_version: 1;
  removed_count: number;
};

export type AttachmentPreview = {
  schema_version: 1;
  id: string;
  thumbnail_data_url: string | null;
};

export type AttachmentNativePreviewResult = {
  schema_version: 1;
  status: 'closed';
};

type NativeLocalAttachments = {
  present(source: AttachmentSource): Promise<AttachmentSelectionResult>;
  discard(ids: string[]): Promise<AttachmentDiscardResult>;
  prune(referencedIds: string[]): Promise<AttachmentPruneResult>;
  preview(id: string): Promise<AttachmentPreview>;
  presentPreview(id: string): Promise<AttachmentNativePreviewResult>;
};

const native = NativeModules.LocalAttachments as unknown;

function hasNativeCapabilities(
  value: unknown,
): value is NativeLocalAttachments {
  if (!nativeImplementationAvailable(value)) return false;
  if (typeof value !== 'object' || value === null) return false;
  const candidate = value as Partial<
    Record<keyof NativeLocalAttachments, unknown>
  >;
  return (
    typeof candidate.present === 'function' &&
    typeof candidate.discard === 'function' &&
    typeof candidate.prune === 'function' &&
    typeof candidate.preview === 'function' &&
    typeof candidate.presentPreview === 'function'
  );
}

function required(): NativeLocalAttachments {
  if (!hasNativeCapabilities(native)) {
    throw new Error('LocalAttachments native module is not linked');
  }
  return native;
}

/**
 * Whether an attachment of this kind can actually reach a model here.
 *
 * The composer asks this before it starts a turn, so the person is told
 * plainly with the draft kept instead of watching a round fail for a reason
 * nothing explains. A platform that exports no such constant delivers every
 * kind, which is what iOS does.
 */
function kindDeliverable(kind: AttachmentKind): boolean {
  if (typeof native !== 'object' || native === null) return true;
  const declared = Reflect.get(native, 'model_delivery');
  if (!Array.isArray(declared)) return true;
  return declared.includes(kind);
}

/**
 * Whether an attachment of this kind needs a model that reads images here.
 *
 * An image always does. A PDF does on Android, which sends its pages as
 * pictures, and not on iOS, which sends its text. A platform that exports no
 * `model_vision_kinds` treats only images as pictures.
 */
function kindNeedsVision(kind: AttachmentKind): boolean {
  if (kind === 'image') return true;
  if (typeof native !== 'object' || native === null) return false;
  const declared = Reflect.get(native, 'model_vision_kinds');
  return Array.isArray(declared) && declared.includes(kind);
}

export const LocalAttachments = {
  isAvailable: () => hasNativeCapabilities(native),
  isKindDeliverable: kindDeliverable,
  kindNeedsVision,
  present: (source: AttachmentSource) => required().present(source),
  discard: (ids: string[]) => required().discard(ids),
  prune: (referencedIds: string[]) => required().prune(referencedIds),
  preview: (id: string) => required().preview(id),
  presentPreview: (id: string) => required().presentPreview(id),
};
