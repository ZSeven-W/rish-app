// The remote half of a workspace project: its origin, and a bounded push.
//
// A push is the one git operation here that leaves the device, so it is the
// one that is bounded in every direction the network can fail in: a
// credential that is offered once and only to the host it was stored for,
// a cancel flag every callback checks, a deadline, and a result that says
// whether bytes may already have reached the remote. The sequence and the
// outcome vocabulary are DSHGitPushSupport.mm's, so the two platforms
// answer the same question the same way.
//
// Nothing here validates a URL or reads a credential store: Kotlin does
// both before it calls in, and a URL that reaches this layer has already
// been judged.

#include <jni.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <map>
#include <mutex>
#include <string>

#include <git2.h>

#include "rish_git_support.h"

namespace {

using rish::Chars;
using rish::OpenRepository;
using rish::Quoted;
using rish::Release;

constexpr int kConnectTimeoutMilliseconds = 15000;
constexpr int kServerTimeoutMilliseconds = 15000;

/// One flag per operation id, set by cancelPush from another thread and
/// read by every libgit2 callback of that push.
std::mutex g_cancel_mutex;
std::map<std::string, std::atomic<bool> *> g_cancel_flags;

std::atomic<bool> *RegisterCancel(const std::string &operation) {
  std::lock_guard<std::mutex> guard(g_cancel_mutex);
  auto *flag = new std::atomic<bool>(false);
  auto existing = g_cancel_flags.find(operation);
  if (existing != g_cancel_flags.end()) {
    delete existing->second;
    g_cancel_flags.erase(existing);
  }
  g_cancel_flags.emplace(operation, flag);
  return flag;
}

void UnregisterCancel(const std::string &operation, std::atomic<bool> *flag) {
  std::lock_guard<std::mutex> guard(g_cancel_mutex);
  auto existing = g_cancel_flags.find(operation);
  if (existing != g_cancel_flags.end() && existing->second == flag) g_cancel_flags.erase(existing);
  delete flag;
}

std::string LastError() {
  const git_error *error = git_error_last();
  return error != nullptr && error->message != nullptr ? error->message : "";
}

std::string Failure(int code, const std::string &stage) {
  return "{\"ok\":false,\"code\":" + std::to_string(code) + ",\"stage\":" + Quoted(stage) +
         ",\"error\":" + Quoted(LastError()) + "}";
}

struct PushState {
  // The credential, offered once and only for the host it belongs to.
  std::string host;
  std::string username;
  std::string token;
  bool attempted = false;
  // What the remote said about the one reference this push names.
  std::string target_ref;
  size_t target_count = 0;
  size_t unexpected_count = 0;
  bool target_rejected = false;
  bool target_non_fast_forward = false;
  bool malformed = false;
  // Interruption and its consequence.
  std::atomic<bool> *cancel = nullptr;
  std::chrono::steady_clock::time_point deadline;
  bool interrupted_by_cancel = false;
  bool interrupted_by_deadline = false;
  bool bytes_may_have_been_sent = false;
};

int AbortIfRequested(PushState *state) {
  if (state == nullptr) return 0;
  if (state->cancel != nullptr && state->cancel->load()) {
    state->interrupted_by_cancel = true;
    return GIT_EUSER;
  }
  if (std::chrono::steady_clock::now() >= state->deadline) {
    state->interrupted_by_deadline = true;
    return GIT_EUSER;
  }
  return 0;
}

/// The host of `url`, lowercased, or empty when it has none.
std::string HostOf(const char *url) {
  if (url == nullptr) return "";
  std::string text(url);
  const size_t scheme = text.find("://");
  if (scheme == std::string::npos) return "";
  size_t start = scheme + 3;
  const size_t at = text.find('@', start);
  const size_t slash = text.find('/', start);
  if (at != std::string::npos && (slash == std::string::npos || at < slash)) start = at + 1;
  size_t end = text.find_first_of(":/", start);
  if (end == std::string::npos) end = text.size();
  std::string host = text.substr(start, end - start);
  for (char &c : host) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
  return host;
}

int CredentialCallback(git_credential **out, const char *url, const char *username_from_url,
                       unsigned int allowed_types, void *payload) {
  (void)username_from_url;
  auto *state = static_cast<PushState *>(payload);
  if (AbortIfRequested(state) != 0) return GIT_EUSER;
  if (state->token.empty() || state->username.empty()) return GIT_EAUTH;
  // The credential was stored for one host; a redirect or a rewritten URL
  // that asks for it elsewhere gets nothing.
  if (HostOf(url) != state->host) return GIT_EAUTH;
  if (allowed_types & GIT_CREDENTIAL_USERPASS_PLAINTEXT) {
    if (state->attempted) return GIT_EAUTH;
    state->attempted = true;
    return git_credential_userpass_plaintext_new(out, state->username.c_str(), state->token.c_str());
  }
  if (allowed_types & GIT_CREDENTIAL_USERNAME) {
    return git_credential_username_new(out, state->username.c_str());
  }
  return GIT_PASSTHROUGH;
}

int SidebandCallback(const char *, int, void *payload) {
  return AbortIfRequested(static_cast<PushState *>(payload));
}

int NegotiationCallback(const git_push_update **, size_t, void *payload) {
  return AbortIfRequested(static_cast<PushState *>(payload));
}

int TransferProgress(unsigned int, unsigned int, size_t, void *payload) {
  auto *state = static_cast<PushState *>(payload);
  if (state != nullptr) state->bytes_may_have_been_sent = true;
  return AbortIfRequested(state);
}

int UpdateReference(const char *refname, const char *status, void *payload) {
  auto *state = static_cast<PushState *>(payload);
  if (state == nullptr) return 0;
  if (refname == nullptr) {
    state->malformed = true;
    return 0;
  }
  if (state->target_ref != refname) {
    state->unexpected_count += 1;
    return 0;
  }
  state->target_count += 1;
  if (status != nullptr) {
    state->target_rejected = true;
    if (strstr(status, "non-fast-forward") != nullptr || strstr(status, "fetch first") != nullptr) {
      state->target_non_fast_forward = true;
    }
  }
  return 0;
}

/// What the remote advertises for `reference`, or empty when it has none.
std::string AdvertisedOid(git_remote *remote, const std::string &reference, int *code_out) {
  const git_remote_head **heads = nullptr;
  size_t count = 0;
  const int code = git_remote_ls(&heads, &count, remote);
  std::string resolved;
  if (code == 0) {
    for (size_t index = 0; index < count; index += 1) {
      if (heads[index] != nullptr && heads[index]->name != nullptr && reference == heads[index]->name) {
        char buffer[GIT_OID_SHA1_HEXSIZE + 1] = {};
        git_oid_tostr(buffer, sizeof(buffer), &heads[index]->oid);
        resolved = buffer;
        break;
      }
    }
  }
  if (code_out != nullptr) *code_out = code;
  return resolved;
}

int FetchProgress(const git_indexer_progress *stats, void *payload) {
  (void)stats;
  return AbortIfRequested(static_cast<PushState *>(payload));
}

void FillCallbacks(git_remote_callbacks *callbacks, PushState *state, bool with_credentials) {
  if (with_credentials) callbacks->credentials = CredentialCallback;
  callbacks->sideband_progress = SidebandCallback;
  callbacks->push_transfer_progress = TransferProgress;
  callbacks->push_update_reference = UpdateReference;
  callbacks->push_negotiation = NegotiationCallback;
  callbacks->payload = state;
}

const char *OutcomeName(int outcome) {
  switch (outcome) {
    case 0: return "success";
    case 1: return "conflict";
    case 2: return "non_fast_forward";
    case 3: return "rejected";
    case 4: return "auth_failure";
    case 5: return "timed_out";
    case 6: return "cancelled";
    default: return "failed";
  }
}

struct PushResult {
  int outcome = 7;
  std::string advertised;
  std::string remote_oid;
  bool verified = false;
  bool effect_may_have_occurred = false;
};

std::string Encode(const PushResult &result) {
  return std::string("{\"ok\":true,\"outcome\":") + Quoted(OutcomeName(result.outcome)) +
         ",\"advertised_oid\":" + (result.advertised.empty() ? "null" : Quoted(result.advertised)) +
         ",\"remote_oid\":" + (result.remote_oid.empty() ? "null" : Quoted(result.remote_oid)) +
         ",\"verified\":" + (result.verified ? "true" : "false") +
         ",\"effect_may_have_occurred\":" + (result.effect_may_have_occurred ? "true" : "false") +
         // libgit2's own words for a failure, for the log and the test report; never shown to a person.
         (result.outcome == 7 ? ",\"error\":" + Quoted(LastError()) : std::string()) + "}";
}

int InterruptedOutcome(const PushState &state, int code, int otherwise) {
  if (state.interrupted_by_cancel) return 6;
  if (state.interrupted_by_deadline) return 5;
  if (code == GIT_EAUTH) return 4;
  return otherwise;
}

/// DSHGitPushExecute, step for step: connect, read what is advertised,
/// upload the one refspec, read the remote's verdict on it, reconnect to
/// verify what it holds now.
PushResult Execute(git_repository *repository, const std::string &remote_url, const std::string &reference,
                   const std::string &local_oid, PushState *state, bool has_expected,
                   const std::string &expected_remote_oid) {
  PushResult result;
  const bool with_credentials = !state->token.empty() && !state->username.empty();
  git_remote *remote = nullptr;
  int code = git_remote_lookup(&remote, repository, "origin");
  if (code == 0 && !remote_url.empty()) {
    code = git_remote_set_instance_url(remote, remote_url.c_str());
    if (code == 0) code = git_remote_set_instance_pushurl(remote, remote_url.c_str());
  }
  git_push_options push_options = {};
  git_remote_connect_options connect_options = {};
  if (code == 0) code = git_push_options_init(&push_options, GIT_PUSH_OPTIONS_VERSION);
  if (code == 0) code = git_remote_connect_options_init(&connect_options, GIT_REMOTE_CONNECT_OPTIONS_VERSION);
  if (code == 0) {
    push_options.follow_redirects = GIT_REMOTE_REDIRECT_NONE;
    push_options.proxy_opts.type = GIT_PROXY_NONE;
    FillCallbacks(&push_options.callbacks, state, with_credentials);
    connect_options.callbacks = push_options.callbacks;
    connect_options.follow_redirects = push_options.follow_redirects;
    connect_options.proxy_opts = push_options.proxy_opts;
    code = git_remote_connect_ext(remote, GIT_DIRECTION_PUSH, &connect_options);
  }
  int advertised_code = 0;
  const std::string advertised = code == 0 ? AdvertisedOid(remote, reference, &advertised_code) : std::string();
  if (code == 0) code = advertised_code;
  result.advertised = advertised;
  if (code != 0) {
    if (remote != nullptr) git_remote_free(remote);
    result.outcome = InterruptedOutcome(*state, code, 7);
    return result;
  }
  // The caller may have prepared against what the remote advertised then;
  // a remote that moved since is a conflict before anything is uploaded.
  if (has_expected && advertised != expected_remote_oid) {
    git_remote_disconnect(remote);
    git_remote_free(remote);
    result.outcome = 1;
    return result;
  }
  const std::string refspec = reference + ":" + reference;
  char *raw_refspec = const_cast<char *>(refspec.c_str());
  git_strarray refspecs = {&raw_refspec, 1};
  code = git_remote_upload(remote, &refspecs, &push_options);
  git_remote_disconnect(remote);
  if (code != 0) {
    git_remote_free(remote);
    if (code == GIT_ENONFASTFORWARD) {
      result.outcome = 2;
      return result;
    }
    result.effect_may_have_occurred = state->bytes_may_have_been_sent;
    result.outcome = InterruptedOutcome(*state, code, 7);
    if (result.outcome == 7) result.effect_may_have_occurred = true;
    return result;
  }
  const bool shape_exact = !state->malformed && state->unexpected_count == 0 && state->target_count == 1;
  if (!shape_exact) {
    git_remote_free(remote);
    result.outcome = 7;
    result.effect_may_have_occurred = true;
    return result;
  }
  if (state->target_rejected) {
    git_remote_free(remote);
    result.outcome = state->target_non_fast_forward ? 2 : 3;
    return result;
  }
  state->attempted = false;
  int verify_code = git_remote_connect_ext(remote, GIT_DIRECTION_FETCH, &connect_options);
  const std::string observed = verify_code == 0 ? AdvertisedOid(remote, reference, &verify_code) : std::string();
  if (git_remote_connected(remote)) git_remote_disconnect(remote);
  git_remote_free(remote);
  result.outcome = 0;
  result.verified = verify_code == 0 && !observed.empty();
  result.remote_oid = result.verified ? observed : local_oid;
  return result;
}

std::string String(JNIEnv *env, jstring value) {
  const char *chars = Chars(env, value);
  std::string out = chars == nullptr ? std::string() : std::string(chars);
  Release(env, value, chars);
  return out;
}

}  // namespace

