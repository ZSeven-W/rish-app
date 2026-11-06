// Single host-detection gate for the RishTests target.
//
// Every test that must behave differently on the CoreSimulator host versus a
// physical iPhone goes through these two predicates. CoreSimulator runs the
// test bundle as a macOS process: data protection is not enforced, fork(2)
// is available, and the filesystem is permissive. A physical device enforces
// real NSFileProtection semantics, forbids fork(2) for app processes, and
// applies the container sandbox. Tests must not repeat the
// TARGET_OS_IPHONE/TARGET_OS_SIMULATOR idiom; they import this header and
// call the predicates below.

#import <TargetConditionals.h>

static inline BOOL DSHTestHostIsSimulator(void) {
  return TARGET_OS_SIMULATOR != 0;
}

static inline BOOL DSHTestHostIsDevice(void) {
  return TARGET_OS_IPHONE != 0 && TARGET_OS_SIMULATOR == 0;
}
