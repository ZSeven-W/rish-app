#import "ShellAssistantAvatarPicker.h"
#import "ShellAssistantAvatarImage.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

BOOL ShellAssistantAvatarRequestValid(id request) {
  if (![request isKindOfClass:NSDictionary.class] || [request count] != 2) return NO;
  NSNumber *schema = request[@"schema_version"], *initiated = request[@"userInitiated"];
  return [schema isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)schema) != CFBooleanGetTypeID() &&
    !CFNumberIsFloatType((__bridge CFNumberRef)schema) && schema.longLongValue == 1 &&
    [initiated isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)initiated) == CFBooleanGetTypeID() &&
    initiated.boolValue;
}

@interface ShellAssistantAvatarPicker () <PHPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic, strong) PHPickerViewController *picker;
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic, copy) NSString *operation;
@property(nonatomic, copy) RishResolveBlock resolve;
@property(nonatomic, copy) RishRejectBlock reject;
@property(nonatomic) BOOL selectionStarted;
@end

@implementation ShellAssistantAvatarPicker
- (BOOL)busy { return self.operation != nil; }
- (void)presentFrom:(UIViewController *)presenter directory:(NSURL *)directory
           resolve:(RishResolveBlock)resolve reject:(RishRejectBlock)reject {
  NSAssert(NSThread.isMainThread, @"Avatar picker requires the main queue");
  if (self.busy) { reject(@"E_ASSISTANT_AVATAR_BUSY", @"Another avatar selection is in progress.", nil); return; }
  if (presenter == nil || presenter.isBeingDismissed || presenter.isBeingPresented ||
      UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
    reject(@"E_ASSISTANT_AVATAR_UNAVAILABLE", @"Return to Rish to choose an avatar.", nil); return;
  }
  self.directory = directory;
  self.operation = NSUUID.UUID.UUIDString;
  self.resolve = resolve; self.reject = reject; self.selectionStarted = NO;
  // The system picker grants access only to the selected item. There is no
  // PHPhotoLibrary authorization request and no shared chat-attachment store.
  PHPickerConfiguration *configuration = [PHPickerConfiguration new];
  configuration.filter = PHPickerFilter.imagesFilter;
  configuration.selectionLimit = 1;
  configuration.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
  self.picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
  self.picker.delegate = self;
  self.picker.modalPresentationStyle = UIModalPresentationPageSheet;
  [presenter presentViewController:self.picker animated:YES completion:nil];
  self.picker.presentationController.delegate = self;
}
- (void)finish:(id)value error:(NSError *)error operation:(NSString *)operation {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![self.operation isEqual:operation]) return;
    RishResolveBlock resolve = self.resolve; RishRejectBlock reject = self.reject;
    self.resolve = nil; self.reject = nil; self.operation = nil; self.picker = nil; self.directory = nil;
    self.selectionStarted = NO;
    if (error) {
      id candidate = error.userInfo[@"code"];
      NSString *code = [candidate isKindOfClass:NSString.class] &&
          [@[@"E_ASSISTANT_AVATAR_INVALID", @"E_ASSISTANT_AVATAR_TOO_LARGE", @"E_ASSISTANT_AVATAR_STORAGE"] containsObject:candidate]
          ? candidate : @"E_ASSISTANT_AVATAR_INVALID";
      reject(code, @"This image cannot be used as an avatar.", error);
    } else resolve(value ?: NSNull.null);
  });
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
  if (picker != self.picker || self.selectionStarted) return;
  NSString *operation = self.operation;
  self.selectionStarted = YES;
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (results.count == 0) { [self finish:NSNull.null error:nil operation:operation]; return; }
  if (results.count != 1) {
    [self finish:nil error:[NSError errorWithDomain:@"RishAssistantAvatar" code:1 userInfo:nil] operation:operation]; return;
  }
  NSItemProvider *provider = results.firstObject.itemProvider;
  NSString *identifier = nil;
  for (NSString *registered in provider.registeredTypeIdentifiers) {
    if ([[UTType typeWithIdentifier:registered] conformsToType:UTTypeImage]) { identifier = registered; break; }
  }
  if (identifier == nil) {
    [self finish:nil error:[NSError errorWithDomain:@"RishAssistantAvatar" code:1 userInfo:nil] operation:operation]; return;
  }
  NSURL *directory = self.directory;
  [provider loadFileRepresentationForTypeIdentifier:identifier completionHandler:^(NSURL *url, NSError *providerError) {
    @autoreleasepool {
      NSError *error = providerError;
      // NSItemProvider invokes completion on an internal queue, and its source
      // URL expires when this block returns. Import bounded pixels here before
      // hopping back to main; no photo data or absolute path crosses the bridge.
      NSDictionary *avatar = url && !error ? [ShellAssistantAvatarImage importImageAtURL:url
          intoAssistantDirectory:directory error:&error] : nil;
      if (!avatar && !error) error = [NSError errorWithDomain:@"RishAssistantAvatar" code:1 userInfo:nil];
      [self finish:avatar ? @{@"schema_version":@1, @"avatar":avatar} : nil error:error operation:operation];
    }
  }];
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)controller {
  if (controller.presentedViewController == self.picker && !self.selectionStarted)
    [self finish:NSNull.null error:nil operation:self.operation];
}
@end
