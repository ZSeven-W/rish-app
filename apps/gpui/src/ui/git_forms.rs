use super::{
    git_operations::GitAction,
    i18n::{Locale, Text},
    name_prompt,
};
use gpui::App;
use rish_shell_core::RuntimeCommand;
use serde_json::{Value, json};

pub(super) fn command(
    action: GitAction,
    initial: &Value,
    locale: Locale,
    cx: &App,
) -> RuntimeCommand {
    let remote = action == GitAction::Remote;
    let field = |key: &str, label: Text, placeholder: Text| {
        json!({
            "key":key, "label":locale.text(label), "placeholder":locale.text(placeholder),
            "value":initial[key].as_str().unwrap_or(""),
        })
    };
    let fields = if remote {
        vec![field("url", Text::GitRemoteUrl, Text::GitRemotePlaceholder)]
    } else {
        vec![
            field("message", Text::GitMessage, Text::GitMessagePlaceholder),
            field(
                "author_name",
                Text::GitAuthorName,
                Text::GitAuthorNamePlaceholder,
            ),
            field(
                "author_email",
                Text::GitAuthorEmail,
                Text::GitAuthorEmailPlaceholder,
            ),
        ]
    };
    RuntimeCommand::new(
        "ShellInput",
        "gitForm",
        vec![json!({
            "kind":if remote {"remote"} else {"commit"},
            "appearance":name_prompt::appearance(cx),
            "title":locale.text(if remote {Text::GitRemote} else {Text::GitCommit}),
            "submit_label":locale.text(if remote {Text::Save} else {Text::GitCommit}),
            "cancel_label":locale.text(Text::Cancel), "fields":fields,
            "hint":locale.text(if remote {Text::GitRemoteHint} else {Text::GitCommitHint}),
            "invalid_message":locale.text(Text::GitInvalidForm),
        })],
    )
}