extern "C" {

/// Where OpenSSL finds the roots it trusts. Android keeps its system roots
/// under names OpenSSL no longer hashes by, so Kotlin exports the store to
/// one PEM file and hands its path here once per process.
JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_configureCertificates(JNIEnv *env, jclass, jstring fileValue) {
  const std::string file = String(env, fileValue);
  const int code = git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, file.empty() ? nullptr : file.c_str(), nullptr);
  git_libgit2_opts(GIT_OPT_SET_SERVER_CONNECT_TIMEOUT, kConnectTimeoutMilliseconds);
  git_libgit2_opts(GIT_OPT_SET_SERVER_TIMEOUT, kServerTimeoutMilliseconds);
  return env->NewStringUTF(code == 0 ? "ok" : ("error:" + LastError()).c_str());
}

/// `git remote add|set-url origin <url>`, and the push URL cleared so both
/// directions go where the person said. Answers "ok" or "error:<stage>:<why>".
JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_setRemote(JNIEnv *env, jclass, jstring gitDirValue,
                                                          jstring workDirValue, jstring urlValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const std::string url = String(env, urlValue);
  std::string answer = "ok";
  git_repository *repository = nullptr;
  git_remote *remote = nullptr;
  do {
    if (workdir == nullptr || url.empty()) { answer = "error:arguments:"; break; }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = std::string("error:") + stage + ":" + LastError(); break; }
    int code = git_remote_lookup(&remote, repository, "origin");
    if (code == GIT_ENOTFOUND) {
      code = git_remote_create(&remote, repository, "origin", url.c_str());
    } else if (code == 0) {
      code = git_remote_set_url(repository, "origin", url.c_str());
    }
    // A push URL that was never set is nothing to clear: the one direction
    // the person named is the one both directions use.
    if (code == 0) {
      const int cleared = git_remote_set_pushurl(repository, "origin", nullptr);
      if (cleared != 0 && cleared != GIT_ENOTFOUND) code = cleared;
    }
    if (code != 0) { answer = "error:remote:" + LastError(); break; }
  } while (false);
  if (remote != nullptr) git_remote_free(remote);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return env->NewStringUTF(answer.c_str());
}

