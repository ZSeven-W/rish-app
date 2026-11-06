#import "ShellAssistantModule.h"
#import "ShellAssistantAvatarPicker.h"
#import <RishNative/RishUIKit.h>
#import <TargetConditionals.h>
#include <sys/stat.h>

@interface ShellAssistantModule ()
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic, strong) ShellAssistantAvatarPicker *avatarPicker;
@end

@implementation ShellAssistantModule
RISH_NATIVE_MODULE(ShellAssistant)
+ (BOOL)requiresMainQueueSetup { return NO; }
- (instancetype)init {
  NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
      inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
  return [self initWithDirectory:[base URLByAppendingPathComponent:@"Assistant-v1" isDirectory:YES]];
}
- (instancetype)initWithDirectory:(NSURL *)directory {
  self = [super init];
  if (self) _directory = directory;
  return self;
}
RISH_NATIVE_METHOD(pickAvatar, pickAvatarWithRequest:(NSDictionary *)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!ShellAssistantAvatarRequestValid(request)) {
    reject(@"E_ASSISTANT_AVATAR_INVALID", @"Choose an avatar from an explicit user action.", nil); return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self storageWithResolver:^(id metadata) {
      if (self.avatarPicker == nil) self.avatarPicker = [ShellAssistantAvatarPicker new];
      NSURL *directory = [NSURL fileURLWithPath:metadata[@"directory"] isDirectory:YES];
      [self.avatarPicker presentFrom:RishPresentedViewController() directory:directory resolve:resolve reject:reject];
    } rejecter:reject];
  });
}
RISH_NATIVE_METHOD(storage, storageWithResolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  NSFileManager *manager = NSFileManager.defaultManager;
  NSURL *directory = self.directory;
  struct stat metadata = {};
  NSError *error = nil;
  if (!directory.isFileURL || !directory.path.isAbsolutePath ||
      (lstat(directory.fileSystemRepresentation, &metadata) == 0 && !S_ISDIR(metadata.st_mode)) ||
      ![manager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{
        NSFilePosixPermissions: @0700, NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication
      } error:&error] ||
      ![manager setAttributes:@{NSFilePosixPermissions: @0700,
        NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:directory.path error:&error] ||
      ![directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error] ||
      lstat(directory.fileSystemRepresentation, &metadata) != 0 || !S_ISDIR(metadata.st_mode) || (metadata.st_mode & 0777) != 0700) {
    reject(@"assistant_storage_unavailable", @"Assistant storage is unavailable.", error); return;
  }
  [directory removeAllCachedResourceValues];
  NSNumber *excluded = nil;
  if (![directory getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:&error] || !excluded.boolValue) {
    reject(@"assistant_storage_unavailable", @"Assistant storage is unavailable.", error); return;
  }
#if !TARGET_OS_SIMULATOR
  if (![[manager attributesOfItemAtPath:directory.path error:&error][NSFileProtectionKey]
        isEqual:NSFileProtectionCompleteUntilFirstUserAuthentication]) {
    reject(@"assistant_storage_unavailable", @"Assistant storage is unavailable.", error); return;
  }
#endif
  resolve(@{@"schema_version": @1, @"directory": directory.URLByResolvingSymlinksInPath.path, @"platform": @"ios"});
}
@end
