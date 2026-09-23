// The JNI face of the shared merge (modules/rish/shared/git): each call
// opens the project the way this app keeps one, hands the repository to the
// shared function, and frees it. What a merge decides and writes lives
// there, once, for both hosts; see rish_project_merge.h for the contract.

#include <git2.h>
#include <jni.h>

#include <string>

#include "rish_git_support.h"
#include "rish_project_merge.h"

namespace {

using rish::Chars;
using rish::OpenRepository;
using rish::Quoted;
using rish::Release;

std::string OpenFailure(const char *stage) {
  return "{\"ok\":false,\"code\":3102,\"stage\":" + Quoted(stage) + ",\"error\":" + Quoted(rish::LastError()) + "}";
}

std::string Text(const char *value) { return value == nullptr ? std::string() : std::string(value); }

/// Opens the project and runs `operation` on it, releasing every string.
template <typename Operation>
jbyteArray WithRepository(JNIEnv *env, jstring gitDirValue, jstring workDirValue, Operation operation) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  std::string answer;
  git_repository *repository = nullptr;
  if (workdir == nullptr) {
    answer = "{\"ok\":false,\"code\":3101,\"stage\":\"arguments\",\"error\":\"\"}";
  } else {
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    answer = stage != nullptr ? OpenFailure(stage) : operation(repository);
  }
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return rish::Bytes(env, answer);
}

/// A Java string as a std::string, released before returning.
std::string Held(JNIEnv *env, jstring value) {
  const char *chars = Chars(env, value);
  std::string out = Text(chars);
  Release(env, value, chars);
  return out;
}

}  // namespace

extern "C" {

JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_mergePrepare(
    JNIEnv *env, jclass, jstring gitDirValue, jstring workDirValue, jstring branchValue,
    jstring expectedHeadValue, jstring expectedTheirsValue, jstring nameValue, jstring emailValue) {
  const std::string branch = Held(env, branchValue);
  const std::string head = Held(env, expectedHeadValue);
  const std::string theirs = Held(env, expectedTheirsValue);
  const std::string name = Held(env, nameValue);
  const std::string email = Held(env, emailValue);
  return WithRepository(env, gitDirValue, workDirValue, [&](git_repository *repository) {
    return rish::merge::Prepare(repository, branch, head, theirs, name, email);
  });
}

JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_mergeApply(
    JNIEnv *env, jclass, jstring gitDirValue, jstring workDirValue, jstring branchValue,
    jstring oursValue, jstring mergeValue) {
  const std::string branch = Held(env, branchValue);
  const std::string ours = Held(env, oursValue);
  const std::string merge = Held(env, mergeValue);
  return WithRepository(env, gitDirValue, workDirValue, [&](git_repository *repository) {
    return rish::merge::Apply(repository, branch, ours, merge);
  });
}

JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_mergeMoveRef(
    JNIEnv *env, jclass, jstring gitDirValue, jstring workDirValue, jstring branchValue,
    jstring oursValue, jstring mergeValue) {
  const std::string branch = Held(env, branchValue);
  const std::string ours = Held(env, oursValue);
  const std::string merge = Held(env, mergeValue);
  return WithRepository(env, gitDirValue, workDirValue, [&](git_repository *repository) {
    return rish::merge::MoveRef(repository, branch, ours, merge);
  });
}

JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_mergeInspect(
    JNIEnv *env, jclass, jstring gitDirValue, jstring workDirValue, jstring branchValue,
    jstring oursValue, jstring mergeValue) {
  const std::string branch = Held(env, branchValue);
  const std::string ours = Held(env, oursValue);
  const std::string merge = Held(env, mergeValue);
  return WithRepository(env, gitDirValue, workDirValue, [&](git_repository *repository) {
    return rish::merge::Inspect(repository, branch, ours, merge);
  });
}

}  // extern "C"
