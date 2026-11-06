#![cfg(unix)]

use super::*;
use serde_json::json;
use std::{fs, path::PathBuf};

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("rish-assistant-avatar-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn file(&self) -> PathBuf {
        self.0.join("assistant-v1.json")
    }
    fn open(&self) -> AssistantStore {
        AssistantStore::open(&self.0).unwrap()
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn avatar() -> AssistantAvatar {
    AssistantAvatar {
        id: "c0417c3a-2161-4d6b-8aac-84611d677ad6".into(),
        sha256: "abcdef0123456789".repeat(4),
        mime_type: "image/png".into(),
        width: MAX_AVATAR_DIMENSION,
        height: 1,
        byte_length: MAX_AVATAR_BYTES,
    }
}
fn profile() -> AssistantProfile {
    AssistantProfile {
        name: "我的助手".into(),
        soul: default_soul(),
        notes: "保留用户的长期备注。".into(),
        avatar: Some(avatar()),
        runtime: RuntimeSpec::pi(),
    }
}

#[test]
fn legacy_schema_one_profile_is_loaded_without_rewrite_or_new_avatar_key() {
    let directory = Directory::new();
    let legacy = json!({"schema_version":1,"revision":7,"clock_high_water_ms":123,
        "profile":{"name":"旧助手","notes":"原有中文备注"},"tasks":[]});
    let bytes = serde_json::to_vec_pretty(&legacy).unwrap();
    fs::write(directory.file(), &bytes).unwrap();
    let store = directory.open();
    let loaded = store.load().unwrap();
    assert_eq!(loaded.schema_version, 1);
    assert_eq!(loaded.profile.name, "旧助手");
    assert_eq!(loaded.profile.notes, "原有中文备注");
    assert!(loaded.profile.avatar.is_none());
    let mut migrated = legacy.clone();
    migrated["profile"]["soul"] = json!(default_soul());
    assert_eq!(serde_json::to_value(&loaded).unwrap(), migrated);
    assert_eq!(fs::read(directory.file()).unwrap(), bytes);
    let saved = store.set_profile(loaded.revision, loaded.profile).unwrap();
    let mut expected = migrated;
    expected["revision"] = json!(8);
    assert_eq!(serde_json::to_value(saved).unwrap(), expected);
    let disk: Value = serde_json::from_slice(&fs::read(directory.file()).unwrap()).unwrap();
    assert!(disk["profile"].get("avatar").is_none());
}

#[test]
fn invalid_avatar_metadata_never_replaces_profile_and_corrupt_disk_is_preserved() {
    let directory = Directory::new();
    let store = directory.open();
    let saved = store.set_profile(0, profile()).unwrap();
    let bytes = fs::read(directory.file()).unwrap();
    let valid = serde_json::to_value(avatar()).unwrap();
    for (field, value) in [
        ("id", json!("C0417C3A-2161-4D6B-8AAC-84611D677AD6")),
        ("id", json!("c0417c3a21614d6b8aac84611d677ad6")),
        ("id", json!("/private/avatars/photo.png")),
        ("id", json!("file:///private/avatars/photo.png")),
        ("sha256", json!("a".repeat(63))),
        ("sha256", json!("A".repeat(64))),
        ("sha256", json!("g".repeat(64))),
        ("mime_type", json!("image/jpeg")),
        ("mime_type", json!("IMAGE/PNG")),
        ("width", json!(0)),
        ("width", json!(513)),
        ("height", json!(0)),
        ("height", json!(513)),
        ("byte_length", json!(0)),
        ("byte_length", json!(MAX_AVATAR_BYTES + 1)),
    ] {
        let mut invalid = valid.clone();
        invalid[field] = value;
        let mut candidate = saved.profile.clone();
        let metadata: AssistantAvatar = serde_json::from_value(invalid.clone()).unwrap();
        assert_eq!(
            metadata.validate(),
            Err(AssistantStoreError::Invalid("avatar metadata"))
        );
        candidate.avatar = Some(metadata);
        assert_eq!(
            store.set_profile(saved.revision, candidate),
            Err(AssistantStoreError::Invalid("avatar metadata")),
            "{field}: {invalid}"
        );
        assert_eq!(fs::read(directory.file()).unwrap(), bytes);
        assert_eq!(store.load().unwrap(), saved);

        let mut corrupt = serde_json::to_value(&saved).unwrap();
        corrupt["profile"]["avatar"] = invalid;
        let corrupt_bytes = serde_json::to_vec(&corrupt).unwrap();
        fs::write(directory.file(), &corrupt_bytes).unwrap();
        assert!(matches!(
            AssistantStore::open(&directory.0),
            Err(AssistantStoreError::Corrupt)
        ));
        assert_eq!(fs::read(directory.file()).unwrap(), corrupt_bytes);
        fs::write(directory.file(), &bytes).unwrap();
    }
    let mut with_path = serde_json::to_value(&saved).unwrap();
    with_path["profile"]["avatar"]["uri"] = json!("file:///private/photo.png");
    let untrusted = serde_json::to_vec(&with_path).unwrap();
    fs::write(directory.file(), &untrusted).unwrap();
    assert!(matches!(
        AssistantStore::open(&directory.0),
        Err(AssistantStoreError::Corrupt)
    ));
    assert_eq!(fs::read(directory.file()).unwrap(), untrusted);
}

#[test]
fn avatar_profile_roundtrips_through_cas_and_removal_omits_its_key() {
    let directory = Directory::new();
    let store = directory.open();
    assert_eq!(avatar().validate(), Ok(()));
    let saved = store.set_profile(0, profile()).unwrap();
    assert_eq!(directory.open().load().unwrap(), saved);
    let bytes = fs::read(directory.file()).unwrap();
    let mut removed = saved.profile.clone();
    removed.avatar = None;
    assert!(matches!(
        store.set_profile(0, removed.clone()),
        Err(AssistantStoreError::Conflict { .. })
    ));
    assert_eq!(fs::read(directory.file()).unwrap(), bytes);
    let cleared = store.set_profile(saved.revision, removed).unwrap();
    assert!(cleared.profile.avatar.is_none());
    assert_eq!(cleared.profile.name, saved.profile.name);
    assert_eq!(cleared.profile.notes, saved.profile.notes);
    let disk: Value = serde_json::from_slice(&fs::read(directory.file()).unwrap()).unwrap();
    assert!(disk["profile"].get("avatar").is_none());
}

#[test]
fn task_claim_retains_profile_but_excludes_avatar_from_model_context_snapshot() {
    let directory = Directory::new();
    let store = directory.open();
    let saved = store.set_profile(0, profile()).unwrap();
    let task = store
        .create_task(
            saved.revision,
            AssistantTaskConfig::manual(
                "检查项目",
                "说明项目进度",
                "deepseek-v4-flash",
                json!({"workspace_id":"workspace-1"}),
                json!({"id":"workspace-1"}),
            ),
            100,
        )
        .unwrap();
    let claim = store
        .claim(
            task.revision,
            &task.tasks[0].id,
            AssistantClaimMode::Manual,
            101,
        )
        .unwrap();
    assert_eq!(claim.snapshot.profile.avatar, Some(avatar()));
    let snapshot = serde_json::to_value(&claim.run.snapshot).unwrap();
    assert_eq!(snapshot["name"], saved.profile.name);
    assert_eq!(snapshot["notes"], saved.profile.notes);
    assert_eq!(snapshot.as_object().unwrap().len(), 8);
    assert_eq!(snapshot["soul"], default_soul());
    assert_eq!(
        snapshot["runtime"],
        serde_json::to_value(RuntimeSpec::pi()).unwrap()
    );
    assert!(snapshot.get("avatar").is_none());
    assert!(!snapshot.to_string().contains(&avatar().id));
    assert!(!snapshot.to_string().contains(&avatar().sha256));
}
