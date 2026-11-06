#import <RishNative/RishNativeModule.h>
#import <RishNative/RishUIKit.h>
#import "RishNameController.h"
#import "RishNameValidation.h"
#import "RishFileEditorController.h"
#import "RishFileEditorValidation.h"
#import "RishGitFormController.h"
#import "RishGitFormValidation.h"

#import "RishComposerController.h"
#import "RishInlineComposer.h"
#import "RishInlineComposerValidation.h"

@interface ShellInputModule : NSObject <RishNativeModule>
@property(nonatomic, strong) UIViewController *activeEditor;
@property(nonatomic, strong) RishInlineComposer *inlineComposer;
@end

@implementation ShellInputModule
RISH_NATIVE_MODULE(ShellInput)
+ (BOOL)requiresMainQueueSetup { return YES; }
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }
- (RishInlineComposer *)inlineHost {
  if (self.inlineComposer == nil) self.inlineComposer = [RishInlineComposer new];
  return self.inlineComposer;
}
RISH_NATIVE_METHOD(inlineSync, inlineSyncWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (self.activeEditor != nil && RishInlineSyncValid(options)) {
    NSMutableDictionary *hidden = [options mutableCopy]; hidden[@"visible"] = @NO;
    [[self inlineHost] sync:hidden resolve:resolve reject:reject];
  } else [[self inlineHost] sync:options resolve:resolve reject:reject];
}
RISH_NATIVE_METHOD(inlineWait, inlineWaitWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  [[self inlineHost] wait:options resolve:resolve reject:reject];
}
RISH_NATIVE_METHOD(inlineSnapshot, inlineSnapshotWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  [[self inlineHost] snapshot:options resolve:resolve reject:reject];
}
RISH_NATIVE_METHOD(inlineClose, inlineCloseWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  [[self inlineHost] close:options resolve:resolve reject:reject];
}
RISH_NATIVE_METHOD(inlineClearIfUnchanged, inlineClearIfUnchangedWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  [[self inlineHost] clearIfUnchanged:options resolve:resolve reject:reject];
}
RISH_NATIVE_METHOD(gitForm, gitFormWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!RishGitFormOptionsAreValid(options)) {
    reject(@"shell_input_invalid_options", @"The Git form options are invalid.", nil);
    return;
  }
  UIViewController *presenter = RishPresentedViewController();
  if (self.activeEditor != nil || presenter == nil || presenter.isBeingDismissed) {
    reject(@"shell_input_unavailable", @"The Git form cannot be presented right now.", nil);
    return;
  }
  RishGitFormController *editor = [RishGitFormController new];
  editor.options = options;
  editor.overrideUserInterfaceStyle = [options[@"appearance"] isEqual:@"dark"] ?
    UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
  editor.modalPresentationStyle = UIModalPresentationFullScreen;
  editor.presentationController.delegate = editor;
  __weak ShellInputModule *weakSelf = self;
  editor.finish = ^(id value) {
    weakSelf.activeEditor = nil;
    resolve(value);
  };
  self.activeEditor = editor;
  [self.inlineComposer obscure];
  [presenter presentViewController:editor animated:YES completion:nil];
}
RISH_NATIVE_METHOD(editFile, editFileWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!RishFileEditorOptionsAreValid(options)) {
    reject(@"shell_input_invalid_options", @"The file editor options are invalid.", nil);
    return;
  }
  UIViewController *presenter = RishPresentedViewController();
  if (self.activeEditor != nil || presenter == nil || presenter.isBeingDismissed) {
    reject(@"shell_input_unavailable", @"The file editor cannot be presented right now.", nil);
    return;
  }
  RishFileEditorController *editor = [RishFileEditorController new];
  editor.options = options;
  editor.overrideUserInterfaceStyle = [options[@"appearance"] isEqual:@"dark"] ?
    UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
  editor.modalPresentationStyle = UIModalPresentationFullScreen;
  editor.presentationController.delegate = editor;
  __weak ShellInputModule *weakSelf = self;
  editor.finish = ^(id value) {
    weakSelf.activeEditor = nil;
    resolve(value);
  };
  self.activeEditor = editor;
  [self.inlineComposer obscure];
  [presenter presentViewController:editor animated:YES completion:nil];
}
RISH_NATIVE_METHOD(name, nameWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!RishNameOptionsAreValid(options)) {
    reject(@"shell_input_invalid_options", @"The naming options are invalid.", nil);
    return;
  }
  UIViewController *presenter = RishPresentedViewController();
  if (self.activeEditor != nil || presenter == nil || presenter.isBeingDismissed) {
    reject(@"shell_input_unavailable", @"The name editor cannot be presented right now.", nil);
    return;
  }
  RishNameController *editor = [RishNameController new];
  editor.options = options;
  editor.overrideUserInterfaceStyle = [options[@"appearance"] isEqual:@"dark"] ?
    UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
  editor.modalPresentationStyle = UIModalPresentationOverFullScreen;
  editor.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
  [editor preparePresentation];
  editor.presentationController.delegate = editor;
  __weak ShellInputModule *weakSelf = self;
  editor.finish = ^(id value) {
    weakSelf.activeEditor = nil;
    resolve(value);
  };
  self.activeEditor = editor;
  [self.inlineComposer obscure];
  [presenter presentViewController:editor animated:YES completion:nil];
}
RISH_NATIVE_METHOD(edit, edit:(NSString *)initialText title:(NSString *)title
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  UIViewController *presenter = RishPresentedViewController();
  if (self.activeEditor != nil || presenter == nil || presenter.isBeingDismissed) {
    reject(@"shell_input_unavailable", @"The text editor cannot be presented right now.", nil);
    return;
  }
  RishComposerController *editor = [RishComposerController new];
  editor.title = title;
  editor.initialText = initialText;
  __weak ShellInputModule *weakSelf = self;
  editor.finish = ^(id value) {
    weakSelf.activeEditor = nil;
    resolve(value);
  };
  self.activeEditor = editor;
  editor.modalPresentationStyle = UIModalPresentationFullScreen;
  editor.presentationController.delegate = editor;
  [self.inlineComposer obscure];
  [presenter presentViewController:self.activeEditor animated:YES completion:nil];
}
@end
