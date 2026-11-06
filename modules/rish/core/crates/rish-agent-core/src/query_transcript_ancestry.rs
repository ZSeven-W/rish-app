//! Read-only recovery of a UI checkpoint whose native tool reply was lost.
//! Neither a matching UUID nor a larger generation proves ancestry. Require
//! the durable append checkpoints and hash the actual protected prefix.
use super::*;
use crate::canonical::canonical_json;
use crate::schema::transcript_reference;
use std::collections::BTreeMap;

pub(super) fn proves(state: &Value, base: &Value, request: &Value) -> bool {
    let before = &request["expected_transcript"];
    let after = &base["transcript"];
    if !transcript_reference(Some(before))
        || !transcript_reference(Some(after))
        || before["transcript_ref"] != after["transcript_ref"]
        || u64_of(before.get("generation")) >= u64_of(after.get("generation"))
    {
        return false;
    }
    let same_owner = |row: &Value| {
        row["task_id"] == request["task_id"] && row["attempt_id"] == request["attempt_id"]
    };
    let same_root = |row: &Value| {
        row["root_fingerprint_sha256"] == request["expected_root_fingerprint_sha256"]
            && row["binding_revision"] == request["expected_workspace_binding_revision"]
    };
    let authorities: Vec<_> = array(state.get("authorities"))
        .iter()
        .filter(|row| same_owner(row))
        .collect();
    if authorities.len() != 1
        || authorities[0]["conversation_id"] != request["conversation_id"]
        || authorities[0]["root"] != base["root"]
        || authorities[0]["transcript"] != *after
    {
        return false;
    }
    let transcripts: Vec<_> = array(state.get("transcripts"))
        .iter()
        .filter(|row| {
            row["attempt_id"] == request["attempt_id"]
                && row["transcript_ref"] == after["transcript_ref"]
                && row["root_fingerprint_sha256"] == request["expected_root_fingerprint_sha256"]
        })
        .collect();
    if transcripts.len() != 1 {
        return false;
    }
    let transcript = transcripts[0];
    for key in ["generation", "transcript_sha256", "transcript_bytes"] {
        if transcript[key] != after[key] {
            return false;
        }
    }
    let Some(messages) = transcript["messages"].as_array() else {
        return false;
    };
    let mut checkpoints: BTreeMap<u64, Value> = BTreeMap::new();
    let mut appends: BTreeMap<u64, (Value, Value, usize)> = BTreeMap::new();
    let mut prefix = None;
    let mut published_before = false;
    for table in ["rounds", "ledger", "denied_calls"] {
        for row in array(state.get(table)) {
            let locator = if table == "denied_calls" {
                row
            } else {
                &row["locator"]
            };
            if !same_owner(locator) || !same_root(row) {
                continue;
            }
            let start = &row["transcript_before"];
            let end = &row["transcript_after"];
            if !transcript_reference(Some(start))
                || start["transcript_ref"] != after["transcript_ref"]
            {
                continue;
            }
            let start_generation = u64_of(start.get("generation"));
            published_before |= start == before;
            if let Some(prior) = checkpoints.insert(start_generation, start.clone()) {
                if prior != *start {
                    return false;
                }
            }
            let terminal = matches!(
                row["state"].as_str(),
                Some("completed" | "settled" | "cancelled" | "ambiguous")
            ) || (table == "denied_calls"
                && matches!(row["state"].as_str(), Some("denied" | "rejected")));
            if !terminal
                || !transcript_reference(Some(end))
                || end["transcript_ref"] != after["transcript_ref"]
            {
                continue;
            }
            let generation = u64_of(end.get("generation"));
            if generation <= start_generation {
                continue;
            }
            let indices: Vec<_> = messages
                .iter()
                .enumerate()
                .filter_map(|(index, message)| {
                    (message["round_index"] == locator["round_index"]
                        && if table == "rounds" {
                            message["role"] == "assistant"
                        } else {
                            message["role"] == "tool" && message["call_id"] == locator["call_id"]
                        })
                    .then_some(index)
                })
                .collect();
            if indices.is_empty() || (table != "rounds" && indices.len() != 1) {
                return false;
            }
            if table == "rounds"
                && (indices.len() > 16
                    || generation - start_generation != indices.len() as u64
                    || indices.windows(2).any(|pair| pair[1] != pair[0] + 1)
                    || !prefix_matches(transcript, start, &messages[..indices[0]])
                    || !prefix_matches(
                        transcript,
                        end,
                        &messages[..indices[indices.len() - 1] + 1],
                    ))
            {
                return false;
            }
            let mut step_start = start.clone();
            for (offset, index) in indices.iter().copied().enumerate() {
                let (step_generation, step_end) = if table == "rounds" {
                    let next = start_generation + offset as u64 + 1;
                    let Some(handle) = prefix_handle(transcript, next, &messages[..index + 1])
                    else {
                        return false;
                    };
                    (next, handle)
                } else {
                    (generation, end.clone())
                };
                if let Some(prior) = checkpoints.insert(step_generation, step_end.clone()) {
                    if prior != step_end {
                        return false;
                    }
                }
                if appends
                    .insert(step_generation, (step_start, step_end.clone(), index + 1))
                    .is_some()
                {
                    return false;
                }
                step_start = step_end;
            }
            if end == before {
                published_before = true;
                prefix = Some(indices[indices.len() - 1] + 1);
            }
        }
    }
    let from = u64_of(before.get("generation"));
    let to = u64_of(after.get("generation"));
    if !published_before
        || checkpoints.get(&from) != Some(before)
        || checkpoints.get(&to) != Some(after)
        || to - from > appends.len() as u64
    {
        return false;
    }
    if prefix.is_none() {
        prefix = appends
            .values()
            .filter(|(start, _, _)| start == before)
            .map(|(_, _, length)| length - 1)
            .min();
    }
    let Some(mut length) = prefix else {
        return false;
    };
    if !prefix_matches(transcript, before, &messages[..length])
        || !prefix_matches(transcript, after, messages)
    {
        return false;
    }
    for generation in from + 1..=to {
        let Some((start, end, next_length)) = appends.get(&generation) else {
            return false;
        };
        // A prepared batch shares its initial checkpoint. Its individual tool
        // receipts still prove every intervening append in strict message order.
        if checkpoints.get(&u64_of(start.get("generation"))) != Some(start)
            || u64_of(start.get("generation")) >= generation
            || *next_length <= length
            || checkpoints.get(&generation) != Some(end)
            || (generation != to && !prefix_matches(transcript, end, &messages[..*next_length]))
        {
            return false;
        }
        length = *next_length;
    }
    length == messages.len()
}

fn prefix_matches(transcript: &Value, handle: &Value, messages: &[Value]) -> bool {
    let value = json!({"schema_version":1,"transcript_ref":transcript["transcript_ref"],
        "attempt_id":transcript["attempt_id"],"root_fingerprint_sha256":transcript["root_fingerprint_sha256"],
        "generation":handle["generation"],"messages":messages});
    canonical_json(&value).is_ok_and(|bytes| handle["transcript_bytes"] == json!(bytes.len()))
        && hash_json("agent-transcript", &value).as_deref() == handle["transcript_sha256"].as_str()
}

fn prefix_handle(transcript: &Value, generation: u64, messages: &[Value]) -> Option<Value> {
    let value = json!({"schema_version":1,"transcript_ref":transcript["transcript_ref"],
        "attempt_id":transcript["attempt_id"],"root_fingerprint_sha256":transcript["root_fingerprint_sha256"],
        "generation":generation,"messages":messages});
    Some(
        json!({"schema_version":1,"transcript_ref":transcript["transcript_ref"],"generation":generation,
        "transcript_bytes":canonical_json(&value).ok()?.len(),"transcript_sha256":hash_json("agent-transcript",&value)?}),
    )
}
