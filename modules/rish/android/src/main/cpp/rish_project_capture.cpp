// What the project context reads from git when a selection is captured.
//
// iOS's `captureLease` walks the index, two diffs and the blobs of the files
// it was asked for, and decides as it goes. Here the decisions stay in Kotlin
// -- which paths are eligible, what a selection expands to, what a file's
// bytes are allowed to be -- and this file answers the git questions those
// decisions need: the index and its two diffs, whether a blob exists, a
// blob's bytes, and a patch between two revisions of one file in the exact
// form the envelope frames.
//
// The options are iOS's, line for line, because the source fingerprint and
// the patch bytes have to come out the same for the same repository.

#include <jni.h>

#include <string>
#include <vector>

#include <git2.h>

#include "rish_git_support.h"

namespace {

using rish::Bytes;
using rish::Chars;
using rish::Oid;
using rish::OpenRepository;
using rish::Quoted;
using rish::Release;
using rish::ValidUtf8;

/// `DSHProjectContextMaxEntries`, `DSHProjectContextMaxChangedPaths`, `DSHProjectContextMaxFileBytes`.
constexpr size_t kMaxEntries = 5000;
constexpr size_t kRenameLimit = 100;
constexpr size_t kMaxFileBytes = 64 * 1024;

std::string Failure(const char *code, const char *stage) {
  return std::string("{\"ok\":false,\"code\":") + Quoted(code) + ",\"stage\":" + Quoted(stage) +
         ",\"error\":" + Quoted(rish::LastError()) + "}";
}

/// The diff options `captureLease` uses for both diffs and, with FORCE_TEXT
/// added, for every patch.
git_diff_options CaptureOptions() {
  git_diff_options options = GIT_DIFF_OPTIONS_INIT;
  options.flags = GIT_DIFF_INCLUDE_TYPECHANGE | GIT_DIFF_INCLUDE_TYPECHANGE_TREES |
                  GIT_DIFF_IGNORE_SUBMODULES | GIT_DIFF_DISABLE_PATHSPEC_MATCH;
  options.context_lines = 3;
  options.interhunk_lines = 0;
  options.id_abbrev = GIT_OID_SHA1_HEXSIZE;
  options.max_size = static_cast<git_object_size_t>(kMaxFileBytes + 1);
  options.old_prefix = "a";
  options.new_prefix = "b";
  return options;
}

const char *DeltaPath(const git_diff_delta *delta, bool new_side) {
  if (delta == nullptr) return nullptr;
  const char *path = new_side ? delta->new_file.path : delta->old_file.path;
  if (path == nullptr) path = new_side ? delta->old_file.path : delta->new_file.path;
  return path;
}

std::string StatusRows(git_diff *diff, const char *kind, bool *valid) {
  std::string rows;
  const size_t count = git_diff_num_deltas(diff);
  for (size_t item = 0; item < count; item += 1) {
    const git_diff_delta *delta = git_diff_get_delta(diff, item);
    const char *old_path = DeltaPath(delta, false);
    const char *new_path = DeltaPath(delta, true);
    if ((old_path != nullptr && !ValidUtf8(old_path)) || (new_path != nullptr && !ValidUtf8(new_path))) {
      *valid = false;
      return "";
    }
    if (!rows.empty()) rows += ",";
    rows += "{\"kind\":" + Quoted(kind);
    rows += ",\"status\":" + std::to_string(delta == nullptr ? GIT_DELTA_UNMODIFIED : delta->status);
    rows += ",\"old_path\":" + Quoted(old_path == nullptr ? "" : old_path);
    rows += ",\"new_path\":" + Quoted(new_path == nullptr ? "" : new_path);
    rows += ",\"old_mode\":" + std::to_string(delta == nullptr ? 0 : delta->old_file.mode);
    rows += ",\"new_mode\":" + std::to_string(delta == nullptr ? 0 : delta->new_file.mode);
    rows += ",\"old_oid\":" + Quoted(delta == nullptr ? "" : Oid(&delta->old_file.id));
    rows += ",\"new_oid\":" + Quoted(delta == nullptr ? "" : Oid(&delta->new_file.id));
    rows += "}";
  }
  return rows;
}

/// A patch's text, exactly as `serializedPatch` accepts it: the printed
/// lines and the buffer must agree byte for byte, nothing in it may be a NUL
/// or a control character other than tab, newline and return, and it must be
/// non-empty UTF-8.
struct PrintedLines {
  std::string bytes;
  bool failed = false;
};

int AppendLine(const git_diff_delta *, const git_diff_hunk *, const git_diff_line *line, void *payload) {
  auto *printed = static_cast<PrintedLines *>(payload);
  if (line == nullptr || (line->content_len > 0 && line->content == nullptr)) {
    printed->failed = true;
    return -1;
  }
  if (line->origin == GIT_DIFF_LINE_CONTEXT || line->origin == GIT_DIFF_LINE_ADDITION ||
      line->origin == GIT_DIFF_LINE_DELETION) {
    printed->bytes.push_back(line->origin);
  }
  if (line->content_len > 0) printed->bytes.append(line->content, line->content_len);
  return 0;
}

bool SerializedPatch(git_patch *patch, std::string *out) {
  if (patch == nullptr) return false;
  const size_t accounted = git_patch_size(patch, 1, 1, 1);
  PrintedLines printed;
  const int print_result = git_patch_print(patch, AppendLine, &printed);
  git_buf buffer = GIT_BUF_INIT;
  const int result = git_patch_to_buf(&buffer, patch);
  std::string data;
  if (result == 0 && buffer.ptr != nullptr) data.assign(buffer.ptr, buffer.size);
  git_buf_dispose(&buffer);
  if (print_result != 0 || printed.failed || result != 0 || accounted == 0 || printed.bytes.empty() ||
      data.size() != printed.bytes.size() || accounted > printed.bytes.size() || data != printed.bytes) {
    return false;
  }
  for (const char c : data) {
    const unsigned char byte = static_cast<unsigned char>(c);
    if (byte == 0 || (byte < 0x20 && byte != '\n' && byte != '\r' && byte != '\t')) return false;
  }
  if (data.empty() || !ValidUtf8(data)) return false;
  *out = std::move(data);
  return true;
}

bool LookupBlob(git_repository *repository, const char *hex, git_blob **out) {
  git_oid oid;
  if (hex == nullptr || *hex == '\0' || git_oid_fromstr(&oid, hex) != 0) return false;
  if (git_oid_is_zero(&oid)) return true;  // no blob on that side, and that is fine
  return git_blob_lookup(out, repository, &oid) == 0 && *out != nullptr;
}

}  // namespace

