#import <UIKit/UIKit.h>
#import "RishFileEditorController.h"
#import "RishComposerController.h"

@interface RishComposerController (LayoutTests)
- (void)settleCancellation;
@end

// This executable creates only offscreen views. It exercises real Auto Layout
// before any keyboard/window attachment; no UI events or presentation occur.
static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
  checks += 1;
  NSCAssert(condition, @"%@", message);
}

static void Layout(UIView *view, CGSize size) {
  view.frame = (CGRect){CGPointZero, size};
  [view setNeedsLayout];
  [view layoutIfNeeded];
}

static void CheckViewport(RishFileEditorController *controller, CGSize size) {
  UIView *view = controller.view;
  Layout(view, size);
  UITextView *editor = [controller valueForKey:@"editor"];
  UIButton *save = [controller valueForKey:@"saveButton"];
  UIButton *cancel = [controller valueForKey:@"cancelButton"];
  CGRect editorFrame = [editor convertRect:editor.bounds toView:view];
  CGRect saveFrame = [save convertRect:save.bounds toView:view];
  CGRect cancelFrame = [cancel convertRect:cancel.bounds toView:view];
  CGRect allowed = CGRectInset(view.bounds, -0.5, -0.5);
  Check(editor.bounds.size.height >= 100 && editor.bounds.size.width >= 200,
        [NSString stringWithFormat:@"Visible text viewport before keyboard: %@ in %@",
          NSStringFromCGRect(editorFrame), NSStringFromCGSize(size)]);
  Check(!editor.hasAmbiguousLayout && !editor.superview.hasAmbiguousLayout,
        @"Text viewport and content stack must be fully constrained");
  Check(CGRectContainsRect(allowed, editorFrame), @"Editor must stay inside the viewport");
  Check(CGRectContainsRect(allowed, saveFrame) && CGRectContainsRect(allowed, cancelFrame),
        @"Both header actions must stay inside the viewport");
  Check(!save.hasAmbiguousLayout && !cancel.hasAmbiguousLayout &&
    saveFrame.size.width >= 44 && saveFrame.size.height >= 44 &&
    cancelFrame.size.width >= 44 && cancelFrame.size.height >= 44,
    [NSString stringWithFormat:@"Header actions need constrained, usable touch targets: save %@ ambiguous=%d, cancel %@ ambiguous=%d",
      NSStringFromCGRect(saveFrame), save.hasAmbiguousLayout,
      NSStringFromCGRect(cancelFrame), cancel.hasAmbiguousLayout]);
  Check(CGRectGetMinY(editorFrame) >= MAX(CGRectGetMaxY(saveFrame), CGRectGetMaxY(cancelFrame)),
        @"Header controls cannot overlap editable text");
}

static void TestAppearance(UIUserInterfaceStyle style) {
  NSString *text = @"  中文 👩‍💻\r\n\tCafe\u0301\n\n";
  RishFileEditorController *controller = [RishFileEditorController new];
  controller.options = @{@"initial_text": text, @"title": @"很长的文件名-configuration.md",
    @"appearance": style == UIUserInterfaceStyleDark ? @"dark" : @"light",
    @"save_label": @"保存", @"cancel_label": @"取消", @"max_bytes": @64,
    @"too_long_message": @"文件太大，请缩短内容后再保存。"};
  controller.overrideUserInterfaceStyle = style;
  [controller loadViewIfNeeded];
  UITextView *editor = [controller valueForKey:@"editor"];
  UIView *helperArea = [controller valueForKey:@"helperArea"];
  UILabel *helper = [controller valueForKey:@"helper"];
  UIButton *save = [controller valueForKey:@"saveButton"];

  CheckViewport(controller, CGSizeMake(402, 874));
  CGFloat fontSize = editor.font.pointSize;
  for (NSValue *size in @[[NSValue valueWithCGSize:CGSizeMake(844, 250)],
                         [NSValue valueWithCGSize:CGSizeMake(320, 640)],
                         [NSValue valueWithCGSize:CGSizeMake(768, 1024)],
                         [NSValue valueWithCGSize:CGSizeMake(1366, 1024)]]) {
    CheckViewport(controller, size.CGSizeValue);
    Check(editor.bounds.size.width <= 960 && editor.font.pointSize == fontSize,
          @"iPad and Split View use a reading column without enlarging text");
  }
  Check(fabs(editor.bounds.size.width - 960) < 1,
        @"Wide iPad makes more code visible up to the readable column limit");
  Check(editor.editable && [editor.text isEqualToString:text],
        @"Editable initial contents must retain whitespace, CRLF, combining marks and emoji");
  Check(helperArea.hidden && save.enabled, @"Valid initial text must not show an error");
  Check(controller.view.opaque && controller.view.layer.backgroundColor != NULL &&
    CGColorGetAlpha(controller.view.layer.backgroundColor) == 1,
    @"The full-screen surface needs an explicit opaque layer fill");
  CGFloat white = 0, alpha = 0;
  [[UIColor colorWithCGColor:controller.view.layer.backgroundColor] getWhite:&white alpha:&alpha];
  Check(alpha == 1 && (style == UIUserInterfaceStyleDark ? white < 0.2 : white > 0.9),
        @"The full-screen layer must resolve to the requested appearance");

  NSString *oversized = [@"" stringByPaddingToLength:65 withString:@"a" startingAtIndex:0];
  editor.text = oversized;
  [controller textViewDidChange:editor];
  Layout(controller.view, CGSizeMake(844, 250));
  Check(!helperArea.hidden && !save.enabled && helper.bounds.size.height > 0,
        @"An oversized buffer must display the error and disable saving");
  Check([editor.text isEqualToString:oversized] && editor.bounds.size.height >= 100,
        @"Validation must keep the full buffer and a usable text viewport");
  Check(CGRectContainsRect(CGRectInset(controller.view.bounds, -0.5, -0.5),
      [helper convertRect:helper.bounds toView:controller.view]),
      @"The validation message must remain within short landscape bounds");

  editor.text = @"";
  [controller textViewDidChange:editor];
  Layout(controller.view, CGSizeMake(402, 874));
  Check(helperArea.hidden && save.enabled && editor.text.length == 0,
        @"Clearing a file is valid and must remove the error without inserting text");
  Check(!editor.hasAmbiguousLayout && editor.bounds.size.height > 700,
        @"The viewport must recover after hiding the error");

  // Exercise the initial no-tracked-constraints lifecycle and verify that a
  // later keyboard boundary can override, then release, the safe-area fallback.
  [controller.view.keyboardLayoutGuide removeAllTrackedConstraints];
  Layout(controller.view, CGSizeMake(402, 874));
  CGFloat initialHeight = editor.bounds.size.height;
  Check(initialHeight > 700 && !editor.hasAmbiguousLayout,
        @"The editor must stay visible before keyboard tracking is initialized");
  NSLayoutConstraint *keyboardBoundary = [editor.superview.bottomAnchor
    constraintEqualToAnchor:controller.view.bottomAnchor constant:-280];
  keyboardBoundary.active = YES;
  [controller.view layoutIfNeeded];
  Check(editor.bounds.size.height > 400 && editor.bounds.size.height < initialHeight &&
    !editor.hasAmbiguousLayout, @"Keyboard constraints must override the baseline without collapsing text");
  keyboardBoundary.active = NO;
  [controller.view layoutIfNeeded];
  Check(fabs(editor.bounds.size.height - initialHeight) < 1,
        @"The editor must recover its height after the keyboard constraint is removed");
}

