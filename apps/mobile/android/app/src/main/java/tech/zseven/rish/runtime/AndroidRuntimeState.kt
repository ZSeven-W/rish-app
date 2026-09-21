package tech.zseven.rish.runtime

import android.app.Application
import android.content.Context
import android.os.Build
import org.json.JSONObject
import java.util.concurrent.Executors

internal class AndroidRuntimeState private constructor(val app: Application) {
    init { AndroidDshModelCatalog.initialize(app) }
    val credentials = AndroidCredentialStore(app)
    val configurations = AndroidProviderConfiguration(app)
    val sessions = AndroidSessionStore(app)
    /// The agent WAL lives beside the session database, outside backup, in the
    /// same bytes iOS writes. One root, because Android resolves none.
    val agentWal = AndroidAgentWal(java.io.File(app.noBackupFilesDir, "agent"))
    /// App-private workspace roots. Android resolves only these: no
    /// security-scoped folders, no legacy projects, no rebinding yet.
    val workspaces = AndroidWorkspaceRegistry(java.io.File(app.filesDir, "workspaces"))
    /// The git project a workspace is attached to: a private gitdir beside
    /// the registry, paired with the workspace root as its working tree.
    val workspaceProjects = AndroidWorkspaceProjects(workspaces)
    val roots = AndroidAgentRootResolver(workspaces, workspaceProjects)
    /// Forgetting a workspace and deleting its owned content, cleared
    /// against the committed session and journaled on disk.
    val workspaceRemoval = AndroidWorkspaceRemoval(sessions, workspaces, workspaceProjects)
    val projectContext = AndroidProjectContextService(workspaceProjects, roots)
    /// Git HTTPS credentials by (project, host), and the roots OpenSSL trusts
    /// when a push leaves the device.
    val gitCredentials = AndroidGitCredentials(app)
    val gitRoots = AndroidGitCertificates.ensure(app)
    val projectGit = AndroidProjectGit(workspaceProjects, workspaces, gitCredentials)
    /// A public repository into a new workspace, the network half staged first.
    val workspaceClone = AndroidWorkspaceClone(app, workspaces, workspaceProjects)
    /// Prepared context snapshots, outside backup like the agent WAL.
    val projectContextStore = AndroidProjectContextStore(java.io.File(app.noBackupFilesDir, "project-context"))
    val projectSnapshots = AndroidProjectContextSnapshots(
        workspaceProjects, roots, projectContextStore,
        providerBinding = { model ->
            try { configurations.binding(configurations.forModel(model), model) } catch (_: Exception) { null }
        },
    )
    val preparedAttempts = AndroidPreparedAttemptStore(sessions, agentWal, roots)
    /// Which native tasks this process still owns; a persisted owner from a
    /// previous launch is not alive, so its rows can be recovered.
    val liveTasks = AndroidLiveTasks()
    val agentOperations = AndroidAgentOperations(agentWal)
    val executionLedger = AndroidAgentExecutionLedger(agentWal, liveTasks, agentOperations)
    val workspaceTools = AndroidWorkspaceToolExecutor(workspaces, roots)
    /// The agent's git_status, git_commit and git_push, over an attached project.
    val gitTools = AndroidAgentGitToolExecutor(workspaceProjects, workspaces, roots, gitCredentials)
    val agentPolicy = AndroidAgentPolicyService(roots, AndroidAgentToolRegistry)
    val agentRounds = AndroidAgentRoundJournal(agentWal, liveTasks)
    val agentTranscripts = AndroidAgentTranscriptStore(agentWal)
    val toolBatch = AndroidAgentToolBatchService(
        agentWal, sessions, preparedAttempts, executionLedger, roots, workspaceTools,
        agentOperations, agentTranscripts, gitTools,
    )
    val toolExecution = AndroidAgentToolExecutionService(
        agentWal, sessions, preparedAttempts, executionLedger, roots, workspaceTools, liveTasks,
        agentTranscripts, agentOperations, gitTools,
    )
    val lifecycle = AndroidAgentLifecycleService(agentWal, sessions, agentOperations, roots)
    val approvals = AndroidAgentApprovalService(
        agentWal, sessions, executionLedger, agentOperations, roots,
    )
    val transport = AndroidModelTransport(credentials, configurations)
    val providerRound = AndroidAgentProviderRoundService(
        sessions, preparedAttempts, agentRounds, roots, AndroidAgentToolRegistry, transport, agentWal,
        agentOperations, liveTasks, agentTranscripts, projectSnapshots,
    )
    val queries = AndroidAgentQueryService(
        agentWal, sessions, preparedAttempts, executionLedger, agentTranscripts,
    )
    val recovery = AndroidAgentRecoveryService(
        agentWal, sessions, preparedAttempts, queries, providerRound, toolExecution, roots,
        agentOperations,
    )
    val cancellation = AndroidAgentCancelService(
        agentWal, sessions, preparedAttempts, executionLedger, providerRound, roots,
        agentOperations,
    )
    /// Files a person attached to a message: copied in once, because a
    /// document URI is a borrowed permission and a draft has to outlive it.
    val attachments = AndroidAttachmentStore(app.filesDir)
    /// What the Files drawer lists and opens, over the same roots and the
    /// same core rules the agent's tools use.
    val workspaceFiles = AndroidWorkspaceFiles(workspaces, roots)
    /// Documents coming into a workspace or going back out, staged first so
    /// a half-finished import can be finished instead of repeated.
    val documentTransfers = AndroidDocumentTransfers(
        app.filesDir, workspaceFiles, workspaces, roots,
    )
    /// The guest's package mirrors, staged into an app-private overlay that
    /// no booted guest reads yet -- the same overlay, and the same standing
    /// caveat, as iOS.
    val mirrors = AndroidMirrorStore(app.filesDir)
    val subscriptionAuth = AndroidSubscriptionAuthManager(app)
    val io = Executors.newFixedThreadPool(2)
    /**
     * Where a round's preview goes, when anyone is listening.
     *
     * The bridge sets this when JavaScript subscribes and clears it when the
     * last listener goes away; the round service only asks for a stream when
     * it is set. Preview material is display-only and is never persisted, so
     * nothing downstream depends on whether it was delivered.
     */
    @Volatile var roundPreview: ((JSONObject) -> Unit)? = null
    @Volatile var selectedSlot = "DEEPSEEK_API_KEY"
    @Volatile var restored = false
    companion object {
        @Volatile private var instance: AndroidRuntimeState? = null
        fun get(context: Context): AndroidRuntimeState = instance ?: synchronized(this) {
            instance ?: AndroidRuntimeState(context.applicationContext as Application).also { instance = it }
        }

        /** The runtime if one exists; a service deep in a turn never makes one. */
        fun current(): AndroidRuntimeState? = instance
    }
    fun loadSnapshot(): JSONObject = sessions.load().also {
        if(it.getString("status") == "present" && it.getString("writer_launch_instance_id") != AndroidSessionStore.launchId) restored = true
    }
    fun proof(): JSONObject {
        val hasCredential = transport.configured(selectedSlot)
        val model = transport.lastModel
        val harness = when(selectedSlot) { "BIGMODEL_API_KEY" -> "glm"; "OPENAI_API_KEY" -> "codex"; "ANTHROPIC_API_KEY" -> "claude-code"; else -> "dsh" }
        val proof = JSONObject().put("schema_version", 2).put("product", "rish").put("active_harness", harness)
            .put("mode", "local_substrate").put("platform", if(Build.HARDWARE in setOf("ranchu", "goldfish")) "android_emulator" else "android_device")
            .put("bundle_id", app.packageName).put("runtime_id", "rish-android-api-v1").put("launch_instance_id", AndroidSessionStore.launchId)
            .put("process_id", android.os.Process.myPid()).put("generated_at", RuntimeJson.now())
            .put("container_root", app.filesDir.absolutePath).put("session_store", app.getDatabasePath("rish.sessions.v1.db").absolutePath)
            .put("model_transport", "okhttp").put("rish_backend", "unavailable").put("rish_protocol_version", 0)
            .put("rish_probe", JSONObject().put("path_kind", "unavailable").put("exit_code", -1))
            .put("mac_dsh_port_3180_reachable", JSONObject.NULL)
            .put("checks", JSONObject().put("credential_in_keychain", false).put("credential_in_secure_store", hasCredential)
                .put("model_response_received", model != null && AndroidProviderConfiguration.harness(model) == harness)
                .put("session_restored_after_restart", restored).put("rish_applet_executed", false)
                // The guest applet and the workspace tools are two different
                // things, and this build has one of them. Reporting only the
                // applet made the status say "local tools unavailable" while
                // list_dir, read_file and write_file were running.
                .put("workspace_tools_available", RishAgentCoreNative.available))
        transport.lastProof?.let { proof.put("model_response", JSONObject(it.toString())) }
        return JSONObject().put("proof", proof).put("rish", JSONObject().put("available", false))
    }
}
