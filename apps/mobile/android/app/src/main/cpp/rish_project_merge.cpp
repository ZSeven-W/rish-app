// Merging a diverged branch with its upstream, for the Git panel.
//
// Only a clean merge is ever carried out. A merge with a conflict is refused
// with the conflicting paths and nothing about the repository moves: no
// conflict markers, no MERGE_HEAD, no index or working-tree change, no ref.
// `git_merge_commits` may still leave unreferenced blobs in the object
// database, which is harmless; the promise is about refs, index, working
// tree and merge state.
//
// The work is split so the caller can journal between the part that only
// decides and the part that changes files:
//
//   mergePrepare  every precondition, the merge in memory, the merge commit
//                 object (referenced by nothing), and a dry-run checkout.
//                 Changes no ref, index or working tree.
//   mergeApply    checks the merged tree out over the recorded baseline,
//                 then moves the branch with a compare-and-swap.
//   mergeMoveRef  the compare-and-swap alone, for a recovery that finds the
//                 checkout already done.
//   mergeInspect  what the branch, the index and the working tree are now,
//                 so recovery decides from facts rather than from a phase
//                 that may have been written before its effect.
//
// Every checkout here uses GIT_CHECKOUT_DONT_OVERWRITE_IGNORED: SAFE alone
// writes over a file the person keeps out of Git.

#include <git2.h>
#include <jni.h>

#include <string>
#include <vector>

#include "rish_git_support.h"

namespace {

using rish::Chars;
using rish::Oid;
using rish::OpenRepository;
using rish::Quoted;
using rish::Release;

std::string Failure(int code, const std::string &stage) {
  return "{\"ok\":false,\"code\":" + std::to_string(code) + ",\"stage\":" + Quoted(stage) +
         ",\"error\":" + Quoted(rish::LastError()) + "}";
}

std::string Outcome(const char *outcome) {
  return std::string("{\"ok\":true,\"outcome\":") + Quoted(outcome) + "}";
}

std::string Array(const std::vector<std::string> &values) {
  std::string out = "[";
  for (size_t index = 0; index < values.size(); index += 1) {
    if (index > 0) out += ",";
    out += Quoted(values[index]);
  }
  return out + "]";
}

std::string OptionalPath(const git_index_entry *entry) {
  return entry == nullptr || entry->path == nullptr ? "null" : Quoted(entry->path);
}

bool ParseOid(git_oid *out, const std::string &hex) {
  return hex.size() == GIT_OID_SHA1_HEXSIZE && git_oid_fromstr(out, hex.c_str()) == 0;
}

/// A filter or a merge driver this merge cannot honour. A filter -- LFS is
/// the common one -- means the blob is not the file; a named merge driver
/// that libgit2 does not have is silently replaced by the text driver.
/// Either would produce a merge of something other than what the
/// repository means, so both are refused rather than approximated.
bool UnsupportedAttributes(git_repository *repository, const char *path, const git_oid *theirs) {
  const char *value = nullptr;
  git_attr_options options = GIT_ATTR_OPTIONS_INIT;
  const unsigned int sources[] = {GIT_ATTR_CHECK_INDEX_THEN_FILE,
                                  GIT_ATTR_CHECK_INDEX_ONLY | GIT_ATTR_CHECK_INCLUDE_COMMIT};
  for (unsigned int source : sources) {
    options.flags = source;
    git_oid_cpy(&options.attr_commit_id, theirs);
    if (git_attr_get_ext(&value, repository, &options, path, "filter") == 0 &&
        GIT_ATTR_IS_TRUE(value) == false && GIT_ATTR_IS_FALSE(value) == false &&
        GIT_ATTR_IS_UNSPECIFIED(value) == false) {
      return true;
    }
    if (git_attr_get_ext(&value, repository, &options, path, "merge") == 0 &&
        git_attr_value(value) == GIT_ATTR_VALUE_STRING) {
      const std::string driver(value);
      if (driver != "text" && driver != "binary" && driver != "union") return true;
    }
  }
  return false;
}

/// Whether tracked files differ from HEAD, in the index or in the working
/// tree, or the index carries a conflict. Untracked files are allowed, as
/// the fast-forward allows them; the dry-run checkout is what refuses one
/// that the merge would need to write over.
bool Dirty(git_repository *repository, bool *failed) {
  *failed = false;
  git_index *index = nullptr;
  if (git_repository_index(&index, repository) != 0) { *failed = true; return true; }
  const bool conflicted = git_index_has_conflicts(index) != 0;
  git_index_free(index);
  if (conflicted) return true;
  git_status_options options = GIT_STATUS_OPTIONS_INIT;
  options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
  options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
  git_status_list *list = nullptr;
  if (git_status_list_new(&list, repository, &options) != 0) { *failed = true; return true; }
  bool dirty = false;
  const size_t count = git_status_list_entrycount(list);
  for (size_t at = 0; at < count && !dirty; at += 1) {
    const git_status_entry *entry = git_status_byindex(list, at);
    if (entry != nullptr && (entry->status & ~GIT_STATUS_WT_NEW) != 0) dirty = true;
  }
  git_status_list_free(list);
  return dirty;
}

/// The branch HEAD names, in full, or empty when HEAD is not a born branch.
std::string HeadBranch(git_reference *head) {
  const char *name = head == nullptr ? nullptr : git_reference_name(head);
  return name == nullptr ? std::string() : std::string(name);
}

struct Obstructions {
  std::vector<std::string> paths;
};

int NotifyObstruction(git_checkout_notify_t, const char *path, const git_diff_file *,
                      const git_diff_file *, const git_diff_file *, void *payload) {
  auto *found = static_cast<Obstructions *>(payload);
  if (path != nullptr && found->paths.size() < 64) found->paths.emplace_back(path);
  return 0;
}

}  // namespace

