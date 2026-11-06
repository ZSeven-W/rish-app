#pragma once
#import <UIKit/UIKit.h>

static inline UIApplication *RishSharedApplication(void) {
  return UIApplication.sharedApplication;
}

static inline UIViewController *RishPresentedViewController(void) {
  UIWindow *window = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (scene.activationState != UISceneActivationStateForegroundActive ||
        ![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
      if (candidate.isKeyWindow) { window = candidate; break; }
    }
    if (window != nil) break;
  }
  // The pinned GPUI platform creates a legacy UIWindow without a scene.
  if (window == nil) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
      if (candidate.isKeyWindow) { window = candidate; break; }
    }
#pragma clang diagnostic pop
  }
  UIViewController *controller = window.rootViewController;
  while (controller.presentedViewController != nil &&
         !controller.presentedViewController.isBeingDismissed) {
    controller = controller.presentedViewController;
  }
  return controller;
}
