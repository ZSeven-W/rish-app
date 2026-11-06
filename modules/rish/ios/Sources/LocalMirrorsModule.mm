#import "DSHGuestRuntimeState.h"

#import <Foundation/Foundation.h>
#import <RishNative/RishNativeModule.h>

#include <sys/stat.h>

static NSError *LMError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:@"tech.zseven.rish.mirrors"
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *LMString(id value) {
  return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSNumber *LMBool(id value) {
  return [value isKindOfClass:NSNumber.class] ? value : nil;
}

@interface LocalMirrorsModule : NSObject <RishNativeModule>
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation LocalMirrorsModule

RISH_NATIVE_MODULE(LocalMirrors)

+ (BOOL)requiresMainQueueSetup { return NO; }

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _queue = dispatch_queue_create(
      "tech.zseven.rish.local-mirrors",
      DISPATCH_QUEUE_SERIAL
    );
  }
  return self;
}

- (NSURL *)overlayRoot:(NSError **)error {
  NSURL *support = [[NSFileManager defaultManager]
    URLForDirectory:NSApplicationSupportDirectory
           inDomain:NSUserDomainMask
  appropriateForURL:nil
             create:YES
              error:error];
  if (support == nil) return nil;
  NSURL *root = [support URLByAppendingPathComponent:@"rish-guest-overlay" isDirectory:YES];
  if (![[NSFileManager defaultManager] createDirectoryAtURL:root
                                withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions: @0700}
                                                      error:error]) {
    return nil;
  }
  chmod(root.fileSystemRepresentation, 0700);
  return root;
}

- (NSString *)normalizedHTTPSBaseURL:(id)value error:(NSError **)error {
  NSString *raw = LMString(value);
  if (raw.length == 0 || [raw lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 2048) {
    if (error != nil) *error = LMError(3001, @"Mirror URL is invalid");
    return nil;
  }
  NSURLComponents *components = [NSURLComponents componentsWithString:raw];
  if (components == nil || ![components.scheme.lowercaseString isEqualToString:@"https"]
    || components.host.length == 0 || components.user.length > 0
    || components.password.length > 0 || components.query.length > 0
    || components.fragment.length > 0) {
    if (error != nil) *error = LMError(3002, @"Mirror URL must be a credential-free HTTPS base URL");
    return nil;
  }
  NSString *normalized = components.URL.absoluteString;
  return [normalized hasSuffix:@"/"] ? normalized : [normalized stringByAppendingString:@"/"];
}

- (BOOL)writeText:(NSString *)text relativePath:(NSString *)relative root:(NSURL *)root error:(NSError **)error {
  NSURL *target = [root URLByAppendingPathComponent:relative isDirectory:NO];
  NSURL *parent = target.URLByDeletingLastPathComponent;
  if (![[NSFileManager defaultManager] createDirectoryAtURL:parent
                                withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions: @0700}
                                                      error:error]) {
    return NO;
  }
  chmod(parent.fileSystemRepresentation, 0700);
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil || ![data writeToURL:target options:NSDataWritingAtomic error:error]) return NO;
  chmod(target.fileSystemRepresentation, 0600);
  return YES;
}

- (NSDictionary *)validatedEntry:(NSDictionary *)mirrors
                         category:(NSString *)category
                      logicalPath:(NSString *)logicalPath
                      defaultBase:(NSString *)defaultBase
                            error:(NSError **)error {
  NSDictionary *raw = [mirrors[category] isKindOfClass:NSDictionary.class] ? mirrors[category] : nil;
  NSNumber *enabledValue = LMBool(raw[@"enabled"]);
  NSString *baseURL = [self normalizedHTTPSBaseURL:raw[@"baseUrl"] error:error];
  if (raw == nil || enabledValue == nil || baseURL == nil) {
    if (error != nil && *error == nil) *error = LMError(3003, @"Mirror configuration is invalid");
    return nil;
  }
  BOOL enabled = enabledValue.boolValue;
  return @{
    @"category": category,
    @"enabled": @(enabled),
    @"base_url": enabled ? baseURL : defaultBase,
    @"logical_path": logicalPath,
  };
}

