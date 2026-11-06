//! Safe presentation and private driver state for the durable native Agent.
use crate::RuntimeCommand;
use serde_json::Value;

#[derive(Clone, Debug, PartialEq)]
pub struct AgentToolView {
    pub round_index: u64,
    pub call_id: String,
    pub name: String,
    pub status: String,
    pub preview: Value,
}
#[derive(Clone, Debug, PartialEq)]
pub struct AgentApprovalView {
    pub approval_id: String,
    pub call_id: String,
    pub name: String,
    pub preview: Value,
    pub allowed_decisions: Vec<String>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct AgentQuestionView {
    pub id: String,
    pub call_id: String,
    pub question: String,
    pub options: Vec<(String, String)>,
    pub input_mode: String,
}
#[derive(Clone, Debug, PartialEq)]
pub struct AgentView {
    pub phase: String,
    pub failure_code: Option<String>,
    pub round: u64,
    pub tools: Vec<AgentToolView>,
    pub approval: Option<AgentApprovalView>,
    pub question: Option<AgentQuestionView>,
    pub preview_text: String,
    pub preview_reasoning: String,
    pub recoverable: bool,
    pub preview_incomplete: bool,
}
#[derive(Clone, Debug)]
pub(crate) struct AgentRun {
    pub conversation_id: String,
    pub attempt_id: String,
    pub assistant_message_id: String,
    pub action: String,
    pub operation_id: String,
    pub in_flight: Option<RuntimeCommand>,
    pub batch: Value,
    pub decision: Value,
    pub cleanup: Value,
    pub cancel_requested: bool,
    pub answer_draft_pending: bool,
    pub recoverable: bool,
    pub preview_text: String,
    pub preview_reasoning: String,
    pub preview_seq: u64,
    pub preview_provider: Option<String>,
    pub preview_ended: bool,
    pub preview_incomplete: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AgentPresentation {
    pub user_message_id: String,
    pub attempt_id: String,
    pub round_id: String,
    pub round_index: u64,
    pub kind: String,
    pub text: String,
    pub reasoning: String,
}
