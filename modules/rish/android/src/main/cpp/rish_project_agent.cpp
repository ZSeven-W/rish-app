// What the agent's Git tools ask of libgit2: where HEAD points, a status
// summary, the tree a stage-all would commit, and the commit itself -- made
// only if it comes out with the id the approved precondition predicted.
//
// Mirrors AgentGitToolSupport.mm and the commit half of
// AgentGitToolExecutor.mm. The prediction is the core's (`commit_identity`);
// what this file adds is the libgit2 half, in the same order iOS does it, so
// that a crash between "the object was written" and "the ledger recorded it"
// leaves exactly the id recovery looks for.

#include <jni.h>

#include <string>

#include <git2.h>

#include "rish_git_support.h"

namespace {

using rish::Bytes;
using rish::Chars;
using rish::LastError;
using rish::Oid;
using rish::OpenRepository;
using rish::Quoted;
using rish::Release;
using rish::ValidUtf8;

std::string Failure(const char *code, const char *stage) {
  return std::string("{\"ok\":false,\"failure\":") + Quoted(code) + ",\"stage\":" + Quoted(stage) +
         ",\"error\":" + Quoted(LastError()) + "}";
}

/// `DSHAgentGitBranchReference`: HEAD as a branch, or nothing.
bool BranchReference(git_repository *repository, std::string *reference, std::string *branch, std::string *oid) {
  git_reference *head = nullptr;
  if (git_repository_head(&head, repository) != 0 || git_reference_target(head) == nullptr) {
    if (head != nullptr) git_reference_free(head);
    return false;
  }
  const char *name = git_reference_name(head);
  const char *shorthand = git_reference_shorthand(head);
  std::string full = name == nullptr ? "" : name;
  std::string shorter = shorthand == nullptr ? "" : shorthand;
  std::string target = Oid(git_reference_target(head));
  git_reference_free(head);
  if (full.rfind("refs/heads/", 0) != 0 || shorter.empty()) return false;
  if (reference != nullptr) *reference = full;
  if (branch != nullptr) *branch = shorter;
  if (oid != nullptr) *oid = target;
  return true;
}

/// `DSHAgentGitHeadReferenceName`: the branch HEAD is on, born or not.
std::string HeadReferenceName(git_repository *repository) {
  std::string reference;
  if (BranchReference(repository, &reference, nullptr, nullptr)) return reference;
  git_reference *head = nullptr;
  if (git_reference_lookup(&head, repository, "HEAD") != 0) return "";
  const char *symbolic = git_reference_symbolic_target(head);
  std::string value = symbolic == nullptr ? "" : symbolic;
  git_reference_free(head);
  return value.rfind("refs/heads/", 0) == 0 ? value : "";
}

/// `DSHAgentGitStageAll`: the index with everything added and updated, and
/// the tree it would commit. Nothing is written unless the caller writes it.
git_index *StageAll(git_repository *repository, git_oid *tree, std::string *entries_json) {
  git_index *index = nullptr;
  if (git_repository_index(&index, repository) != 0 || git_index_read(index, 1) != 0 ||
      git_index_add_all(index, nullptr, GIT_INDEX_ADD_DEFAULT, nullptr, nullptr) != 0 ||
      git_index_update_all(index, nullptr, nullptr, nullptr) != 0 ||
      git_index_write_tree_to(tree, index, repository) != 0) {
    if (index != nullptr) git_index_free(index);
    return nullptr;
  }
  if (entries_json != nullptr) {
    std::string rows = "[";
    const size_t count = git_index_entrycount(index);
    for (size_t item = 0; item < count; item += 1) {
      const git_index_entry *entry = git_index_get_byindex(index, item);
      if (entry == nullptr || entry->path == nullptr || !ValidUtf8(entry->path)) {
        git_index_free(index);
        return nullptr;
      }
      if (item > 0) rows += ",";
      rows += "{\"path\":" + Quoted(entry->path) + ",\"mode\":" + std::to_string(entry->mode) +
              ",\"oid\":" + Quoted(Oid(&entry->id)) + ",\"stage\":" + std::to_string(git_index_entry_stage(entry)) + "}";
    }
    *entries_json = rows + "]";
  }
  return index;
}

}  // namespace

