use super::i18n::Locale;
use crate::assistant_runtime::RunnerStatus;
use chrono::{DateTime, Local, Utc};
use rish_shell_core::assistant_store::{AssistantRunStatus, AssistantTask};

pub(super) fn copy(locale: Locale, en: &'static str, zh: &'static str) -> &'static str {
    if locale == Locale::Zh { zh } else { en }
}

pub(super) fn runner(locale: Locale, status: &RunnerStatus) -> &'static str {
    match status {
        RunnerStatus::Idle => copy(locale, "Ready", "随时待命"),
        RunnerStatus::WaitingForForeground => {
            copy(locale, "Waiting for this app", "等待应用回到前台")
        }
        RunnerStatus::Running => copy(locale, "Working", "执行中"),
        RunnerStatus::NeedsAttention => copy(locale, "Needs your attention", "需要你核对"),
    }
}

pub(super) fn run(locale: Locale, status: AssistantRunStatus) -> &'static str {
    match status {
        AssistantRunStatus::Running => copy(locale, "Running", "执行中"),
        AssistantRunStatus::NeedsAttention => copy(locale, "Needs attention", "需要核对"),
        AssistantRunStatus::Completed => copy(locale, "Completed", "已完成"),
        AssistantRunStatus::Failed => copy(locale, "Failed", "执行失败"),
        AssistantRunStatus::Cancelled => copy(locale, "Stopped", "已停止"),
    }
}

pub(super) fn interval(locale: Locale, minutes: Option<u32>) -> String {
    match minutes {
        Some(n) => {
            if locale == Locale::Zh {
                format!("每 {n} 分钟跟进")
            } else {
                format!("Every {n} minutes")
            }
        }
        None => copy(locale, "Manual only", "仅手动运行").into(),
    }
}

pub(super) fn task_status(locale: Locale, task: &AssistantTask) -> &'static str {
    if let Some(run) = &task.last_run
        && run.status.is_active()
    {
        return self::run(locale, run.status);
    }
    if task.pending_manual {
        return copy(locale, "Queued", "等待运行");
    }
    if !task.enabled {
        return copy(locale, "Paused", "已暂停");
    }
    copy(locale, "Ready", "待命")
}

pub(super) fn failure(locale: Locale, code: &str) -> String {
    let message = match code {
        "E_ASSISTANT_BACKGROUND_EXPIRED" | "E_ASSISTANT_NATIVE_BACKGROUND_EXPIRED" => copy(
            locale,
            "The system ended background execution. Check the saved run before continuing.",
            "系统已结束后台执行，请核对已保存的运行记录后继续。",
        ),
        "E_ASSISTANT_NATIVE_STOP_REQUESTED" => copy(
            locale,
            "A stop was requested. Check the saved run to confirm it has stopped.",
            "已请求停止，请核对运行记录以确认任务已结束。",
        ),
        "E_ASSISTANT_START_INTERRUPTED" => copy(
            locale,
            "This task was interrupted before it started. You can run it again.",
            "任务在开始前中断，可以重新运行。",
        ),
        "E_ASSISTANT_RECONCILIATION_REQUIRED" => copy(
            locale,
            "Check the saved run before continuing. Some workspace changes may already be complete.",
            "请先核对运行记录，部分工作空间改动可能已完成。",
        ),
        "E_CONVERSATION_WORKSPACE_UNAVAILABLE" => copy(
            locale,
            "This workspace is unavailable. Reopen it before running the task.",
            "工作空间暂不可用，请重新打开工作空间后再运行。",
        ),
        _ => return super::agent_copy::failure(locale, code),
    };
    message.into()
}

pub(super) fn message(locale: Locale, value: &str) -> String {
    let translated = match value {
        "Saved assistant work needs reconciliation" => copy(
            locale,
            "Check saved progress to continue.",
            "请核对已保存的任务进度后继续。",
        ),
        "Assistant needs an answer" => copy(
            locale,
            "Your assistant has a question for you.",
            "助手需要你补充信息。",
        ),
        "Assistant needs approval" => copy(
            locale,
            "Your assistant needs your approval.",
            "助手需要你确认下一步操作。",
        ),
        "Background execution expired. Review this run before starting another." => copy(
            locale,
            "The system ended background execution. Check this run before starting another.",
            "系统已结束后台执行，请先核对这次运行记录。",
        ),
        "Reconcile the existing assistant run before starting another" => copy(
            locale,
            "Check the previous run before starting another.",
            "请先核对上一次运行，再开始新任务。",
        ),
        "Assistant state is corrupt; existing data was preserved" => copy(
            locale,
            "Saved assistant data could not be read. The existing data was kept.",
            "无法读取已保存的助手数据，原有数据已保留。",
        ),
        "Assistant task is paused or is not due" => copy(
            locale,
            "This task is paused or its next follow-up is not due yet.",
            "任务已暂停，或尚未到下次跟进时间。",
        ),
        "Invalid assistant state: workspace is fixed after the first run; create a new task" => {
            copy(
                locale,
                "This task already has a conversation. Create a new task to use another workspace.",
                "这个任务已经关联会话。使用其他工作空间时，请新建任务。",
            )
        }
        _ if value.starts_with("E_") && !value.contains(' ') => return failure(locale, value),
        _ => return value.to_owned(),
    };
    translated.into()
}

