// JNI shim for the shared Rust agent core (modules/rish/core). It exposes the
// reducers Android calls and nothing else: requests and replies cross as JSON
// strings, and the core owns every string it returns.
//
// The UTF-8/UTF-16 conversion is the same strict pair rish_guest_jni.cpp uses,
// for the same reason: JNI's "modified UTF-8" differs from real UTF-8 for
// supplementary characters and U+0000, so neither GetStringUTFChars nor
// NewStringUTF is safe for arbitrary session text.

#include <jni.h>

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include <rish_agent_core.h>

namespace {

// A session candidate is capped at 16 MiB by the store; the JSON envelope
// around it is small. Anything larger is not a request Android produces.
constexpr jsize kMaximumRequestCharacters = 24 * 1024 * 1024;

void AppendUtf8(std::uint32_t code_point, std::string *output) {
  if (code_point <= 0x7f) {
    output->push_back(static_cast<char>(code_point));
  } else if (code_point <= 0x7ff) {
    output->push_back(static_cast<char>(0xc0 | (code_point >> 6)));
    output->push_back(static_cast<char>(0x80 | (code_point & 0x3f)));
  } else if (code_point <= 0xffff) {
    output->push_back(static_cast<char>(0xe0 | (code_point >> 12)));
    output->push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3f)));
    output->push_back(static_cast<char>(0x80 | (code_point & 0x3f)));
  } else {
    output->push_back(static_cast<char>(0xf0 | (code_point >> 18)));
    output->push_back(static_cast<char>(0x80 | ((code_point >> 12) & 0x3f)));
    output->push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3f)));
    output->push_back(static_cast<char>(0x80 | (code_point & 0x3f)));
  }
}

// Strict UTF-16 -> UTF-8. Rejects lone surrogates, oversized input, and a raw
// U+0000 (the Rust C ABI is NUL-terminated; an escaped NUL arrives as ASCII).
bool JStringToUtf8(JNIEnv *env, jstring input, std::string *output,
                   jsize maximum_characters = kMaximumRequestCharacters) {
  const jsize length = env->GetStringLength(input);
  if (length > maximum_characters) return false;
  const jchar *characters = env->GetStringChars(input, nullptr);
  if (characters == nullptr) return false;

  output->clear();
  output->reserve(static_cast<std::size_t>(length));
  bool valid = true;
  for (jsize index = 0; index < length; ++index) {
    std::uint32_t code_point = characters[index];
    if (code_point >= 0xd800 && code_point <= 0xdbff) {
      if (index + 1 >= length) { valid = false; break; }
      const std::uint32_t low = characters[++index];
      if (low < 0xdc00 || low > 0xdfff) { valid = false; break; }
      code_point = 0x10000 + ((code_point - 0xd800) << 10) + (low - 0xdc00);
    } else if (code_point >= 0xdc00 && code_point <= 0xdfff) {
      valid = false;
      break;
    }
    if (code_point == 0) { valid = false; break; }
    AppendUtf8(code_point, output);
  }
  env->ReleaseStringChars(input, characters);
  return valid;
}

bool ReadContinuation(std::string_view input, std::size_t *index,
                      std::uint32_t *value) {
  if (*index >= input.size()) return false;
  const auto byte = static_cast<std::uint8_t>(input[(*index)++]);
  if ((byte & 0xc0) != 0x80) return false;
  *value = (*value << 6) | (byte & 0x3f);
  return true;
}