/// The origin's URL, or "" when there is no origin. Answers
/// `{"ok":true,"url":…|null}` or `{"ok":false,...}`.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_remoteUrl(JNIEnv *env, jclass, jstring gitDirValue,
                                                          jstring workDirValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  std::string answer;
  git_repository *repository = nullptr;
  git_remote *remote = nullptr;
  do {
    if (workdir == nullptr) { answer = Failure(3101, "arguments"); break; }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure(3102, stage); break; }
    const int code = git_remote_lookup(&remote, repository, "origin");
    if (code == GIT_ENOTFOUND) { answer = "{\"ok\":true,\"url\":null}"; break; }
    if (code != 0) { answer = Failure(3199, "remote"); break; }
    const char *url = git_remote_url(remote);
    answer = std::string("{\"ok\":true,\"url\":") + (url == nullptr ? "null" : Quoted(url)) + "}";
  } while (false);
  if (remote != nullptr) git_remote_free(remote);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return rish::Bytes(env, answer);
}

/// Pushes `reference` (refs/heads/<branch>) to origin, bounded by
/// `timeoutSeconds` and by cancelPush(operationId). The credential is used
/// only for `host`. Answers `{"ok":true,"outcome":…,"advertised_oid":…,
/// "remote_oid":…,"verified":…,"effect_may_have_occurred":…}`.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_push(JNIEnv *env, jclass, jstring gitDirValue,
                                                     jstring workDirValue, jstring operationValue,
                                                     jstring remoteUrlValue, jstring hostValue,
                                                     jstring referenceValue, jstring localOidValue,
                                                     jstring usernameValue, jstring tokenValue,
                                                     jint timeoutSeconds, jboolean hasExpected,
                                                     jstring expectedRemoteOidValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const std::string operation = String(env, operationValue);
  const std::string expected_remote_oid = String(env, expectedRemoteOidValue);
  const std::string remote_url = String(env, remoteUrlValue);
  const std::string host = String(env, hostValue);
  const std::string reference = String(env, referenceValue);
  const std::string local_oid = String(env, localOidValue);
  const std::string username = String(env, usernameValue);
  const std::string token = String(env, tokenValue);
  std::string answer;
  git_repository *repository = nullptr;
  do {
    if (workdir == nullptr || operation.empty() || reference.rfind("refs/heads/", 0) != 0 ||
        local_oid.size() != GIT_OID_SHA1_HEXSIZE || (!remote_url.empty() && host.empty()) ||
        timeoutSeconds < 1) {
      answer = Failure(3101, "arguments");
      break;
    }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure(3102, stage); break; }
    std::atomic<bool> *cancel = RegisterCancel(operation);
    PushState state;
    state.host = host;
    state.username = username;
    state.token = token;
    state.target_ref = reference;
    state.cancel = cancel;
    state.deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeoutSeconds);
    const PushResult result =
        Execute(repository, remote_url, reference, local_oid, &state, hasExpected == JNI_TRUE, expected_remote_oid);
    UnregisterCancel(operation, cancel);
    answer = Encode(result);
  } while (false);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return rish::Bytes(env, answer);
}