extern "C" {

/// `{ok, reference|null, branch|null, head_oid|null, head_reference_name|null}`.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_agentBranch(JNIEnv *env, jclass, jstring gitDirValue,
                                                            jstring workDirValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  git_repository *repository = nullptr;
  std::string answer;
  const char *stage = workdir == nullptr ? "path" : OpenRepository(&repository, gitdir, workdir);
  if (stage != nullptr) {
    answer = Failure("unavailable", stage);
  } else {
    std::string reference, branch, oid;
    const bool born = BranchReference(repository, &reference, &branch, &oid);
    const std::string head_name = HeadReferenceName(repository);
    answer = "{\"ok\":true,\"reference\":" + (born ? Quoted(reference) : std::string("null")) +
             ",\"branch\":" + (born ? Quoted(branch) : std::string("null")) +
             ",\"head_oid\":" + (born ? Quoted(oid) : std::string("null")) +
             ",\"head_reference_name\":" + (head_name.empty() ? std::string("null") : Quoted(head_name)) + "}";
  }
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return Bytes(env, answer);
}

/// `DSHAgentGitStatus`: the summary the agent is shown.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_agentStatus(JNIEnv *env, jclass, jstring gitDirValue,
                                                            jstring workDirValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  git_repository *repository = nullptr;
  git_status_list *list = nullptr;
  std::string answer;
  do {
    const char *stage = workdir == nullptr ? "path" : OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure("unavailable", stage); break; }
    git_status_options options = GIT_STATUS_OPTIONS_INIT;
    options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
    options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS |
                    GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX | GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR;
    if (git_status_list_new(&list, repository, &options) != 0) { answer = Failure("unavailable", "status"); break; }
    const size_t count = git_status_list_entrycount(list);
    bool conflicts = false;
    for (size_t index = 0; index < count; index += 1) {
      const git_status_entry *entry = git_status_byindex(list, index);
      if (entry != nullptr && (entry->status & GIT_STATUS_CONFLICTED) != 0) conflicts = true;
    }
    std::string branch, oid;
    const bool born = BranchReference(repository, nullptr, &branch, &oid);
    answer = "{\"ok\":true,\"branch\":" + (born ? Quoted(branch) : std::string("null")) +
             ",\"head_oid\":" + (born ? Quoted(oid) : std::string("null")) +
             std::string(",\"clean\":") + (count == 0 ? "true" : "false") +
             std::string(",\"has_conflicts\":") + (conflicts ? "true" : "false") +
             ",\"entry_count\":" + std::to_string(count) + "}";
  } while (false);
  if (list != nullptr) git_status_list_free(list);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return Bytes(env, answer);
}

/// The tree a stage-all would commit and the index rows its digest is taken
/// over. Nothing is written.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_agentStage(JNIEnv *env, jclass, jstring gitDirValue,
                                                           jstring workDirValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  git_repository *repository = nullptr;
  git_index *index = nullptr;
  std::string answer;
  do {
    const char *stage = workdir == nullptr ? "path" : OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure("unavailable", stage); break; }
    git_oid tree;
    std::string entries;
    index = StageAll(repository, &tree, &entries);
    if (index == nullptr) { answer = Failure("unavailable", "stage"); break; }
    answer = "{\"ok\":true,\"tree_oid\":" + Quoted(Oid(&tree)) + ",\"entries\":" + entries + "}";
  } while (false);
  if (index != nullptr) git_index_free(index);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return Bytes(env, answer);
}

