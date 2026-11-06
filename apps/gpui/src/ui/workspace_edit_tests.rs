use super::*;

fn root(id: &str, binding: u64) -> Value {
    json!({"schema_version":1,"workspace_id":id,"binding_revision":binding,"project_id":null})
}
fn browser() -> Browser {
    Browser {
        root: Some(root("workspace-a", 4)),
        path: "src".into(),
        generation: 7,
        capabilities: json!({"read":true,"write":true}),
        ..Browser::default()
    }
}
fn draft(create_only: bool) -> FileDraft {
    FileDraft {
        target: EditTarget {
            root: root("workspace-a", 4),
            path: "src/main.rs".into(),
            folder: "src".into(),
            generation: 7,
        },
        content: "你好\n  text\n".into(),
        expected_revision: (!create_only).then(|| "a".repeat(64)),
        create_only,
        failed: false,
    }
}
fn read(content: &str) -> Value {
    json!({"schema_version":1,"root":root("workspace-a",4),"path":"src/main.rs",
        "content":content,"file":{"path":"src/main.rs","name":"main.rs","kind":"file",
            "revision":"a".repeat(64),"size":content.len()}})
}
fn saved(draft: &FileDraft) -> Value {
    json!({"schema_version":1,"root":draft.target.root,"created":draft.create_only,
        "file":{"path":draft.target.path,"name":"main.rs","kind":"file",
            "revision":"b".repeat(64),"size":draft.content.len()}})
}

#[test]
fn an_editor_is_bound_to_workspace_binding_folder_and_generation() {
    let target = draft(false).target;
    let mut browser = browser();
    assert!(target.current(&browser));
    browser.generation += 1;
    assert!(!target.current(&browser));
    browser.generation = 7;
    browser.root = Some(root("workspace-b", 4));
    assert!(!target.current(&browser));
    browser.root = Some(root("workspace-a", 5));
    assert!(!target.current(&browser));
    browser.root = Some(root("workspace-a", 4));
    browser.path = "docs".into();
    assert!(!target.current(&browser));
    browser.path = "src".into();
    browser.capabilities["write"] = json!(false);
    assert!(!target.current(&browser));
}

#[test]
fn new_files_never_overwrite_and_existing_files_keep_the_read_revision() {
    let created = draft(true).write_command().unwrap();
    assert_eq!(created.module, "LocalWorkspace");
    assert_eq!(created.method, "writeV2");
    assert_eq!(created.args[0]["create_only"], true);
    assert_eq!(created.args[0]["expected_revision"], Value::Null);
    assert_eq!(created.args[0].as_object().unwrap().len(), 6);
    let existing = draft(false);
    let command = existing.write_command().unwrap();
    assert_eq!(command.args[0]["root"], root("workspace-a", 4));
    assert_eq!(command.args[0]["path"], "src/main.rs");
    assert_eq!(command.args[0]["expected_revision"], "a".repeat(64));
    assert_eq!(command.args[0]["content"], existing.content);
    assert_eq!(command.args[0]["create_only"], false);
}

#[test]
fn missing_revision_is_never_sent_as_an_unconditional_overwrite() {
    let mut edit = draft(false);
    edit.expected_revision = None;
    assert!(edit.write_command().is_err());
    edit.expected_revision = Some("wrong".into());
    assert!(edit.write_command().is_err());
    edit.create_only = true;
    assert!(edit.write_command().is_err());
}

#[test]
fn editor_limits_count_utf8_bytes_and_allow_an_empty_file() {
    let mut edit = draft(true);
    edit.content.clear();
    assert_eq!(edit.write_command().unwrap().args[0]["content"], "");
    edit.content = "中".repeat(MAX_EDIT_BYTES / 3);
    assert!(edit.write_command().is_ok());
    edit.content.push('中');
    assert!(edit.write_command().is_err());
}

#[test]
fn native_reads_keep_the_revision_and_refuse_editing_partial_text() {
    let value = read("你好\n");
    let full = FileSnapshot::from_read(&value, &root("workspace-a", 4), "src/main.rs").unwrap();
    assert!(full.editable());
    assert_eq!(full.revision, "a".repeat(64));
    assert_eq!(full.content, "你好\n");
    let mut partial = value.clone();
    partial["file"]["size"] = json!(999);
    assert!(
        !FileSnapshot::from_read(&partial, &root("workspace-a", 4), "src/main.rs")
            .unwrap()
            .editable()
    );
    partial = value.clone();
    partial["truncated"] = json!(true);
    assert!(
        !FileSnapshot::from_read(&partial, &root("workspace-a", 4), "src/main.rs")
            .unwrap()
            .editable()
    );
    partial = value;
    partial["file"]["revision"] = Value::Null;
    assert!(FileSnapshot::from_read(&partial, &root("workspace-a", 4), "src/main.rs").is_err());
}