extern "C" {

/// The index and the two diffs, with nothing decided. Kotlin decides.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_captureRepository(JNIEnv *env, jclass, jstring gitDirValue,
                                                                  jstring workDirValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  git_repository *repository = nullptr;
  git_index *index = nullptr;
  git_reference *head = nullptr;
  git_commit *commit = nullptr;
  git_tree *head_tree = nullptr;
  git_diff *staged = nullptr;
  git_diff *worktree = nullptr;
  std::string answer;
  do {
    const char *stage = workdir == nullptr ? "path" : OpenRepository(&repository, gitdir, workdir);
    if (stage != nullptr) { answer = Failure("project_unavailable", stage); break; }
    if (git_repository_index(&index, repository) != 0 || git_index_read(index, 1) != 0) {
      answer = Failure("project_unavailable", "index");
      break;
    }
    const size_t count = git_index_entrycount(index);
    if (count > kMaxEntries) { answer = Failure("budget_exceeded", "entries"); break; }

    std::string head_oid;
    std::string branch;
    std::string head_target;
    const int head_result = git_repository_head(&head, repository);
    if (head_result == 0 && head != nullptr) {
      const git_oid *target = git_reference_target(head);
      if (target != nullptr) head_oid = Oid(target);
      if (git_reference_is_branch(head)) {
        const char *name = git_reference_shorthand(head);
        if (name != nullptr) branch = name;
      }
      if (target == nullptr || git_commit_lookup(&commit, repository, target) != 0 ||
          git_commit_tree(&head_tree, commit) != 0 || head_tree == nullptr) {
        answer = Failure("integrity", "head_tree");
        break;
      }
    } else if (head_result == GIT_EUNBORNBRANCH || head_result == GIT_ENOTFOUND) {
      git_reference *symbolic = nullptr;
      if (git_reference_lookup(&symbolic, repository, "HEAD") == 0 && symbolic != nullptr) {
        const char *target = git_reference_symbolic_target(symbolic);
        if (target != nullptr) head_target = target;
        if (head_target.rfind("refs/heads/", 0) == 0) branch = head_target.substr(11);
        git_reference_free(symbolic);
      }
    } else {
      answer = Failure("project_unavailable", "head");
      break;
    }

    std::string entries = "[";
    bool paths_valid = true;
    for (size_t item = 0; item < count; item += 1) {
      const git_index_entry *entry = git_index_get_byindex(index, item);
      if (entry == nullptr || entry->path == nullptr || !ValidUtf8(entry->path)) { paths_valid = false; break; }
      if (item > 0) entries += ",";
      entries += "{\"path\":" + Quoted(entry->path) + ",\"stage\":" + std::to_string(git_index_entry_stage(entry)) +
                 ",\"mode\":" + std::to_string(entry->mode) + ",\"size\":" + std::to_string(entry->file_size) +
                 ",\"oid\":" + Quoted(Oid(&entry->id)) + "}";
    }
    entries += "]";
    if (!paths_valid) { answer = Failure("integrity", "index_path"); break; }

    git_diff_options options = CaptureOptions();
    if (git_diff_tree_to_index(&staged, repository, head_tree, index, &options) != 0 ||
        git_diff_index_to_workdir(&worktree, repository, index, &options) != 0 || staged == nullptr ||
        worktree == nullptr) {
      answer = Failure("project_unavailable", "diff");
      break;
    }
    git_diff_find_options find = GIT_DIFF_FIND_OPTIONS_INIT;
    find.flags = GIT_DIFF_FIND_RENAMES;
    find.rename_limit = kRenameLimit;
    if (git_diff_find_similar(staged, &find) != 0 || git_diff_find_similar(worktree, &find) != 0) {
      answer = Failure("integrity", "find_similar");
      break;
    }
    bool rows_valid = true;
    std::string rows = StatusRows(staged, "staged", &rows_valid);
    std::string worktree_rows = StatusRows(worktree, "worktree", &rows_valid);
    if (!rows_valid) { answer = Failure("integrity", "delta_path"); break; }
    if (!rows.empty() && !worktree_rows.empty()) rows += ",";
    rows += worktree_rows;

    const git_oid *checksum = git_index_checksum(index);
    std::string out = "{\"ok\":true,\"head_oid\":";
    out += head_oid.empty() ? "null" : Quoted(head_oid);
    out += ",\"branch\":";
    out += branch.empty() ? "null" : Quoted(branch);
    out += ",\"head_target\":";
    out += head_target.empty() ? "null" : Quoted(head_target);
    out += ",\"repository_state\":" + std::to_string(git_repository_state(repository));
    out += ",\"index_checksum\":";
    out += checksum == nullptr ? "null" : Quoted(Oid(checksum));
    out += ",\"entries\":" + entries + ",\"status_rows\":[" + rows + "]}";
    answer = std::move(out);
  } while (false);
  if (worktree != nullptr) git_diff_free(worktree);
  if (staged != nullptr) git_diff_free(staged);
  if (head_tree != nullptr) git_tree_free(head_tree);
  if (commit != nullptr) git_commit_free(commit);
  if (head != nullptr) git_reference_free(head);
  if (index != nullptr) git_index_free(index);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  return Bytes(env, answer);
}

