// Diagnostics the Kotlin side cannot perform.
//
// The guest rejected every boot in about 30ms, identically at 768, 512 and 256
// MiB. That is far too fast to have read a 12 MiB kernel, and the memory size
// is plainly not the variable, so the failure is at the very start of
// rish_vm_boot_session -- which returns a null pointer and no reason. These
// three calls test the three things that start could plausibly need, from
// native code, in the same process, and report errno rather than a verdict.
#include <jni.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <vector>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <cstdlib>
#include <unistd.h>

namespace {

std::string Describe(const char *what, bool ok, const std::string &detail) {
  std::string line = what;
  line += ok ? "  OK" : "  FAILED";
  if (!detail.empty()) {
    line += "  ";
    line += detail;
  }
  return line;
}

std::string ErrnoText() {
  std::string text = "errno=";
  text += std::to_string(errno);
  text += " (";
  text += std::strerror(errno);
  text += ")";
  return text;
}

} // namespace

/**
 * open() + read() of the staged asset, from native code. The Kotlin layer
 * wrote and hashed this file, so Java can plainly reach it; whether the native
 * side sees the same path is a separate question, and one a container that
 * virtualises the filesystem can answer differently.
 */
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_guestprobe_NativeProbe_readFile(JNIEnv *env, jclass,
                                                      jstring path) {
  const char *chars = env->GetStringUTFChars(path, nullptr);
  if (chars == nullptr) return env->NewStringUTF("native read  FAILED  no path");
  std::string result;
  struct stat info {};
  if (::stat(chars, &info) != 0) {
    result = Describe("native stat", false, ErrnoText());
  } else {
    result = Describe("native stat", true, std::to_string(info.st_size) + " bytes");
    int fd = ::open(chars, O_RDONLY);
    if (fd < 0) {
      result += "\n" + Describe("native open", false, ErrnoText());
    } else {
      result += "\n" + Describe("native open", true, "");
      char head[64];
      ssize_t got = ::read(fd, head, sizeof(head));
      if (got < 0) {
        result += "\n" + Describe("native read", false, ErrnoText());
      } else {
        char hex[16 * 3 + 1];
        int used = 0;
        for (ssize_t i = 0; i < got && i < 16; ++i) {
          used += std::snprintf(hex + used, sizeof(hex) - used, "%02x ",
                                static_cast<unsigned char>(head[i]));
        }
        result += "\n" + Describe("native read", true,
                                  std::to_string(got) + " bytes, starts " + hex);
      }
      ::close(fd);
    }
  }
  env->ReleaseStringUTFChars(path, chars);
  return env->NewStringUTF(result.c_str());
}

/** An anonymous mapping the size of the guest's RAM. */
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_guestprobe_NativeProbe_mapAnonymous(JNIEnv *env, jclass,
                                                          jint mib) {
  size_t bytes = static_cast<size_t>(mib) * 1024u * 1024u;
  void *address = ::mmap(nullptr, bytes, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  std::string label = "mmap " + std::to_string(mib) + " MiB rw";
  if (address == MAP_FAILED) return env->NewStringUTF(Describe(label.c_str(), false, ErrnoText()).c_str());
  // Touch both ends: a reservation that cannot be committed fails here, not above.
  static_cast<char *>(address)[0] = 1;
  static_cast<char *>(address)[bytes - 1] = 1;
  ::munmap(address, bytes);
  return env->NewStringUTF(Describe(label.c_str(), true, "reserved and touched").c_str());
}

/**
 * An executable mapping. A container enforcing W^X refuses this, and an
 * interpreter that compiles anything at all would die exactly this early.
 */
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_guestprobe_NativeProbe_mapExecutable(JNIEnv *env, jclass) {
  size_t bytes = 1024u * 1024u;
  void *address = ::mmap(nullptr, bytes, PROT_READ | PROT_WRITE | PROT_EXEC,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (address == MAP_FAILED) return env->NewStringUTF(Describe("mmap 1 MiB rwx", false, ErrnoText()).c_str());
  ::munmap(address, bytes);
  return env->NewStringUTF(Describe("mmap 1 MiB rwx", true, "").c_str());
}


/**
 * Where Rust's `std::env::temp_dir()` would point, and whether a 64 MiB file
 * can actually be made there.
 *
 * boot_channel() creates a throwaway root disk with tempfile::NamedTempFile
 * and calls set_len(64 MiB) on it -- an initramfs boot never reads it, but the
 * VM config demands a path. temp_dir() honours TMPDIR and otherwise falls back
 * to /tmp, which does not exist on Android. Stock Android sets TMPDIR to the
 * app's cache directory; a container need not. That single call would fail in
 * microseconds, before any memory is touched, identically at every guest size.
 */
extern "C" JNIEXPORT jstring JNICALL
Java_tech_zseven_rish_guestprobe_NativeProbe_tempStatus(JNIEnv *env, jclass) {
  std::string result;
  const char *tmpdir = ::getenv("TMPDIR");
  result += "TMPDIR=";
  result += (tmpdir == nullptr ? "(unset -- Rust falls back to /tmp)" : tmpdir);

  const char *dir = (tmpdir == nullptr || *tmpdir == '\0') ? "/tmp" : tmpdir;
  struct stat info {};
  if (::stat(dir, &info) != 0) {
    result += "\n" + Describe("temp dir exists", false, ErrnoText());
    return env->NewStringUTF(result.c_str());
  }
  result += "\n" + Describe("temp dir exists", true, dir);

  std::string tmpl = std::string(dir) + "/rishprobeXXXXXX";
  std::vector<char> path(tmpl.begin(), tmpl.end());
  path.push_back('\0');
  int fd = ::mkstemp(path.data());
  if (fd < 0) {
    result += "\n" + Describe("create a temp file", false, ErrnoText());
    return env->NewStringUTF(result.c_str());
  }
  result += "\n" + Describe("create a temp file", true, path.data());
  // The same 64 MiB the scratch root disk is sized to.
  if (::ftruncate(fd, 64L * 1024 * 1024) != 0) {
    result += "\n" + Describe("size it to 64 MiB", false, ErrnoText());
  } else {
    result += "\n" + Describe("size it to 64 MiB", true, "");
  }
  struct statvfs vfs {};
  if (::statvfs(dir, &vfs) == 0) {
    unsigned long long free_mib =
        (static_cast<unsigned long long>(vfs.f_bavail) * vfs.f_frsize) / (1024ull * 1024ull);
    result += "\n" + Describe("free space", true, std::to_string(free_mib) + " MiB");
  }
  ::close(fd);
  ::unlink(path.data());
  return env->NewStringUTF(result.c_str());
}
