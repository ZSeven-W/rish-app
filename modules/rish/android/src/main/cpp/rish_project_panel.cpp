// The git panel's four local operations over a workspace's project: status,
// diff, stage everything, commit.
//
// Each is iOS's `LocalProjectsModule` operation of the same name, with the
// same libgit2 options, the same status vocabulary, the same limits and the
// same error numbers, because JavaScript reads both hosts' answers with one
// validator. What is decided here is only what git reports; whether the
// root may be asked at all is decided in Kotlin, before this is called.
//
// Answers are JSON as UTF-8 bytes. A failure is
// `{"ok":false,"number":<iOS error number>,"stage":"...","error":"..."}`.

#include <jni.h>

#include <string>
#include <vector>

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
using rish::SafeRepositoryPath;
using rish::Utf8Prefix;
using rish::ValidUtf8;

constexpr size_t kMaxStatusEntries = 10000;
constexpr size_t kMaxDiffFiles = 1000;
constexpr size_t kMaxDiffBytes = 1024 * 1024;
constexpr size_t kMaxDiffFileBytes = 4 * 1024 * 1024;

std::string Failure(int number, const char *stage) {
  return "{\"ok\":false,\"number\":" + std::to_string(number) + ",\"stage\":" + Quoted(stage) +
         ",\"error\":" + Quoted(LastError()) + "}";
}

/// `LPStatusName`: one word per side, and a conflict reads as modified on both.
const char *StatusName(unsigned int status, bool index) {
  if (status & GIT_STATUS_CONFLICTED) return "modified";
  if (index) {
    if (status & GIT_STATUS_INDEX_NEW) return "added";
    if (status & GIT_STATUS_INDEX_MODIFIED) return "modified";
    if (status & GIT_STATUS_INDEX_DELETED) return "deleted";
    if (status & GIT_STATUS_INDEX_RENAMED) return "renamed";
    if (status & GIT_STATUS_INDEX_TYPECHANGE) return "typechange";
  } else {
    if (status & GIT_STATUS_WT_NEW) return "added";
    if (status & GIT_STATUS_WT_MODIFIED) return "modified";
    if (status & GIT_STATUS_WT_DELETED) return "deleted";
    if (status & GIT_STATUS_WT_RENAMED) return "renamed";
    if (status & GIT_STATUS_WT_TYPECHANGE) return "typechange";
    if (status & GIT_STATUS_WT_UNREADABLE) return "unreadable";
  }
  return "unmodified";
}

/// `LPDiffStatusName`.
const char *DeltaName(git_delta_t status) {
  switch (status) {
    case GIT_DELTA_ADDED:
    case GIT_DELTA_UNTRACKED: return "added";
    case GIT_DELTA_DELETED: return "deleted";
    case GIT_DELTA_RENAMED:
    case GIT_DELTA_COPIED: return "renamed";
    case GIT_DELTA_TYPECHANGE: return "typechange";
    case GIT_DELTA_UNREADABLE: return "unreadable";
    case GIT_DELTA_UNMODIFIED: return "unmodified";
    default: return "modified";
  }
}

/// `LPPathForStatusEntry`: the path on the workdir side first, then the index side.
const char *StatusPath(const git_status_entry *entry) {
  const char *path = nullptr;
  if (entry->index_to_workdir != nullptr) {
    path = entry->index_to_workdir->new_file.path != nullptr ? entry->index_to_workdir->new_file.path
                                                              : entry->index_to_workdir->old_file.path;
  }
  if (path == nullptr && entry->head_to_index != nullptr) {
    path = entry->head_to_index->new_file.path != nullptr ? entry->head_to_index->new_file.path
                                                           : entry->head_to_index->old_file.path;
  }
  return path;
}

/// HEAD's tree, or an unborn-branch code. `LPHeadTree`.
int HeadTree(git_tree **out, git_repository *repository) {
  git_reference *head = nullptr;
  int result = git_repository_head(&head, repository);
  if (result != 0) return result;
  git_commit *commit = nullptr;
  const git_oid *target = git_reference_target(head);
  result = target == nullptr ? -1 : git_commit_lookup(&commit, repository, target);
  if (result == 0) result = git_commit_tree(out, commit);
  if (commit != nullptr) git_commit_free(commit);
  git_reference_free(head);
  return result;
}

