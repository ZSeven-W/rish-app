// A floor test for the vendored libgit2, not a feature.
//
// Building a library, linking it, and having it work on a device are three
// different things, and the third is the one that matters. This exposes just
// enough to ask libgit2 on the device: what version are you, can you
// initialise, and can you open a repository you just created and read a
// commit back out of it. Everything the project context service will need
// sits on top of those answers.

#include <jni.h>

#include <string>

#include <git2.h>

namespace {

jstring MakeString(JNIEnv *env, const std::string &value) {
  return env->NewStringUTF(value.c_str());
}

/// libgit2's last error, or an empty string when it did not say.
std::string LastError() {
  const git_error *error = git_error_last();
  return error != nullptr && error->message != nullptr ? error->message : "";
}

}  // namespace

extern "C" {

JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_version(JNIEnv *env, jclass) {
  int major = 0;
  int minor = 0;
  int revision = 0;
  git_libgit2_version(&major, &minor, &revision);
  return MakeString(env, std::to_string(major) + "." + std::to_string(minor) +
                             "." + std::to_string(revision));
}

/// The features compiled in, as a comma-separated list. The service needs
/// HTTPS and SSH, and a library that built without them would otherwise only
/// say so when a fetch failed.
JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_features(JNIEnv *env, jclass) {
  const int features = git_libgit2_features();
  std::string listed;
  const auto add = [&listed](const char *name) {
    if (!listed.empty()) listed += ",";
    listed += name;
  };
  if (features & GIT_FEATURE_THREADS) add("threads");
  if (features & GIT_FEATURE_HTTPS) add("https");
  if (features & GIT_FEATURE_SSH) add("ssh");
  if (features & GIT_FEATURE_NSEC) add("nsec");
  return MakeString(env, listed);
}

/// Creates a repository at `path`, commits one file into it, and reads the
/// commit's message and tree back. Answers "ok:<message>" or "error:<why>".
///
/// It writes rather than only reading because the object database, the index
/// and the commit path are what the service leans on, and a library that can
/// only be initialised proves none of them.
JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_runtime_RishLibgit2Native_roundTrip(JNIEnv *env, jclass,
                                                          jstring pathValue) {
  const char *path = env->GetStringUTFChars(pathValue, nullptr);
  if (path == nullptr) return MakeString(env, "error:path");
  std::string answer;

  git_repository *repository = nullptr;
  git_index *index = nullptr;
  git_signature *who = nullptr;
  git_tree *tree = nullptr;
  git_commit *commit = nullptr;
  git_oid tree_id;
  git_oid commit_id;

  const auto fail = [&answer](const char *stage) {
    answer = std::string("error:") + stage + ":" + LastError();
  };

  do {
    if (git_repository_init(&repository, path, 0) != 0) {
      fail("init");
      break;
    }
    // One file, staged through the index the same way the service stages a
    // captured selection.
    const std::string file = std::string(path) + "/hello.txt";
    FILE *handle = fopen(file.c_str(), "wb");
    if (handle == nullptr) {
      fail("write");
      break;
    }
    fputs("hello from android\n", handle);
    fclose(handle);

    if (git_repository_index(&index, repository) != 0) {
      fail("index");
      break;
    }
    if (git_index_add_bypath(index, "hello.txt") != 0) {
      fail("add");
      break;
    }
    if (git_index_write_tree(&tree_id, index) != 0) {
      fail("write_tree");
      break;
    }
    // The tree is in the object database but the index is still only in
    // memory; `git add` writes it, and anything that reads the repository
    // afterwards reads the file rather than this process.
    if (git_index_write(index) != 0) {
      fail("index_write");
      break;
    }
    if (git_signature_new(&who, "Rish", "rish@example.invalid", 1700000000, 0) != 0) {
      fail("signature");
      break;
    }
    if (git_tree_lookup(&tree, repository, &tree_id) != 0) {
      fail("tree_lookup");
      break;
    }
    if (git_commit_create(&commit_id, repository, "HEAD", who, who, "UTF-8",
                          "first", tree, 0, nullptr) != 0) {
      fail("commit");
      break;
    }
    if (git_commit_lookup(&commit, repository, &commit_id) != 0) {
      fail("commit_lookup");
      break;
    }
    const char *message = git_commit_message(commit);
    answer = std::string("ok:") + (message != nullptr ? message : "");
  } while (false);

  if (commit != nullptr) git_commit_free(commit);
  if (tree != nullptr) git_tree_free(tree);
  if (who != nullptr) git_signature_free(who);
  if (index != nullptr) git_index_free(index);
  if (repository != nullptr) git_repository_free(repository);
  env->ReleaseStringUTFChars(pathValue, path);
  return MakeString(env, answer);
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *, void *) {
  git_libgit2_init();
  return JNI_VERSION_1_6;
}

}  // extern "C"