/// The commit, made the way iOS makes it: staged again, the tree required
/// to be the predicted one, the object written without touching HEAD, its
/// id required to be the predicted one, then HEAD moved from exactly the
/// expected old id and the index written. `{ok, commit_oid, tree_oid}` or
/// `{ok:false, failure:"conflict"|"tool_failed"|"ambiguous"}`.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_agentCommit(JNIEnv *env, jclass, jstring gitDirValue,
                                                            jstring workDirValue, jstring messageValue,
                                                            jlong timestampSeconds, jint timezoneMinutes,
                                                            jstring expectedHeadValue, jstring expectedTreeValue,
                                                            jstring expectedCommitValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const char *message = Chars(env, messageValue);
  const char *expected_head = Chars(env, expectedHeadValue);
  const char *expected_tree = Chars(env, expectedTreeValue);
  const char *expected_commit = Chars(env, expectedCommitValue);
  git_repository *repository = nullptr;
  git_index *index = nullptr;
  git_signature *signature = nullptr;
  git_commit *parent = nullptr;
  git_tree *tree = nullptr;
  git_reference *updated = nullptr;
  std::string answer;
  do {
    if (workdir == nullptr || message == nullptr || expected_tree == nullptr || expected_commit == nullptr) {
      answer = Failure("tool_failed", "arguments");
      break;
    }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure("tool_failed", stage); break; }
    const std::string head_reference = HeadReferenceName(repository);
    git_oid tree_id;
    index = StageAll(repository, &tree_id, nullptr);
    if (index == nullptr) { answer = Failure("tool_failed", "stage"); break; }
    if (Oid(&tree_id) != expected_tree) { answer = Failure("conflict", "tree"); break; }
    if (git_signature_new(&signature, "Rish Agent", "agent@rish.local", static_cast<git_time_t>(timestampSeconds),
                          static_cast<int>(timezoneMinutes)) != 0) {
      answer = Failure("tool_failed", "signature");
      break;
    }
    git_oid parent_id;
    if (expected_head != nullptr && *expected_head != '\0') {
      if (git_oid_fromstr(&parent_id, expected_head) != 0 || git_commit_lookup(&parent, repository, &parent_id) != 0) {
        answer = Failure("tool_failed", "parent");
        break;
      }
    }
    if (git_tree_lookup(&tree, repository, &tree_id) != 0) { answer = Failure("tool_failed", "tree_lookup"); break; }
    git_oid commit_id;
    const git_commit *parents[] = {parent};
    if (git_commit_create(&commit_id, repository, nullptr, signature, signature, "UTF-8", message, tree,
                          parent == nullptr ? 0 : 1, parent == nullptr ? nullptr : parents) != 0) {
      answer = Failure("tool_failed", "commit");
      break;
    }
    const std::string commit_hex = Oid(&commit_id);
    if (commit_hex != expected_commit) { answer = Failure("ambiguous", "commit_oid"); break; }
    if (head_reference.empty()) { answer = Failure("conflict", "head_reference"); break; }
    git_oid absent;
    memset(&absent, 0, sizeof(absent));
    const git_oid *expected_old = parent == nullptr ? &absent : &parent_id;
    if (git_reference_create_matching(&updated, repository, head_reference.c_str(), &commit_id, 1, expected_old,
                                      "rish agent commit") != 0) {
      answer = Failure("conflict", "reference");
      break;
    }
    if (git_index_write(index) != 0) { answer = Failure("ambiguous", "index_write"); break; }
    answer = "{\"ok\":true,\"commit_oid\":" + Quoted(commit_hex) + ",\"tree_oid\":" + Quoted(Oid(&tree_id)) + "}";
  } while (false);
  if (updated != nullptr) git_reference_free(updated);
  if (tree != nullptr) git_tree_free(tree);
  if (parent != nullptr) git_commit_free(parent);
  if (signature != nullptr) git_signature_free(signature);
  if (index != nullptr) git_index_free(index);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  Release(env, messageValue, message);
  Release(env, expectedHeadValue, expected_head);
  Release(env, expectedTreeValue, expected_tree);
  Release(env, expectedCommitValue, expected_commit);
  return Bytes(env, answer);
}

}  // extern "C"
