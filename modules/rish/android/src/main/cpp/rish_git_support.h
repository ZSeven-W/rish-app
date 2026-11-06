// What the libgit2 JNI files share: opening a repository the way this app
// keeps one, and writing an answer as JSON.
//
// A workspace's project is a private bare gitdir paired with the workspace
// root as its working tree at every open; nothing inside the workspace says
// it is a repository. That pairing lives here so every function that reads or
// writes a project opens it the same way.

#pragma once

#include <jni.h>

#include <cstdio>
#include <string>

#include <git2.h>

namespace rish {

/// libgit2's last error, or an empty string when it did not say.
inline std::string LastError() {
  const git_error *error = git_error_last();
  return error != nullptr && error->message != nullptr ? error->message : "";
}

/// A JSON string, escaped the way any JSON writer must. The bytes are passed
/// through; the caller has checked they are UTF-8 where that matters.
inline std::string Quoted(const char *value) {
  std::string out = "\"";
  for (const char *cursor = value == nullptr ? "" : value; *cursor != '\0'; cursor += 1) {
    const unsigned char c = static_cast<unsigned char>(*cursor);
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char escape[7];
          snprintf(escape, sizeof(escape), "\\u%04x", c);
          out += escape;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out + "\"";
}

inline std::string Quoted(const std::string &value) { return Quoted(value.c_str()); }

inline std::string Oid(const git_oid *id) {
  char hex[GIT_OID_SHA1_HEXSIZE + 1];
  git_oid_tostr(hex, sizeof(hex), id);
  return std::string(hex);
}

/// Whether `bytes` is well-formed UTF-8. Overlong forms, surrogates and
/// anything past U+10FFFF are refused, as a decoder would refuse them.
inline bool ValidUtf8(const unsigned char *bytes, size_t length) {
  size_t index = 0;
  while (index < length) {
    const unsigned char lead = bytes[index];
    size_t need = 0;
    unsigned int code = 0;
    if (lead < 0x80) { index += 1; continue; }
    if (lead >= 0xC2 && lead <= 0xDF) { need = 1; code = lead & 0x1F; }
    else if (lead >= 0xE0 && lead <= 0xEF) { need = 2; code = lead & 0x0F; }
    else if (lead >= 0xF0 && lead <= 0xF4) { need = 3; code = lead & 0x07; }
    else return false;
    if (index + need >= length) return false;
    for (size_t offset = 1; offset <= need; offset += 1) {
      const unsigned char next = bytes[index + offset];
      if ((next & 0xC0) != 0x80) return false;
      code = (code << 6) | (next & 0x3F);
    }
    if ((need == 2 && code < 0x800) || (need == 3 && code < 0x10000) ||
        (code >= 0xD800 && code <= 0xDFFF) || code > 0x10FFFF) {
      return false;
    }
    index += need + 1;
  }
  return true;
}

inline bool ValidUtf8(const std::string &text) {
  return ValidUtf8(reinterpret_cast<const unsigned char *>(text.data()), text.size());
}

/// The longest prefix of `text` of at most `limit` bytes that ends on a
/// character boundary. `text` is assumed valid UTF-8.
inline size_t Utf8Prefix(const std::string &text, size_t limit) {
  if (text.size() <= limit) return text.size();
  size_t cut = limit;
  while (cut > 0 && (static_cast<unsigned char>(text[cut]) & 0xC0) == 0x80) cut -= 1;
  return cut;
}

/// Opens the repository the caller describes: a plain one whose `.git` is in
/// `workdir`, or, when `gitdir` is given, a private bare gitdir whose working
/// tree is `workdir`. Answers the stage that failed, or nullptr.
///
/// `git_repository_set_workdir` with `update_gitlink` off changes only this
/// handle: nothing is written into the workspace or the gitdir's config, so
/// the pairing has to be restated at every open. That is deliberate -- the
/// binding beside the gitdir is what says which workspace it belongs to.
inline const char *OpenRepository(git_repository **out, const char *gitdir, const char *workdir) {
  if (gitdir == nullptr) {
    return git_repository_open(out, workdir) == 0 ? nullptr : "open";
  }
  if (git_repository_open_ext(out, gitdir,
                              GIT_REPOSITORY_OPEN_NO_SEARCH | GIT_REPOSITORY_OPEN_NO_DOTGIT |
                                  GIT_REPOSITORY_OPEN_BARE,
                              nullptr) != 0) {
    return "open";
  }
  if (!git_repository_is_bare(*out)) return "not_bare";
  if (git_repository_set_workdir(*out, workdir, 0) != 0) return "workdir";
  if (git_repository_is_bare(*out) || git_repository_workdir(*out) == nullptr) return "workdir";
  return nullptr;
}

/// A Java string as UTF-8, or nullptr for a null reference.
inline const char *Chars(JNIEnv *env, jstring value) {
  return value == nullptr ? nullptr : env->GetStringUTFChars(value, nullptr);
}

inline void Release(JNIEnv *env, jstring value, const char *chars) {
  if (value != nullptr && chars != nullptr) env->ReleaseStringUTFChars(value, chars);
}

/// UTF-8 bytes as a Java byte array. Answers cross as bytes rather than a
/// Java string because NewStringUTF wants modified UTF-8, which a patch with
/// a four-byte character is not.
inline jbyteArray Bytes(JNIEnv *env, const std::string &text) {
  jbyteArray array = env->NewByteArray(static_cast<jsize>(text.size()));
  if (array != nullptr) {
    env->SetByteArrayRegion(array, 0, static_cast<jsize>(text.size()),
                            reinterpret_cast<const jbyte *>(text.data()));
  }
  return array;
}

/// A relative path git may report, as the app is willing to show it: no
/// leading slash, no backslash, no control characters, and no component that
/// is empty, `.`, `..` or `.git`.
inline bool SafeRepositoryPath(const std::string &path) {
  if (path.empty() || path[0] == '/' || !ValidUtf8(path)) return false;
  std::string component;
  for (size_t index = 0; index <= path.size(); index += 1) {
    const char c = index < path.size() ? path[index] : '/';
    if (c == '\\' || (static_cast<unsigned char>(c) < 0x20) || c == 0x7f) return false;
    if (c == '/') {
      if (component.empty() || component == "." || component == ".." || component == ".git") return false;
      component.clear();
    } else {
      component += c;
    }
  }
  return true;
}

}  // namespace rish