/// Whether the object database holds a blob with this id.
JNIEXPORT jboolean JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_blobExists(JNIEnv *env, jclass, jstring gitDirValue,
                                                           jstring workDirValue, jstring oidValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const char *hex = Chars(env, oidValue);
  git_repository *repository = nullptr;
  git_blob *blob = nullptr;
  bool exists = false;
  if (workdir != nullptr && hex != nullptr && OpenRepository(&repository, gitdir, workdir) == nullptr) {
    git_oid oid;
    exists = git_oid_fromstr(&oid, hex) == 0 && git_blob_lookup(&blob, repository, &oid) == 0 && blob != nullptr;
  }
  if (blob != nullptr) git_blob_free(blob);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  Release(env, oidValue, hex);
  return exists ? JNI_TRUE : JNI_FALSE;
}

/// A blob's raw bytes, or null when there is no such blob.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_blob(JNIEnv *env, jclass, jstring gitDirValue, jstring workDirValue,
                                                     jstring oidValue) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const char *hex = Chars(env, oidValue);
  git_repository *repository = nullptr;
  git_blob *blob = nullptr;
  jbyteArray answer = nullptr;
  if (workdir != nullptr && hex != nullptr && OpenRepository(&repository, gitdir, workdir) == nullptr) {
    git_oid oid;
    if (git_oid_fromstr(&oid, hex) == 0 && git_blob_lookup(&blob, repository, &oid) == 0 && blob != nullptr) {
      const git_object_size_t size = git_blob_rawsize(blob);
      const char *content = static_cast<const char *>(git_blob_rawcontent(blob));
      answer = Bytes(env, std::string(content == nullptr ? "" : content, content == nullptr ? 0 : static_cast<size_t>(size)));
    }
  }
  if (blob != nullptr) git_blob_free(blob);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  Release(env, oidValue, hex);
  return answer;
}