#[test]
fn a_read_cannot_replace_a_different_file_or_binding() {
    let value = read("safe");
    assert!(FileSnapshot::from_read(&value, &root("workspace-a", 5), "src/main.rs").is_err());
    assert!(FileSnapshot::from_read(&value, &root("workspace-a", 4), "src/other.rs").is_err());
    let mut bad = value;
    bad["file"]["path"] = json!("src/other.rs");
    assert!(FileSnapshot::from_read(&bad, &root("workspace-a", 4), "src/main.rs").is_err());
}

#[test]
fn saves_must_acknowledge_exact_root_path_size_and_creation_mode() {
    let edit = draft(false);
    let value = saved(&edit);
    assert_eq!(edit.accept_write(&value).unwrap().content, edit.content);
    for (key, replacement) in [("root", root("workspace-b", 4)), ("created", json!(true))] {
        let mut wrong = value.clone();
        wrong[key] = replacement;
        assert!(edit.accept_write(&wrong).is_err());
    }
    for (key, replacement) in [
        ("path", json!("other.rs")),
        ("kind", json!("directory")),
        ("size", json!(0)),
        ("revision", json!("bad")),
    ] {
        let mut wrong = value.clone();
        wrong["file"][key] = replacement;
        assert!(edit.accept_write(&wrong).is_err());
    }
}

#[test]
fn a_failed_save_keeps_verbatim_draft_and_original_revision() {
    let edit = draft(false);
    let mut state = EditState {
        active: Some("save-a".into()),
        ..EditState::default()
    };
    assert!(!state.finish("stale-prompt"));
    assert!(state.busy());
    assert!(state.finish("save-a"));
    state.retain_failed(edit.clone());
    let retained = state.draft.as_ref().unwrap();
    assert!(retained.failed);
    assert_eq!(retained.content, edit.content);
    assert_eq!(retained.expected_revision, edit.expected_revision);
    assert_eq!(retained.target.root, edit.target.root);
    assert!(!state.busy());
    // Explicit resume may rebind the view generation, but even a new save still
    // carries the old expected revision and cannot replace changed disk bytes.
    let mut resumed = retained.clone();
    resumed.target.generation += 1;
    assert_eq!(
        resumed.write_command().unwrap().args[0]["expected_revision"],
        "a".repeat(64)
    );
}