extern "C" {

/// Every precondition, the merge in memory, the unreferenced merge commit,
/// and a dry-run checkout. Answers `{"ok":true,"outcome":…}` with one of
/// ready | up_to_date | fast_forward_available | conflicts | obstructed |
/// detached_head | unborn_head | head_changed | operation_in_progress |
/// shallow | no_upstream | upstream_changed | unrelated_histories | dirty |
/// unsupported_submodule | unsupported_filter | unsupported_paths.
/// `ready` carries merge_oid, tree_oid, ours, theirs; `conflicts` carries
/// the conflicting entries; `obstructed` the paths in the way.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_mergePrepare(
    JNIEnv *env, jclass, jstring gitDirValue, jstring workDirValue, jstring branchValue,
    jstring expectedHeadValue, jstring expectedTheirsValue, jstring nameValue, jstring emailValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const char *branch = Chars(env, branchValue);
  const char *expectedHead = Chars(env, expectedHeadValue);
  const char *expectedTheirs = Chars(env, expectedTheirsValue);
  const char *name = Chars(env, nameValue);
  const char *email = Chars(env, emailValue);
  std::string answer;
  git_repository *repository = nullptr;
  git_reference *head = nullptr;
  git_reference *tracking = nullptr;
  git_commit *ours = nullptr;
  git_commit *theirs = nullptr;
  git_tree *oursTree = nullptr;
  git_tree *theirsTree = nullptr;
  git_diff *changes = nullptr;
  git_index *merged = nullptr;
  git_tree *mergedTree = nullptr;
  git_signature *signature = nullptr;
  git_commit *mergeCommit = nullptr;
  do {
    git_oid headOid;
    git_oid theirsOid;
    if (workdir == nullptr || branch == nullptr || expectedHead == nullptr || expectedTheirs == nullptr ||
        name == nullptr || email == nullptr || !ParseOid(&headOid, expectedHead) ||
        !ParseOid(&theirsOid, expectedTheirs) || std::string(name).empty() || std::string(email).empty()) {
      answer = Failure(3101, "arguments");
      break;
    }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure(3102, stage); break; }

    // Which branch, not only which commit: two branches can point at the
    // same commit, and the person approved merging into one of them.
    const int headResult = git_repository_head(&head, repository);
    if (headResult == GIT_EUNBORNBRANCH || headResult == GIT_ENOTFOUND) { answer = Outcome("unborn_head"); break; }
    if (headResult != 0 || head == nullptr) { answer = Failure(3199, "head"); break; }
    if (git_repository_head_detached(repository) == 1 || !git_reference_is_branch(head)) {
      answer = Outcome("detached_head");
      break;
    }
    const std::string fullBranch = std::string("refs/heads/") + branch;
    const git_oid *headTarget = git_reference_target(head);
    if (HeadBranch(head) != fullBranch || headTarget == nullptr || !git_oid_equal(headTarget, &headOid)) {
      answer = Outcome("head_changed");
      break;
    }
    // A merge, rebase, cherry-pick or revert already under way: MERGE_HEAD
    // alone would miss most of them.
    if (git_repository_state(repository) != GIT_REPOSITORY_STATE_NONE) {
      answer = Outcome("operation_in_progress");
      break;
    }
    // Incomplete history can make a wrong merge base look like a right one.
    if (git_repository_is_shallow(repository) == 1) { answer = Outcome("shallow"); break; }

    // The upstream, bound to the fetch the person reviewed.
    const std::string trackingName = std::string("refs/remotes/origin/") + branch;
    if (git_reference_lookup(&tracking, repository, trackingName.c_str()) != 0 || tracking == nullptr ||
        git_reference_target(tracking) == nullptr) {
      answer = Outcome("no_upstream");
      break;
    }
    if (!git_oid_equal(git_reference_target(tracking), &theirsOid)) { answer = Outcome("upstream_changed"); break; }

    size_t ahead = 0;
    size_t behind = 0;
    if (git_graph_ahead_behind(&ahead, &behind, repository, &headOid, &theirsOid) != 0) {
      answer = Failure(3199, "ahead_behind");
      break;
    }
    if (behind == 0) { answer = Outcome("up_to_date"); break; }
    if (ahead == 0) { answer = Outcome("fast_forward_available"); break; }

    // libgit2 merges two commits with no common ancestor without complaint,
    // which would splice two unrelated projects into one.
    git_oid base;
    const int baseResult = git_merge_base(&base, repository, &headOid, &theirsOid);
    if (baseResult == GIT_ENOTFOUND) { answer = Outcome("unrelated_histories"); break; }
    if (baseResult != 0) { answer = Failure(3199, "merge_base"); break; }

    bool statusFailed = false;
    if (Dirty(repository, &statusFailed)) {
      answer = statusFailed ? Failure(3199, "status") : Outcome("dirty");
      break;
    }

    if (git_commit_lookup(&ours, repository, &headOid) != 0 ||
        git_commit_lookup(&theirs, repository, &theirsOid) != 0 ||
        git_commit_tree(&oursTree, ours) != 0 || git_commit_tree(&theirsTree, theirs) != 0) {
      answer = Failure(3199, "commits");
      break;
    }

    // What either side touched, judged before anything is merged: a
    // submodule or a filtered path is refused rather than merged as text.
    if (git_diff_tree_to_tree(&changes, repository, oursTree, theirsTree, nullptr) != 0) {
      answer = Failure(3199, "diff");
      break;
    }
    bool submodule = false;
    bool filtered = false;
    const size_t deltas = git_diff_num_deltas(changes);
    for (size_t at = 0; at < deltas && !submodule && !filtered; at += 1) {
      const git_diff_delta *delta = git_diff_get_delta(changes, at);
      if (delta == nullptr) continue;
      const git_diff_file files[] = {delta->old_file, delta->new_file};
      for (const git_diff_file &file : files) {
        if (file.mode == GIT_FILEMODE_COMMIT) submodule = true;
        if (file.path != nullptr && std::string(file.path) == ".gitmodules") submodule = true;
        if (file.path != nullptr && UnsupportedAttributes(repository, file.path, &theirsOid)) filtered = true;
      }
    }
    if (submodule) { answer = Outcome("unsupported_submodule"); break; }
    if (filtered) { answer = Outcome("unsupported_filter"); break; }

    // The merge itself, in memory.
    git_merge_options mergeOptions = GIT_MERGE_OPTIONS_INIT;
    if (git_merge_commits(&merged, repository, ours, theirs, &mergeOptions) != 0) {
      answer = Failure(3199, "merge");
      break;
    }
    if (git_index_has_conflicts(merged)) {
      git_index_conflict_iterator *iterator = nullptr;
      if (git_index_conflict_iterator_new(&iterator, merged) != 0) { answer = Failure(3199, "conflicts"); break; }
      std::string list = "[";
      const git_index_entry *ancestor = nullptr;
      const git_index_entry *mine = nullptr;
      const git_index_entry *other = nullptr;
      size_t listed = 0;
      while (listed < 64 && git_index_conflict_next(&ancestor, &mine, &other, iterator) == 0) {
        if (listed > 0) list += ",";
        list += "{\"ancestor\":" + OptionalPath(ancestor) + ",\"ours\":" + OptionalPath(mine) +
                ",\"theirs\":" + OptionalPath(other) + "}";
        listed += 1;
      }
      git_index_conflict_iterator_free(iterator);
      answer = "{\"ok\":true,\"outcome\":\"conflicts\",\"conflicts\":" + list + "]}";
      break;
    }

    // The merge commit, referenced by nothing yet. Parents in this order:
    // the person's history first, the upstream second.
    git_oid treeOid;
    if (git_index_write_tree_to(&treeOid, merged, repository) != 0 ||
        git_tree_lookup(&mergedTree, repository, &treeOid) != 0) {
      answer = Failure(3199, "write_tree");
      break;
    }
    if (git_signature_now(&signature, name, email) != 0) { answer = Failure(3199, "signature"); break; }
    const std::string message = std::string("Merge remote-tracking branch 'origin/") + branch + "'\n";
    const git_commit *parents[] = {ours, theirs};
    git_oid mergeOid;
    if (git_commit_create(&mergeOid, repository, nullptr, signature, signature, "UTF-8", message.c_str(),
                          mergedTree, 2, parents) != 0) {
      answer = Failure(3199, "commit");
      break;
    }

    // A dry run over the same baseline the real checkout will use, so an
    // untracked or ignored file in the way is found before anything is
    // written. It cannot promise the real writes will succeed; the journal
    // is what covers that.
    Obstructions obstructions;
    git_checkout_options checkout = GIT_CHECKOUT_OPTIONS_INIT;
    checkout.checkout_strategy = GIT_CHECKOUT_DRY_RUN | GIT_CHECKOUT_SAFE | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED;
    checkout.baseline = oursTree;
    checkout.notify_flags = GIT_CHECKOUT_NOTIFY_CONFLICT;
    checkout.notify_cb = NotifyObstruction;
    checkout.notify_payload = &obstructions;
    const int dryRun = git_checkout_tree(repository, reinterpret_cast<const git_object *>(mergedTree), &checkout);
    if (dryRun == GIT_ECONFLICT || !obstructions.paths.empty()) {
      answer = "{\"ok\":true,\"outcome\":\"obstructed\",\"paths\":" + Array(obstructions.paths) + "}";
      break;
    }
    if (dryRun != 0) { answer = Outcome("unsupported_paths"); break; }

    answer = "{\"ok\":true,\"outcome\":\"ready\",\"merge_oid\":" + Quoted(Oid(&mergeOid)) +
             ",\"tree_oid\":" + Quoted(Oid(&treeOid)) + ",\"ours\":" + Quoted(Oid(&headOid)) +
             ",\"theirs\":" + Quoted(Oid(&theirsOid)) + "}";
  } while (false);
  if (mergeCommit != nullptr) git_commit_free(mergeCommit);
  if (signature != nullptr) git_signature_free(signature);
  if (mergedTree != nullptr) git_tree_free(mergedTree);
  if (merged != nullptr) git_index_free(merged);
  if (changes != nullptr) git_diff_free(changes);
  if (theirsTree != nullptr) git_tree_free(theirsTree);
  if (oursTree != nullptr) git_tree_free(oursTree);
  if (theirs != nullptr) git_commit_free(theirs);
  if (ours != nullptr) git_commit_free(ours);
  if (tracking != nullptr) git_reference_free(tracking);
  if (head != nullptr) git_reference_free(head);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  Release(env, branchValue, branch);
  Release(env, expectedHeadValue, expectedHead);
  Release(env, expectedTheirsValue, expectedTheirs);
  Release(env, nameValue, name);
  Release(env, emailValue, email);
  return rish::Bytes(env, answer);
}