- (NSDictionary *)apply:(id)value error:(NSError **)error {
  NSDictionary *mirrors = [value isKindOfClass:NSDictionary.class] ? value : nil;
  if (mirrors == nil || mirrors.count != 3) {
    if (error != nil) *error = LMError(3004, @"Mirror configuration must contain three categories");
    return nil;
  }
  NSDictionary *alpine = [self validatedEntry:mirrors
                                      category:@"alpine"
                                   logicalPath:@"etc/apk/repositories"
                                   defaultBase:@"https://dl-cdn.alpinelinux.org/alpine/"
                                         error:error];
  NSDictionary *pip = [self validatedEntry:mirrors
                                   category:@"pip"
                                logicalPath:@"etc/pip/pip.conf"
                                defaultBase:@"https://pypi.org/simple/"
                                      error:error];
  NSDictionary *npm = [self validatedEntry:mirrors
                                   category:@"npm"
                                logicalPath:@"root/.npmrc"
                                defaultBase:@"https://registry.npmjs.org/"
                                      error:error];
  if (alpine == nil || pip == nil || npm == nil) return nil;

  NSURL *root = [self overlayRoot:error];
  if (root == nil) return nil;
  NSString *alpineBase = alpine[@"base_url"];
  NSString *pipBase = pip[@"base_url"];
  NSString *npmBase = npm[@"base_url"];
  NSString *apk = [NSString stringWithFormat:@"%@v3.21/main\n%@v3.21/community\n", alpineBase, alpineBase];
  NSString *pipConfig = [NSString stringWithFormat:@"[global]\nbreak-system-packages = true\nindex-url = %@\n", pipBase];
  NSString *npmConfig = [NSString stringWithFormat:@"registry=%@\n", npmBase];
  if (![self writeText:apk relativePath:alpine[@"logical_path"] root:root error:error]
    || ![self writeText:pipConfig relativePath:pip[@"logical_path"] root:root error:error]
    || ![self writeText:npmConfig relativePath:npm[@"logical_path"] root:root error:error]) {
    return nil;
  }

  NSString *stagedAt = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
  // guest_runtime_mounted reflects the shared registry: YES only while a
  // LocalGuestModule session is genuinely booted. It does NOT mean the staged
  // overlay below reached the guest — the interpreter has no block-device
  // injection, so staged_config_enters_guest stays false until a real mount
  // path exists (see docs/mobile-guest-runtime.md).
  NSDictionary *receipt = @{
    @"schema_version": @1,
    @"status": @"staged",
    @"staged_at": stagedAt,
    @"guest_runtime_mounted":
        @([[DSHGuestRuntimeState sharedState] guestRuntimeMounted]),
    @"staged_config_enters_guest": @NO,
    @"root": @"rish-guest-overlay",
    @"entries": @[alpine, pip, npm],
  };
  NSData *manifest = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:error];
  NSURL *manifestURL = [root URLByAppendingPathComponent:@"mirrors.json"];
  if (manifest == nil || ![manifest writeToURL:manifestURL options:NSDataWritingAtomic error:error]) return nil;
  chmod(manifestURL.fileSystemRepresentation, 0600);
  return receipt;
}

RISH_NATIVE_METHOD(applyMirrors,
                 applyMirrorsValue:(NSDictionary *)mirrors
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  dispatch_async(self.queue, ^{
    NSError *error = nil;
    NSDictionary *receipt = [self apply:mirrors error:&error];
    if (receipt == nil) {
      reject(@"mirrors", error.localizedDescription ?: @"Mirror configuration could not be staged", error);
      return;
    }
    resolve(receipt);
  });
}

RISH_NATIVE_METHOD(mirrorStatus,
                 mirrorStatusWithResolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  dispatch_async(self.queue, ^{
    NSError *error = nil;
    NSURL *root = [self overlayRoot:&error];
    NSURL *manifestURL = [root URLByAppendingPathComponent:@"mirrors.json"];
    NSData *data = root == nil ? nil : [NSData dataWithContentsOfURL:manifestURL options:0 error:&error];
    if (data == nil) {
      if (error == nil || error.code == NSFileReadNoSuchFileError) resolve((id)kCFNull);
      else reject(@"mirrors", error.localizedDescription, error);
      return;
    }
    NSDictionary *receipt = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![receipt isKindOfClass:NSDictionary.class]) {
      reject(@"mirrors", @"Stored mirror manifest is invalid", error);
      return;
    }
    resolve(receipt);
  });
}

@end
