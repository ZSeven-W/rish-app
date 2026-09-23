// See rish_project_merge.h. Compiled by the Android CMake build and included
// by modules/rish/ios/Sources/LocalProjectsModule.mm, so it keeps to
// libgit2 and the C++ standard library and defines nothing outside
// rish::merge.

#include "rish_project_merge.h"

#include <cstdio>
#include <string>
#include <vector>

namespace rish {
namespace merge {
namespace detail {

inline std::string LastError() {
  const git_error *error = git_error_last();
  return error != nullptr && error->message != nullptr ? error->message : "";
}

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

inline std::string Hex(const git_oid *id) {
  char hex[GIT_OID_SHA1_HEXSIZE + 1];
  git_oid_tostr(hex, sizeof(hex), id);
  return std::string(hex);
}

inline std::string Failure(int code, const std::string &stage) {
  return "{\"ok\":false,\"code\":" + std::to_string(code) + ",\"stage\":" + Quoted(stage) +
         ",\"error\":" + Quoted(LastError()) + "}";
}

inline std::string Outcome(const char *outcome) {
  return std::string("{\"ok\":true,\"outcome\":") + Quoted(outcome) + "}";
}

inline std::string Array(const std::vector<std::string> &values) {
  std::string out = "[";
  for (size_t index = 0; index < values.size(); index += 1) {
    if (index > 0) out += ",";
    out += Quoted(values[index]);
  }
  return out + "]";
}

inline std::string OptionalPath(const git_index_entry *entry) {
  return entry == nullptr || entry->path == nullptr ? "null" : Quoted(entry->path);
}

inline bool ParseOid(git_oid *out, const std::string &hex) {
  return hex.size() == GIT_OID_SHA1_HEXSIZE && git_oid_fromstr(out, hex.c_str()) == 0;
}

/// A filter or a merge driver this merge cannot honour. A filter -- LFS is
/// the common one -- means the blob is not the file; a named merge driver
/// that libgit2 does not have is silently replaced by the text driver.
/// Either would produce a merge of something other than what the
/// repository means, so both are refused rather than approximated.
inline bool UnsupportedAttributes(git_repository *repository, const char *path, const git_oid *theirs) {
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

/// The repository's index as it is on disk now. A host that keeps one
/// repository handle open (iOS holds it for the whole lease) would
/// otherwise judge from an in-memory index a failed write left behind.
inline int FreshIndex(git_index **out, git_repository *repository) {
  const int opened = git_repository_index(out, repository);
  if (opened != 0) return opened;
  const int read = git_index_read(*out, 1);
  if (read != 0) {
    git_index_free(*out);
    *out = nullptr;
  }
  return read;
}

/// Whether tracked files differ from HEAD, in the index or in the working
/// tree, or the index carries a conflict. Untracked files are allowed, as
/// the fast-forward allows them; the dry-run checkout is what refuses one
/// that the merge would need to write over.
inline bool Dirty(git_repository *repository, bool *failed) {
  *failed = false;
  git_index *index = nullptr;
  if (FreshIndex(&index, repository) != 0) { *failed = true; return true; }
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
inline std::string HeadBranch(git_reference *head) {
  const char *name = head == nullptr ? nullptr : git_reference_name(head);
  return name == nullptr ? std::string() : std::string(name);
}

/// Whether HEAD is the named branch and points at `expected`.
inline bool HeadIs(git_repository *repository, const std::string &branch, const git_oid &expected) {
  git_reference *head = nullptr;
  const bool same = git_repository_head(&head, repository) == 0 && head != nullptr &&
                    git_reference_is_branch(head) && HeadBranch(head) == "refs/heads/" + branch &&
                    git_reference_target(head) != nullptr && git_oid_equal(git_reference_target(head), &expected);
  if (head != nullptr) git_reference_free(head);
  return same;
}

struct Obstructions {
  std::vector<std::string> paths;
};

inline int NotifyObstruction(git_checkout_notify_t, const char *path, const git_diff_file *, const git_diff_file *,
                             const git_diff_file *, void *payload) {
  auto *found = static_cast<Obstructions *>(payload);
  if (path != nullptr && found->paths.size() < 64) found->paths.emplace_back(path);
  return 0;
}

}  // namespace detail

std::string Prepare(git_repository *repository, const std::string &branch, const std::string &expectedHead,
                    const std::string &expectedTheirs, const std::string &name, const std::string &email) {
  using namespace detail;
  std::string answer;
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
  do {
    git_oid headOid;
    git_oid theirsOid;
    if (repository == nullptr || branch.empty() || !ParseOid(&headOid, expectedHead) ||
        !ParseOid(&theirsOid, expectedTheirs) || name.empty() || email.empty()) {
      answer = Failure(3101, "arguments");
      break;
    }

    // Which branch, not only which commit: two branches can point at the
    // same commit, and the person approved merging into one of them.
    const int headResult = git_repository_head(&head, repository);
    if (headResult == GIT_EUNBORNBRANCH || headResult == GIT_ENOTFOUND) { answer = Outcome("unborn_head"); break; }
    if (headResult != 0 || head == nullptr) { answer = Failure(3199, "head"); break; }
    if (git_repository_head_detached(repository) == 1 || !git_reference_is_branch(head)) {
      answer = Outcome("detached_head");
      break;
    }
    const git_oid *headTarget = git_reference_target(head);
    if (HeadBranch(head) != "refs/heads/" + branch || headTarget == nullptr || !git_oid_equal(headTarget, &headOid)) {
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
    const std::string trackingName = "refs/remotes/origin/" + branch;
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

    if (git_commit_lookup(&ours, repository, &headOid) != 0 || git_commit_lookup(&theirs, repository, &theirsOid) != 0 ||
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
    if (git_signature_now(&signature, name.c_str(), email.c_str()) != 0) { answer = Failure(3199, "signature"); break; }
    const std::string message = "Merge remote-tracking branch 'origin/" + branch + "'\n";
    const git_commit *parents[] = {ours, theirs};
    git_oid mergeOid;
    if (git_commit_create(&mergeOid, repository, nullptr, signature, signature, "UTF-8", message.c_str(), mergedTree,
                          2, parents) != 0) {
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

    answer = "{\"ok\":true,\"outcome\":\"ready\",\"merge_oid\":" + Quoted(Hex(&mergeOid)) +
             ",\"tree_oid\":" + Quoted(Hex(&treeOid)) + ",\"ours\":" + Quoted(Hex(&headOid)) +
             ",\"theirs\":" + Quoted(Hex(&theirsOid)) + "}";
  } while (false);
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
  return answer;
}

std::string MoveRef(git_repository *repository, const std::string &branch, const std::string &oursHex,
                    const std::string &mergeHex) {
  using namespace detail;
  git_oid ours;
  git_oid merge;
  if (repository == nullptr || branch.empty() || !ParseOid(&ours, oursHex) || !ParseOid(&merge, mergeHex)) {
    return Failure(3101, "arguments");
  }
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
    const int moved = git_reference_set_target(&updated, head, &merge, "rish merge");
    if (moved == GIT_EMODIFIED) { answer = Outcome("ref_changed"); break; }
    if (moved != 0) { answer = Outcome("ref_failed"); break; }
    answer = Outcome("merged");
  } while (false);
  if (updated != nullptr) git_reference_free(updated);
  if (head != nullptr) git_reference_free(head);
  return answer;
}

std::string Apply(git_repository *repository, const std::string &branch, const std::string &oursHex,
                  const std::string &mergeHex) {
  using namespace detail;
  git_oid oursOid;
  git_oid mergeOid;
  if (repository == nullptr || branch.empty() || !ParseOid(&oursOid, oursHex) || !ParseOid(&mergeOid, mergeHex)) {
    return Failure(3101, "arguments");
  }
  std::string answer;
  git_index *index = nullptr;
  git_commit *ours = nullptr;
  git_commit *merge = nullptr;
  git_tree *oursTree = nullptr;
  git_tree *mergeTree = nullptr;
  do {
    if (!HeadIs(repository, branch, oursOid)) { answer = Outcome("head_changed"); break; }
    if (git_commit_lookup(&ours, repository, &oursOid) != 0 || git_commit_lookup(&merge, repository, &mergeOid) != 0 ||
        git_commit_tree(&oursTree, ours) != 0 || git_commit_tree(&mergeTree, merge) != 0) {
      answer = Failure(3199, "commits");
      break;
    }
    // The checkout below compares against the repository's index; make that
    // the one on disk, not whatever a long-lived handle remembers.
    if (FreshIndex(&index, repository) != 0) { answer = Failure(3199, "index"); break; }
    git_checkout_options checkout = GIT_CHECKOUT_OPTIONS_INIT;
    checkout.checkout_strategy = GIT_CHECKOUT_SAFE | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED;
    checkout.baseline = oursTree;
    // A conflict is found in a pass before anything is written, so this one
    // outcome is safe to report as "nothing changed".
    const int checkedOut = git_checkout_tree(repository, reinterpret_cast<const git_object *>(mergeTree), &checkout);
    if (checkedOut == GIT_ECONFLICT) { answer = Outcome("obstructed"); break; }
    if (checkedOut != 0) { answer = Outcome("checkout_failed"); break; }
    answer = MoveRef(repository, branch, oursHex, mergeHex);
  } while (false);
  if (mergeTree != nullptr) git_tree_free(mergeTree);
  if (oursTree != nullptr) git_tree_free(oursTree);
  if (merge != nullptr) git_commit_free(merge);
  if (ours != nullptr) git_commit_free(ours);
  if (index != nullptr) git_index_free(index);
  return answer;
}

std::string Inspect(git_repository *repository, const std::string &branch, const std::string &oursHex,
                    const std::string &mergeHex) {
  using namespace detail;
  git_oid oursOid;
  git_oid mergeOid;
  if (repository == nullptr || branch.empty() || !ParseOid(&oursOid, oursHex) || !ParseOid(&mergeOid, mergeHex)) {
    return Failure(3101, "arguments");
  }
  std::string answer;
  git_reference *head = nullptr;
  git_index *index = nullptr;
  git_commit *ours = nullptr;
  git_commit *merge = nullptr;
  git_status_list *list = nullptr;
  do {
    const char *headState = "other";
    if (git_repository_head(&head, repository) == 0 && head != nullptr && git_reference_is_branch(head) &&
        HeadBranch(head) == "refs/heads/" + branch && git_reference_target(head) != nullptr) {
      if (git_oid_equal(git_reference_target(head), &oursOid)) headState = "ours";
      else if (git_oid_equal(git_reference_target(head), &mergeOid)) headState = "merge";
    }
    if (git_commit_lookup(&ours, repository, &oursOid) != 0 || git_commit_lookup(&merge, repository, &mergeOid) != 0 ||
        FreshIndex(&index, repository) != 0) {
      answer = Failure(3199, "lookup");
      break;
    }
    const bool conflicted = git_index_has_conflicts(index) != 0;
    bool indexOurs = false;
    bool indexMerge = false;
    git_oid indexTree;
    if (!conflicted && git_index_write_tree(&indexTree, index) == 0) {
      indexOurs = git_oid_equal(&indexTree, git_commit_tree_id(ours)) != 0;
      indexMerge = git_oid_equal(&indexTree, git_commit_tree_id(merge)) != 0;
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
    answer = std::string("{\"ok\":true,\"head\":") + Quoted(headState) +
             ",\"index_ours\":" + (indexOurs ? "true" : "false") +
             ",\"index_merge\":" + (indexMerge ? "true" : "false") +
             ",\"worktree_clean\":" + (clean ? "true" : "false") +
             ",\"conflicted\":" + (conflicted ? "true" : "false") + "}";
  } while (false);
  if (list != nullptr) git_status_list_free(list);
  if (merge != nullptr) git_commit_free(merge);
  if (ours != nullptr) git_commit_free(ours);
  if (index != nullptr) git_index_free(index);
  if (head != nullptr) git_reference_free(head);
  return answer;
}

}  // namespace merge
}  // namespace rish