pub(super) fn time(locale: Locale, millis: Option<u64>) -> String {
    millis
        .and_then(|ms| i64::try_from(ms).ok())
        .and_then(DateTime::<Utc>::from_timestamp_millis)
        .map(|date| date.with_timezone(&Local).format("%m-%d %H:%M").to_string())
        .unwrap_or_else(|| copy(locale, "Not scheduled", "未安排").into())
}

pub(super) fn workspace_name(value: &serde_json::Value, locale: Locale) -> String {
    value["display_name"]
        .as_str()
        .filter(|name| !name.is_empty())
        .unwrap_or(copy(locale, "Choose a workspace", "选择工作空间"))
        .to_owned()
}

use super::name_prompt;
use rish_shell_core::{
    RuntimeCommand,
    assistant_store::{AssistantTaskConfig, MAX_TEXT_BYTES, MIN_INTERVAL_MINUTES},
};
use serde_json::json;

pub(super) fn parse_interval(text: &str) -> Result<Option<u32>, ()> {
    if text.trim().is_empty() {
        return Ok(None);
    }
    let minutes = text.trim().parse::<u32>().map_err(|_| ())?;
    if minutes < MIN_INTERVAL_MINUTES {
        return Err(());
    }
    Ok(Some(minutes))
}

pub(super) fn validate_draft(
    config: &AssistantTaskConfig,
    locale: super::Locale,
) -> Result<(), String> {
    if config.title.trim().is_empty() || config.instructions.trim().is_empty() {
        return Err(copy(
            locale,
            "Add a title and instructions.",
            "请填写任务名称和要求。",
        )
        .into());
    }
    if config.title.len() > MAX_TEXT_BYTES || config.instructions.len() > MAX_TEXT_BYTES {
        return Err(copy(locale, "Task text is too long.", "任务文字过长。").into());
    }
    if !config.workspace_binding.is_object()
        || !config.workspace_descriptor.is_object()
        || config.model_id.is_empty()
    {
        return Err(copy(
            locale,
            "Choose a workspace and an existing model.",
            "请选择工作空间与已配置模型。",
        )
        .into());
    }
    if config
        .interval_minutes
        .is_some_and(|n| n < MIN_INTERVAL_MINUTES)
    {
        return Err(copy(
            locale,
            "Follow-ups must be at least 15 minutes apart.",
            "跟进间隔至少为 15 分钟。",
        )
        .into());
    }
    Ok(())
}

pub(super) fn field_command(
    title: &str,
    initial: &str,
    multiline: bool,
    locale: super::Locale,
    cx: &gpui::App,
) -> RuntimeCommand {
    let save = copy(locale, "Done", "完成");
    let cancel = copy(locale, "Cancel", "取消");
    let long = copy(locale, "Text is too long.", "文字过长。");
    if multiline {
        RuntimeCommand::new(
            "ShellInput",
            "editFile",
            vec![json!({
                "initial_text":initial, "title":title, "appearance":name_prompt::appearance(cx),
                "save_label":save, "cancel_label":cancel, "max_bytes":MAX_TEXT_BYTES, "too_long_message":long,
            })],
        )
    } else {
        RuntimeCommand::new(
            "ShellInput",
            "name",
            vec![json!({
                "kind":"conversation", "initial_text":initial, "title":title, "label":title,
                "placeholder":title, "hint":"", "submit_label":save, "cancel_label":cancel,
                "empty_error":copy(locale, "Enter a value.", "请输入内容。"),
                "invalid_error":copy(locale, "Check this value.", "请检查输入内容。"),
                "long_error":long, "appearance":name_prompt::appearance(cx),
            })],
        )
    }
}
