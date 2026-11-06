use super::*;

pub(in crate::assistant_store) fn validate_groups(
    state: &AssistantSnapshot,
    insert: &mut impl FnMut(&str) -> StoreResult<()>,
) -> StoreResult<()> {
    if state.groups.len() > MAX_ASSISTANT_GROUPS {
        return Err(AssistantStoreError::Invalid("group limit"));
    }
    for group in &state.groups {
        memory::canonical_id(&group.id)?;
        insert(&group.id)?;
        if normalize_name(&group.name)? != group.name
            || group.rounds.len() > MAX_GROUP_ROUNDS
            || group.members.len() > MAX_BOTS
        {
            return Err(AssistantStoreError::Invalid("group state"));
        }
        validate_targets(state, &group.active_bot_ids, 2)?;
        let mut owners = HashSet::new();
        for member in &group.members {
            if state.bot_profile(&member.bot_id).is_none() || !owners.insert(&member.bot_id) {
                return Err(AssistantStoreError::Invalid("group member ownership"));
            }
            memory::canonical_id(&member.conversation_id)?;
            insert(&member.conversation_id)?;
        }
        if group.active_bot_ids.iter().any(|id| !owners.contains(id)) {
            return Err(AssistantStoreError::Invalid("missing group lane"));
        }
        let mut active = 0;
        for round in &group.rounds {
            for id in [&round.id, &round.user_message_id] {
                memory::canonical_id(id)?;
                insert(id)?;
            }
            bounded_group_text(&round.text, MAX_GROUP_INPUT_BYTES, true)?;
            if round.created_at_ms > state.clock_high_water_ms {
                return Err(AssistantStoreError::Invalid("group round clock"));
            }
            if group
                .rounds
                .first()
                .is_some_and(|first| first.workspace_binding != round.workspace_binding)
            {
                return Err(AssistantStoreError::Invalid("group workspace changed"));
            }
            let config = AssistantTaskConfig {
                title: group.name.clone(),
                instructions: round.text.clone(),
                model_id: round.model_id.clone(),
                workspace_binding: round.workspace_binding.clone(),
                workspace_descriptor: round.workspace_descriptor.clone(),
                interval_minutes: None,
                enabled: true,
                runtime: round.runtime.clone(),
            };
            validate_config(&config)?;
            let ids: Vec<_> = round.replies.iter().map(|r| r.bot_id.clone()).collect();
            validate_targets(state, &ids, 1)?;
            let mut unfinished = false;
            for reply in &round.replies {
                memory::canonical_id(&reply.id)?;
                insert(&reply.id)?;
                if !group
                    .members
                    .iter()
                    .any(|m| m.bot_id == reply.bot_id && m.conversation_id == reply.conversation_id)
                {
                    return Err(AssistantStoreError::Invalid("group reply lane"));
                }
                if let Some(text) = &reply.text {
                    bounded_group_text(text, MAX_GROUP_REPLY_BYTES, false)?;
                }
                if let Some(run) = &reply.run {
                    if (run.status == AssistantRunStatus::Completed) != reply.text.is_some() {
                        return Err(AssistantStoreError::Invalid("group completion text"));
                    }
                    if unfinished {
                        return Err(AssistantStoreError::Invalid("group reply order"));
                    }
                    if run.snapshot.model_id != round.model_id
                        || run.snapshot.workspace_binding != round.workspace_binding
                        || run.snapshot.workspace_descriptor != round.workspace_descriptor
                    {
                        return Err(AssistantStoreError::Invalid("group frozen context"));
                    }
                    for id in [
                        &run.run_id,
                        &run.ids.turn_id,
                        &run.ids.attempt_id,
                        &run.ids.round_id,
                        &run.ids.user_message_id,
                        &run.ids.assistant_message_id,
                    ] {
                        insert(id)?;
                    }
                    let task = AssistantTask {
                        id: reply.id.clone(),
                        title: group.name.clone(),
                        instructions: round.text.clone(),
                        conversation_id: reply.conversation_id.clone(),
                        workspace_binding: round.workspace_binding.clone(),
                        workspace_descriptor: round.workspace_descriptor.clone(),
                        model_id: round.model_id.clone(),
                        interval_minutes: None,
                        enabled: true,
                        next_due_ms: None,
                        pending_manual: false,
                        last_run: Some(run.clone()),
                        runtime: round.runtime.clone(),
                    };
                    validate_snapshot(&AssistantSnapshot {
                        revision: state.revision,
                        tasks: vec![task],
                        clock_high_water_ms: state.clock_high_water_ms,
                        ..Default::default()
                    })?;
                    if run.status != AssistantRunStatus::Completed {
                        unfinished = true;
                    }
                    if run.status.is_active() {
                        active += 1;
                    }
                    if matches!(
                        run.status,
                        AssistantRunStatus::Failed | AssistantRunStatus::Cancelled
                    ) && !round.stopped
                    {
                        return Err(AssistantStoreError::Invalid("failed group continues"));
                    }
                } else {
                    if reply.text.is_some() {
                        return Err(AssistantStoreError::Invalid("unclaimed group reply"));
                    }
                    unfinished = true;
                }
            }
        }
        if active > 1 || group.rounds.iter().filter(|r| r.is_pending()).count() > 1 {
            return Err(AssistantStoreError::Invalid("overlapping group rounds"));
        }
    }
    Ok(())
}
