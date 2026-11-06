#include <jni.h>

#include <cerrno>
#include <linux/fs.h>
#include <string>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace {

bool Leaf(JNIEnv *env, jbyteArray value, std::string *name) {
  if (value == nullptr) return false;
  jsize size = env->GetArrayLength(value);
  if (size < 1 || size > 255) return false;
  name->resize(static_cast<size_t>(size));
  env->GetByteArrayRegion(value, 0, size, reinterpret_cast<jbyte *>(name->data()));
  return !env->ExceptionCheck() && *name != "." && *name != ".." &&
      name->find('/') == std::string::npos && name->find('\0') == std::string::npos;
}

}  // namespace

// Directory FDs and leaf names only: never re-resolve an absolute path.
// Missing filesystem/kernel support refuses; there is no racy rename fallback.
extern "C" JNIEXPORT jint JNICALL
Java_tech_zseven_rish_runtime_AndroidWorkspaceFileNative_renameAt(
    JNIEnv *env, jclass, jint sourceDirectory, jbyteArray source, jint destinationDirectory, jbyteArray destination,
    jboolean exchange) {
  std::string from, to;
  if (sourceDirectory < 0 || destinationDirectory < 0 || !Leaf(env, source, &from) || !Leaf(env, destination, &to) || (sourceDirectory == destinationDirectory && from == to)) {
    return EINVAL;
  }
  struct stat state = {};
  if (fstat(sourceDirectory, &state) != 0) return errno;
  if (!S_ISDIR(state.st_mode)) return ENOTDIR;
  if (fstat(destinationDirectory, &state) != 0) return errno;
  if (!S_ISDIR(state.st_mode)) return ENOTDIR;
  int flags = exchange == JNI_TRUE ? RENAME_EXCHANGE : RENAME_NOREPLACE;
  return syscall(__NR_renameat2, sourceDirectory, from.c_str(), destinationDirectory, to.c_str(), flags) == 0
      ? 0 : errno;
}