/// What origin advertises for `reference` right now, over a FETCH
/// connection with the same credential rule as a push. Answers
/// `{"ok":true,"oid":…|null}`; null is a reference the remote does not have.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_remoteRefOid(JNIEnv *env, jclass, jstring gitDirValue,
                                                             jstring workDirValue, jstring remoteUrlValue,
                                                             jstring hostValue, jstring referenceValue,
                                                             jstring usernameValue, jstring tokenValue,
                                                             jint timeoutSeconds) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const std::string remote_url = String(env, remoteUrlValue);
  const std::string host = String(env, hostValue);
  const std::string reference = String(env, referenceValue);
  const std::string username = String(env, usernameValue);
  const std::string token = String(env, tokenValue);
  std::string answer;
  git_repository *repository = nullptr;
  git_remote *remote = nullptr;
  do {
    if (workdir == nullptr || reference.rfind("refs/heads/", 0) != 0 || (!remote_url.empty() && host.empty()) ||
        timeoutSeconds < 1) {
      answer = Failure(3101, "arguments");
      break;
    }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure(3102, stage); break; }
    PushState state;
    state.host = host;
    state.username = username;
    state.token = token;
    state.target_ref = reference;
    state.deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeoutSeconds);
    int code = git_remote_lookup(&remote, repository, "origin");
    if (code == 0 && !remote_url.empty()) code = git_remote_set_instance_url(remote, remote_url.c_str());
    git_remote_connect_options connect_options = {};
    if (code == 0) code = git_remote_connect_options_init(&connect_options, GIT_REMOTE_CONNECT_OPTIONS_VERSION);
    if (code == 0) {
      connect_options.follow_redirects = GIT_REMOTE_REDIRECT_NONE;
      connect_options.proxy_opts.type = GIT_PROXY_NONE;
      FillCallbacks(&connect_options.callbacks, &state, !token.empty() && !username.empty());
      code = git_remote_connect_ext(remote, GIT_DIRECTION_FETCH, &connect_options);
    }
    int ls_code = 0;
    const std::string advertised = code == 0 ? AdvertisedOid(remote, reference, &ls_code) : std::string();
    if (code == 0) code = ls_code;
    if (git_remote_connected(remote)) git_remote_disconnect(remote);
    if (code != 0) {
      answer = Failure(InterruptedOutcome(state, code, 7) == 4 ? 3197 : 3199, "remote_ls");
      break;
    }
    answer = std::string("{\"ok\":true,\"oid\":") + (advertised.empty() ? "null" : Quoted(advertised)) + "}";
  } while (false);
  if (remote != nullptr) git_remote_free(remote);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return rish::Bytes(env, answer);
}