#[test]
fn new_names_are_one_leaf_and_cannot_address_internal_metadata() {
    for invalid in [
        "",
        ".",
        "..",
        "../secret",
        "/absolute",
        "a/b",
        "a\\b",
        ".git",
        ".GIT",
        ".trash",
        ".staging-1",
        ".rish-write-a",
        "a:b",
        "a\0b",
        "a\nb",
        " padded ",
    ] {
        assert!(entry_path("src", invalid).is_none(), "{invalid:?}");
    }
    assert_eq!(entry_path("src", "你好.md"), Some("src/你好.md".into()));
    assert_eq!(entry_path("", ".gitignore"), Some(".gitignore".into()));
    assert!(entry_path("src", &"x".repeat(256)).is_none());
    assert!(entry_path(&"x".repeat(510), "ok").is_none());
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
mod controller {
    use super::*;
    use gpui::{TestAppContext, px, size};

    fn with_shell(test: impl FnOnce(&mut Shell, &mut Context<Shell>)) {
        let mut cx = TestAppContext::single();
        let window = cx.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
        window
            .update(&mut cx, |shell, _, cx| {
                shell.browser = browser();
                shell.page = Page::Files;
                test(shell, cx);
            })
            .unwrap();
    }

    #[test]
    fn a_completed_editor_after_navigation_preserves_text_without_dispatching_a_write() {
        with_shell(|shell, cx| {
            let request = FileEditRequest {
                id: "editor-a".into(),
                draft: draft(false),
            };
            shell.browser.edit.active = Some(request.id.clone());
            shell.aux_busy = true;
            shell.browser.generation += 1;
            shell.accept(
                Reply::FileEditor(request),
                Ok(json!("new unsaved text\n")),
                cx,
            );
            assert!(
                !shell.browser.edit.busy(),
                "a stale editor must not dispatch writeV2"
            );
            assert!(!shell.aux_busy);
            let retained = shell.browser.edit.draft.as_ref().unwrap();
            assert_eq!(retained.content, "new unsaved text\n");
            assert_eq!(retained.expected_revision, Some("a".repeat(64)));
            assert_eq!(retained.target.root, root("workspace-a", 4));
        });
    }

    #[test]
    fn a_read_only_or_rebound_workspace_cannot_accept_a_pending_name_prompt() {
        for revoked in [false, true] {
            with_shell(|shell, cx| {
                let request = EntryRequest {
                    id: "name-a".into(),
                    target: draft(false).target,
                    kind: EntryKind::Folder,
                };
                shell.browser.edit.active = Some(request.id.clone());
                shell.aux_busy = true;
                if revoked {
                    shell.browser.capabilities["write"] = json!(false);
                } else {
                    shell.browser.root = Some(root("workspace-b", 4));
                }
                shell.accept(Reply::EntryName(request), Ok(json!("new-folder")), cx);
                assert!(
                    !shell.browser.edit.busy(),
                    "must not dispatch directory creation"
                );
                assert!(!shell.aux_busy);
                assert!(shell.browser.entries.is_empty());
            });
        }
    }

    #[test]
    fn conflict_and_unknown_results_preserve_drafts_without_automatic_retry() {
        for error in ["E_WORKSPACE_CONFLICT", "Native operation disconnected"] {
            with_shell(|shell, cx| {
                let request = FileEditRequest {
                    id: "write-a".into(),
                    draft: draft(false),
                };
                shell.browser.edit.active = Some(request.id.clone());
                shell.aux_busy = true;
                shell.accept(Reply::FileWritten(request), Err(error.into()), cx);
                assert!(!shell.browser.edit.busy());
                assert!(!shell.aux_busy);
                let retained = shell.browser.edit.draft.as_ref().unwrap();
                assert!(retained.failed);
                assert_eq!(retained.content, "你好\n  text\n");
                assert_eq!(retained.expected_revision, Some("a".repeat(64)));
                assert!(shell.browser.file.is_none());
            });
        }
    }

    #[test]
    fn failed_or_stale_resume_does_not_open_an_editor_or_drop_the_draft() {
        for stale in [false, true] {
            with_shell(|shell, cx| {
                let request = FileEditRequest {
                    id: "resume-a".into(),
                    draft: draft(false),
                };
                shell.browser.edit.active = Some(request.id.clone());
                shell.browser.edit.draft = Some(request.draft.clone());
                shell.aux_busy = true;
                if stale {
                    shell.browser.generation += 1;
                }
                shell.accept(
                    Reply::ResumeDraftFolder(request),
                    Err("Workspace unavailable".into()),
                    cx,
                );
                assert!(!shell.browser.edit.busy());
                assert!(!shell.aux_busy);
                let retained = shell.browser.edit.draft.as_ref().unwrap();
                assert_eq!(retained.content, "你好\n  text\n");
                assert_eq!(retained.expected_revision, Some("a".repeat(64)));
            });
        }
    }

    #[test]
    fn successful_old_writes_do_not_replace_the_new_workspace_view() {
        with_shell(|shell, cx| {
            let request = FileEditRequest {
                id: "write-a".into(),
                draft: draft(false),
            };
            let result = saved(&request.draft);
            shell.browser.edit.active = Some(request.id.clone());
            shell.browser.edit.draft = Some(request.draft.clone());
            shell.browser.root = Some(root("workspace-b", 4));
            shell.browser.generation += 1;
            shell.accept(Reply::FileWritten(request.clone()), Ok(result.clone()), cx);
            assert!(shell.browser.file.is_none());
            assert!(shell.browser.entries.is_empty());
            assert!(shell.browser.edit.draft.is_none());
            // A duplicate delivery cannot clear a later editor's busy state.
            shell.browser.edit.active = Some("new-editor".into());
            shell.aux_busy = true;
            shell.accept(Reply::FileWritten(request), Ok(result), cx);
            assert!(shell.aux_busy);
            assert_eq!(shell.browser.edit.active.as_deref(), Some("new-editor"));
        });
    }
}
