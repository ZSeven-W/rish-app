//! Unsent text shares the session CAS; local edits are an overlay until its
//! matching proof arrives. Neither a reload nor a failed save discards edits.
use crate::{model::Result, RuntimeCommand, ShellState};
use rish_agent_core::session_schema;
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

const NEW_DRAFT: &str = "new-draft";

#[derive(Clone, Debug)]
struct Edit {
    base: String,
    text: String,
    revision: u64,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct DraftState {
    edits: BTreeMap<String, Edit>,
    revision: u64,
}

#[derive(Clone, Debug, Default)]
pub(crate) enum DraftEffect {
    #[default]
    None,
    Consume {
        key: String,
        text: String,
    },
    ConsumeAnswer {
        key: String,
        text: String,
    },
    Adopt {
        target: String,
    },
}

#[derive(Clone, Debug)]
pub(crate) struct DraftCommit {
    revisions: BTreeMap<String, u64>,
    pub(crate) effect: DraftEffect,
}

fn saved<'a>(session: &'a Value, key: &str) -> &'a str {
    session["composer_drafts"][key].as_str().unwrap_or("")
}

fn put(drafts: &mut Map<String, Value>, key: &str, text: &str) {
    if text.is_empty() {
        drafts.remove(key);
    } else {
        drafts.insert(key.into(), json!(text));
    }
}

fn bounded(drafts: &Map<String, Value>) -> bool {
    session_schema::validate_composer_drafts(&Value::Object(drafts.clone()))
}

impl ShellState {
    /// Stage exact accepted editor text, including whitespace. This is allowed
    /// while loading or another write is pending; it never changes authority.
    pub fn stage_composer_draft(&mut self, key: &str, text: &str) -> Result<()> {
        if !session_schema::valid_identifier(Some(&json!(key)), 256)
            || text.len() > session_schema::MAX_COMPOSER_DRAFT_BYTES
        {
            return Err("E_COMPOSER_DRAFT_BOUNDS".into());
        }
        if self.composer_draft(key) == text {
            return if bounded(&self.effective_composer_drafts()) {
                Ok(())
            } else {
                Err("E_COMPOSER_DRAFT_BOUNDS".into())
            };
        }
        let mut drafts = self.effective_composer_drafts();
        put(&mut drafts, key, text);
        let within_bounds = bounded(&drafts);
        let stored = saved(&self.session, key);
        let pending_differs = self
            .pending
            .as_ref()
            .is_some_and(|p| saved(&p.candidate, key) != text);
        if stored == text && !pending_differs {
            self.composer_drafts.edits.remove(key);
            return Ok(());
        }
        self.composer_drafts.revision = self.composer_drafts.revision.saturating_add(1);
        let base = self
            .composer_drafts
            .edits
            .get(key)
            .map(|e| e.base.clone())
            .unwrap_or_else(|| stored.to_owned());
        self.composer_drafts.edits.insert(
            key.into(),
            Edit {
                base,
                text: text.into(),
                revision: self.composer_drafts.revision,
            },
        );
        // Native accepted this bounded single input. Capacity failure affects
        // persistence only: keep the exact edit available across navigation.
        if within_bounds {
            Ok(())
        } else {
            Err("E_COMPOSER_DRAFT_BOUNDS".into())
        }
    }

    pub fn composer_draft(&self, key: &str) -> &str {
        self.composer_drafts
            .edits
            .get(key)
            .map(|e| e.text.as_str())
            .unwrap_or_else(|| saved(&self.session, key))
    }

    pub fn saved_composer_draft(&self, key: &str) -> &str {
        saved(&self.session, key)
    }

    pub fn has_unsaved_composer_drafts(&self) -> bool {
        !self.composer_drafts.edits.is_empty()
    }

    /// The ordinary session lane is the only writer. Busy callers retain the
    /// overlay and retry after their pending operation has settled.
    pub fn persist_composer_drafts(&mut self) -> Result<Option<RuntimeCommand>> {
        if !self.has_unsaved_composer_drafts() {
            return Ok(None);
        }
        self.ready()?;
        if !self.composer_draft_conflicts().is_empty() {
            return Err("E_COMPOSER_DRAFT_CONFLICT".into());
        }
        if !bounded(&self.effective_composer_drafts()) {
            return Err("E_COMPOSER_DRAFT_BOUNDS".into());
        }
        self.commit(self.session.clone(), None, false).map(Some)
    }

    /// Keep UI edits when the assistant actor returns its newer authoritative
    /// session. Only the overlay moves: saved bytes and CAS proof stay native.
    pub fn retain_composer_drafts_from(&mut self, previous: &Self) {
        self.composer_drafts.revision = self
            .composer_drafts
            .revision
            .max(previous.composer_drafts.revision);
        for (key, edit) in &previous.composer_drafts.edits {
            self.composer_drafts.edits.insert(key.clone(), edit.clone());
        }
    }

    /// Remote and local text are both retained until an explicit resolution.
    pub fn composer_draft_conflicts(&self) -> Vec<String> {
        self.composer_drafts
            .edits
            .iter()
            .filter(|(key, edit)| {
                let current = saved(&self.session, key);
                current != edit.base && current != edit.text
            })
            .map(|(key, _)| key.clone())
            .collect()
    }