/// `statusForRepository`.
std::string Status(git_repository *repository) {
  git_status_options options = GIT_STATUS_OPTIONS_INIT;
  options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
  options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS |
                  GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX | GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR |
                  GIT_STATUS_OPT_SORT_CASE_SENSITIVELY;
  git_status_list *list = nullptr;
  if (git_status_list_new(&list, repository, &options) < 0) return Failure(3019, "status");
  const size_t count = git_status_list_entrycount(list);
  if (count > kMaxStatusEntries) {
    git_status_list_free(list);
    return Failure(3020, "too_many_entries");
  }
  std::string entries = "[";
  bool conflicts = false;
  for (size_t index = 0; index < count; index += 1) {
    const git_status_entry *entry = git_status_byindex(list, index);
    const char *raw = entry == nullptr ? nullptr : StatusPath(entry);
    if (raw == nullptr || !SafeRepositoryPath(raw)) {
      git_status_list_free(list);
      return Failure(3021, "unsafe_path");
    }
    const bool conflicted = (entry->status & GIT_STATUS_CONFLICTED) != 0;
    conflicts = conflicts || conflicted;
    if (index > 0) entries += ",";
    entries += "{\"path\":" + Quoted(raw) + ",\"index_status\":" + Quoted(StatusName(entry->status, true)) +
               ",\"worktree_status\":" + Quoted(StatusName(entry->status, false)) +
               ",\"conflicted\":" + (conflicted ? "true" : "false") + "}";
  }
  entries += "]";
  git_status_list_free(list);

  std::string branch;
  std::string head_oid;
  size_t ahead = 0;
  size_t behind = 0;
  git_reference *head = nullptr;
  const int head_result = git_repository_head(&head, repository);
  if (head_result == 0 && head != nullptr) {
    const git_oid *target = git_reference_target(head);
    if (target != nullptr) head_oid = Oid(target);
    if (git_reference_is_branch(head)) {
      const char *shorthand = git_reference_shorthand(head);
      if (shorthand != nullptr) branch = shorthand;
      git_reference *upstream = nullptr;
      if (git_branch_upstream(&upstream, head) == 0 && upstream != nullptr) {
        const git_oid *upstream_target = git_reference_target(upstream);
        if (target != nullptr && upstream_target != nullptr) {
          git_graph_ahead_behind(&ahead, &behind, repository, target, upstream_target);
        }
        git_reference_free(upstream);
      }
    }
  } else if (head_result == GIT_EUNBORNBRANCH) {
    // No commit yet, but HEAD still names the branch the first one will be on.
    git_reference *symbolic = nullptr;
    if (git_reference_lookup(&symbolic, repository, "HEAD") == 0 && symbolic != nullptr) {
      const char *target = git_reference_symbolic_target(symbolic);
      if (target != nullptr && std::string(target).rfind("refs/heads/", 0) == 0) branch = target + 11;
      git_reference_free(symbolic);
    }
  }
  if (head != nullptr) git_reference_free(head);
  if (!branch.empty() && (!SafeRepositoryPath(branch) || branch.find("..") != std::string::npos ||
                          branch.find(' ') != std::string::npos)) {
    return Failure(3022, "unsafe_branch");
  }
  std::string out = "{\"ok\":true,\"branch\":";
  out += branch.empty() ? "null" : Quoted(branch);
  out += ",\"head_oid\":";
  out += head_oid.empty() ? "null" : Quoted(head_oid);
  out += std::string(",\"clean\":") + (count == 0 ? "true" : "false");
  out += std::string(",\"has_conflicts\":") + (conflicts ? "true" : "false");
  out += ",\"ahead\":" + std::to_string(ahead) + ",\"behind\":" + std::to_string(behind);
  out += ",\"entries\":" + entries + "}";
  return out;
}