/// Moves the branch from `ours` to `mergeOid` if and only if it still points
/// at `ours`. Shared by apply and by a recovery that finds the checkout done.
static std::string MoveRef(git_repository *repository, const std::string &branch, const git_oid &ours,
                           const git_oid &mergeOid) {
  git_reference *head = nullptr;
  git_reference *updated = nullptr;
  std::string answer;
  do {
    const int headResult = git_repository_head(&head, repository);
    if (headResult != 0 || head == nullptr || !git_reference_is_branch(head) ||
        HeadBranch(head) != "refs/heads/" + branch || git_reference_target(head) == nullptr ||
        !git_oid_equal(git_reference_target(head), &ours)) {
      answer = Outcome("ref_changed");
      break;
    }
    // set_target on the loaded reference is itself a compare-and-swap: it
    // answers GIT_EMODIFIED if the branch moved since it was read.
    const int moved = git_reference_set_target(&updated, head, &mergeOid, "rish merge");
    if (moved == GIT_EMODIFIED) { answer = Outcome("ref_changed"); break; }
    if (moved != 0) { answer = Outcome("ref_failed"); break; }
    answer = Outcome("merged");
  } while (false);
  if (updated != nullptr) git_reference_free(updated);
  if (head != nullptr) git_reference_free(head);
  return answer;
}