// Strict UTF-8 -> UTF-16. Rejects overlong forms, surrogate code points, and
// anything above U+10FFFF instead of silently substituting.
bool Utf8ToUtf16(std::string_view input, std::vector<jchar> *output) {
  output->clear();
  output->reserve(input.size());
  std::size_t index = 0;
  while (index < input.size()) {
    const auto lead = static_cast<std::uint8_t>(input[index++]);
    std::uint32_t code_point = 0;
    std::uint32_t minimum = 0;
    int continuation_count = 0;
    if (lead <= 0x7f) {
      code_point = lead;
    } else if ((lead & 0xe0) == 0xc0) {
      code_point = lead & 0x1f; minimum = 0x80; continuation_count = 1;
    } else if ((lead & 0xf0) == 0xe0) {
      code_point = lead & 0x0f; minimum = 0x800; continuation_count = 2;
    } else if ((lead & 0xf8) == 0xf0) {
      code_point = lead & 0x07; minimum = 0x10000; continuation_count = 3;
    } else {
      return false;
    }
    for (int count = 0; count < continuation_count; ++count) {
      if (!ReadContinuation(input, &index, &code_point)) return false;
    }
    if (code_point < minimum || code_point > 0x10ffff ||
        (code_point >= 0xd800 && code_point <= 0xdfff)) {
      return false;
    }
    if (code_point <= 0xffff) {
      output->push_back(static_cast<jchar>(code_point));
    } else {
      code_point -= 0x10000;
      output->push_back(static_cast<jchar>(0xd800 | (code_point >> 10)));
      output->push_back(static_cast<jchar>(0xdc00 | (code_point & 0x3ff)));
    }
  }
  return true;
}

jstring Utf8ToJString(JNIEnv *env, std::string_view input) {
  std::vector<jchar> utf16;
  if (!Utf8ToUtf16(input, &utf16)) return nullptr;
  if (utf16.empty()) return env->NewStringUTF("");
  return env->NewString(utf16.data(), static_cast<jsize>(utf16.size()));
}

jstring TakeOwnedReply(JNIEnv *env, char *raw) {
  if (raw == nullptr) return nullptr;
  jstring reply = Utf8ToJString(env, std::string_view(raw));
  rish_agent_string_free(raw);
  return reply;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_protocolVersion(JNIEnv *,
                                                                  jclass) {
  return static_cast<jint>(rish_agent_protocol_version());
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_buildId(JNIEnv *env, jclass) {
  return TakeOwnedReply(env, rish_agent_build_id());
}

// The session reducer takes its operation envelope and the operation's raw
// bytes apart, because a candidate is judged as bytes rather than as reparsed
// JSON. `input` may be empty for ops that take none.
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_sessionReduce(
    JNIEnv *env, jclass, jstring request, jstring input) {
  std::string request_utf8;
  std::string input_utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &request_utf8)) {
    return nullptr;
  }
  if (input != nullptr && !JStringToUtf8(env, input, &input_utf8)) {
    return nullptr;
  }
  return TakeOwnedReply(
      env, rish_agent_session_reduce(
               request_utf8.data(), request_utf8.size(),
               reinterpret_cast<const std::uint8_t *>(input_utf8.data()),
               input_utf8.size()));
}

// DSHAgentHJ: the domain-separated digest of a canonical JSON value. Stores
// need it to name an operation by its request, and there must be one
// implementation of it.
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_hashJson(
    JNIEnv *env, jclass, jstring tag, jstring json) {
  std::string tag_utf8;
  std::string json_utf8;
  if (tag == nullptr || !JStringToUtf8(env, tag, &tag_utf8)) return nullptr;
  if (json == nullptr || !JStringToUtf8(env, json, &json_utf8)) return nullptr;
  return TakeOwnedReply(
      env, rish_agent_hash_json(tag_utf8.data(), tag_utf8.size(),
                                json_utf8.data(), json_utf8.size()));
}

// The prepared-attempt reducer, like the session one, takes the committed
// session's exact bytes alongside its envelope: the rule is about those bytes,
// not about a value that happens to encode to them.
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_preparedAttemptReduce(
    JNIEnv *env, jclass, jstring request, jstring session) {
  std::string request_utf8;
  std::string session_utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &request_utf8)) {
    return nullptr;
  }
  if (session != nullptr && !JStringToUtf8(env, session, &session_utf8)) {
    return nullptr;
  }
  return TakeOwnedReply(
      env, rish_agent_prepared_attempt_reduce(
               request_utf8.data(), request_utf8.size(),
               reinterpret_cast<const std::uint8_t *>(session_utf8.data()),
               session_utf8.size()));
}

