use super::*;

#[test]
fn runtime_inheritance_is_frozen_per_claim_and_task_override_survives_profile_changes() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let custom = RuntimeSpec::custom("Review", "{beforeModel(){return {allow:true}}}").unwrap();
    let saved = store
        .set_profile(
            0,
            AssistantProfile {
                runtime: custom.clone(),
                ..Default::default()
            },
        )
        .unwrap();
    let saved = store
        .create_task(saved.revision, config(None), NOW)
        .unwrap();
    let id = saved.tasks[0].id.clone();
    let claim = store
        .claim(saved.revision, &id, AssistantClaimMode::Manual, NOW + 1)
        .unwrap();
    assert_eq!(claim.run.snapshot.runtime, Some(custom.clone()));
    let changed = store
        .set_profile(claim.snapshot.revision, AssistantProfile::default())
        .unwrap();
    assert_eq!(
        changed.tasks[0].last_run.as_ref().unwrap().snapshot.runtime,
        Some(custom.clone())
    );
    assert_eq!(directory.store().load().unwrap(), changed);
    let mut overridden = config(None);
    overridden.runtime = Some(custom.clone());
    let saved = store
        .create_task(changed.revision, overridden, NOW + 2)
        .unwrap();
    let id = saved.tasks[1].id.clone();
    let claim = store
        .claim(saved.revision, &id, AssistantClaimMode::Manual, NOW + 3)
        .unwrap();
    assert_eq!(claim.run.snapshot.runtime, Some(custom));
    assert_eq!(claim.run.snapshot.model_id, "deepseek-v4-flash");
}

#[test]
fn old_profiles_default_to_pi_but_existing_runs_keep_explicit_legacy_identity() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let (saved, id) = create(&store, None);
    let claim = store
        .claim(saved.revision, &id, AssistantClaimMode::Manual, NOW + 1)
        .unwrap();
    assert_eq!(claim.run.snapshot.runtime, Some(RuntimeSpec::pi()));
    let mut legacy = serde_json::to_value(claim.snapshot).unwrap();
    legacy["profile"].as_object_mut().unwrap().remove("runtime");
    legacy["tasks"][0]["last_run"]["snapshot"]
        .as_object_mut()
        .unwrap()
        .remove("runtime");
    fs::write(directory.0.join("assistant-v1.json"), legacy.to_string()).unwrap();
    let loaded = store.load().unwrap();
    assert_eq!(loaded.profile.runtime, RuntimeSpec::pi());
    assert_eq!(
        loaded.tasks[0].last_run.as_ref().unwrap().snapshot.runtime,
        None
    );
}

#[test]
fn tampered_runtime_source_cannot_replace_durable_profile() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let (saved, _) = create(&store, None);
    let bytes = directory.state_bytes();
    let mut runtime = RuntimeSpec::custom("Review", "{}").unwrap();
    if let RuntimeSpec::Custom { source, .. } = &mut runtime {
        source.push(' ');
    }
    assert!(store
        .set_profile(
            saved.revision,
            AssistantProfile {
                runtime,
                ..Default::default()
            }
        )
        .is_err());
    assert_eq!(directory.state_bytes(), bytes);
}

#[test]
fn soul_is_frozen_for_new_claims_and_legacy_runs_remain_empty() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let saved = store
        .set_profile(
            0,
            AssistantProfile {
                soul: "Use concise, practical follow-ups.".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let saved = store
        .create_task(saved.revision, config(None), NOW)
        .unwrap();
    let id = saved.tasks[0].id.clone();
    let claim = store
        .claim(saved.revision, &id, AssistantClaimMode::Manual, NOW + 1)
        .unwrap();
    assert_eq!(
        claim.run.snapshot.soul,
        "Use concise, practical follow-ups."
    );
    let changed = store
        .set_profile(
            claim.snapshot.revision,
            AssistantProfile {
                soul: "A newly edited character.".into(),
                ..Default::default()
            },
        )
        .unwrap();
    assert_eq!(
        changed.tasks[0].last_run.as_ref().unwrap().snapshot.soul,
        claim.run.snapshot.soul
    );
    let mut legacy = serde_json::to_value(changed).unwrap();
    legacy["tasks"][0]["last_run"]["snapshot"]
        .as_object_mut()
        .unwrap()
        .remove("soul");
    fs::write(directory.0.join("assistant-v1.json"), legacy.to_string()).unwrap();
    let before = directory.state_bytes();
    let reloaded = directory.store().load().unwrap();
    assert!(reloaded.tasks[0]
        .last_run
        .as_ref()
        .unwrap()
        .snapshot
        .soul
        .is_empty());
    assert_eq!(reloaded.profile.soul, "A newly edited character.");
    assert_eq!(directory.state_bytes(), before);
}