/// `diffForRepository`, the unpaged shape: every file's stats, and as much
/// of the patch text as fits in a mebibyte, cut on a character boundary.
std::string Diff(git_repository *repository, bool staged, unsigned int context_lines) {
  git_diff_options options = GIT_DIFF_OPTIONS_INIT;
  options.context_lines = context_lines;
  options.max_size = kMaxDiffFileBytes;
  options.flags = GIT_DIFF_INCLUDE_TYPECHANGE | GIT_DIFF_INCLUDE_TYPECHANGE_TREES;
  if (!staged) {
    options.flags |= GIT_DIFF_INCLUDE_UNTRACKED | GIT_DIFF_RECURSE_UNTRACKED_DIRS |
                     GIT_DIFF_SHOW_UNTRACKED_CONTENT;
  }
  git_index *index = nullptr;
  if (git_repository_index(&index, repository) < 0 || index == nullptr) return Failure(3023, "index");
  git_tree *head_tree = nullptr;
  const int head_result = HeadTree(&head_tree, repository);
  if (head_result != 0 && head_result != GIT_EUNBORNBRANCH && head_result != GIT_ENOTFOUND) {
    git_index_free(index);
    return Failure(3024, "head");
  }
  git_diff *diff = nullptr;
  const int result = staged ? git_diff_tree_to_index(&diff, repository, head_tree, index, &options)
                            : git_diff_index_to_workdir(&diff, repository, index, &options);
  if (head_tree != nullptr) git_tree_free(head_tree);
  git_index_free(index);
  if (result < 0 || diff == nullptr) {
    if (diff != nullptr) git_diff_free(diff);
    return Failure(3025, "diff");
  }
  const size_t count = git_diff_num_deltas(diff);
  if (count > kMaxDiffFiles) {
    git_diff_free(diff);
    return Failure(3026, "too_many_files");
  }
  std::string files = "[";
  std::string patch_text;
  bool truncated = false;
  for (size_t item = 0; item < count; item += 1) {
    const git_diff_delta *delta = git_diff_get_delta(diff, item);
    const char *raw = delta == nullptr ? nullptr
                      : (delta->new_file.path != nullptr ? delta->new_file.path : delta->old_file.path);
    if (raw == nullptr || !SafeRepositoryPath(raw)) {
      git_diff_free(diff);
      return Failure(3021, "unsafe_path");
    }
    git_patch *patch = nullptr;
    size_t context = 0;
    size_t additions = 0;
    size_t deletions = 0;
    if (git_patch_from_diff(&patch, diff, item) == 0 && patch != nullptr) {
      git_patch_line_stats(&context, &additions, &deletions, patch);
    }
    if (item > 0) files += ",";
    files += "{\"path\":" + Quoted(raw) + ",\"status\":" + Quoted(DeltaName(delta->status)) +
             ",\"additions\":" + std::to_string(additions) + ",\"deletions\":" + std::to_string(deletions) + "}";
    if (patch != nullptr && !truncated) {
      git_buf buffer = GIT_BUF_INIT;
      if (git_patch_to_buf(&buffer, patch) == 0 && buffer.ptr != nullptr && buffer.size > 0) {
        std::string text(buffer.ptr, buffer.size);
        if (!ValidUtf8(text)) text = std::string("Binary or non-UTF-8 diff omitted: ") + raw + "\n";
        const size_t remaining = kMaxDiffBytes - patch_text.size();
        if (text.size() <= remaining) {
          patch_text += text;
        } else {
          patch_text += text.substr(0, Utf8Prefix(text, remaining));
          truncated = true;
        }
      }
      git_buf_dispose(&buffer);
    }
    if (patch != nullptr) git_patch_free(patch);
  }
  files += "]";
  git_diff_free(diff);
  std::string out = "{\"ok\":true,\"staged\":";
  out += staged ? "true" : "false";
  out += std::string(",\"truncated\":") + (truncated ? "true" : "false");
  out += ",\"patch\":" + Quoted(patch_text) + ",\"files\":" + files + "}";
  return out;
}

}  // namespace

extern "C" {

JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_status(JNIEnv *env, jclass, jstring gitDirValue,
                                                       jstring workDirValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  git_repository *repository = nullptr;
  std::string answer;
  const char *stage = workdir == nullptr ? "path" : OpenRepository(&repository, gitdir, workdir);
  answer = stage != nullptr ? Failure(3102, stage) : Status(repository);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return Bytes(env, answer);
}

JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_diff(JNIEnv *env, jclass, jstring gitDirValue,
                                                     jstring workDirValue, jboolean staged,
                                                     jint contextLines) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  git_repository *repository = nullptr;
  std::string answer;
  const char *stage = workdir == nullptr ? "path" : OpenRepository(&repository, gitdir, workdir);
  answer = stage != nullptr
               ? Failure(3102, stage)
               : Diff(repository, staged == JNI_TRUE, contextLines < 0 ? 0u : static_cast<unsigned int>(contextLines));
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return Bytes(env, answer);
}