/// Checks the merged tree out over the `ours` baseline, then moves the
/// branch. Answers merged | head_changed | obstructed | checkout_failed |
/// ref_changed | ref_failed. Only `head_changed` and `obstructed` are
/// guaranteed to have written nothing.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_mergeApply(
    JNIEnv *env, jclass, jstring gitDirValue, jstring workDirValue, jstring branchValue,
    jstring oursValue, jstring mergeValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const char *branch = Chars(env, branchValue);
  const char *oursHex = Chars(env, oursValue);
  const char *mergeHex = Chars(env, mergeValue);
  std::string answer;
  git_repository *repository = nullptr;
  git_reference *head = nullptr;
  git_commit *ours = nullptr;
  git_commit *merge = nullptr;
  git_tree *oursTree = nullptr;
  git_tree *mergeTree = nullptr;
  do {
    git_oid oursOid;
    git_oid mergeOid;
    if (workdir == nullptr || branch == nullptr || oursHex == nullptr || mergeHex == nullptr ||
        !ParseOid(&oursOid, oursHex) || !ParseOid(&mergeOid, mergeHex)) {
      answer = Failure(3101, "arguments");
      break;
    }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure(3102, stage); break; }
    const int headResult = git_repository_head(&head, repository);
    if (headResult != 0 || head == nullptr || !git_reference_is_branch(head) ||
        HeadBranch(head) != std::string("refs/heads/") + branch || git_reference_target(head) == nullptr ||
        !git_oid_equal(git_reference_target(head), &oursOid)) {
      answer = Outcome("head_changed");
      break;
    }
    if (git_commit_lookup(&ours, repository, &oursOid) != 0 || git_commit_lookup(&merge, repository, &mergeOid) != 0 ||
        git_commit_tree(&oursTree, ours) != 0 || git_commit_tree(&mergeTree, merge) != 0) {
      answer = Failure(3199, "commits");
      break;
    }
    git_checkout_options checkout = GIT_CHECKOUT_OPTIONS_INIT;
    checkout.checkout_strategy = GIT_CHECKOUT_SAFE | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED;
    checkout.baseline = oursTree;
    // A conflict is found in a pass before anything is written, so this one
    // outcome is safe to report as "nothing changed".
    const int checkedOut = git_checkout_tree(repository, reinterpret_cast<const git_object *>(mergeTree), &checkout);
    if (checkedOut == GIT_ECONFLICT) { answer = Outcome("obstructed"); break; }
    if (checkedOut != 0) { answer = Outcome("checkout_failed"); break; }
    answer = MoveRef(repository, branch, oursOid, mergeOid);
  } while (false);
  if (mergeTree != nullptr) git_tree_free(mergeTree);
  if (oursTree != nullptr) git_tree_free(oursTree);
  if (merge != nullptr) git_commit_free(merge);
  if (ours != nullptr) git_commit_free(ours);
  if (head != nullptr) git_reference_free(head);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  Release(env, branchValue, branch);
  Release(env, oursValue, oursHex);
  Release(env, mergeValue, mergeHex);
  return rish::Bytes(env, answer);
}

