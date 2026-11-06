package tech.zseven.rish.runtime

import org.json.JSONObject

/**
 * The tool registry, read from the shared core rather than typed out again.
 *
 * The table is a pure table and the digest taken over it is what every stored
 * authority is bound to, so there is exactly one copy of it — in
 * `tool_registry.rs`. All this side contributes is the build fact the core
 * cannot know: whether the guest CGI tools exist here. They do not yet on
 * Android, and saying so is what makes this build's `toolset_sha256` honest.
 */
internal object AndroidAgentToolRegistry {
    /** Android ships no guest CGI tools, so they are not in its toolset. */
    private const val GUEST_CGI = false
    const val CURRENT_VERSION = 4

    class Refused(val code: Int) : RuntimeException("E_AGENT_STORE_$code")

    private fun reduce(op: String, fields: JSONObject, version: Int = CURRENT_VERSION, digest: String? = null): JSONObject {
        check(RishAgentCoreNative.available) { "the shared agent core is not staged in this build" }
        val envelope = JSONObject(fields.toString()).put("op", op).put("guest_cgi", GUEST_CGI)
            .put("registry_version", version)
        if (version >= 4) envelope.put("runtime_tools", false)
        if (digest != null) envelope.put("toolset_sha256", digest)
        val reply = RishAgentCoreNative.toolRegistryReduce(envelope.toString())
            ?: throw Refused(2)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) throw Refused(parsed.optInt("error", 2))
        return parsed
    }

    /** The digest a stored authority's registry must carry. */
    fun toolsetSha256(version: Int = CURRENT_VERSION): String =
        reduce("toolset_sha256", JSONObject(), version).getString("toolset_sha256")

    fun registryForRoot(root: JSONObject, version: Int = CURRENT_VERSION): JSONObject =
        reduce("registry", JSONObject().put("root", root), version).getJSONObject("registry")

    fun policyForRoot(root: JSONObject): JSONObject =
        reduce("policy", JSONObject().put("root", root)).getJSONObject("policy")

    /** The safe projection for one tool, or a durable denial. */
    fun descriptorForTool(name: String, root: JSONObject, version: Int = CURRENT_VERSION, digest: String? = null): JSONObject =
        reduce("descriptor", JSONObject().put("name", name).put("root", root), version, digest)
            .getJSONObject("descriptor")

    /** The full descriptor, for building a provider request. */
    fun nativeDescriptor(name: String, version: Int = CURRENT_VERSION, digest: String? = null): JSONObject =
        reduce("native_descriptor", JSONObject().put("name", name), version, digest).getJSONObject("descriptor")

    fun validateRegistry(registry: JSONObject, root: JSONObject): Boolean =
        reduce("registry_shape", JSONObject().put("registry", registry).put("root", root), registry.optInt("registry_version"))
            .optBoolean("valid")
}
