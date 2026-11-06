#import "LayoutMetrics.h"
#import <UIKit/UIKit.h>
#include <math.h>

static UIWindow *RishKeyWindow(void) {
  UIApplication *application = UIApplication.sharedApplication;
  for (UIScene *scene in application.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] ||
        (scene.activationState != UISceneActivationStateForegroundActive &&
         scene.activationState != UISceneActivationStateForegroundInactive)) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      if (window.isKeyWindow) return window;
    }
  }
  // The pinned GPUI backend still creates a legacy UIWindow. Inspect the real
  // key window in that path too; never substitute UIScreen size or guessed safe
  // areas for a window that has not yet been created.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  for (UIWindow *window in application.windows) {
    if (window.isKeyWindow) return window;
  }
#pragma clang diagnostic pop
  return nil;
}

bool rish_gpui_layout_metrics(float *values, size_t count) {
  if (values == NULL || count < 8 || !NSThread.isMainThread) return false;
  UIWindow *window = RishKeyWindow();
  if (window == nil) return false;
  CGSize size = window.bounds.size;
  if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0) return false;
  UIEdgeInsets insets = window.safeAreaInsets;
  values[0] = (float)size.width;
  values[1] = (float)size.height;
  values[2] = (float)insets.top;
  values[3] = (float)insets.right;
  values[4] = (float)insets.bottom;
  values[5] = (float)insets.left;
  values[6] = (float)window.traitCollection.horizontalSizeClass;
  values[7] = (float)window.traitCollection.verticalSizeClass;
  return true;
}
