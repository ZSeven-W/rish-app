use super::Reply;

/// Auxiliary file reads share one native-operation lane with Git. The exact
/// request owns its busy flag even after navigation changes the generation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct BrowserReadRequest {
    pub generation: u64,
    path: String,
    directory: bool,
}
impl BrowserReadRequest {
    pub fn from_reply(reply: &Reply) -> Option<Self> {
        let (generation, path, directory) = match reply {
            Reply::Files(generation, path) => (*generation, path.clone(), true),
            Reply::Read(generation, path) => (*generation, path.clone(), false),
            _ => return None,
        };
        Some(Self {
            generation,
            path,
            directory,
        })
    }
}

#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod tests {
    use super::*;
    use crate::ui::{
        Shell,
        git_operations::{GitAction, GitActionRequest, GitStep},
    };
    use gpui::{Context, TestAppContext, px, size};
    use rish_shell_core::RuntimeCommand;
    use serde_json::{Value, json};

    fn with_shell(test: impl FnOnce(&mut Shell, &mut Context<Shell>)) {
        let mut cx = TestAppContext::single();
        let window = cx.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
        window.update(&mut cx,|shell,_,cx| {
            shell.browser.generation=1;
            shell.browser.root=Some(json!({"schema_version":1,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":4,"project_id":"85ac8af6-b884-4b55-b63a-b46cabf56296"}));
            test(shell,cx);
        }).unwrap();
    }
    fn command() -> RuntimeCommand {
        RuntimeCommand::new("LocalWorkspaces", "list", vec![])
    }

    #[test]
    fn an_abandoned_file_read_releases_its_own_busy_flag_without_showing_an_old_error() {
        with_shell(|shell, cx| {
            let reply = Reply::Read(1, "notes.md".into());
            shell.run(reply.clone(), command(), cx);
            shell.browser.generation += 1;
            shell.browser.root = None;
            shell.accept(reply, Err("old file no longer exists".into()), cx);
            assert!(!shell.aux_busy);
            assert!(shell.browser_pending.is_none());
            assert!(shell.notice.is_none());
            assert!(shell.browser.root.is_none());
        });
    }
    #[test]
    fn an_old_folder_reply_cannot_clear_a_newer_folders_busy_state() {
        with_shell(|shell, cx| {
            let old = Reply::Files(1, "".into());
            shell.run(old.clone(), command(), cx);
            shell.browser.generation = 2;
            let newer = Reply::Files(2, "new-folder".into());
            shell.run(newer.clone(), command(), cx);
            let owned = shell.browser_pending.clone();
            shell.accept(old, Err("old failure".into()), cx);
            assert!(shell.aux_busy);
            assert_eq!(shell.browser_pending, owned);
            assert!(shell.notice.is_none());
            shell.accept(newer,Ok(json!({"schema_version":1,"root":shell.browser.root,"path":"new-folder","entries":[]})),cx);
            assert!(!shell.aux_busy);
            assert!(shell.browser_pending.is_none());
            assert_eq!(shell.browser.path, "new-folder");
        });
    }
    #[test]
    fn an_old_file_reply_cannot_release_a_git_operations_busy_state() {
        with_shell(|shell, cx| {
            let old = Reply::Read(1, "notes.md".into());
            shell.run(old.clone(), command(), cx);
            let git = GitActionRequest {
                generation: 1,
                root: shell.browser.root.clone().unwrap(),
                action: GitAction::Fetch,
                step: GitStep::Fetch,
                id: uuid::Uuid::new_v4().to_string(),
                head: json!("a".repeat(40)),
                branch: json!("main"),
                host: json!("example.test"),
                origin: json!("https://example.test/repo.git"),
                fields: Value::Null,
                receipts: vec![],
                acknowledged: false,
            };
            shell.run(Reply::GitAction(git.clone()), git.command(), cx);
            assert!(shell.browser_pending.is_none());
            shell.accept(old, Err("old failure".into()), cx);
            assert!(shell.aux_busy);
            assert_eq!(shell.browser.git_actions.pending, Some(git));
            assert!(shell.notice.is_none());
        });
    }
    #[test]
    fn file_and_directory_reads_of_the_same_path_have_distinct_ownership() {
        with_shell(|shell, cx| {
            let old = Reply::Files(1, "item".into());
            shell.run(old.clone(), command(), cx);
            let current = Reply::Read(1, "item".into());
            shell.run(current.clone(), command(), cx);
            shell.accept(old, Err("stale directory failure".into()), cx);
            assert!(shell.aux_busy);
            assert_eq!(
                shell.browser_pending,
                BrowserReadRequest::from_reply(&current)
            );
            shell.accept(current, Err("current text failure".into()), cx);
            assert!(!shell.aux_busy);
            assert_eq!(shell.notice.as_deref(), Some("current text failure"));
        });
    }
    #[test]
    fn an_old_folder_reply_cannot_release_a_workspace_list_refresh() {
        with_shell(|shell, cx| {
            let old = Reply::Files(1, "".into());
            shell.run(old.clone(), command(), cx);
            shell.run(Reply::Workspaces, command(), cx);
            shell.accept(old, Err("stale folder failure".into()), cx);
            assert!(shell.aux_busy);
            assert!(shell.notice.is_none());
            shell.accept(
                Reply::Workspaces,
                Ok(json!({"schema_version":1,"workspaces":[]})),
                cx,
            );
            assert!(!shell.aux_busy);
            assert!(shell.browser.workspaces_loaded);
        });
    }
}