/// The patch between two revisions of one file, in the form the envelope
/// frames. `staged` compares two blobs; otherwise the old blob against the
/// bytes Kotlin read from the working tree (the same bytes it will send). A
/// zero or empty id is "no blob on that side". Null when git cannot say or
/// the patch is not clean text.
JNIEXPORT jbyteArray JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_patch(JNIEnv *env, jclass, jstring gitDirValue, jstring workDirValue,
                                                      jboolean staged, jstring oldOidValue, jstring oldPathValue,
                                                      jstring newOidValue, jstring newPathValue, jbyteArray newBuffer) {
  const char *gitdir = Chars(env, gitDirValue);
  const char *workdir = Chars(env, workDirValue);
  const char *old_oid = Chars(env, oldOidValue);
  const char *old_path = Chars(env, oldPathValue);
  const char *new_oid = Chars(env, newOidValue);
  const char *new_path = Chars(env, newPathValue);
  git_repository *repository = nullptr;
  git_blob *old_blob = nullptr;
  git_blob *new_blob = nullptr;
  git_patch *patch = nullptr;
  jbyteArray answer = nullptr;
  std::vector<char> buffer;
  do {
    if (workdir == nullptr || OpenRepository(&repository, gitdir, workdir) != nullptr) break;
    if (old_oid != nullptr && *old_oid != '\0' && !LookupBlob(repository, old_oid, &old_blob)) break;
    git_diff_options options = CaptureOptions();
    options.flags |= GIT_DIFF_FORCE_TEXT;
    int result;
    if (staged == JNI_TRUE) {
      if (new_oid != nullptr && *new_oid != '\0' && !LookupBlob(repository, new_oid, &new_blob)) break;
      result = git_patch_from_blobs(&patch, old_blob, old_path, new_blob, new_path, &options);
    } else {
      if (newBuffer != nullptr) {
        const jsize length = env->GetArrayLength(newBuffer);
        buffer.resize(static_cast<size_t>(length));
        if (length > 0) env->GetByteArrayRegion(newBuffer, 0, length, reinterpret_cast<jbyte *>(buffer.data()));
      }
      result = git_patch_from_blob_and_buffer(&patch, old_blob, old_path, buffer.data(), buffer.size(), new_path,
                                              &options);
    }
    std::string text;
    if (result != 0 || !SerializedPatch(patch, &text)) break;
    answer = Bytes(env, text);
  } while (false);
  if (patch != nullptr) git_patch_free(patch);
  if (new_blob != nullptr) git_blob_free(new_blob);
  if (old_blob != nullptr) git_blob_free(old_blob);
  if (repository != nullptr) git_repository_free(repository);
  Release(env, gitDirValue, gitdir);
  Release(env, workDirValue, workdir);
  Release(env, oldOidValue, old_oid);
  Release(env, oldPathValue, old_path);
  Release(env, newOidValue, new_oid);
  Release(env, newPathValue, new_path);
  return answer;
}

}  // extern "C"
