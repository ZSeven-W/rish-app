package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * `complete_agent_round_v2` on Android.
 *
 * Mirrors modules/rish/ios/Sources/AgentProviderRoundService.mm, whose pure
 * half is already `provider_round` in the shared core. That module names the
 * split: *the host keeps the transport, credentials, the tool registry's
 * native descriptors, the root projection validator, and the two provider
 * digests* -- the digests because they are taken with `NSJSONSerialization`
 * and sorted keys, a different byte protocol from the crate's canonical JSON,
 * so they are passed in as host facts rather than recomputed.
 *
 * The round is the step that asks the model what to do next. What it reads,
 * what the model is shown, how a reply becomes tool calls, and what the
 * journal records are all the core's; calling the provider and writing the
 * row are this file's.
 *
 * **Streaming is not here.** iOS shows a round's text as it arrives; this
 * waits for the whole reply. A round still completes and its calls are still
 * journalled; the only thing missing is watching it happen.
 *
 * Tools do travel, on the chat-completions protocol. What the model is shown
 * is the registry's description of each tool the root carries, and what comes
 * back is read by the core: turning untrusted model output into calls is
 * `completion_response`'s rule, and the transport carries the provider's reply
 * for it rather than reading it here.
 */
internal class AndroidAgentProviderRoundService(
    private val sessions: AndroidSessionStore,
    private val prepared: AndroidPreparedAttemptStore,
    private val rounds: AndroidAgentRoundJournal,
    private val roots: AndroidAgentRootResolver,
    private val tools: AndroidAgentToolRegistry,
    private val transport: AndroidModelTransport,
    private val wal: AndroidAgentWal,
    private val operations: AndroidAgentOperations,
    private val liveTasks: AndroidLiveTasks,
    private val transcripts: AndroidAgentTranscriptStore,
    private val snapshots: AndroidProjectContextSnapshots? = null,
) {
    class Refused(val code: String) : Exception(code)

    private fun decide(envelope: JSONObject): JSONObject {
        if (!RishAgentCoreNative.available) throw Refused(NATIVE)
        val reply = RishAgentCoreNative.providerRoundReduce(envelope.toString())
            ?: throw Refused(NATIVE)
        val parsed = JSONObject(reply)
        if (!parsed.optBoolean("ok")) {
            // A round walks through eight of the core's rules. Which one said
            // no is the whole diagnosis, and the code that reaches JavaScript
            // cannot carry it.
            android.util.Log.w(
                "RishAgent",
                "round reduce refused: op=${envelope.optString("op")} error=${parsed.optInt("error", 2)}",
            )
            throw Refused(codeFor(parsed.optInt("error", 2)))
        }
        return parsed
    }

    private fun codeFor(error: Int): String = when (error) {
        1 -> "E_AGENT_BAD_ARGUMENTS"
        3 -> "E_AGENT_CONFLICT"
        4 -> "E_AGENT_PERSISTENCE"
        else -> NATIVE
    }

    /**
     * The environment the round rules read. It is the model catalogue, not a
     * clock: the core asks it which harness serves the model a request names,
     * and it can only ask a host that shipped the catalogue. Collected from
     * the request's own strings, exactly as `DSHProviderEnvironment` collects
     * it from the request on iOS.
     */
    private fun env(request: JSONObject): JSONObject =
        AndroidSessionEnvironment.facts(request)

    fun completeRound(request: JSONObject, retryFailedRound: Boolean = false): JSONObject {
        val root = request.optJSONObject("root")
        val rootOk = roots.resolveAgentProjection(root) != null
        if (!rootOk) android.util.Log.w("RishAgent", "round root did not resolve: $root")

        // Shape and locator first. A request the rules refuse never reaches
        // the journal, let alone the provider.
        val located = decide(
            JSONObject().put("op", "round_request").put("request", request)
                .put("root_ok", rootOk).put("env", env(request)),
        )
        val locator = located.optJSONObject("locator") ?: throw Refused(BAD_ARGUMENTS)

        val taskId = request.optString("task_id")
        val attemptId = request.optString("attempt_id")
        val authority = prepared.authorityFor(taskId, attemptId)
            ?: throw Refused(CONFLICT)
        // The session the request was built against, not whichever one is
        // stored now. A round decided over a session that has since moved on
        // is a conflict the controller recovers from by re-reading.
        val session = AndroidCommittedSession.load(sessions, request) ?: throw Refused(CONFLICT)
        val conversation = AndroidCommittedSession.conversation(session, request)
            ?: throw Refused(CONFLICT)

        // The first time a round is asked for, its row does not exist yet:
        // this operation is what creates it. Only a retry finds one, and a
        // retry claims what is there rather than inserting over it.
        // The owner this process is about to claim has to be alive before the
        // journal will accept it: a row owned by a task nobody is running is
        // exactly what recovery exists to reclaim, and the core refuses to
        // create one. iOS registers the same id for the same reason.
        val nativeTaskId = request.optString("operation_id")
        liveTasks.register(nativeTaskId)
        return try {
            launched(request, locator, root, authority, conversation, nativeTaskId, retryFailedRound)
        } finally {
            // The owner is alive only while this round is being run. Leaving
            // it registered told every later reader that a round nobody was
            // running was still in flight -- so a failed round could never be
            // reclaimed and recovery could never take one over, in this
            // process. iOS releases the same id on every exit for the same
            // reason.
            liveTasks.unregister(nativeTaskId)
        }
    }

    private fun launched(
        request: JSONObject,
        locator: JSONObject,
        root: JSONObject?,
        authority: JSONObject,
        conversation: JSONObject,
        nativeTaskId: String,
        retryFailedRound: Boolean,
    ): JSONObject {
        val owner = ownerFor(request)
        val existing = rowFor(wal.snapshot(), locator)
        if (retryFailedRound) {
            // A retry re-launches a row that failed retryably, and only that:
            // the row must still be the one the caller saw, it must not have
            // been launched eight times already, and this must be the very
            // next launch. Anything else is a conflict, not a second attempt
            // at someone else's round.
            val previous = existing?.optInt("launch_attempt", -1) ?: -1
            val shaped = existing != null &&
                existing.optString("state") == "failed_retryable" &&
                AndroidJson.equal(
                    existing.opt("row_revision"), request.opt("expected_round_revision"),
                ) &&
                previous in 0..7 &&
                request.optInt("launch_attempt", -1) == previous + 1
            if (!shaped) {
                android.util.Log.w(
                    "RishAgent",
                    "round retry refused: state=${existing?.optString("state")} launch=$previous",
                )
                throw Refused(CONFLICT)
            }
        }
        if (existing == null) {
            rounds.create(insertCas(request, locator), startedRound(request, locator, owner))
                ?: throw Refused(PERSISTENCE)
        } else {
            // Claimed before the provider is called, so a crash during the
            // call leaves a round that may have happened rather than one that
            // plainly did not.
            val cas = decide(
                JSONObject().put("op", "round_cas").put("row", existing),
            ).optJSONObject("cas") ?: throw Refused(CONFLICT)
            rounds.claim(cas, owner) ?: throw Refused(CONFLICT)
        }
        rowFor(wal.snapshot(), locator) ?: throw Refused(PERSISTENCE)

        // What the model is shown of the conversation so far. The messages are
        // the transcript's own -- the store reads them out of the WAL under
        // the transcript reference the request names -- and the core turns
        // them into the provider's shape. The transcripts *table* is not that
        // list, and handing it over is how this refused as corrupt.
        val native = transcripts.nativeMessages(
            JSONObject().put("schema_version", 1)
                .put("attempt_id", request.opt("attempt_id"))
                .put("root", request.opt("root"))
                .put("transcript", request.opt("transcript")),
        ) ?: throw Refused(TRANSCRIPT)
        val body = decide(
            JSONObject().put("op", "transcript_body").put("request", JSONObject())
                .put("messages", native),
        ).optJSONArray("messages") ?: JSONArray()

        // What the model is shown. The registry decides which tools a root
        // carries and what each one is; the core turns a descriptor into the
        // description a model sees, so neither this file nor the transport
        // invents anything a tool can be asked to do.
        val registry = tools.registryForRoot(root ?: JSONObject())
        val declared = JSONArray()
        val names = registry.optJSONArray("tools") ?: JSONArray()
        for (index in 0 until names.length()) {
            val name = names.optJSONObject(index)?.optString("name")
                ?: names.optString(index).takeIf { it.isNotEmpty() }
                ?: continue
            // The registry supplies a tool's native identity and its
            // parameters; the core supplies the sentence the model is shown,
            // as a *string*. Reading that string as an object is how a root
            // with three tools declared none of them, and a model with no
            // tools answers a request to write a file by explaining how the
            // person could write it themselves.
            val native = try {
                tools.nativeDescriptor(name)
            } catch (_: Exception) {
                continue
            }
            val described = decide(
                JSONObject().put("op", "tool_description").put("name", native.optString("name")),
            ).optString("description", "")
            declared.put(
                JSONObject().put("type", "function")
                    .put("name", native.opt("name"))
                    .put(
                        "description",
                        described.ifEmpty { native.optString("safe_summary_key") },
                    )
                    .put("parameters", native.opt("parameters") ?: JSONObject()),
            )
        }

        // The verified project context, when the attempt carries one. iOS
        // asks its service for the envelope under the attempt's consent,
        // checks it against what the attempt recorded, and the core's
        // context_bundle rule releases the system messages and the receipt.
        // The bridge hands every number over as a Double, so `== 3` against
        // an Int literal is false for a request JavaScript sent and true for
        // one a test built; read it as a number.
        val (contextReceipt, contextMessages) = if (request.optInt("transport_schema_version") == 3) {
            contextBundle(request, authority, conversation)
        } else {
            Pair(null, null)
        }

        // Everything above and below this point runs while the round is still
        // `not_dispatched`, and the marker is only set once the request has
        // been built and the transport has accepted it. iOS does the same: it
        // assembles messages, tools and the provider body, and marks dispatched
        // only after all of that succeeded.
        //
        // **Why the order matters.** A refusal raised while the request is
        // being built -- an attachment this transport cannot carry, a protocol
        // that cannot express a round transcript, a body over the limit -- is
        // proof that nothing was sent. Marking first made the core reconcile
        // such a round as `ambiguous`, and the person was shown
        // `E_AGENT_EXECUTION_AMBIGUOUS` over a turn that provably never left
        // the device, with only retries that could not succeed. The marker
        // still commits *before* the network call, because a crash during the
        // call must leave a round that may have happened.
        var providerError: String? = null
        val prepared = try {
            val envelope = JSONObject()
                .put("schema_version", 2)
                .put("harness_id", request.optString("harness_id"))
                .put("model", request.optString("model"))
                .put("round_id", request.optString("round_id"))
                // The transport calls it `turn_id`; an agent request calls the
                // same identity `task_id`, and asking for a key the request
                // does not have yields "" -- which is not a UUID.
                .put("turn_id", request.optString("task_id"))
                .put("attempt_id", request.optString("attempt_id"))
                .put("round_index", request.optInt("round_index"))
                .put("thinking_mode", request.optString("thinking_mode", "off"))
                .put("visible_history", visibleHistory(conversation, authority))
                .put("round_transcript", body)
                .put("project_context", contextMessages ?: JSONObject.NULL)
                .put("tools", declared)
            transport.prepare(envelope.toString()).also { transport.validate(it) }
        } catch (failure: Exception) {
            // What the transport said is what decides the round's failure
            // code, so its own vocabulary is kept rather than discarded.
            providerError = (failure as? RuntimeFailure)?.code
            android.util.Log.w("RishAgent", "round preparation refused: $providerError", failure)
            null
        }

        // The request exists and the transport has accepted it, so from here
        // on a silence really could mean the provider saw it.
        if (prepared != null) {
            try {
                val claimed = rowFor(wal.snapshot(), locator) ?: throw Refused(PERSISTENCE)
                val dispatchCas = decide(
                    JSONObject().put("op", "round_cas").put("row", claimed),
                ).optJSONObject("cas") ?: throw Refused(CONFLICT)
                rounds.markDispatched(dispatchCas) ?: throw Refused(CONFLICT)
            } catch (failure: Throwable) {
                // The request holds a transport slot that only a run gives
                // back. Leaving it there would refuse the next round as busy
                // over a request nobody ever sent.
                transport.discard(prepared)
                throw failure
            }
        }

        val reply = if (prepared == null) null else try {
            // Correlation first: a preview event that cannot be tied to the
            // round it belongs to is not display material, it is noise.
            val preview = previewSink(request, locator)
            try {
                transport.execute(prepared, preview).also {
                    preview?.invoke(JSONObject().put("kind", "end").put("status", "validated"))
                }
            } catch (failure: Exception) {
                preview?.invoke(
                    JSONObject().put("kind", "end").put("status", "failed")
                        .put(
                            "failure_code",
                            (failure as? RuntimeFailure)?.code ?: "E_COMPLETION_NATIVE",
                        ),
                )
                throw failure
            }
        } catch (failure: Exception) {
            providerError = (failure as? RuntimeFailure)?.code
            android.util.Log.w("RishAgent", "round transport failed: $providerError", failure)
            null
        }

        val status = if (reply == null) "failed_retryable" else "completed"
        // A completed round carries no failure code. A failed one carries the
        // code the *core* derives from what the provider said -- the mapping
        // from a transport error to an agent failure is a rule, not a lookup
        // this file gets to invent.
        val failure = if (status == "completed") "" else decide(
            JSONObject().put("op", "failure_code")
                .put("provider_error_code", providerError ?: JSONObject.NULL)
                .put("digest_mismatch", false),
        ).optString("code", "")

        val dispatched = rowFor(wal.snapshot(), locator) ?: throw Refused(CONFLICT)
        val completeCas = decide(
            JSONObject().put("op", "round_cas").put("row", dispatched),
        ).optJSONObject("cas") ?: throw Refused(CONFLICT)
        if (reply != null) {
            return settle(request, locator, completeCas, reply, root ?: JSONObject(), authority, contextReceipt)
        }

        // The provider call failed, so nobody is running this round any more.
        // Release the owner first -- the core refuses to reconcile a row whose
        // owner is still alive -- then reconcile the row out of `in_flight`.
        // Leaving it there is residue no discard will ever clear: an
        // `in_flight` round pins its attempt, so the turn can never be
        // finalized and its cleanup never drains. iOS releases and reconciles
        // at exactly this point.
        liveTasks.unregister(nativeTaskId)
        // The cause travels into the row. A refusal raised while the request
        // was being built is the only account of why this turn ended, and
        // the core keeps it only for a round it can see was never
        // dispatched, so an ambiguity cannot be talked out of.
        val reconciled = rounds.reconcile(locator, completeCas, failure.ifEmpty { null })
            ?.optJSONObject("row")
        val settled = reconciled ?: rowFor(wal.snapshot(), locator) ?: throw Refused(CONFLICT)
        // The reconcile decides what the round became: a request that never
        // reached the provider is `failed_retryable`, one that did is
        // `ambiguous`. Reporting the row's own state keeps the controller's
        // journal and this WAL saying the same thing.
        val settledState = settled.optString("state")
        val reportedStatus =
            if (settledState.isEmpty() || settledState == "in_flight" ||
                settledState == "cancel_requested"
            ) status else settledState
        val reportedFailure = settled.optString("failure_code").ifEmpty { failure }
        return decide(
            JSONObject().put("op", "round_result").put("request", request)
                .put("row", settled).put("status", reportedStatus)
                .put("failure_code", reportedFailure),
        ).optJSONObject("result") ?: throw Refused(NATIVE)
    }

    /**
     * Settles a round the provider answered.
     *
     * Every shape here is the core's: the per-call identity and its arguments
     * digest, the assistant message the transcript records, and the receipt.
     * What this file contributes is the *order* -- a call the registry cannot
     * describe, or arguments that do not parse, fails the round rather than
     * being written as something the model did not say.
     */
    private fun settle(
        request: JSONObject,
        locator: JSONObject,
        cas: JSONObject,
        reply: JSONObject,
        root: JSONObject,
        authority: JSONObject,
        contextReceipt: JSONObject?,
    ): JSONObject {
        val stated = reply.optJSONArray("tool_calls") ?: JSONArray()
        val calls = JSONArray()
        val presentations = JSONArray()
        for (index in 0 until stated.length()) {
            val call = stated.optJSONObject(index) ?: continue
            val name = call.optString("name")
            val arguments = call.optString("arguments")
            // The strict parser takes the arguments text itself and answers
            // their canonical form, not an envelope with an `ok` flag.
            val parsedArguments = RishAgentCoreNative.parseArguments(arguments)
                ?.let { JSONObject(it) } ?: throw Refused(TRANSCRIPT)
            val digest = RishAgentCoreNative.hash(
                "tool-arguments",
                JSONObject().put("name", name).put("arguments", parsedArguments),
            )
            val descriptor = try {
                tools.descriptorForTool(name, root)
            } catch (failure: Exception) {
                android.util.Log.w("RishAgent", "settle: no descriptor for $name", failure)
                throw Refused(TRANSCRIPT)
            }
            val access = descriptor.optString("access")
            calls.put(
                JSONObject().put("schema_version", 3).put("call_index", index)
                    .put("call_id", call.opt("id")).put("name", name)
                    .put("arguments_sha256", digest)
                    .put("safe_summary_key", descriptor.opt("safe_summary_key"))
                    .put("access", access)
                    .put(
                        "approval_state",
                        if (access == "durable_deny") "durable_denied" else "deferred",
                    ),
            )
            presentations.put(
                JSONObject().put("call_id", call.opt("id")).put("name", name)
                    .put("arguments", arguments),
            )
        }

        val message = decide(
            JSONObject().put("op", "assistant_message").put(
                "message",
                JSONObject().put("schema_version", 1).put("role", "assistant")
                    .put("round_index", request.opt("round_index"))
                    .put("content", reply.optString("text"))
                    .put("reasoning_content", reply.optString("reasoning"))
                    .put("tool_calls", presentations),
            ),
        ).optJSONObject("message") ?: throw Refused(TRANSCRIPT)

        // The journal's receipt is exact: the keys below and `harness_id`,
        // nothing else. `public_receipt` builds the *other* one -- what the
        // controller is handed -- and its extra fields are refused here.
        // Mirrors the literal in AgentProviderRoundService.mm.
        val receipt = JSONObject()
            .put("schema_version", 1)
            .put("transport_schema_version", request.opt("transport_schema_version"))
            .put("turn_id", request.opt("task_id"))
            .put("attempt_id", request.opt("attempt_id"))
            .put("round_id", request.opt("round_id"))
            .put("round_index", request.opt("round_index"))
            .put("harness_id", reply.opt("harness_id") ?: request.opt("harness_id"))
            .put("provider_request_id", reply.opt("provider_request_id"))
            .put("provider_response_id", reply.opt("provider_response_id"))
            .put("requested_model", request.opt("model"))
            .put("model", request.opt("model"))
            .put("thinking_mode", request.opt("thinking_mode"))
            .put("finish_reason", reply.optString("finish_reason"))
            .put("latency_ms", reply.opt("latency_ms") ?: 0)
            .put(
                "visible_history_sha256",
                reply.opt("visible_history_sha256") ?: request.opt("visible_history_sha256"),
            )
            .put("model_input_sha256", reply.opt("model_input_sha256"))
            .put("request_body_sha256", reply.opt("request_body_sha256"))
            .put("project_context_receipt", contextReceipt ?: JSONObject.NULL)

        val terminal = when (reply.optString("finish_reason")) {
            "stop" -> "final"
            "tool_calls" -> "tool_batch"
            else -> "blocked"
        }
        val completed = rounds.complete(
            locator, cas, JSONArray().put(message), receipt, terminal, calls, root,
        ) ?: throw Refused(PERSISTENCE)

        // What the controller is handed. This is the *public* receipt -- the
        // one `public_receipt` builds -- and an outcome whose kind is the
        // round's terminal kind. The journal's receipt above is a different
        // record with a different exact shape; they are not interchangeable.
        val publicReceipt = decide(
            JSONObject().put("op", "public_receipt").put("provider", reply)
                .put("request", request)
                .put("provider_request_id", reply.opt("provider_request_id"))
                // The public receipt carries the context receipt too: a
                // transport-3 receipt without one is refused by the reader.
                .put("context_receipt", contextReceipt ?: JSONObject.NULL),
        ).optJSONObject("receipt") ?: throw Refused(NATIVE)
        val after = completed.opt("transcript") ?: JSONObject.NULL
        val revision = completed.optJSONObject("row")?.opt("row_revision")

        var denied = 0
        for (index in 0 until calls.length()) {
            if (calls.optJSONObject(index)?.optString("access") == "durable_deny") denied += 1
        }
        val outcome = JSONObject().put("schema_version", 3)
            .put("finish_reason", reply.optString("finish_reason"))
            .put("completion_receipt", publicReceipt).put("transcript", after)
        when (terminal) {
            "final" -> outcome.put("kind", "final")
                .put("text", reply.optString("text"))
                .put("reasoning", reply.optString("reasoning"))
            "tool_batch" -> outcome.put("kind", "tool_batch").put("calls", calls)
                .put(
                    "batch_class",
                    when (denied) {
                        0 -> "executable"
                        calls.length() -> "denied_only"
                        else -> "mixed"
                    },
                )
                .put("executable_call_count", calls.length() - denied)
                .put("denied_call_count", denied)
                .put("reasoning", reply.optString("reasoning"))
            else -> outcome.put("kind", "blocked").put(
                "failure_code",
                if (reply.optString("finish_reason") == "length") {
                    "E_COMPLETION_LENGTH"
                } else {
                    "E_COMPLETION_CONTENT_FILTER"
                },
            )
        }
        return JSONObject().put("schema_version", 2).put("status", "completed")
            .put("operation_id", request.opt("operation_id"))
            .put("task_id", request.opt("task_id"))
            .put("attempt_id", request.opt("attempt_id"))
            .put("round_id", request.opt("round_id"))
            .put("round_index", request.opt("round_index"))
            .put("launch_attempt", request.opt("launch_attempt"))
            .put("result_round_revision", revision)
            .put("transcript", after)
            .put("outcome", outcome)
    }

    /**
     * What the person can see of this conversation, as the model is shown it.
     *
     * The authority names the exact messages -- `visible_message_ids` -- and
     * the committed session holds their text. Neither is the transcript: that
     * records what *this round* already did, which is `round_transcript`, and
     * sending one in place of the other leaves the model with no question to
     * answer.
     *
     * Mirrors `DSHRuntimeVisibleHistory`. A named message the session does not
     * carry is a conflict, not a message to skip.
     */
    /**
     * `DSHRuntimeContextBundle`, then `DSHProviderContextBundle`: the attempt's
     * project context, verified against the live project on a first round
     * and against the frozen snapshot on a continuation, and released by
     * the core as the receipt and the system messages to prepend.
     */
    private fun contextBundle(request: JSONObject, authority: JSONObject, conversation: JSONObject): Pair<JSONObject, JSONArray> {
        val service = snapshots ?: throw Refused(CONFLICT)
        val attempts = conversation.optJSONArray("attempts") ?: JSONArray()
        var context: JSONObject? = null
        for (index in 0 until attempts.length()) {
            val attempt = attempts.optJSONObject(index) ?: continue
            if (attempt.optString("attempt_id") == request.optString("attempt_id")) {
                context = attempt.optJSONObject("project_context")
                break
            }
        }
        val recorded = context ?: throw Refused(CONFLICT)
        val authorityRoot = authority.optJSONObject("root") ?: throw Refused(CONFLICT)
        val rootRef = JSONObject().put("schema_version", 1)
            .put("workspace_id", authorityRoot.opt("workspace_id"))
            .put("binding_revision", authorityRoot.opt("workspace_binding_revision"))
            .put("project_id", authorityRoot.opt("project_id"))
        val verifiedRequest = JSONObject().put("schema_version", 2)
            .put("snapshot_id", recorded.opt("snapshot_id"))
            .put("consent_receipt_id", recorded.opt("consent_receipt_id"))
            .put("root", rootRef)
            .put("conversation_id", recorded.opt("runtime_context_id"))
            .put("model_id", authority.opt("model"))
            .put("policy", recorded.opt("policy"))
        val continuation = (authority.optJSONObject("transcript")?.optLong("generation") ?: 0L) > 0L
        val (envelope, receipt) = try {
            service.verifiedEnvelope(verifiedRequest, requireLiveSource = !continuation)
        } catch (refused: AndroidProjectContextSnapshots.Refused) {
            android.util.Log.w("RishAgent", "project context refused: ${refused.code}")
            throw Refused(CONFLICT)
        }
        val content = String(envelope, Charsets.UTF_8)
        if (recorded.optLong("context_bytes", -1L) != envelope.size.toLong() ||
            receipt.optString("snapshot_sha256") != recorded.optString("snapshot_sha256") ||
            receipt.optString("source_fingerprint") != recorded.optString("source_fingerprint")
        ) {
            throw Refused(CONFLICT)
        }
        val bundle = JSONObject()
            .put("project_context_sha256", authority.opt("project_context_sha256"))
            .put(
                "receipt",
                JSONObject().put("schema_version", 1).put("snapshot_id", recorded.opt("snapshot_id"))
                    .put("snapshot_sha256", recorded.opt("snapshot_sha256"))
                    .put("source_fingerprint", recorded.opt("source_fingerprint"))
                    .put("context_bytes", recorded.opt("context_bytes"))
                    .put("verified_at", receipt.opt("verified_at")),
            )
            .put("messages", JSONArray().put(JSONObject().put("role", "system").put("content", content).put("attachments", JSONArray())))
        val released = decide(
            JSONObject().put("op", "context_bundle").put("bundle", bundle)
                .put("expected_digest", request.opt("project_context_sha256")),
        )
        return Pair(
            released.optJSONObject("receipt") ?: throw Refused(CONFLICT),
            released.optJSONArray("messages") ?: throw Refused(CONFLICT),
        )
    }

    private fun visibleHistory(conversation: JSONObject, authority: JSONObject): JSONArray {
        val byId = HashMap<String, JSONObject>()
        val messages = conversation.optJSONArray("messages") ?: JSONArray()
        for (index in 0 until messages.length()) {
            val message = messages.optJSONObject(index) ?: continue
            (message.opt("id") as? String)?.let { byId[it] = message }
        }
        val ids = authority.optJSONArray("visible_message_ids") ?: JSONArray()
        val visible = JSONArray()
        for (index in 0 until ids.length()) {
            val message = byId[ids.optString(index)] ?: throw Refused(CONFLICT)
            val attachments = JSONArray()
            val carried = message.optJSONArray("attachments") ?: JSONArray()
            for (at in 0 until carried.length()) {
                val attachment = carried.optJSONObject(at) ?: continue
                attachments.put(
                    JSONObject()
                        .put("schema_version", attachment.opt("schema_version"))
                        .put("id", attachment.opt("id"))
                        .put("kind", attachment.opt("kind"))
                        .put("name", attachment.opt("name"))
                        .put("mime_type", attachment.opt("mime_type"))
                        .put("size", attachment.opt("size")),
                )
            }
            visible.put(
                JSONObject().put("role", message.opt("role"))
                    .put("content", message.opt("text"))
                    .put("attachments", attachments),
            )
        }
        return visible
    }

    /**
     * The row a first round starts as: in flight, owned by this process, bound
     * to the transcript and the root the request names. Mirrors the literal
     * iOS builds before `createAgentRoundV3WithInsertCAS:`.
     */
    private fun startedRound(request: JSONObject, locator: JSONObject, owner: JSONObject): JSONObject {
        val now = RuntimeJson.now()
        val root = request.optJSONObject("root")
        return JSONObject()
            .put("schema_version", 3)
            .put("locator", locator)
            .put("row_revision", 1)
            .put("root_fingerprint_sha256", root?.opt("root_fingerprint_sha256"))
            .put("binding_revision", root?.opt("workspace_binding_revision"))
            .put("request_sha256", operations.requestSha256("complete_agent_round_v2", request))
            .put("transcript_before", request.optJSONObject("transcript"))
            .put("launch_attempt", request.opt("launch_attempt"))
            .put("state", "in_flight")
            .put("owner", owner)
            .put("failure_code", JSONObject.NULL)
            .put("completion_receipt", JSONObject.NULL)
            .put("transcript_after", JSONObject.NULL)
            .put("calls", JSONArray())
            .put("batch_class", JSONObject.NULL)
            .put("executable_call_count", 0)
            .put("denied_call_count", 0)
            .put("terminal_kind", JSONObject.NULL)
            .put("created_at", now).put("updated_at", now)
    }

    /**
     * Reconciles a round after a restart, for `recover_agent_attempt`.
     *
     * The question a recovery asks is not "what happened" but "is anyone
     * still doing it". A row whose owner is alive in *this* launch is still in
     * flight and is left alone; a row whose writer died with the process is
     * reclaimed, and what it is reclaimed *as* -- retryable, ambiguous,
     * completed -- is the core's reading of the state it was left in. A row
     * with no owner at all was released deliberately, and only some states are
     * reportable from there.
     *
     * This never calls the provider. A round that was in flight when the app
     * died has no reply to wait for; the reply, if it arrived, was lost with
     * the process that asked for it.
     */
    fun recoverRound(request: JSONObject): JSONObject {
        val root = request.optJSONObject("root")
        val rootOk = roots.resolveAgentProjection(root) != null
        val located = decide(
            JSONObject().put("op", "selector_request").put("request", request)
                .put("cancellation", false).put("root_ok", rootOk).put("env", env(request)),
        )
        val locator = located.optJSONObject("locator") ?: throw Refused(BAD_ARGUMENTS)
        if (!rootOk) {
            return conflictResult(
                request,
                JSONObject().put("row_revision", request.opt("expected_round_revision"))
                    .put("state", "unknown")
                    .put("transcript_before", request.opt("transcript")),
                "E_AGENT_ROOT_STALE",
            )
        }
        val query = rounds.query(locator) ?: throw Refused(PERSISTENCE)
        val row = query.optJSONObject("row") ?: return query
        val matches = decide(
            JSONObject().put("op", "selector_matches").put("request", request).put("row", row),
        ).optBoolean("matches")
        if (!matches) return conflictResult(request, row, "E_AGENT_CONFLICT")

        val owner = row.optJSONObject("owner")
        if (owner == null) {
            // Released on purpose. Only some states can be reported from an
            // ownerless row; the rest are a conflict the controller retries.
            val state = row.optString("state")
            val ownerless = decide(
                JSONObject().put("op", "round_failure_code").put("kind", "ownerless")
                    .put("state", state)
                    .put("recorded", row.opt("failure_code") ?: JSONObject.NULL),
            )
            if (!ownerless.optBoolean("reportable")) throw Refused(CONFLICT)
            return queryResult(request, row, state, ownerless.opt("code"))
        }
        if (liveTasks.isAlive(
                owner.optString("native_task_id"), owner.optString("launch_id"),
            )
        ) {
            return queryResult(request, row, "in_flight", null)
        }

        val cas = decide(JSONObject().put("op", "round_cas").put("row", row))
            .optJSONObject("cas") ?: throw Refused(NATIVE)
        val reconciled = rounds.reconcile(locator, cas)?.optJSONObject("row") ?: row
        val state = reconciled.optString("state")
        val failure = decide(
            JSONObject().put("op", "round_failure_code").put("kind", "reconciled")
                .put("state", state)
                .put("recorded", reconciled.opt("failure_code") ?: JSONObject.NULL),
        ).opt("code")
        return queryResult(request, reconciled, state, failure)
    }

    private fun queryResult(
        request: JSONObject,
        row: JSONObject,
        status: String,
        failureCode: Any?,
    ): JSONObject {
        val result = decide(
            JSONObject().put("op", "query_result").put("request", request)
                .put("row", row).put("status", status)
                .put("failure_code", failureCode ?: JSONObject.NULL),
        ).optJSONObject("result") ?: throw Refused(NATIVE)
        // A completed round the controller never saw settle carries the round
        // itself, so the recovery can hand back what the model actually said
        // rather than only that it finished.
        if (status == "completed") {
            completedProjection(request, row)?.let { result.put("completed_round", it) }
        }
        return result
    }

    /** What a completed row says, as the core projects it for a recovery. */
    private fun completedProjection(request: JSONObject, row: JSONObject): JSONObject? {
        val messages = transcripts.nativeMessages(
            JSONObject().put("schema_version", 1)
                .put("attempt_id", request.opt("attempt_id"))
                .put("root", request.opt("root"))
                .put("transcript", row.opt("transcript_after") ?: request.opt("transcript")),
        ) ?: return null
        return try {
            decide(
                JSONObject().put("op", "recovered_projection").put("request", request)
                    .put("row", row).put("messages", messages),
            ).optJSONObject("projection")
        } catch (refused: Refused) {
            // A projection the core will not build is not worth failing a
            // recovery over: the status it reports is already true.
            android.util.Log.w("RishAgent", "completed round not projectable: ${refused.code}")
            null
        }
    }

    /**
     * Cancels a round in flight, for `cancel_agent_attempt`.
     *
     * Two things have to happen and neither is enough alone: the provider call
     * has to stop, and the row has to say so. The transport holds the call by
     * the round id it was prepared under, so cancelling it interrupts a reply
     * that may be minutes from arriving; the journal then moves the row, and
     * what the caller is told about it is the core's query result, not this
     * file's reading of the row.
     *
     * A cancellation names a row that already exists, so the selector is
     * validated as a cancellation -- iOS passes the same two flags -- and a
     * root that no longer proves out is a conflict rather than a refusal: the
     * person asked to stop, and they are told what state it stopped in.
     */
    fun cancelRound(request: JSONObject): JSONObject {
        val root = request.optJSONObject("root")
        val rootOk = roots.resolveAgentProjection(root) != null
        val located = decide(
            JSONObject().put("op", "selector_request").put("request", request)
                .put("cancellation", true).put("root_ok", rootOk).put("env", env(request)),
        )
        val locator = located.optJSONObject("locator") ?: throw Refused(BAD_ARGUMENTS)
        if (!rootOk) {
            return conflictResult(
                request,
                JSONObject().put("row_revision", request.opt("expected_round_revision"))
                    .put("state", "unknown")
                    .put("transcript_before", request.opt("transcript")),
                "E_AGENT_ROOT_STALE",
            )
        }
        val query = rounds.query(locator) ?: throw Refused(PERSISTENCE)
        val row = query.optJSONObject("row") ?: return query
        val matches = decide(
            JSONObject().put("op", "selector_matches").put("request", request).put("row", row),
        ).optBoolean("matches")
        if (!matches) return conflictResult(request, row, "E_AGENT_CONFLICT")

        val cas = decide(JSONObject().put("op", "round_cas").put("row", row))
            .optJSONObject("cas") ?: throw Refused(NATIVE)
        // The provider call is keyed by the round id it was prepared under.
        // Stopping it is what makes cancelling immediate rather than a note
        // the next reply overwrites.
        transport.cancel(request.optString("round_id"))
        val cancelled = rounds.cancel(cas)?.optJSONObject("row") ?: row
        val state = cancelled.optString("state")
        val failure = decide(
            JSONObject().put("op", "round_failure_code").put("kind", "cancelled")
                .put("state", state),
        ).opt("code")
        return decide(
            JSONObject().put("op", "query_result").put("request", request)
                .put("row", cancelled).put("status", state)
                .put("failure_code", failure ?: JSONObject.NULL),
        ).optJSONObject("result") ?: throw Refused(NATIVE)
    }

    private fun conflictResult(
        request: JSONObject,
        row: JSONObject,
        failureCode: String,
    ): JSONObject = decide(
        JSONObject().put("op", "selector_conflict").put("request", request)
            .put("row", row).put("failure_code", failureCode),
    ).optJSONObject("result") ?: throw Refused(NATIVE)

    /**
     * The sink a round's provider call reports through, or null when nobody is
     * watching.
     *
     * Every event carries the correlation the display keys on and a sequence
     * number, and the host counts the sequence rather than the provider: the
     * chunks are not numbered, and a preview that skipped one would be
     * rendered as a gap rather than as the text that arrived.
     */
    private fun previewSink(
        request: JSONObject,
        locator: JSONObject,
    ): ((JSONObject) -> Unit)? {
        val publish = AndroidRuntimeState.current()?.roundPreview ?: return null
        val correlation = JSONObject()
            .put("schema_version", 1)
            .put("task_id", request.opt("task_id"))
            .put("attempt_id", request.opt("attempt_id"))
            .put("round_id", locator.opt("round_id"))
            .put("round_index", locator.opt("round_index"))
            .put("operation_id", request.opt("operation_id"))
            .put("provider_request_id", request.opt("operation_id"))
            .put("harness_id", request.optString("harness_id", "dsh"))
        // The display refuses a sequence that starts at zero: the first event
        // a round ever sends is seq 1.
        var seq = 1
        return { event ->
            val payload = JSONObject(correlation.toString())
            for (key in event.keys()) payload.put(key, event.get(key))
            if (!payload.has("kind")) payload.put("kind", "delta")
            if (payload.optString("kind") == "end" && !payload.has("truncated")) {
                payload.put("truncated", false)
            }
            payload.put("seq", seq)
            seq += 1
            publish(payload)
        }
    }

    /** What the insert asserts about a world that has no such row yet. */
    private fun insertCas(request: JSONObject, locator: JSONObject): JSONObject {
        val transcript = request.optJSONObject("transcript")
        val root = request.optJSONObject("root")
        return JSONObject()
            .put("schema_version", 1)
            .put("locator", locator)
            .put("expected_absent", true)
            .put("expected_transcript_generation", transcript?.opt("generation"))
            .put("expected_transcript_sha256", transcript?.opt("transcript_sha256"))
            .put("expected_root_fingerprint_sha256", root?.opt("root_fingerprint_sha256"))
            .put("expected_binding_revision", root?.opt("workspace_binding_revision"))
    }

    private fun rowFor(state: JSONObject, locator: JSONObject): JSONObject? {
        val table = state.optJSONArray("rounds") ?: return null
        val key = decide(
            JSONObject().put("op", "locator_key").put("locator", locator),
        ).optString("key")
        for (index in 0 until table.length()) {
            val row = table.optJSONObject(index) ?: continue
            val candidate = decide(
                JSONObject().put("op", "locator_key")
                    .put("locator", row.optJSONObject("locator") ?: JSONObject()),
            ).optString("key")
            if (candidate == key) return row
        }
        return null
    }

    private fun ownerFor(request: JSONObject): JSONObject = JSONObject()
        .put("schema_version", 1)
        .put("task_id", request.optString("task_id"))
        .put("launch_id", AndroidAgentWal.launchId)
        .put("native_task_id", request.optString("operation_id"))
        .put("owner_generation", 1)
        .put("heartbeat_at", RuntimeJson.now())

    private companion object {
        const val NATIVE = "E_AGENT_NATIVE"
        const val CONFLICT = "E_AGENT_CONFLICT"
        const val BAD_ARGUMENTS = "E_AGENT_BAD_ARGUMENTS"
        const val PERSISTENCE = "E_AGENT_PERSISTENCE"
        const val TRANSCRIPT = "E_AGENT_TRANSCRIPT"
    }
}