static void TestComposer(UIUserInterfaceStyle style) {
  RishComposerController *controller = [RishComposerController new];
  controller.initialText = @"  中文 👩‍💻\r\n\tCafe\u0301\n\n";
  controller.title = @"让 Rish 帮你实现想法…";
  controller.overrideUserInterfaceStyle = style;
  [controller loadViewIfNeeded];
  [controller.view.keyboardLayoutGuide removeAllTrackedConstraints];
  UITextView *editor = [controller valueForKey:@"editor"];
  UIButton *done = [controller valueForKey:@"doneButton"];
  UIButton *cancel = [controller valueForKey:@"cancelButton"];
  CGFloat fontSize = editor.font.pointSize;
  for (NSValue *size in @[[NSValue valueWithCGSize:CGSizeMake(402, 874)],
                         [NSValue valueWithCGSize:CGSizeMake(844, 250)],
                         [NSValue valueWithCGSize:CGSizeMake(320, 640)],
                         [NSValue valueWithCGSize:CGSizeMake(768, 1024)],
                         [NSValue valueWithCGSize:CGSizeMake(1366, 1024)]]) {
    Layout(controller.view, size.CGSizeValue);
    Check(editor.bounds.size.width <= 720 && editor.bounds.size.height >= 100 &&
          !editor.hasAmbiguousLayout, @"Composer retains a constrained usable viewport at every window size");
    Check(done.bounds.size.width >= 44 && done.bounds.size.height >= 44 &&
          cancel.bounds.size.width >= 44 && cancel.bounds.size.height >= 44,
          @"Composer actions remain at least 44 points without navigation chrome");
    Check(editor.font.pointSize == fontSize && [editor.text isEqual:controller.initialText],
          @"Resizing preserves composer font size and exact editing buffer");
    Check(CGRectContainsRect(CGRectInset(controller.view.bounds, -0.5, -0.5), editor.frame),
          @"Composer remains inside narrow and wide windows");
  }
  Check(controller.view.opaque && CGColorGetAlpha(controller.view.layer.backgroundColor) == 1 &&
        editor.opaque && CGColorGetAlpha(editor.layer.backgroundColor) == 1,
        @"Composer and editing surface use explicit opaque theme fills");
  Layout(controller.view, CGSizeMake(402, 874));
  CGFloat initialHeight = editor.bounds.size.height;
  NSLayoutConstraint *keyboard = [editor.bottomAnchor constraintEqualToAnchor:controller.view.bottomAnchor constant:-280];
  keyboard.active = YES;
  [controller.view layoutIfNeeded];
  Check(editor.bounds.size.height > 400 && editor.bounds.size.height < initialHeight &&
        !editor.hasAmbiguousLayout, @"Keyboard overrides composer baseline without collapsing text");
  keyboard.active = NO;
  [controller.view layoutIfNeeded];
  Check(fabs(editor.bounds.size.height - initialHeight) < 1, @"Composer baseline returns after keyboard dismissal");
  __block NSUInteger settlements = 0;
  controller.finish = ^(id value) { settlements++; Check(value == NSNull.null, @"Dismissed composer cancels"); };
  [controller settleCancellation];
  [controller settleCancellation];
  Check(settlements == 1, @"Composer settles the bridge exactly once");
}

int main(void) {
  @autoreleasepool {
    TestAppearance(UIUserInterfaceStyleLight);
    TestAppearance(UIUserInterfaceStyleDark);
    TestComposer(UIUserInterfaceStyleLight);
    TestComposer(UIUserInterfaceStyleDark);
    printf("PASS: %lu offscreen UIKit editor/composer checks, iPhone, iPad landscape, Split View, opaque themes and keyboard baseline\n",
           (unsigned long)checks);
  }
  return 0;
}
