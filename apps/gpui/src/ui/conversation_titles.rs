use super::*;

impl Shell {
    /// Localize the persisted default without renaming the conversation or
    /// changing a title that the user explicitly chose, including "New chat".
    pub(super) fn conversation_title(&self, id: &str, fallback: &str) -> String {
        let default_title = self.state.raw_session()["conversations"]
            .as_array()
            .and_then(|conversations| {
                conversations
                    .iter()
                    .find(|conversation| conversation["id"].as_str() == Some(id))
            })
            .is_some_and(|conversation| {
                conversation["title_source"].as_str() == Some("auto")
                    && conversation["title"].as_str() == Some("New chat")
            });
        if default_title {
            self.locale.text(Text::NewChat).to_owned()
        } else {
            fallback.to_owned()
        }
    }
}
