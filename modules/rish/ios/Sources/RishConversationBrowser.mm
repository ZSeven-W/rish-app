#import "RishConversationBrowser.h"
#import <RishNative/RishUIKit.h>
#import <SafariServices/SafariServices.h>
#import <UIKit/UIKit.h>

@interface RishConversationBrowser () <SFSafariViewControllerDelegate>
@property(nonatomic, strong) SFSafariViewController *browser;
@property(nonatomic, strong) NSURL *currentURL;
@end

@implementation RishConversationBrowser

+ (NSURL *)URLForRequest:(id)request {
  if (![request isKindOfClass:NSDictionary.class] || [request count] != 2 ||
      ![request[@"schema_version"] isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)request[@"schema_version"]) == CFBooleanGetTypeID() ||
      ![request[@"schema_version"] isEqual:@1] ||
      ![request[@"url"] isKindOfClass:NSString.class]) return nil;
  NSString *address = request[@"url"];
  if (address.length == 0 || address.length > 2048 ||
      [address rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
      [address rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
      [address containsString:@"\\"]) return nil;
  NSURLComponents *parts = [NSURLComponents componentsWithString:address];
  if (![@[@"http", @"https"] containsObject:parts.scheme.lowercaseString ?: @""] ||
      parts.host.length == 0 || parts.user != nil || parts.password != nil ||
      (parts.port != nil && (parts.port.integerValue < 1 || parts.port.integerValue > 65535))) return nil;
  return parts.URL;
}

- (void)openRequest:(id)request
        completion:(void (^)(NSString *))completion {
  NSURL *url = [self.class URLForRequest:request];
  if (url == nil) { completion(@"E_BROWSER_URL"); return; }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.browser != nil) {
      completion([self.currentURL isEqual:url] ? nil : @"E_BROWSER_BUSY");
      return;
    }
    UIViewController *presenter = RishPresentedViewController();
    if (presenter == nil || presenter.isBeingDismissed || presenter.isBeingPresented ||
        [presenter isKindOfClass:UIAlertController.class] ||
        [presenter isKindOfClass:SFSafariViewController.class]) {
      completion(@"E_BROWSER_UNAVAILABLE"); return;
    }
    SFSafariViewController *browser = [[SFSafariViewController alloc] initWithURL:url];
    browser.delegate = self;
    browser.dismissButtonStyle = SFSafariViewControllerDismissButtonStyleClose;
    browser.modalPresentationStyle = UIModalPresentationFullScreen;
    self.browser = browser;
    self.currentURL = url;
    [presenter presentViewController:browser animated:YES completion:^{ completion(nil); }];
  });
}

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
  [controller dismissViewControllerAnimated:YES completion:^{
    if (self.browser == controller) {
      self.browser = nil;
      self.currentURL = nil;
    }
  }];
}

@end