/// `refs/remotes/origin/<branch>` := `oid`, what a push just proved the
/// remote holds. Answers "ok" or "error:<stage>".
JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_setTrackingReference(JNIEnv *env, jclass, jstring gitDirValue,
                                                                     jstring workDirValue, jstring branchValue,
                                                                     jstring oidValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const std::string branch = String(env, branchValue);
  const std::string oid_hex = String(env, oidValue);
  std::string answer = "ok";
  git_repository *repository = nullptr;
  git_reference *tracking = nullptr;
  git_oid oid;
  do {
    if (workdir == nullptr || branch.empty() || oid_hex.size() != GIT_OID_SHA1_HEXSIZE) { answer = "error:arguments"; break; }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = std::string("error:") + stage; break; }
    if (git_oid_fromstr(&oid, oid_hex.c_str()) != 0) { answer = "error:oid"; break; }
    const std::string name = "refs/remotes/origin/" + branch;
    if (git_reference_create(&tracking, repository, name.c_str(), &oid, 1, "rish agent push") != 0) {
      answer = "error:reference";
      break;
    }
  } while (false);
  if (tracking != nullptr) git_reference_free(tracking);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return env->NewStringUTF(answer.c_str());
}

/// `git fetch origin`, bounded the way a push is: the credential offered
/// once and only to its host, the cancel flag checked from every callback,
/// a deadline, no redirects, no proxy. Afterwards `refs/heads/<branch>`
/// tracks `origin/<branch>` when the remote has it, so status can count
/// ahead and behind. Answers `{"ok":true,"outcome":success|auth_failure|
/// timed_out|cancelled|failed,"remote_oid":…|null,"ahead":n,"behind":n}`.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_fetch(JNIEnv *env, jclass, jstring gitDirValue,
                                                      jstring workDirValue, jstring operationValue,
                                                      jstring remoteUrlValue, jstring hostValue,
                                                      jstring branchValue, jstring usernameValue,
                                                      jstring tokenValue, jint timeoutSeconds) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const std::string operation = String(env, operationValue);
  const std::string remote_url = String(env, remoteUrlValue);
  const std::string host = String(env, hostValue);
  const std::string branch = String(env, branchValue);
  const std::string username = String(env, usernameValue);
  const std::string token = String(env, tokenValue);
  std::string answer;
  git_repository *repository = nullptr;
  git_remote *remote = nullptr;
  git_reference *local = nullptr;
  git_reference *tracking = nullptr;
  do {
    if (workdir == nullptr || operation.empty() || branch.empty() || (!remote_url.empty() && host.empty()) ||
        timeoutSeconds < 1) {
      answer = Failure(3101, "arguments");
      break;
    }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure(3102, stage); break; }
    std::atomic<bool> *cancel = RegisterCancel(operation);
    PushState state;
    state.host = host;
    state.username = username;
    state.token = token;
    state.cancel = cancel;
    state.deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeoutSeconds);
    int code = git_remote_lookup(&remote, repository, "origin");
    if (code == 0 && !remote_url.empty()) code = git_remote_set_instance_url(remote, remote_url.c_str());
    git_fetch_options options = {};
    if (code == 0) code = git_fetch_options_init(&options, GIT_FETCH_OPTIONS_VERSION);
    if (code == 0) {
      options.follow_redirects = GIT_REMOTE_REDIRECT_NONE;
      options.proxy_opts.type = GIT_PROXY_NONE;
      FillCallbacks(&options.callbacks, &state, !token.empty() && !username.empty());
      options.callbacks.transfer_progress = FetchProgress;
      code = git_remote_fetch(remote, nullptr, &options, "rish fetch");
    }
    UnregisterCancel(operation, cancel);
    if (code != 0) {
      const int outcome = InterruptedOutcome(state, code, 7);
      answer = std::string("{\"ok\":true,\"outcome\":") + Quoted(OutcomeName(outcome)) +
               ",\"remote_oid\":null,\"ahead\":0,\"behind\":0}";
      break;
    }
    // What the remote holds for this branch, and where the local branch
    // stands against it. The upstream is set the first time the remote has
    // the branch, so the panel's ahead/behind count from then on.
    std::string remote_oid;
    size_t ahead = 0;
    size_t behind = 0;
    const std::string tracking_name = "refs/remotes/origin/" + branch;
    if (git_reference_lookup(&tracking, repository, tracking_name.c_str()) == 0 && tracking != nullptr) {
      const git_oid *remote_target = git_reference_target(tracking);
      if (remote_target != nullptr) {
        char buffer[GIT_OID_SHA1_HEXSIZE + 1] = {};
        git_oid_tostr(buffer, sizeof(buffer), remote_target);
        remote_oid = buffer;
      }
      if (git_branch_lookup(&local, repository, branch.c_str(), GIT_BRANCH_LOCAL) == 0 && local != nullptr) {
        git_reference *upstream = nullptr;
        if (git_branch_upstream(&upstream, local) != 0) {
          const std::string upstream_name = "origin/" + branch;
          (void)git_branch_set_upstream(local, upstream_name.c_str());
        } else if (upstream != nullptr) {
          git_reference_free(upstream);
        }
        const git_oid *local_target = git_reference_target(local);
        if (local_target != nullptr && remote_target != nullptr) {
          git_graph_ahead_behind(&ahead, &behind, repository, local_target, remote_target);
        }
      }
    }
    answer = std::string("{\"ok\":true,\"outcome\":\"success\",\"remote_oid\":") +
             (remote_oid.empty() ? "null" : Quoted(remote_oid)) + ",\"ahead\":" + std::to_string(ahead) +
             ",\"behind\":" + std::to_string(behind) + "}";
  } while (false);
  if (tracking != nullptr) git_reference_free(tracking);
  if (local != nullptr) git_reference_free(local);
  if (remote != nullptr) git_remote_free(remote);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return rish::Bytes(env, answer);
}

