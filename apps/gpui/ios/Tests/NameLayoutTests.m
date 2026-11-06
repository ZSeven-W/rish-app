#import <UIKit/UIKit.h>
#import "RishNameController.h"

// UIKit regression executable, run inside an iOS simulator with simctl spawn.
// No application is presented and no keyboard/UI events are synthesized.
int main(void) {
  @autoreleasepool {
    RishNameController *controller = [RishNameController new];
    controller.options = @{
      @"kind": @"workspace", @"initial_text": @"", @"title": @"工作空间名称",
      @"label": @"名称", @"placeholder": @"例如：我的项目", @"hint": @"为工作空间选择一个名称",
      @"submit_label": @"创建", @"cancel_label": @"取消", @"empty_error": @"请输入名称",
      @"invalid_error": @"名称无效", @"long_error": @"名称太长", @"appearance": @"light",
    };
    controller.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    [controller loadViewIfNeeded];
    UIView *view = controller.view;
    view.frame = CGRectMake(0, 0, 402, 314);
    UIScrollView *scroll = [controller valueForKey:@"scroll"];
    UITextField *editor = [controller valueForKey:@"editor"];
    UIStackView *content = [controller valueForKey:@"content"];
    UIView *card = [controller valueForKey:@"card"];
    UIView *scrim = [controller valueForKey:@"scrim"];

    // The simulator's first sheet attachment left both tracked constraints
    // inactive. Reproduce that lifecycle state before evaluating the viewport.
    [view.keyboardLayoutGuide removeAllTrackedConstraints];
    [view setNeedsLayout];
    [view layoutIfNeeded];
    NSCAssert(scroll.bounds.size.height > 200, @"Initial form must have a visible viewport");
    NSCAssert(!scroll.hasAmbiguousLayout, @"Initial viewport must be fully constrained");
    NSCAssert(content.bounds.size.height > 100 && editor.bounds.size.height >= 28,
              @"Naming controls must retain their intrinsic content sizes");
    CGFloat initialHeight = scroll.bounds.size.height;

    // A required keyboard constraint must still take precedence over the
    // baseline. This checks the fallback does not obstruct later avoidance.
    NSLayoutConstraint *keyboardBottom =
      [scroll.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-120];
    keyboardBottom.active = YES;
    [view layoutIfNeeded];
    NSCAssert(scroll.bounds.size.height > 0 && scroll.bounds.size.height < initialHeight,
              @"Keyboard must be able to shrink the initial viewport");
    NSCAssert(!scroll.hasAmbiguousLayout, @"Keyboard-adjusted viewport must remain constrained");
    keyboardBottom.active = NO;
    [view layoutIfNeeded];
    NSCAssert(fabs(scroll.bounds.size.height - initialHeight) < 1,
              @"Baseline must restore the viewport after keyboard constraints deactivate");
    NSCAssert(card.opaque && card.layer.backgroundColor != NULL &&
      CGColorGetAlpha(card.layer.backgroundColor) == 1,
      @"Card must have an explicit opaque layer fill");
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    [[UIColor colorWithCGColor:card.layer.backgroundColor] getRed:&red green:&green blue:&blue alpha:&alpha];
    NSCAssert(fabs(red - 1) < 0.001 && fabs(green - 1) < 0.001 && fabs(blue - 1) < 0.001 &&
      alpha == 1, @"Light card layer must paint the exact white panel palette");
    NSCAssert([view.subviews indexOfObject:scrim] < [view.subviews indexOfObject:card] &&
      fabs(CGColorGetAlpha(scrim.layer.backgroundColor) - 0.25) < 0.001,
      @"The 25 percent scrim must remain behind the card");
    view.frame = CGRectMake(0, 0, 844, 250);
    [view setNeedsLayout];
    [view layoutIfNeeded];
    NSCAssert(card.bounds.size.width <= 540 && scroll.bounds.size.height > 100 &&
      CGRectGetMinY(card.frame) >= 12 && CGRectGetMaxY(card.frame) <= 242,
      @"Short landscape must bound the card and retain a usable scroll viewport");
    CGFloat fontSize = editor.font.pointSize;
    for (NSValue *size in @[[NSValue valueWithCGSize:CGSizeMake(320, 640)],
                           [NSValue valueWithCGSize:CGSizeMake(768, 1024)],
                           [NSValue valueWithCGSize:CGSizeMake(1366, 1024)]]) {
      view.frame = (CGRect){CGPointZero, size.CGSizeValue};
      [view setNeedsLayout];
      [view layoutIfNeeded];
      NSCAssert(card.bounds.size.width <= 540 && scroll.bounds.size.height > 200 &&
        !scroll.hasAmbiguousLayout, @"iPad and Split View retain a bounded usable form");
      NSCAssert(editor.font.pointSize == fontSize, @"Wide forms must not enlarge field typography");
    }
    NSCAssert(fabs(card.bounds.size.width - 540) < 1, @"Wide iPad keeps the naming card at its readable width");
    puts("PASS: 17 UIKit name layout checks, keyboard, opaque card, iPad landscape and Split View");
  }
  return 0;
}
