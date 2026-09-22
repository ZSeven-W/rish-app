package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * The project-context snapshot, from a selection to the bytes a model is
 * shown: `prepareCandidateV2`, `confirmSnapshotV2`, `inspectSnapshotV2`,
 * `discardProjectContextV2` and the verified envelope the agent round takes.
 *
 * Mirrors the v2 half of `ProjectContextService.mm`. The capture is
 * [AndroidProjectContextCapture]'s and the files are
 * [AndroidProjectContextStore]'s; what this adds is the order iOS does
 * things in and the checks between them: the root is proven before and after
 * each step, a snapshot is verified against the live project before it is
 * confirmed or sent, and a consent receipt is honoured only for the bytes it
 * was issued for.
 *
 * Every refusal carries the code JavaScript branches on and nothing more.
 */
internal class AndroidProjectContextSnapshots(
    private val projects: AndroidWorkspaceProjects,
    private val roots: AndroidAgentRootResolver,
    private val store: AndroidProjectContextStore,
    private val capture: AndroidProjectContextCapture = AndroidProjectContextCapture(),
    private val providerBinding: (String) -> JSONObject? = { null },
    private val clock: () -> String = { RuntimeJson.now() },
    private val identifiers: () -> String = { UUID.randomUUID().toString() },
) {
    class Refused(val code: String, reason: String) : Exception(reason)

    /** The proven root: what iOS holds in a project lease for the operation. */
    private class Lease(
        val root: JSONObject,
        val projectId: String,
        val descriptor: JSONObject,
        val gitDir: File,
        val workDir: File,
        val rootFingerprint: String,
        val bindingDigest: String,
    )

    // --- prepare ------------------------------------------------------------

    fun prepare(rawRequest: JSONObject?): JSONObject {
        val request = exact(rawRequest, PREPARE_KEYS, 2)
        val root = canonicalRoot(request)
        val conversation = request.opt("conversation_id") as? String
        val model = request.opt("model_id") as? String
        val policy = request.opt("policy")
        val paths = request.optJSONArray("selected_paths")
        if (conversation == null || !RuntimeJson.uuid(conversation) || model == null ||
            !AndroidSessionEnvironment.isSupported(model) || policy != POLICY || paths == null || paths.length() > MAX_ENTRIES
        ) {
            throw Refused(REQUEST_INVALID, "prepare request is invalid")
        }
        val normalized = ArrayList<String>()
        val seen = HashSet<String>()
        for (index in 0 until paths.length()) {
            val raw = paths.opt(index) as? String
            if (raw == null || raw.isEmpty() || raw.length > MAX_PATH_CHARACTERS) throw Refused(REQUEST_INVALID, "selected path is invalid")
            val decision = AndroidProjectContextPolicy.decisionFor(raw)
            if (decision.normalizedPath.isEmpty() || !seen.add(decision.normalizedPath)) {
                throw Refused(REQUEST_INVALID, "selected path is invalid")
            }
            normalized.add(decision.normalizedPath)
        }
        normalized.sort()
        val deadline = AndroidProjectContextCapture.Deadline()
        val lease = lease(root)
        val captured = captureFor(lease, normalized, includeBlocks = true, deadline)
        val referenceId = referenceId(root, lease.rootFingerprint, conversation)
        val snapshotId = identifiers()
        if (!RuntimeJson.uuid(snapshotId)) throw Refused(REQUEST_INVALID, "snapshot id is invalid")
        val capturedAt = clock()
        val binding = providerBinding(model)
        val metadata = JSONObject().put("schema_version", 2).put("snapshot_id", snapshotId).put("root", root)
            .put("project", lease.descriptor).put("project_id", lease.projectId).put("conversation_id", conversation)
            .put("model_id", model).put("policy", POLICY).put("policy_version", POLICY_VERSION)
            .put("branch", captured.branch ?: JSONObject.NULL).put("head_oid", captured.headOid ?: JSONObject.NULL)
            .put("clean", captured.clean).put("conflicted", captured.conflicted).put("captured_at", capturedAt)
            .put("source_fingerprint", captured.sourceFingerprint)
            .put("selected_paths", JSONArray(captured.expandedPaths)).put("tracked_status", captured.trackedStatus)
        binding?.let { metadata.put("provider_configuration", it) }
        val included = JSONArray()
        val omitted = JSONArray(captured.omitted.toString())
        val envelope = framedEnvelope(metadata, captured.blocks, included, omitted)
        deadline.check()
        val snapshotDigest = AndroidProjectContextCapture.sha256(envelope)
        val manifest = JSONObject().put("schema_version", 2).put("snapshot_id", snapshotId).put("root", root)
            .put("project", lease.descriptor).put("project_id", lease.projectId).put("conversation_id", conversation)
            .put("model_id", model).put("policy", POLICY)
            .put("branch", captured.branch ?: JSONObject.NULL).put("head_oid", captured.headOid ?: JSONObject.NULL)
            .put("clean", captured.clean).put("conflicted", captured.conflicted).put("captured_at", capturedAt)
            .put("policy_version", POLICY_VERSION).put("included", included).put("omitted", omitted)
            .put("context_bytes", envelope.size).put("estimated_tokens", (envelope.size + 3) / 4)
            .put("snapshot_sha256", snapshotDigest).put("source_fingerprint", captured.sourceFingerprint)
        binding?.let { manifest.put("provider_configuration", it) }
        val source = JSONObject().put("schema_version", 2).put("root", root)
            .put("workspace_id", root.getString("workspace_id")).put("workspace_binding_revision", root.get("binding_revision"))
            .put("project_id", lease.projectId).put("conversation_id", conversation).put("model_id", model).put("policy", POLICY)
            .put("selected_paths", JSONArray(normalized)).put("source_fingerprint", captured.sourceFingerprint)
            .put("root_fingerprint_sha256", lease.rootFingerprint).put("workspace_binding_sha256", lease.bindingDigest)
            .put("reference_id", referenceId)
        identityFields(lease, source)
        val activeKey = "active:$referenceId"
        validateLease(lease)
        try {
            store.beginPrepareTransaction(envelope, manifest, source, snapshotId, activeKey)
        } catch (failure: AndroidProjectContextStore.Failed) {
            throw Refused(storeCode(failure), "the snapshot could not be stored")
        }
        try {
            validateLease(lease)
            deadline.check()
        } catch (refused: Refused) {
            try {
                store.abortPrepareTransaction(snapshotId, activeKey)
            } catch (_: AndroidProjectContextStore.Failed) {
                throw Refused(STORAGE, "the snapshot could not be withdrawn")
            }
            throw refused
        }
        return manifest
    }

    // --- confirm --------------------------------------------------------------

    fun confirm(rawRequest: JSONObject?): JSONObject {
        val (root, snapshotId) = snapshotRequest(rawRequest)
        val snapshot = loadSnapshot(snapshotId)
        if (!rootsEqual(root, snapshot.manifest.optJSONObject("root"))) throw Refused(CHANGED, "the snapshot is another root's")
        val omitted = snapshot.manifest.optJSONArray("omitted") ?: JSONArray()
        for (index in 0 until omitted.length()) {
            if (omitted.optJSONObject(index)?.optString("reason") == BUDGET_EXCEEDED) throw Refused(BUDGET, "the snapshot is over budget")
        }
        val lease = verifySnapshot(snapshot, root, requireLiveSource = true)
        val referenceId = snapshot.sourceDescriptor.optString("reference_id")
        val activeKey = "active:$referenceId"
        val transactionKey = "txn:prepare:$referenceId"
        val authorization = try {
            store.beginAuthorization(snapshotId, null)
        } catch (_: AndroidProjectContextStore.Failed) {
            throw Refused(CONSENT, "the snapshot is not authorized")
        }
        try {
            validateLease(lease)
        } catch (refused: Refused) {
            store.cancelAuthorization(authorization); throw refused
        }
        val receipt = try {
            store.completeAuthorization(authorization, activeKey) { current ->
                if (store.snapshotIdForReferenceKey(transactionKey) == null) throw AndroidProjectContextStore.Failed(AndroidProjectContextStore.NOT_FOUND)
                if (!leaseStillValid(lease)) throw AndroidProjectContextStore.Failed(AndroidProjectContextStore.INTEGRITY)
                store.commitPrepareTransaction(snapshotId, activeKey, current.manifest.getString("snapshot_sha256"))
            }
        } catch (failure: AndroidProjectContextStore.Failed) {
            throw Refused(
                when (failure.code) {
                    AndroidProjectContextStore.INTEGRITY -> CHANGED
                    AndroidProjectContextStore.CAPACITY -> BUDGET
                    else -> CONSENT
                },
                "the snapshot could not be confirmed",
            )
        }
        validateLease(lease)
        return JSONObject(receipt.toString()).put("schema_version", 2).put("root", root)
            .put("workspace_id", root.getString("workspace_id")).put("workspace_binding_revision", root.get("binding_revision"))
    }

    // --- inspect ----------------------------------------------------------------

    fun inspect(rawRequest: JSONObject?): JSONObject {
        val (root, snapshotId) = snapshotRequest(rawRequest)
        val snapshot = loadSnapshot(snapshotId)
        if (!rootsEqual(root, snapshot.manifest.optJSONObject("root"))) throw Refused(CHANGED, "the snapshot is another root's")
        val live = try {
            verifySnapshot(snapshot, root, requireLiveSource = true)
            true
        } catch (refused: Refused) {
            if (refused.code == INTEGRITY) throw refused
            false
        }
        if (live) validateLease(lease(root))
        val inspection = JSONObject(snapshot.manifest.toString())
        val referenceId = snapshot.sourceDescriptor.optString("reference_id")
        val prepared = store.snapshotIdForReferenceKey("txn:prepare:$referenceId") != null &&
            store.snapshotIdForReferenceKey("active:$referenceId") == snapshotId
        var confirmed = false
        if (live && !prepared) {
            confirmed = store.consentsFor(snapshotId).any {
                it.optString("snapshot_id") == snapshotId &&
                    it.optString("snapshot_sha256") == snapshot.manifest.optString("snapshot_sha256")
            }
        }
        return JSONObject().put("schema_version", 2)
            .put("state", if (live) (if (confirmed) "confirmed" else "prepared") else "stale")
            .put("manifest", inspection)
    }

    // --- discard ----------------------------------------------------------------

    fun discard(rawRequest: JSONObject?): JSONObject {
        val (root, snapshotId) = snapshotRequest(rawRequest)
        val snapshot = loadSnapshot(snapshotId)
        val manifest = snapshot.manifest
        val source = snapshot.sourceDescriptor
        if (!rootsEqual(root, manifest.optJSONObject("root"))) throw Refused(CHANGED, "the snapshot is another root's")
        if (!rootsEqual(root, source.optJSONObject("root")) || manifest.opt("snapshot_id") != snapshotId ||
            manifest.opt("project_id") != root.get("project_id") || source.opt("project_id") != root.get("project_id") ||
            source.opt("workspace_id") != root.get("workspace_id") ||
            source.opt("workspace_binding_revision") != root.get("binding_revision")
        ) {
            throw Refused(INTEGRITY, "the snapshot's record disagrees with itself")
        }
        val lease = verifySnapshot(snapshot, root, requireLiveSource = true)
        val referenceId = source.optString("reference_id")
        val activeKey = "active:$referenceId"
        val transactionKey = "txn:prepare:$referenceId"
        val activeSnapshot = try { store.snapshotIdForReferenceKey(activeKey) } catch (f: AndroidProjectContextStore.Failed) { throw Refused(storeCode(f), "references unreadable") }
        val transactionValue = try { store.snapshotIdForReferenceKey(transactionKey) } catch (f: AndroidProjectContextStore.Failed) { throw Refused(storeCode(f), "references unreadable") }
        if (activeSnapshot != snapshotId ||
            (transactionValue != null && transactionValue != AndroidProjectContextStore.NO_PRIOR_SNAPSHOT_ID && !RuntimeJson.uuid(transactionValue))
        ) {
            throw Refused(CHANGED, "the snapshot is not the active one")
        }
        try {
            if (transactionValue != null) store.abortPrepareTransaction(snapshotId, activeKey) else store.clearReferenceKey(activeKey)
        } catch (failure: AndroidProjectContextStore.Failed) {
            throw Refused(
                if (failure.code == AndroidProjectContextStore.INTEGRITY || failure.code == AndroidProjectContextStore.NOT_FOUND) CHANGED
                else storeCode(failure),
                "the snapshot could not be discarded",
            )
        }
        validateLease(lease)
        val remaining = try { store.load(snapshotId); true } catch (failure: AndroidProjectContextStore.Failed) {
            if (failure.code != AndroidProjectContextStore.NOT_FOUND) throw Refused(storeCode(failure), "store unreadable")
            false
        }
        if (remaining) throw Refused(CHANGED, "the snapshot is still referenced")
        return JSONObject().put("schema_version", 2).put("status", "discarded").put("snapshot_id", snapshotId).put("root", root)
            .put("workspace_id", root.getString("workspace_id")).put("workspace_binding_revision", root.get("binding_revision"))
    }

    /**
     * `discardProjectContext(snapshotId)`: the project-id era spelling the
     * shared lifecycle controller still uses when it tears a confirmed
     * context down at the end of an unbind or a rebind. The request carries
     * no root, so the root is read from the snapshot's own manifest and then
     * re-proved by [discard] exactly like any other request -- a snapshot
     * naming a root this device cannot prove is refused there, not here.
     */
    fun discardById(snapshotId: String?): JSONObject {
        if (snapshotId == null || !RuntimeJson.uuid(snapshotId)) throw Refused(REQUEST_INVALID, "snapshot id is invalid")
        val root = loadSnapshot(snapshotId).manifest.optJSONObject("root")
            ?: throw Refused(INTEGRITY, "the snapshot names no root")
        discard(JSONObject().put("schema_version", 2).put("snapshot_id", snapshotId).put("root", root))
        // The v1 answer is exactly two keys; the V2 record stays native.
        return JSONObject().put("schema_version", 1).put("status", "discarded")
    }

    // --- the verified envelope -------------------------------------------------

    /**
     * The envelope bytes a model is shown, with the receipt that records the
     * check. [requireLiveSource] re-captures the project and requires the
     * same fingerprint; a continuation of an earlier turn takes the frozen
     * snapshot instead, because the conversation already saw those bytes.
     */
    fun verifiedEnvelope(rawRequest: JSONObject?, requireLiveSource: Boolean): Pair<ByteArray, JSONObject> {
        val request = exact(rawRequest, VERIFIED_KEYS, 2)
        val root = canonicalRoot(request)
        val snapshotId = request.opt("snapshot_id") as? String
        val consentId = request.opt("consent_receipt_id") as? String
        val conversation = request.opt("conversation_id") as? String
        val model = request.opt("model_id") as? String
        if (snapshotId == null || !RuntimeJson.uuid(snapshotId) || consentId == null || !RuntimeJson.uuid(consentId) ||
            conversation == null || !RuntimeJson.uuid(conversation) || model == null ||
            !AndroidSessionEnvironment.isSupported(model) || request.opt("policy") != POLICY
        ) {
            throw Refused(REQUEST_INVALID, "verified send request is invalid")
        }
        val authorization = try {
            store.beginAuthorization(snapshotId, null)
        } catch (failure: AndroidProjectContextStore.Failed) {
            throw Refused(storeCode(failure), "the snapshot is not authorized")
        }
        val snapshot = authorization.snapshot
        val manifest = snapshot.manifest
        val source = snapshot.sourceDescriptor
        val consent = try { store.loadConsent(consentId) } catch (_: AndroidProjectContextStore.Failed) { null }
        val referenceId = source.opt("reference_id") as? String
        val expectedReference = try {
            referenceId(root, source.optString("root_fingerprint_sha256"), conversation)
        } catch (_: Refused) { null }
        if (!rootsEqual(root, source.optJSONObject("root")) || referenceId == null || referenceId != expectedReference ||
            conversation != source.opt("conversation_id") || model != source.opt("model_id") || POLICY != source.opt("policy") ||
            consent == null || consent.opt("snapshot_id") != snapshotId ||
            consent.opt("snapshot_sha256") != manifest.opt("snapshot_sha256")
        ) {
            store.cancelAuthorization(authorization)
            throw Refused(CONSENT, "the consent does not cover this snapshot")
        }
        val transactionKey = "txn:prepare:$referenceId"
        val activeKey = "active:$referenceId"
        if (store.snapshotIdForReferenceKey(transactionKey) != null && store.snapshotIdForReferenceKey(activeKey) == snapshotId) {
            store.cancelAuthorization(authorization)
            throw Refused(CONSENT, "the snapshot is not confirmed")
        }
        val lease = try {
            verifySnapshot(snapshot, root, requireLiveSource)
        } catch (refused: Refused) {
            store.cancelAuthorization(authorization); throw refused
        }
        var receipt: JSONObject? = null
        val verified = try {
            store.completeAuthorization(authorization, activeKey) { current ->
                if (!leaseStillValid(lease)) throw AndroidProjectContextStore.Failed(AndroidProjectContextStore.INTEGRITY)
                val finalConsent = store.loadConsent(consentId)
                if (finalConsent.opt("snapshot_id") != snapshotId ||
                    finalConsent.opt("snapshot_sha256") != current.manifest.opt("snapshot_sha256")
                ) {
                    throw AndroidProjectContextStore.Failed(AndroidProjectContextStore.INTEGRITY)
                }
                receipt = JSONObject().put("schema_version", 2).put("snapshot_id", snapshotId).put("root", root)
                    .put("snapshot_sha256", current.manifest.getString("snapshot_sha256"))
                    .put("source_fingerprint", current.manifest.getString("source_fingerprint"))
                    .put("context_bytes", current.manifest.get("context_bytes")).put("verified_at", clock())
                current.envelope.copyOf()
            }
        } catch (failure: AndroidProjectContextStore.Failed) {
            throw Refused(
                when (failure.code) {
                    AndroidProjectContextStore.INTEGRITY -> CHANGED
                    AndroidProjectContextStore.CAPACITY -> BUDGET
                    AndroidProjectContextStore.NOT_FOUND -> CONSENT
                    else -> STORAGE
                },
                "the envelope could not be released",
            )
        }
        validateLease(lease)
        return Pair(verified, receipt ?: throw Refused(STORAGE, "no receipt"))
    }

    // --- verification --------------------------------------------------------

    /** `verifySnapshotV2`: the stored record against the root and, when asked, the live project. */
    private fun verifySnapshot(snapshot: AndroidProjectContextStore.Snapshot, root: JSONObject, requireLiveSource: Boolean): Lease {
        val manifest = snapshot.manifest
        val source = snapshot.sourceDescriptor
        val model = manifest.opt("model_id") as? String
        if (model == null || !bindingIsCurrent(manifest.opt("provider_configuration"), model)) {
            throw Refused(CHANGED, "the provider binding changed")
        }
        if (source.keys().asSequence().toSet() != SOURCE_KEYS || source.opt("schema_version") != 2) {
            throw Refused(INTEGRITY, "the source descriptor is malformed")
        }
        val paths = source.optJSONArray("selected_paths") ?: throw Refused(INTEGRITY, "no selected paths")
        val seen = HashSet<String>()
        val selected = ArrayList<String>()
        for (index in 0 until paths.length()) {
            val path = paths.opt(index) as? String
            val decision = path?.takeIf { it.isNotEmpty() && it.length <= MAX_PATH_CHARACTERS }?.let { AndroidProjectContextPolicy.decisionFor(it) }
            if (decision == null || decision.normalizedPath != path || !seen.add(path)) throw Refused(INTEGRITY, "selected paths are malformed")
            selected.add(path)
        }
        val fingerprint = source.opt("root_fingerprint_sha256") as? String
        val expectedReference = fingerprint?.let { try { referenceId(root, it, source.optString("conversation_id")) } catch (_: Refused) { null } }
        if (paths.length() > MAX_ENTRIES || !rootsEqual(root, source.optJSONObject("root")) ||
            !RuntimeJson.uuid(manifest.optString("snapshot_id")) || manifest.opt("schema_version") != 2 ||
            !rootsEqual(root, manifest.optJSONObject("root")) || manifest.opt("project_id") != root.get("project_id") ||
            manifest.opt("conversation_id") != source.opt("conversation_id") || manifest.opt("model_id") != source.opt("model_id") ||
            manifest.opt("policy") != source.opt("policy") || !RuntimeJson.uuid(source.optString("project_id")) ||
            source.opt("project_id") != root.get("project_id") || !RuntimeJson.uuid(source.optString("workspace_id")) ||
            source.opt("workspace_id") != root.get("workspace_id") ||
            source.opt("workspace_binding_revision") != root.get("binding_revision") ||
            !digest(fingerprint) || !digest(source.opt("workspace_binding_sha256") as? String) ||
            !RuntimeJson.uuid(source.optString("conversation_id")) || !AndroidSessionEnvironment.isSupported(source.optString("model_id")) ||
            source.opt("policy") != POLICY || !RuntimeJson.uuid(source.optString("reference_id")) ||
            source.opt("reference_id") != expectedReference || manifest.optJSONArray("included") == null ||
            manifest.optJSONArray("omitted") == null || !digest(source.opt("source_fingerprint") as? String) ||
            source.opt("source_fingerprint") != manifest.opt("source_fingerprint") ||
            !digest(manifest.opt("source_fingerprint") as? String) || !digest(manifest.opt("snapshot_sha256") as? String)
        ) {
            throw Refused(INTEGRITY, "the snapshot's record disagrees with the root")
        }
        val lease = lease(root)
        val identity = JSONObject()
        identityFields(lease, identity)
        if (source.opt("root_fingerprint_sha256") != lease.rootFingerprint ||
            source.opt("workspace_binding_sha256") != lease.bindingDigest ||
            IDENTITY_KEYS.any { source.opt(it) != identity.opt(it) }
        ) {
            throw Refused(INTEGRITY, "the project is not the one the snapshot was taken of")
        }
        if (!requireLiveSource) {
            validateLease(lease)
            return lease
        }
        val live = captureFor(lease, selected, includeBlocks = false, AndroidProjectContextCapture.Deadline())
        if (live.sourceFingerprint != manifest.opt("source_fingerprint")) throw Refused(CHANGED, "the project changed since the snapshot")
        validateLease(lease)
        return lease
    }

    // --- the lease -------------------------------------------------------------

    /** `v2LeaseForRoot`: the root proven -- binding, fingerprint, working tree. */
    private fun lease(root: JSONObject): Lease {
        val workspaceId = root.getString("workspace_id")
        val projectId = root.getString("project_id")
        val (descriptor, binding) = try {
            projects.verifiedDescriptorAndBinding(root, projectId)
        } catch (refused: AndroidWorkspaceProjects.Refused) {
            throw Refused(projectCode(refused), refused.message ?: "project unavailable")
        }
        val workDir = projects.workingTree(workspaceId) ?: throw Refused(NOT_FOUND, "the working tree is unavailable")
        val gitDir = projects.gitDirectory(workspaceId, projectId)
        val resolved = roots.resolveWorkspaceRef(
            JSONObject().put("schema_version", 1).put("workspace_id", workspaceId)
                .put("binding_revision", root.get("binding_revision")).put("project_id", JSONObject.NULL),
        ) ?: throw Refused(NOT_FOUND, "the workspace root is unavailable")
        val fingerprint = resolved.optString("root_fingerprint_sha256")
        val bindingDigest = RishAgentCoreNative.projectAccessReduce(
            JSONObject().put("op", "binding_digest").put("binding", binding).toString(),
        )?.let { JSONObject(it) }?.opt("digest") as? String ?: throw Refused(INTEGRITY, "the binding has no digest")
        return Lease(root, projectId, descriptor, gitDir, workDir, fingerprint, bindingDigest)
    }

    private fun leaseStillValid(lease: Lease): Boolean = try {
        val fresh = lease(lease.root)
        fresh.rootFingerprint == lease.rootFingerprint && fresh.bindingDigest == lease.bindingDigest
    } catch (_: Refused) {
        false
    }

    private fun validateLease(lease: Lease) {
        if (!leaseStillValid(lease)) throw Refused(CHANGED, "the root changed")
    }

    private fun captureFor(lease: Lease, paths: List<String>, includeBlocks: Boolean, deadline: AndroidProjectContextCapture.Deadline) =
        try {
            capture.captureAndVerify(lease.gitDir, lease.workDir, lease.bindingDigest, paths, includeBlocks, deadline)
        } catch (refused: AndroidProjectContextCapture.Refused) {
            throw Refused(refused.code, refused.message ?: "capture failed")
        }

    private fun identityFields(lease: Lease, into: JSONObject) {
        val root = capture.identity(lease.workDir)
        val git = capture.identity(lease.gitDir)
        val objects = capture.identity(File(lease.gitDir, "objects"))
        into.put("root_device", root.get("device").toString()).put("root_inode", root.get("inode").toString())
            .put("repository_device", root.get("device").toString()).put("repository_inode", root.get("inode").toString())
            .put("git_device", git.get("device").toString()).put("git_inode", git.get("inode").toString())
            .put("objects_device", objects.get("device").toString()).put("objects_inode", objects.get("inode").toString())
    }

    // --- the envelope ------------------------------------------------------------

    /** `framedEnvelopeMetadata`: the wire form, with the budgets applied per block. */
    private fun framedEnvelope(
        metadata: JSONObject, blocks: List<AndroidProjectContextCapture.Block>, included: JSONArray, omitted: JSONArray,
    ): ByteArray {
        val metadataBytes = RuntimeJson.canonical(metadata).toByteArray(Charsets.UTF_8)
        val envelope = java.io.ByteArrayOutputStream()
        envelope.write("RISH-PROJECT-CONTEXT/2\n".toByteArray(Charsets.UTF_8))
        envelope.write("META ${metadataBytes.size}\n".toByteArray(Charsets.UTF_8))
        envelope.write(metadataBytes)
        envelope.write('\n'.code)
        var diffBytes = 0L
        for (block in blocks.sortedWith(compareBy({ it.path }, { it.source }))) {
            val digest = AndroidProjectContextCapture.sha256(block.data)
            val header = RuntimeJson.canonical(
                JSONObject().put("path", block.path).put("source", block.source).put("sha256", digest).put("length", block.data.size),
            ).toByteArray(Charsets.UTF_8)
            val prefix = "BLOCK ${header.size} ${block.data.size}\n".toByteArray(Charsets.UTF_8)
            val frameBytes = prefix.size + header.size + 1 + block.data.size + 1
            val diff = block.source != "tracked_file"
            val diffBudget = diff && diffBytes + block.data.size > MAX_DIFF_BYTES
            val contextBudget = envelope.size() + frameBytes + 4 > MAX_CONTEXT_BYTES
            if (diffBudget || contextBudget) {
                addOmission(omitted, block.path, BUDGET_EXCEEDED)
                continue
            }
            envelope.write(prefix); envelope.write(header); envelope.write('\n'.code)
            envelope.write(block.data); envelope.write('\n'.code)
            if (diff) diffBytes += block.data.size
            included.put(JSONObject().put("path", block.path).put("source", block.source).put("bytes", block.data.size).put("sha256", digest))
        }
        envelope.write("END\n".toByteArray(Charsets.UTF_8))
        if (envelope.size() > MAX_CONTEXT_BYTES) throw Refused(BUDGET, "the envelope is over budget")
        return envelope.toByteArray()
    }

    private fun addOmission(omitted: JSONArray, path: String, reason: String) {
        for (index in 0 until omitted.length()) {
            val existing = omitted.getJSONObject(index)
            if (existing.optString("path") == path && existing.optString("reason") == reason) return
        }
        omitted.put(JSONObject().put("path", path).put("reason", reason))
    }

    // --- small rules ---------------------------------------------------------------

    private fun exact(rawRequest: JSONObject?, keys: Set<String>, schema: Int): JSONObject {
        val request = rawRequest ?: throw Refused(REQUEST_INVALID, "request is missing")
        if (request.keys().asSequence().toSet() != keys || request.opt("schema_version") != schema) {
            throw Refused(REQUEST_INVALID, "request is invalid")
        }
        return request
    }

    private fun snapshotRequest(rawRequest: JSONObject?): Pair<JSONObject, String> {
        val request = exact(rawRequest, SNAPSHOT_KEYS, 2)
        val root = canonicalRoot(request)
        val snapshotId = request.opt("snapshot_id") as? String
        if (snapshotId == null || !RuntimeJson.uuid(snapshotId)) throw Refused(REQUEST_INVALID, "snapshot id is invalid")
        return Pair(root, snapshotId)
    }

    private fun canonicalRoot(request: JSONObject): JSONObject = try {
        projects.canonicalRoot(request.optJSONObject("root"), projectRequired = true)
    } catch (refused: AndroidWorkspaceProjects.Refused) {
        throw Refused(REQUEST_INVALID, refused.message ?: "root is invalid")
    }

    private fun loadSnapshot(snapshotId: String): AndroidProjectContextStore.Snapshot = try {
        store.load(snapshotId)
    } catch (failure: AndroidProjectContextStore.Failed) {
        throw Refused(storeCode(failure), "the snapshot could not be loaded")
    }

    private fun referenceId(root: JSONObject, fingerprint: String, conversation: String): String =
        RishAgentCoreNative.projectContextServiceReduce(
            JSONObject().put("op", "reference_id").put("root", root).put("root_fingerprint_sha256", fingerprint)
                .put("conversation_id", conversation).toString(),
        )?.let { JSONObject(it) }?.opt("reference_id") as? String ?: throw Refused(INTEGRITY, "no reference id")

    private fun rootsEqual(left: JSONObject?, right: JSONObject?): Boolean =
        RishAgentCoreNative.projectContextServiceReduce(
            JSONObject().put("op", "roots_equal").put("left", left ?: JSONObject.NULL).put("right", right ?: JSONObject.NULL).toString(),
        )?.let { JSONObject(it) }?.optBoolean("equal") == true

    private fun digest(value: String?): Boolean = value != null && value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }

    /** `DSHProviderBindingIsCurrent`: what the manifest recorded is what the model binds to now. */
    private fun bindingIsCurrent(recorded: Any?, model: String): Boolean {
        val current = providerBinding(model)
        val stored = recorded?.takeIf { it != JSONObject.NULL } as? JSONObject
        if (current == null && stored == null) return true
        if (current == null || stored == null) return false
        return RuntimeJson.canonical(current) == RuntimeJson.canonical(stored)
    }

    /** `DSHServiceSnapshotStoreError`. */
    private fun storeCode(failure: AndroidProjectContextStore.Failed): String = when (failure.code) {
        AndroidProjectContextStore.NOT_FOUND -> SNAPSHOT_MISSING
        AndroidProjectContextStore.INTEGRITY -> INTEGRITY
        AndroidProjectContextStore.CAPACITY -> BUDGET
        else -> STORAGE
    }

    private fun projectCode(refused: AndroidWorkspaceProjects.Refused): String = when (refused.number) {
        AndroidWorkspaceProjects.REQUEST_INVALID -> REQUEST_INVALID
        AndroidWorkspaceProjects.UNAVAILABLE -> NOT_FOUND
        else -> CHANGED
    }

    companion object {
        const val REQUEST_INVALID = "E_CONTEXT_REQUEST_INVALID"
        const val NOT_FOUND = "E_PROJECT_NOT_FOUND"
        const val CHANGED = "E_CONTEXT_CHANGED"
        const val BUDGET = "E_CONTEXT_BUDGET"
        const val STORAGE = "E_CONTEXT_STORAGE"
        const val CONSENT = "E_CONTEXT_CONSENT_INVALID"
        const val INTEGRITY = "E_CONTEXT_INTEGRITY"
        const val SNAPSHOT_MISSING = "E_CONTEXT_SNAPSHOT_MISSING"
        const val POLICY = "chat-read-v1"
        const val POLICY_VERSION = "chat-read-v1.0.0"
        private const val MAX_ENTRIES = 5000
        private const val MAX_PATH_CHARACTERS = 4096
        private const val MAX_DIFF_BYTES = 128L * 1024
        private const val MAX_CONTEXT_BYTES = 256L * 1024
        private const val BUDGET_EXCEEDED = "budget_exceeded"
        private val PREPARE_KEYS = setOf("schema_version", "root", "conversation_id", "model_id", "policy", "selected_paths")
        private val SNAPSHOT_KEYS = setOf("schema_version", "snapshot_id", "root")
        private val VERIFIED_KEYS = setOf("schema_version", "snapshot_id", "consent_receipt_id", "root", "conversation_id", "model_id", "policy")
        private val IDENTITY_KEYS = listOf(
            "root_device", "root_inode", "repository_device", "repository_inode", "git_device", "git_inode", "objects_device", "objects_inode",
        )
        private val SOURCE_KEYS = setOf(
            "schema_version", "root", "workspace_id", "workspace_binding_revision", "project_id", "conversation_id", "model_id",
            "policy", "selected_paths", "source_fingerprint", "root_fingerprint_sha256", "workspace_binding_sha256", "reference_id",
        ) + IDENTITY_KEYS
    }
}
