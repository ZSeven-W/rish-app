#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RishGPUIBridge.h"
#import "RishRuntimeEngineDownloads.h"
#import "RishGPUI-Swift.h"

extern void rish_gpui_run(void);
extern void *gpui_ios_initialize(void);
extern void gpui_ios_did_finish_launching(void *app);
extern void *gpui_ios_get_window(void);
extern void gpui_ios_request_frame(void *window);
extern void gpui_ios_will_enter_foreground(void *app);
extern void gpui_ios_did_become_active(void *app);
extern void gpui_ios_will_resign_active(void *app);
extern void gpui_ios_did_enter_background(void *app);
extern void gpui_ios_will_terminate(void *app);

static int RishArgumentCount;
static char **RishArgumentValues;
static int RishExitStatus;
static void *RishGPUIApplication;

@interface RishGPUIAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) void *gpuiApp;
@property(nonatomic) void *gpuiWindow;
@end

@implementation RishGPUIAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  [RishTaskExperienceBridge configureWithEmitter:^(NSString *name, NSDictionary *event) {
    RishGPUIEmitEvent(name, event);
  }];
  self.gpuiApp = RishGPUIApplication;
  // The Rust platform has already stored Application::run's callback. Invoke
  // it only after UIKit launches, while the owning Rust stack remains alive.
  gpui_ios_did_finish_launching(self.gpuiApp);
  self.gpuiWindow = gpui_ios_get_window();
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  for (UIWindow *window in application.windows) {
    if (window.isKeyWindow) { self.window = window; break; }
  }
#pragma clang diagnostic pop
  [self startDisplayLink];
  return YES;
}
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url
    options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
  return [RishTaskExperienceBridge openURL:url];
}
- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier
    completionHandler:(void (^)(void))completionHandler {
  if ([identifier isEqual:RishRuntimeEngineDownloads.backgroundSessionIdentifier]) {
    [[RishRuntimeEngineDownloads shared] handleBackgroundEventsWithCompletion:completionHandler];
  } else {
    completionHandler();
  }
}
- (void)startDisplayLink {
  if (self.displayLink != nil || self.gpuiWindow == NULL) return;
  self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(renderFrame)];
  [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)renderFrame {
  if (self.gpuiWindow != NULL) gpui_ios_request_frame(self.gpuiWindow);
}
- (void)applicationWillEnterForeground:(UIApplication *)application {
  gpui_ios_will_enter_foreground(self.gpuiApp);
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
  [RishTaskExperienceBridge foregroundChanged:YES];
  gpui_ios_did_become_active(self.gpuiApp);
  [self startDisplayLink];
}
- (void)applicationWillResignActive:(UIApplication *)application {
  gpui_ios_will_resign_active(self.gpuiApp);
  [self.displayLink invalidate];
  self.displayLink = nil;
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
  [RishTaskExperienceBridge foregroundChanged:NO];
  gpui_ios_did_enter_background(self.gpuiApp);
}
- (void)applicationWillTerminate:(UIApplication *)application {
  [self.displayLink invalidate];
  self.displayLink = nil;
  [RishTaskExperienceBridge willTerminate];
  gpui_ios_will_terminate(self.gpuiApp);
}
@end

// Called synchronously by the Rust platform's run implementation. Returning
// immediately from that implementation would drop Application's strong owner
// and leave GPUI's native window callbacks pointing into freed Rust state.
int rish_gpui_enter_ui_application(void) {
  RishExitStatus = UIApplicationMain(RishArgumentCount, RishArgumentValues, nil,
                                   NSStringFromClass(RishGPUIAppDelegate.class));
  return RishExitStatus;
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    RishArgumentCount = argc;
    RishArgumentValues = argv;
    RishGPUIApplication = gpui_ios_initialize();
    rish_gpui_run();
    return RishExitStatus;
  }
}