    /// `keep_local` is a deliberate overwrite of the inspected saved draft;
    /// false restores that saved text. Neither choice bypasses a pending CAS.
    pub fn resolve_composer_draft_conflict(&mut self, key: &str, keep_local: bool) -> Result<()> {
        self.ready()?;
        if !self.composer_draft_conflicts().iter().any(|k| k == key) {
            return Err("E_COMPOSER_DRAFT_NO_CONFLICT".into());
        }
        if keep_local {
            self.composer_drafts.revision = self.composer_drafts.revision.saturating_add(1);
            let edit = self.composer_drafts.edits.get_mut(key).unwrap();
            edit.base = saved(&self.session, key).into();
            edit.revision = self.composer_drafts.revision;
        } else {
            self.composer_drafts.edits.remove(key);
        }
        Ok(())
    }

    fn effective_composer_drafts(&self) -> Map<String, Value> {
        let mut drafts = self.session["composer_drafts"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        for (key, edit) in &self.composer_drafts.edits {
            put(&mut drafts, key, &edit.text);
        }
        drafts
    }

    pub(crate) fn merge_composer_drafts(
        &self,
        candidate: &mut Value,
        effect: DraftEffect,
    ) -> Result<DraftCommit> {
        let conflicts = self.composer_draft_conflicts();
        if let DraftEffect::Adopt { target } = &effect {
            if conflicts
                .iter()
                .any(|key| key == NEW_DRAFT || key == target)
            {
                // Adoption changes identity. A conflicting source cannot be
                // skipped like an unrelated draft: moving the remote text
                // would silently rebase the retained local alternative.
                return Err("E_COMPOSER_DRAFT_CONFLICT".into());
            }
        }
        let mut drafts = candidate["composer_drafts"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        let original = drafts.clone();
        let mut revisions = BTreeMap::new();
        for (key, edit) in &self.composer_drafts.edits {
            // A text conflict must not block an Agent receipt or other durable
            // checkpoint. Leave both versions alone until the UI resolves it.
            if conflicts.contains(key) {
                continue;
            }
            put(&mut drafts, key, &edit.text);
            revisions.insert(key.clone(), edit.revision);
        }
        // An actor can save other drafts while it owns the writer. If their
        // combined size now exceeds the limit, retain the overlay for explicit
        // repair without preventing a critical task checkpoint from settling.
        if !bounded(&drafts) {
            drafts = original.clone();
            revisions.clear();
        }
        match &effect {
            DraftEffect::None => {}
            DraftEffect::Consume { key, text } | DraftEffect::ConsumeAnswer { key, text } => {
                if drafts.get(key).and_then(Value::as_str) == Some(text) {
                    drafts.remove(key);
                }
                if let Some(edit) = self.composer_drafts.edits.get(key) {
                    if edit.text == *text && !conflicts.contains(key) {
                        revisions.insert(key.clone(), edit.revision);
                    }
                }
            }
            DraftEffect::Adopt { target } => {
                if let Some(draft) = drafts.remove(NEW_DRAFT) {
                    if drafts.contains_key(target) {
                        return Err("E_COMPOSER_DRAFT_CONFLICT".into());
                    }
                    drafts.insert(target.clone(), draft);
                }
            }
        }
        if !bounded(&drafts) {
            return Err("E_COMPOSER_DRAFT_BOUNDS".into());
        }
        // Read-only load and unrelated writes preserve the legacy version.
        // Once upgraded, an empty map still retains the explicit schema 10.
        if drafts != original || candidate["schema_version"] == 10 {
            candidate["schema_version"] = json!(10);
            candidate["composer_drafts"] = Value::Object(drafts);
        }
        Ok(DraftCommit { revisions, effect })
    }

    pub(crate) fn acknowledge_composer_drafts(&mut self, candidate: &Value, commit: &DraftCommit) {
        if let DraftEffect::ConsumeAnswer { key, .. } = &commit.effect {
            if let Some(run) = self
                .agent_run
                .as_mut()
                .filter(|run| run.conversation_id == *key)
            {
                run.answer_draft_pending = false;
            }
        }
        let adopted_edit = if let DraftEffect::Adopt { target } = &commit.effect {
            self.composer_drafts
                .edits
                .remove(NEW_DRAFT)
                .and_then(|mut edit| {
                    if commit.revisions.get(NEW_DRAFT) == Some(&edit.revision) {
                        None
                    } else {
                        edit.base = saved(candidate, target).into();
                        Some((target.clone(), edit))
                    }
                })
        } else {
            None
        };
        self.composer_drafts.edits.retain(|key, edit| {
            if commit.revisions.get(key) == Some(&edit.revision) {
                return false;
            }
            // New typing after dispatch keeps its revision. Its base advances
            // only when it was based on the snapshot this proof supersedes.
            if edit.base == saved(&self.session, key) {
                edit.base = saved(candidate, key).into();
            }
            edit.text != saved(candidate, key)
        });
        if let Some((target, edit)) = adopted_edit {
            if edit.text != saved(candidate, &target)
                && self
                    .composer_drafts
                    .edits
                    .get(&target)
                    .is_none_or(|existing| existing.revision < edit.revision)
            {
                self.composer_drafts.edits.insert(target, edit);
            }
        }
    }
}
