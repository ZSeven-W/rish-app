#import <Foundation/Foundation.h>

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const DSHTestStorageFixtureErrorDomain =
    @"dev.zseven.rish.tests.storage-fixture";

static inline void DSHSetTestStorageFixtureError(
    NSError **error, NSInteger code, NSString *operation, NSURL *url,
    NSError *underlying) {
  if (error == nullptr) return;
  NSMutableDictionary *userInfo = [@{
    NSLocalizedDescriptionKey : [NSString stringWithFormat:
        @"%@ failed for %@", operation ?: @"storage fixture", url.path ?: @"<nil>"],
  } mutableCopy];
  if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
  if (errno != 0) userInfo[@"errno"] = @(errno);
  *error = [NSError errorWithDomain:DSHTestStorageFixtureErrorDomain
                               code:code userInfo:userInfo];
}

/// A unique test-owned root on the same Application Support volume used by
/// production durable stores. The suite root itself remains backup-eligible;
/// production code must apply its private metadata only to the directories and
/// files it owns below this root.
static inline NSURL *DSHCreateTestStorageFixtureRoot(NSString *suiteName,
                                                     NSError **error) {
  NSError *underlying = nil;
  NSURL *support = [NSFileManager.defaultManager
      URLForDirectory:NSApplicationSupportDirectory
             inDomain:NSUserDomainMask
    appropriateForURL:nil
               create:YES
                error:&underlying];
  if (support == nil || !support.isFileURL ||
      ![support.path hasPrefix:[NSHomeDirectory() stringByAppendingString:@"/"]]) {
    DSHSetTestStorageFixtureError(error, 1, @"resolve Application Support",
                                  support, underlying);
    return nil;
  }
  NSURL *root = [[[support
      URLByAppendingPathComponent:@"RishTests" isDirectory:YES]
      URLByAppendingPathComponent:suiteName isDirectory:YES]
      URLByAppendingPathComponent:NSUUID.UUID.UUIDString.lowercaseString
                       isDirectory:YES];
  if (![NSFileManager.defaultManager
          createDirectoryAtURL:root
   withIntermediateDirectories:YES
                    attributes:@{NSFilePosixPermissions : @0700}
                         error:&underlying] ||
      chmod(root.fileSystemRepresentation, 0700) != 0) {
    DSHSetTestStorageFixtureError(error, 2, @"create fixture root", root,
                                  underlying);
    return nil;
  }
  return root.URLByStandardizingPath;
}

/// Install a protected private fixture without Foundation's implicit atomic
/// temporary path. This mirrors the production metadata order closely while
/// remaining test-only: explicit sibling, write/close, 0600, Complete,
/// no-backup, and rename.
static inline BOOL DSHWriteProtectedTestFixture(NSData *data, NSURL *url,
                                                NSError **error) {
  if (![data isKindOfClass:NSData.class] || !url.isFileURL) {
    DSHSetTestStorageFixtureError(error, 3, @"validate protected fixture", url,
                                  nil);
    return NO;
  }
  NSURL *parent = url.URLByDeletingLastPathComponent;
  struct stat parentState = {};
  if (lstat(parent.fileSystemRepresentation, &parentState) != 0 ||
      !S_ISDIR(parentState.st_mode) || S_ISLNK(parentState.st_mode)) {
    DSHSetTestStorageFixtureError(error, 4, @"validate fixture parent", parent,
                                  nil);
    return NO;
  }
  NSString *name = [NSString stringWithFormat:@".%@.%@.fixture-tmp",
      url.lastPathComponent, NSUUID.UUID.UUIDString.lowercaseString];
  NSURL *temporary = [parent URLByAppendingPathComponent:name];
  int descriptor = open(temporary.fileSystemRepresentation,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        0600);
  if (descriptor < 0) {
    DSHSetTestStorageFixtureError(error, 5, @"open fixture temporary",
                                  temporary, nil);
    return NO;
  }
  const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
  NSUInteger offset = 0;
  BOOL written = YES;
  while (offset < data.length) {
    ssize_t count = write(descriptor, bytes + offset, data.length - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      written = NO;
      break;
    }
    offset += (NSUInteger)count;
  }
  if (close(descriptor) != 0) written = NO;
  if (!written || chmod(temporary.fileSystemRepresentation, 0600) != 0) {
    DSHSetTestStorageFixtureError(error, 6, @"write fixture temporary",
                                  temporary, nil);
    unlink(temporary.fileSystemRepresentation);
    return NO;
  }
  NSError *underlying = nil;
  BOOL fileProtected = [NSFileManager.defaultManager
      setAttributes:@{NSFileProtectionKey : NSFileProtectionComplete}
       ofItemAtPath:temporary.path
              error:&underlying];
  BOOL excluded = fileProtected && [temporary
      setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey
                 error:&underlying];
  if (!fileProtected || !excluded ||
      rename(temporary.fileSystemRepresentation, url.fileSystemRepresentation) != 0 ||
      chmod(url.fileSystemRepresentation, 0600) != 0) {
    DSHSetTestStorageFixtureError(error, 7, @"publish protected fixture", url,
                                  underlying);
    unlink(temporary.fileSystemRepresentation);
    return NO;
  }
  fileProtected = [NSFileManager.defaultManager
      setAttributes:@{NSFileProtectionKey : NSFileProtectionComplete}
       ofItemAtPath:url.path
              error:&underlying];
  excluded = fileProtected && [url
      setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey
                 error:&underlying];
  if (!fileProtected || !excluded) {
    DSHSetTestStorageFixtureError(error, 8, @"verify protected fixture", url,
                                  underlying);
    return NO;
  }
  return YES;
}
