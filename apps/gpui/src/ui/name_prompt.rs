use super::{Locale, Text, theme};
use gpui::App;
use rish_shell_core::RuntimeCommand;
use serde_json::json;

pub(super) enum NameKind {
    Workspace,
    Conversation,
}

/// Native naming fields own composition; only a completed canonical name is
/// returned to the existing workspace or conversation transaction.
pub(super) fn command(kind: NameKind, initial: &str, locale: Locale, cx: &App) -> RuntimeCommand {
    let (kind, title, placeholder, hint, submit) = match kind {
        NameKind::Workspace => (
            "workspace",
            Text::NewWorkspace,
            Text::WorkspaceNamePlaceholder,
            Text::WorkspaceNameHint,
            Text::Create,
        ),
        NameKind::Conversation => (
            "conversation",
            Text::RenameConversation,
            Text::ConversationNamePlaceholder,
            Text::ConversationNameHint,
            Text::Save,
        ),
    };
    RuntimeCommand::new(
        "ShellInput",
        "name",
        vec![json!({
            "kind": kind,
            "initial_text": initial,
            "title": locale.text(title),
            "label": locale.text(Text::Name),
            "placeholder": locale.text(placeholder),
            "hint": locale.text(hint),
            "submit_label": locale.text(submit),
            "cancel_label": locale.text(Text::Cancel),
            "empty_error": locale.text(Text::NameRequired),
            "invalid_error": locale.text(Text::NameInvalid),
            "long_error": locale.text(Text::NameTooLong),
            "appearance": appearance(cx),
        })],
    )
}

pub(super) fn appearance(cx: &App) -> &'static str {
    let theme = cx
        .try_global::<theme::ThemeState>()
        .copied()
        .unwrap_or_default();
    let dark = theme.mode == theme::ThemeMode::Dark
        || (theme.mode == theme::ThemeMode::System && theme.system_dark);
    if dark { "dark" } else { "light" }
}

pub(super) fn entry_command(folder: bool, locale: Locale, cx: &App) -> RuntimeCommand {
    let mut command = command(NameKind::Conversation, "", locale, cx);
    let options = &mut command.args[0];
    options["title"] = json!(locale.text(if folder {
        Text::NewFolder
    } else {
        Text::NewFile
    }));
    options["placeholder"] = json!(locale.text(if folder {
        Text::FolderNamePlaceholder
    } else {
        Text::FileNamePlaceholder
    }));
    options["hint"] = json!(locale.text(Text::EntryNameHint));
    options["submit_label"] = json!(locale.text(if folder { Text::Create } else { Text::Next }));
    options["invalid_error"] = json!(locale.text(Text::EntryNameInvalid));
    command
}