/// The compare-and-swap alone: merged | ref_changed | ref_failed.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_mergeMoveRef(
    JNIEnv *env, jclass, jstring gitDirValue, jstring workDirValue, jstring branchValue,
    jstring oursValue, jstring mergeValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const char *branch = Chars(env, branchValue);
  const char *oursHex = Chars(env, oursValue);
  const char *mergeHex = Chars(env, mergeValue);
  std::string answer;
  git_repository *repository = nullptr;
  do {
    git_oid oursOid;
    git_oid mergeOid;
    if (workdir == nullptr || branch == nullptr || oursHex == nullptr || mergeHex == nullptr ||
        !ParseOid(&oursOid, oursHex) || !ParseOid(&mergeOid, mergeHex)) {
      answer = Failure(3101, "arguments");
      break;
    }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure(3102, stage); break; }
    answer = MoveRef(repository, branch, oursOid, mergeOid);
  } while (false);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  Release(env, branchValue, branch);
  Release(env, oursValue, oursHex);
  Release(env, mergeValue, mergeHex);
  return rish::Bytes(env, answer);
}

/// What the branch, the index and the working tree are right now, measured
/// against the two trees a merge journal names. Answers
/// `{"ok":true,"head":ours|merge|other,"index":ours|merge|other,
/// "worktree_clean":bool,"conflicted":bool}`.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_mergeInspect(
    JNIEnv *env, jclass, jstring gitDirValue, jstring workDirValue, jstring branchValue,
    jstring oursValue, jstring mergeValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const char *branch = Chars(env, branchValue);
  const char *oursHex = Chars(env, oursValue);
  const char *mergeHex = Chars(env, mergeValue);
  std::string answer;
  git_repository *repository = nullptr;
  git_reference *head = nullptr;
  git_index *index = nullptr;
  git_commit *ours = nullptr;
  git_commit *merge = nullptr;
  git_status_list *list = nullptr;
  do {
    git_oid oursOid;
    git_oid mergeOid;
    if (workdir == nullptr || branch == nullptr || oursHex == nullptr || mergeHex == nullptr ||
        !ParseOid(&oursOid, oursHex) || !ParseOid(&mergeOid, mergeHex)) {
      answer = Failure(3101, "arguments");
      break;
    }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure(3102, stage); break; }
    const char *headState = "other";
    if (git_repository_head(&head, repository) == 0 && head != nullptr && git_reference_is_branch(head) &&
        HeadBranch(head) == std::string("refs/heads/") + branch && git_reference_target(head) != nullptr) {
      if (git_oid_equal(git_reference_target(head), &oursOid)) headState = "ours";
      else if (git_oid_equal(git_reference_target(head), &mergeOid)) headState = "merge";
    }
    if (git_commit_lookup(&ours, repository, &oursOid) != 0 || git_commit_lookup(&merge, repository, &mergeOid) != 0 ||
        git_repository_index(&index, repository) != 0) {
      answer = Failure(3199, "lookup");
      break;
    }
    const bool conflicted = git_index_has_conflicts(index) != 0;
    const char *indexState = "other";
    git_oid indexTree;
    if (!conflicted && git_index_write_tree(&indexTree, index) == 0) {
      if (git_oid_equal(&indexTree, git_commit_tree_id(ours))) indexState = "ours";
      else if (git_oid_equal(&indexTree, git_commit_tree_id(merge))) indexState = "merge";
    }
    // The working tree against the index: tracked changes only.
    git_status_options options = GIT_STATUS_OPTIONS_INIT;
    options.show = GIT_STATUS_SHOW_WORKDIR_ONLY;
    if (git_status_list_new(&list, repository, &options) != 0) { answer = Failure(3199, "status"); break; }
    bool clean = true;
    const size_t count = git_status_list_entrycount(list);
    for (size_t at = 0; at < count && clean; at += 1) {
      const git_status_entry *entry = git_status_byindex(list, at);
      if (entry != nullptr && (entry->status & ~GIT_STATUS_WT_NEW) != 0) clean = false;
    }
    answer = std::string("{\"ok\":true,\"head\":") + Quoted(headState) + ",\"index\":" + Quoted(indexState) +
             ",\"worktree_clean\":" + (clean ? "true" : "false") + ",\"conflicted\":" +
             (conflicted ? "true" : "false") + "}";
  } while (false);
  if (list != nullptr) git_status_list_free(list);
  if (merge != nullptr) git_commit_free(merge);
  if (ours != nullptr) git_commit_free(ours);
  if (index != nullptr) git_index_free(index);
  if (head != nullptr) git_reference_free(head);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  Release(env, branchValue, branch);
  Release(env, oursValue, oursHex);
  Release(env, mergeValue, mergeHex);
  return rish::Bytes(env, answer);
}

}  // extern "C"
