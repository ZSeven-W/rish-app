use super::i18n::Locale;

pub(super) fn copy(locale: Locale, en: &'static str, zh: &'static str) -> &'static str {
    if locale == Locale::Zh { zh } else { en }
}

pub(super) fn phase(locale: Locale, value: &str) -> &'static str {
    let (en, zh) = match value {
        "preparing" | "prepare" | "prepared" => ("Preparing workspace", "正在准备工作空间"),
        "sending" | "round" | "begin_round" | "round_in_flight" => {
            ("Working on your request", "正在处理你的任务")
        }
        "awaiting_approval" | "approval" => ("Your approval is needed", "需要你确认"),
        "awaiting_question" | "question" => ("A question for you", "需要你补充信息"),
        "executing" | "execute" | "execution_intent" => ("Running a tool", "正在执行工具"),
        "cancelling" | "cancel_requested" => ("Stopping safely", "正在停止任务"),
        "persisting" | "checkpoint" => ("Saving progress", "正在保存进度"),
        "recovering" | "recover" | "query" => ("Checking saved progress", "正在核对已保存的进度"),
        "recovery_required" => ("Check saved progress to continue", "请核对进度后继续"),
        "manual_reconciliation" | "ambiguous" | "unknown" => {
            ("Execution result needs review", "执行结果需要核对")
        }
        "completed" | "final_response" => ("Task completed", "任务已完成"),
        "cancelled" => ("Task stopped", "任务已停止"),
        "failed" => ("Task stopped with an error", "任务因错误停止"),
        _ => ("Working", "正在处理"),
    };
    copy(locale, en, zh)
}

pub(super) fn tool(locale: Locale, name: &str) -> String {
    let label = match name {
        "list_files" | "list_dir" => Some(("List files", "查看文件列表")),
        "read_file" => Some(("Read file", "读取文件")),
        "search_files" => Some(("Search files", "搜索文件")),
        "write_file" => Some(("Write file", "写入文件")),
        "apply_patch" => Some(("Apply changes", "应用改动")),
        "git_status" => Some(("Git status", "查看 Git 状态")),
        "git_diff" => Some(("Git diff", "查看 Git 差异")),
        "git_commit" => Some(("Git commit", "提交 Git 改动")),
        "git_push" => Some(("Git push", "推送 Git 提交")),
        "run_runtime_program" | "run_program" => Some(("Run program", "运行程序")),
        "start_guest_cgi" => Some(("Start preview service", "启动预览服务")),
        "stop_guest_cgi" => Some(("Stop preview service", "停止预览服务")),
        "start_runtime_service" => Some(("Start service", "启动服务")),
        "stop_runtime_service" => Some(("Stop service", "停止服务")),
        "list_runtime_environments" => Some(("Available runtimes", "查看运行环境")),
        "install_runtime_environment" => Some(("Install runtime", "安装运行环境")),
        "ask_user" => Some(("Ask a question", "询问信息")),
        "list_assistant_tasks" => Some(("Review tasks", "查看任务")),
        "create_assistant_task" => Some(("Create a task", "创建任务")),
        "update_assistant_task" => Some(("Update a task", "调整任务")),
        "search_assistant_memory" => Some(("Recall local memories", "查找本地记忆")),
        "remember_assistant_memory" => Some(("Save a memory", "保存记忆")),
        "forget_assistant_memory" => Some(("Forget a memory", "删除记忆")),
        _ => None,
    };
    label
        .map(|(en, zh)| copy(locale, en, zh).to_owned())
        .unwrap_or_else(|| name.to_owned())
}

pub(super) fn failure(locale: Locale, code: &str) -> String {
    match code {
        "E_AGENT_PROVIDER_CREDENTIAL" => copy(
            locale,
            "Configure this model's API key or sign in from Settings, then try again.",
            "请先在设置中配置该模型的 API 密钥或登录账号，再重新发送。",
        )
        .into(),
        "E_AGENT_ROUND_LIMIT" => copy(
            locale,
            "This task reached its round limit. You can continue with another message.",
            "任务已达到本轮执行次数上限，可以发送新消息继续。",
        )
        .into(),
        "E_AGENT_CANCELLED" => copy(locale, "The task has stopped.", "任务已停止。").into(),
        _ => format!(
            "{} ({code})",
            copy(locale, "The task could not finish.", "任务未能完成。")
        ),
    }
}
