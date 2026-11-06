#![cfg(unix)]

use super::*;
use rish_agent_core::canonical::sha256_hex;
use std::{ffi::CString, fs, os::unix::ffi::OsStrExt, os::unix::fs::symlink, path::PathBuf};

// One fully encoded transparent RGBA pixel, including PNG CRCs and IDAT.
const PNG: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0x00, 0x02, 0x00,
    0x00, 0x05, 0x00, 0x01, 0x7a, 0x5e, 0xab, 0x3f, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
    0xae, 0x42, 0x60, 0x82,
];
const ID: &str = "c0417c3a-2161-4d6b-8aac-84611d677ad6";
struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("rish-avatar-read-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn image(&self) -> PathBuf {
        self.0.join("avatars").join(format!("{ID}.png"))
    }
    fn write(&self, bytes: &[u8]) {
        fs::create_dir_all(self.0.join("avatars")).unwrap();
        fs::write(self.image(), bytes).unwrap();
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn metadata(bytes: &[u8]) -> AssistantAvatar {
    AssistantAvatar {
        id: ID.into(),
        sha256: sha256_hex(bytes),
        mime_type: "image/png".into(),
        width: 1,
        height: 1,
        byte_length: bytes.len() as u64,
    }
}

#[test]
fn verified_png_is_returned_without_creating_or_mutating_store_state() {
    let directory = Directory::new();
    directory.write(PNG);
    assert_eq!(
        read_avatar_bytes(&directory.0, &metadata(PNG)).unwrap(),
        PNG
    );
    assert_eq!(fs::read(directory.image()).unwrap(), PNG);
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    assert!(!directory.0.join("assistant-v1.json").exists());
    assert!(!directory.0.join(".assistant-v1.lock").exists());
}

#[test]
fn altered_bytes_length_and_png_header_are_rejected_before_decode() {
    let directory = Directory::new();
    let original = metadata(PNG);
    let mut changed = PNG.to_vec();
    changed[44] ^= 1;
    directory.write(&changed);
    assert_eq!(
        read_avatar_bytes(&directory.0, &original),
        Err(AssistantStoreError::Corrupt)
    );
    assert_eq!(fs::read(directory.image()).unwrap(), changed);
    for length in [8, 15, 32, PNG.len() - 1] {
        directory.write(&PNG[..length]);
        assert_eq!(
            read_avatar_bytes(&directory.0, &original),
            Err(AssistantStoreError::Corrupt)
        );
        if length < 33 {
            // A matching digest cannot make a truncated IHDR decodable.
            assert_eq!(
                read_avatar_bytes(&directory.0, &metadata(&PNG[..length])),
                Err(AssistantStoreError::Corrupt)
            );
        }
    }
    for index in [0, 11, 12, 19, 23] {
        let mut malformed = PNG.to_vec();
        malformed[index] ^= 1;
        directory.write(&malformed);
        assert_eq!(
            read_avatar_bytes(&directory.0, &metadata(&malformed)),
            Err(AssistantStoreError::Corrupt)
        );
    }
    directory.write(PNG);
    let mut wrong_dimensions = original;
    wrong_dimensions.width = 2;
    assert_eq!(
        read_avatar_bytes(&directory.0, &wrong_dimensions),
        Err(AssistantStoreError::Corrupt)
    );
}

#[test]
fn oversized_file_and_invalid_metadata_are_bounded_and_preserved() {
    let directory = Directory::new();
    let mut oversized = PNG.to_vec();
    oversized.resize(MAX_AVATAR_BYTES as usize + 1, 0);
    directory.write(&oversized);
    assert_eq!(
        read_avatar_bytes(&directory.0, &metadata(PNG)),
        Err(AssistantStoreError::Corrupt)
    );
    assert_eq!(
        read_avatar_bytes(&directory.0, &metadata(&oversized)),
        Err(AssistantStoreError::Invalid("avatar metadata"))
    );
    assert_eq!(
        fs::metadata(directory.image()).unwrap().len(),
        MAX_AVATAR_BYTES + 1
    );
    let mut invalid_id = metadata(PNG);
    invalid_id.id = "../../outside".into();
    assert_eq!(
        read_avatar_bytes(&directory.0, &invalid_id),
        Err(AssistantStoreError::Invalid("avatar metadata"))
    );
}

#[test]
fn symlink_root_directory_file_and_hard_link_cannot_redirect_avatar_reads() {
    let outside = Directory::new();
    outside.write(PNG);
    let linked_root = Directory::new();
    let root_alias = linked_root.0.join("root-alias");
    symlink(&outside.0, &root_alias).unwrap();
    assert_eq!(
        read_avatar_bytes(&root_alias, &metadata(PNG)),
        Err(AssistantStoreError::UnsafePath)
    );
    let linked_directory = Directory::new();
    symlink(
        outside.0.join("avatars"),
        linked_directory.0.join("avatars"),
    )
    .unwrap();
    assert_eq!(
        read_avatar_bytes(&linked_directory.0, &metadata(PNG)),
        Err(AssistantStoreError::UnsafePath)
    );
    let linked_file = Directory::new();
    fs::create_dir(linked_file.0.join("avatars")).unwrap();
    symlink(outside.image(), linked_file.image()).unwrap();
    assert_eq!(
        read_avatar_bytes(&linked_file.0, &metadata(PNG)),
        Err(AssistantStoreError::UnsafePath)
    );
    fs::remove_file(linked_file.image()).unwrap();
    fs::hard_link(outside.image(), linked_file.image()).unwrap();
    assert_eq!(
        read_avatar_bytes(&linked_file.0, &metadata(PNG)),
        Err(AssistantStoreError::UnsafePath)
    );
    assert_eq!(fs::read(outside.image()).unwrap(), PNG);
}

#[test]
fn fifo_avatar_is_rejected_without_waiting_for_a_writer() {
    let directory = Directory::new();
    fs::create_dir(directory.0.join("avatars")).unwrap();
    let path = CString::new(directory.image().as_os_str().as_bytes()).unwrap();
    // SAFETY: path is a live, NUL-terminated filename in this test directory.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    assert_eq!(
        read_avatar_bytes(&directory.0, &metadata(PNG)),
        Err(AssistantStoreError::UnsafePath)
    );
}
