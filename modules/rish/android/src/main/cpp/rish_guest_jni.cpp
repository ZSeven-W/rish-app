// JNI shim for the rish guest session ABI used by LocalGuestModule on
// Android. It exposes exactly the four entry points the module needs and
// nothing else: boot a session, run one command in it, free it, and read the
// runtime's protocol version. Requests and replies cross as JSON strings, the
// session handle crosses as an opaque jlong.
//
// The UTF-8/UTF-16 conversion below is adapted from the rish runtime's own
// platform/android/rish_jni.cpp (MIT, ZSeven-W/rish). JNI's "modified UTF-8"
// differs from real UTF-8 for supplementary characters and U+0000, and the
// Rust ABI expects real UTF-8 without embedded NULs, so neither
// GetStringUTFChars nor NewStringUTF is safe for arbitrary text.

#include <jni.h>

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include <rish.h>

namespace {

// Guest requests are a boot envelope or a bounded argv; anything larger is
// not a request this module produces.
constexpr jsize kMaximumRequestCharacters = 1024 * 1024;

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
bool JStringToUtf8(JNIEnv *env, jstring input, std::string *output) {
  const jsize length = env->GetStringLength(input);
  if (length > kMaximumRequestCharacters) return false;
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

void *SessionFromHandle(jlong handle) {
  return reinterpret_cast<void *>(static_cast<std::intptr_t>(handle));
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_tech_zseven_rish_guest_RishGuestNative_protocolVersion(JNIEnv *, jclass) {
  return static_cast<jint>(rish_protocol_version());
}

// Returns the session handle, or 0 when the request is malformed or the guest
// failed to boot. Blocks for the whole boot: the caller keeps it off the main
// thread and the module's state executor.
extern "C" JNIEXPORT jlong JNICALL
Java_tech_zseven_rish_guest_RishGuestNative_bootSession(JNIEnv *env, jclass,
                                                       jstring request) {
  if (request == nullptr) return 0;
  std::string utf8;
  if (!JStringToUtf8(env, request, &utf8)) return 0;
  void *session = rish_vm_boot_session(utf8.data(), utf8.size());
  return static_cast<jlong>(reinterpret_cast<std::intptr_t>(session));
}

// Returns the runtime's JSON reply, or null when the handle or request is
// unusable or the reply is not valid UTF-8. The Rust string is always freed
// before returning.
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_guest_RishGuestNative_sessionExecJson(JNIEnv *env, jclass,
                                                           jlong handle,
                                                           jstring request) {
  if (handle == 0 || request == nullptr) return nullptr;
  std::string utf8;
  if (!JStringToUtf8(env, request, &utf8)) return nullptr;
  char *reply = rish_vm_session_exec_json(SessionFromHandle(handle),
                                          utf8.data(), utf8.size());
  if (reply == nullptr) return nullptr;
  jstring result = Utf8ToJString(env, reply);
  rish_string_free(reply);
  return result;
}

extern "C" JNIEXPORT void JNICALL
Java_tech_zseven_rish_guest_RishGuestNative_sessionFree(JNIEnv *, jclass,
                                                       jlong handle) {
  if (handle != 0) rish_vm_session_free(SessionFromHandle(handle));
}