/// A fast-forward of the current branch to `origin/<branch>`, and nothing
/// else: never a merge, never over changes to tracked files, never past a
/// HEAD other than `expectedHead`. Answers `{"ok":true,"outcome":updated|
/// up_to_date|diverged|dirty|no_upstream,"oid":…,"previous_oid":…}`; a
/// HEAD that is not `expectedHead` is refused with 3110.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_fastForward(JNIEnv *env, jclass, jstring gitDirValue,
                                                            jstring workDirValue, jstring expectedHeadValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const std::string expected = String(env, expectedHeadValue);
  std::string answer;
  git_repository *repository = nullptr;
  git_reference *head = nullptr;
  git_reference *tracking = nullptr;
  git_commit *commit = nullptr;
  git_status_list *list = nullptr;
  git_reference *updated = nullptr;
  do {
    if (workdir == nullptr || expected.size() != GIT_OID_SHA1_HEXSIZE) { answer = Failure(3101, "arguments"); break; }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure(3102, stage); break; }
    if (git_repository_head(&head, repository) != 0 || head == nullptr || !git_reference_is_branch(head) ||
        git_reference_target(head) == nullptr) {
      answer = Failure(3110, "head");
      break;
    }
    char previous[GIT_OID_SHA1_HEXSIZE + 1] = {};
    git_oid_tostr(previous, sizeof(previous), git_reference_target(head));
    if (expected != previous) { answer = Failure(3110, "head_changed"); break; }
    const char *shorthand = git_reference_shorthand(head);
    const std::string tracking_name = std::string("refs/remotes/origin/") + (shorthand != nullptr ? shorthand : "");
    const auto encode = [&](const char *outcome, const std::string &oid) {
      return std::string("{\"ok\":true,\"outcome\":") + Quoted(outcome) + ",\"oid\":" + Quoted(oid) +
             ",\"previous_oid\":" + Quoted(previous) + "}";
    };
    if (git_reference_lookup(&tracking, repository, tracking_name.c_str()) != 0 || tracking == nullptr ||
        git_reference_target(tracking) == nullptr) {
      answer = encode("no_upstream", previous);
      break;
    }
    const git_oid *remote_target = git_reference_target(tracking);
    char remote_hex[GIT_OID_SHA1_HEXSIZE + 1] = {};
    git_oid_tostr(remote_hex, sizeof(remote_hex), remote_target);
    size_t ahead = 0;
    size_t behind = 0;
    if (git_graph_ahead_behind(&ahead, &behind, repository, git_reference_target(head), remote_target) != 0) {
      answer = Failure(3199, "ahead_behind");
      break;
    }
    if (behind == 0) { answer = encode("up_to_date", previous); break; }
    if (ahead > 0) { answer = encode("diverged", previous); break; }
    // Changes to tracked files are the person's; a fast-forward never
    // touches them. Untracked files are left to the safe checkout, which
    // refuses to overwrite one the update would need.
    git_status_options status_options = GIT_STATUS_OPTIONS_INIT;
    status_options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
    status_options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
    if (git_status_list_new(&list, repository, &status_options) != 0) { answer = Failure(3199, "status"); break; }
    bool dirty = false;
    const size_t count = git_status_list_entrycount(list);
    for (size_t index = 0; index < count && !dirty; index += 1) {
      const git_status_entry *entry = git_status_byindex(list, index);
      if (entry != nullptr && (entry->status & ~GIT_STATUS_WT_NEW) != 0) dirty = true;
    }
    if (dirty) { answer = encode("dirty", previous); break; }
    if (git_commit_lookup(&commit, repository, remote_target) != 0) { answer = Failure(3199, "commit"); break; }
    git_checkout_options checkout = GIT_CHECKOUT_OPTIONS_INIT;
    checkout.checkout_strategy = GIT_CHECKOUT_SAFE;
    const int checked_out = git_checkout_tree(repository, reinterpret_cast<const git_object *>(commit), &checkout);
    if (checked_out == GIT_ECONFLICT) { answer = encode("dirty", previous); break; }
    if (checked_out != 0) { answer = Failure(3199, "checkout"); break; }
    if (git_reference_set_target(&updated, head, remote_target, "rish fast-forward") != 0) {
      answer = Failure(3199, "reference");
      break;
    }
    answer = encode("updated", remote_hex);
  } while (false);
  if (updated != nullptr) git_reference_free(updated);
  if (list != nullptr) git_status_list_free(list);
  if (commit != nullptr) git_commit_free(commit);
  if (tracking != nullptr) git_reference_free(tracking);
  if (head != nullptr) git_reference_free(head);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return rish::Bytes(env, answer);
}

/// Asks a running push to stop at its next callback. Answers whether a push
/// by that id was running.
JNIEXPORT jboolean JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_cancelPush(JNIEnv *env, jclass, jstring operationValue) {
  const std::string operation = String(env, operationValue);
  std::lock_guard<std::mutex> guard(g_cancel_mutex);
  auto existing = g_cancel_flags.find(operation);
  if (existing == g_cancel_flags.end()) return JNI_FALSE;
  existing->second->store(true);
  return JNI_TRUE;
}

}  // extern "C"
