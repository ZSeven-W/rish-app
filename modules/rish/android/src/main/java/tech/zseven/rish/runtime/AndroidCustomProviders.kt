package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/** Metadata and native credential transactions share the transport reservation lock. */
internal class AndroidCustomProviders(
    private val configurations: AndroidProviderConfiguration,
    private val transport: AndroidModelTransport,
    private val credentials: AndroidCredentialStore,
    private val sessions: AndroidSessionStore,
    private val agentWal: AndroidAgentWal,
) {
    constructor(runtime: AndroidRuntimeState) : this(
        runtime.configurations, runtime.transport, runtime.credentials, runtime.sessions, runtime.agentWal,
    )
    private val registry get() = configurations.custom
    fun list(): JSONObject = transport.withProviderLock { registry.read() }
    fun prepareDiscovery(request: JSONObject): AndroidProviderModelDiscovery.Prepared =
        AndroidProviderModelDiscovery(configurations, transport, credentials).prepare(request)

    fun discover(request: JSONObject): JSONObject = prepareDiscovery(request).execute()

    fun cancelDiscovery(request: JSONObject): JSONObject {
        if (request.opt("schema_version") != 1 || request.keys().asSequence().toSet() != setOf("schema_version", "id", "operation_id") ||
            !RuntimeJson.uuid(request.optString("id")) || !RuntimeJson.uuid(request.optString("operation_id"))) {
            throw RuntimeFailure("E_PROVIDER_MODEL_DISCOVERY_INVALID")
        }
        val id = request.getString("id"); val operation = request.getString("operation_id")
        return JSONObject().put("schema_version", 1).put("id", id).put("operation_id", operation)
            .put("status", transport.cancelDiscovery(id, operation))
    }

    fun save(request: JSONObject): JSONObject = transport.whenIdle {
        exact(request, setOf("schema_version", "expected_revision", "provider"))
        requireIdlePersisted()
        val provider = JSONObject(request.getJSONObject("provider").toString())
        provider.put("configuration", configurations.normalize(provider.getJSONObject("configuration")))
        registry.save(revision(request), provider)
    }
    fun remove(request: JSONObject): JSONObject = transport.whenIdle {
        exact(request, setOf("schema_version", "expected_revision", "id"))
        requireIdlePersisted()
        registry.remove(revision(request), request.getString("id")).also {
            // Retired metadata remains readable; the retired endpoint can never recover a key.
            credentials.clearCustomProvider(request.getString("id"))
        }
    }

    data class CredentialScope(val id: String, val configuration: JSONObject, val account: String?)
    fun credentialScope(request: JSONObject): CredentialScope = transport.whenIdle {
        exact(request, setOf("schema_version", "id", "expected_profile"), setOf("locale"))
        requireIdlePersisted()
        val scope = scope(request.getString("id"))
        if (!AndroidJson.equal(scope.configuration, request.getJSONObject("expected_profile"))) {
            throw RuntimeFailure("E_COMPLETION_CREDENTIAL_CHANGED")
        }
        scope
    }
    private fun scope(id: String): CredentialScope {
        val config = registry.provider(id).getJSONObject("configuration")
        return CredentialScope(id, config, account(config))
    }
    fun credentialStatus(request: JSONObject): JSONObject = transport.withProviderLock {
        exact(request, setOf("schema_version", "id"))
        status(scope(request.getString("id")))
    }
    fun put(scope: CredentialScope, secret: String): JSONObject = transport.whenIdle {
        requireIdlePersisted()
        verify(scope)
        val account = scope.account ?: throw RuntimeFailure("E_CUSTOM_PROVIDER_AUTH_NONE")
        credentials.put(account, secret)
        status(scope)
    }
    fun clear(request: JSONObject): JSONObject = transport.whenIdle {
        requireIdlePersisted()
        val scope = credentialScope(request)
        scope.account?.let { credentials.clear(it) }
        status(scope).put("status", "cleared")
    }
    private fun verify(scope: CredentialScope) {
        val current = registry.provider(scope.id).getJSONObject("configuration")
        if (!AndroidJson.equal(current, scope.configuration) || account(current) != scope.account) {
            throw RuntimeFailure("E_COMPLETION_CREDENTIAL_CHANGED")
        }
    }
    private fun status(scope: CredentialScope): JSONObject = JSONObject().put("schema_version", 1)
        .put("id", scope.id).put("status", when {
            scope.account == null -> "not_required"
            credentials.configured(scope.account) -> "configured"
            else -> "missing"
        })
    private fun account(config: JSONObject): String? = AndroidProviderConfiguration.policy(JSONObject()
        .put("op", "credential_account").put("slot", AndroidProviderConfiguration.slot(config.getString("harness_id")))
        .put("configuration", config)) as? String

    /** Prepared authority persists across process death, even with no in-memory HTTP call. */
    internal fun requireIdlePersisted() {
        val authorities = agentWal.snapshot().getJSONArray("authorities")
        for (index in 0 until authorities.length()) {
            if (authorities.getJSONObject(index).optString("state") == "prepared") throw RuntimeFailure("E_COMPLETION_BUSY")
        }
        val load = sessions.load()
        if (load.optString("status") == "present" && containsPendingAttempt(JSONObject(load.getString("session_json")))) {
            throw RuntimeFailure("E_COMPLETION_BUSY")
        }
    }
    companion object {
        internal fun containsPendingAttempt(value: Any?): Boolean = when (value) {
            is JSONArray -> (0 until value.length()).any { containsPendingAttempt(value.opt(it)) }
            is JSONObject -> value.optString("status") in setOf("prepared", "sending") ||
                value.keys().asSequence().any { containsPendingAttempt(value.opt(it)) }
            else -> false
        }
        private fun revision(request: JSONObject): Long {
            val number = request.opt("expected_revision")
            require((number is Int || number is Long) && (number as Number).toLong() >= 0)
            return number.toLong()
        }
        private fun exact(request: JSONObject, required: Set<String>, optional: Set<String> = emptySet()) {
            require(request.opt("schema_version") == 1 && request.keys().asSequence().toSet().let { it.containsAll(required) && (it - required - optional).isEmpty() })
        }
    }
}