// The WAL reducers take a single JSON envelope, like every other reducer.
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_walStateReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_wal_state_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_walOperationReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_wal_operation_reduce(utf8.data(), utf8.size()));
}

// SHA-256 over raw bytes with a tagged prefix. A write's precondition names
// the path and the content by these digests, and a host that spelled them
// itself would be inventing an identity two platforms have to agree on.
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_hashBytes(
    JNIEnv *env, jclass, jstring tag, jbyteArray bytes) {
  std::string tagUtf8;
  if (tag == nullptr || !JStringToUtf8(env, tag, &tagUtf8)) return nullptr;
  if (bytes == nullptr) return nullptr;
  jsize length = env->GetArrayLength(bytes);
  std::vector<uint8_t> buffer(static_cast<size_t>(length));
  if (length > 0) {
    env->GetByteArrayRegion(bytes, 0, length, reinterpret_cast<jbyte *>(buffer.data()));
  }
  return TakeOwnedReply(env, rish_agent_hash_bytes(
      tagUtf8.data(), tagUtf8.size(), buffer.data(), buffer.size()));
}

/// The canonical form of tool arguments, when the strict parser accepts them.
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_parseArguments(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_parse_arguments(utf8.data(), utf8.size()));
}

// The rest of the core's decision surface. Android bound 29 of the 47 entry
// points, and the eighteen below were the ones the agent path needed: a tool
// batch, a tool execution, a ledger batch, a provider round, a policy. Each
// missing one was found by walking into it, one layer at a time; binding the
// surface once ends that.
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_completionResponseReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_completion_response_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_containerAnchorReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_container_anchor_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_gitToolReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_git_tool_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_namePolicy(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_name_policy_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_gitRemotePolicy(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_git_remote_policy_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_modelCatalog(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_model_catalog_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_providerPolicy(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_provider_policy_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_ledgerBatchReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_ledger_batch_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_policyReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_policy_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_projectAccessReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_project_access_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_projectContextBridgeReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_project_context_bridge_reduce(utf8.data(), utf8.size()));
}

// This one carries a file's raw bytes beside the envelope: content_decision
// reads them, and the other ops pass null rather than an empty buffer, because
// "no content" and "an empty file" are different questions.
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_projectContextReduce(
    JNIEnv *env, jclass, jstring request, jbyteArray content) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  if (content == nullptr) {
    return TakeOwnedReply(env, rish_agent_project_context_reduce(
        utf8.data(), utf8.size(), nullptr, 0));
  }
  jsize length = env->GetArrayLength(content);
  std::vector<uint8_t> bytes(static_cast<size_t>(length));
  if (length > 0) {
    env->GetByteArrayRegion(content, 0, length, reinterpret_cast<jbyte *>(bytes.data()));
  }
  return TakeOwnedReply(env, rish_agent_project_context_reduce(
      utf8.data(), utf8.size(), bytes.data(), bytes.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_projectContextServiceReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_project_context_service_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_projectContextStoreReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_project_context_store_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_projectModuleReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_project_module_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_providerRoundReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_provider_round_reduce(utf8.data(), utf8.size()));
}


extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_toolBatchReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_tool_batch_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_toolExecutionReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_tool_execution_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_workspaceClearanceReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_workspace_clearance_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_workspaceErrorReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_workspace_error_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_workspaceReadToolsReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_workspace_read_tools_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_workspaceToolReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_workspace_tool_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_runtimeReduce(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_runtime_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_transcriptReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_transcript_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_roundReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_round_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_roundPresentationReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  // A projected attempt can contain eight text/reasoning pairs. The core owns
  // its 64 MiB byte bound; keep the legacy session cap for every other entry.
  if (request == nullptr || !JStringToUtf8(env, request, &utf8, 64 * 1024 * 1024)) return nullptr;
  return TakeOwnedReply(env, rish_agent_round_presentation_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_ledgerReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_ledger_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_toolRegistryReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_tool_registry_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_workspaceRecordReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_workspace_record_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_workspaceFingerprintReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_workspace_fingerprint_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_workspaceGrantsReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_workspace_grants_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_workspaceAuthorityReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_workspace_authority_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_workspaceDirectoryNameReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_workspace_directory_name_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_rootReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_root_reduce(utf8.data(), utf8.size()));
}

// The stored-JSON scan takes raw bytes rather than an envelope, because the
// question is about bytes that may not be JSON at all.
extern "C" JNIEXPORT jboolean JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_workspaceJsonBoundedNative(
    JNIEnv *env, jclass, jbyteArray bytes) {
  if (bytes == nullptr) return JNI_FALSE;
  jsize length = env->GetArrayLength(bytes);
  jbyte *elements = env->GetByteArrayElements(bytes, nullptr);
  if (elements == nullptr) return JNI_FALSE;
  unsigned char accepted = rish_agent_workspace_json_bounded(
      reinterpret_cast<const char *>(elements), static_cast<size_t>(length));
  env->ReleaseByteArrayElements(bytes, elements, JNI_ABORT);
  return accepted == 1 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_workspaceReceiptReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_workspace_receipt_reduce(utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_workspaceJournalReduceNative(
    JNIEnv *env, jclass, jstring request) {
  std::string utf8;
  if (request == nullptr || !JStringToUtf8(env, request, &utf8)) return nullptr;
  return TakeOwnedReply(env, rish_agent_workspace_journal_reduce(utf8.data(), utf8.size()));
}

// The resident committed state. The handle crosses as an opaque jlong; the
// caller owns it until walClose, exactly as on the C side.
extern "C" JNIEXPORT jlong JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_walOpen(JNIEnv *env, jclass,
                                                          jstring state) {
  std::string utf8;
  if (state == nullptr || !JStringToUtf8(env, state, &utf8)) return 0;
  void *handle = rish_agent_wal_open(utf8.data(), utf8.size());
  return static_cast<jlong>(reinterpret_cast<std::intptr_t>(handle));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_walSnapshot(JNIEnv *env, jclass,
                                                              jlong handle) {
  if (handle == 0) return nullptr;
  return TakeOwnedReply(
      env, rish_agent_wal_snapshot(reinterpret_cast<void *>(
               static_cast<std::intptr_t>(handle))));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_walBegin(JNIEnv *env, jclass,
                                                           jlong handle,
                                                           jstring candidate) {
  std::string utf8;
  if (handle == 0 || candidate == nullptr || !JStringToUtf8(env, candidate, &utf8)) {
    return nullptr;
  }
  return TakeOwnedReply(
      env, rish_agent_wal_begin(
               reinterpret_cast<void *>(static_cast<std::intptr_t>(handle)),
               utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_walConfirm(JNIEnv *env, jclass,
                                                             jlong handle,
                                                             jstring outcome) {
  std::string utf8;
  if (handle == 0 || outcome == nullptr || !JStringToUtf8(env, outcome, &utf8)) {
    return nullptr;
  }
  return TakeOwnedReply(
      env, rish_agent_wal_confirm(
               reinterpret_cast<void *>(static_cast<std::intptr_t>(handle)),
               utf8.data(), utf8.size()));
}

extern "C" JNIEXPORT void JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_walClose(JNIEnv *, jclass,
                                                           jlong handle) {
  if (handle == 0) return;
  rish_agent_wal_close(
      reinterpret_cast<void *>(static_cast<std::intptr_t>(handle)));
}

extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishAgentCoreNative_canonicalJson(
    JNIEnv *env, jclass, jstring json) {
  std::string json_utf8;
  if (json == nullptr || !JStringToUtf8(env, json, &json_utf8)) return nullptr;
  return TakeOwnedReply(
      env, rish_agent_canonical_json(json_utf8.data(), json_utf8.size()));
}