/// `git add -A`, then the status that results. `stageAllV2` on iOS.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_stageAll(JNIEnv *env, jclass, jstring gitDirValue,
                                                         jstring workDirValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  git_repository *repository = nullptr;
  git_index *index = nullptr;
  std::string answer;
  do {
    const char *stage = workdir == nullptr ? "path" : OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure(3102, stage); break; }
    if (git_repository_index(&index, repository) != 0) { answer = Failure(3199, "index"); break; }
    char wildcard[] = "*";
    char *patterns[] = {wildcard};
    git_strarray pathspec = {patterns, 1};
    if (git_index_add_all(index, &pathspec, GIT_INDEX_ADD_DEFAULT, nullptr, nullptr) != 0) {
      answer = Failure(3199, "add_all");
      break;
    }
    if (git_index_write(index) != 0) { answer = Failure(3199, "index_write"); break; }
    answer = Status(repository);
  } while (false);
  if (index != nullptr) git_index_free(index);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return Bytes(env, answer);
}

/// `commitV2`: the index as it is, on HEAD, if HEAD is what the caller
/// expected. `expectedHead` null means "no commit yet". Answers
/// `{"ok":true,"oid":"..."}`; 3110 when HEAD moved, 3199 for anything git
/// refuses -- a conflicted index, an unchanged tree.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_commit(JNIEnv *env, jclass, jstring gitDirValue,
                                                       jstring workDirValue, jstring messageValue,
                                                       jstring nameValue, jstring emailValue,
                                                       jstring expectedHeadValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const char *message = Chars(env, messageValue);
  const char *name = Chars(env, nameValue);
  const char *email = Chars(env, emailValue);
  const char *expected = Chars(env, expectedHeadValue);
  git_repository *repository = nullptr;
  git_reference *head = nullptr;
  git_index *index = nullptr;
  git_tree *tree = nullptr;
  git_commit *parent = nullptr;
  git_signature *signature = nullptr;
  std::string answer;
  do {
    if (workdir == nullptr || message == nullptr || name == nullptr || email == nullptr) {
      answer = Failure(3101, "arguments");
      break;
    }
    const char *stage = OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure(3102, stage); break; }
    const int head_result = git_repository_head(&head, repository);
    const bool unborn = head_result == GIT_EUNBORNBRANCH || head_result == GIT_ENOTFOUND;
    const git_oid *target = head_result == 0 && head != nullptr ? git_reference_target(head) : nullptr;
    const bool matches = expected == nullptr ? unborn
                                             : (head_result == 0 && target != nullptr && Oid(target) == expected);
    if (!matches) { answer = Failure(3110, "head_changed"); break; }
    if (git_repository_index(&index, repository) != 0) { answer = Failure(3199, "index"); break; }
    if (git_index_has_conflicts(index)) { answer = Failure(3199, "conflicts"); break; }
    git_oid tree_id;
    if (git_index_write_tree(&tree_id, index) != 0) { answer = Failure(3199, "write_tree"); break; }
    if (git_tree_lookup(&tree, repository, &tree_id) != 0) { answer = Failure(3199, "tree"); break; }
    if (head_result == 0) {
      if (target == nullptr || git_commit_lookup(&parent, repository, target) != 0) {
        answer = Failure(3199, "parent");
        break;
      }
      if (git_oid_equal(&tree_id, git_commit_tree_id(parent))) { answer = Failure(3199, "unchanged"); break; }
    } else if (unborn) {
      if (git_index_entrycount(index) == 0) { answer = Failure(3199, "unchanged"); break; }
    } else {
      answer = Failure(3199, "head");
      break;
    }
    if (git_signature_now(&signature, name, email) != 0) { answer = Failure(3199, "signature"); break; }
    const git_commit *parents[] = {parent};
    git_oid commit_id;
    if (git_commit_create(&commit_id, repository, "HEAD", signature, signature, "UTF-8", message, tree,
                          parent == nullptr ? 0 : 1, parents) != 0) {
      answer = Failure(3199, "commit");
      break;
    }
    answer = "{\"ok\":true,\"oid\":" + Quoted(Oid(&commit_id)) + "}";
  } while (false);
  if (signature != nullptr) git_signature_free(signature);
  if (parent != nullptr) git_commit_free(parent);
  if (tree != nullptr) git_tree_free(tree);
  if (index != nullptr) git_index_free(index);
  if (head != nullptr) git_reference_free(head);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  Release(env, messageValue, message);
  Release(env, nameValue, name);
  Release(env, emailValue, email);
  Release(env, expectedHeadValue, expected);
  return Bytes(env, answer);
}

}  // extern "C"
