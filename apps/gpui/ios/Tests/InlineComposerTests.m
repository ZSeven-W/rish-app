#import <UIKit/UIKit.h>
#import "RishInlineComposer.h"
#import "RishInlineComposerValidation.h"

// No GPUI, UIWindow, workspace module, first responder or UI event injection.
// The offscreen root is the only view the inline host may attach to.
void *gpui_ios_get_window(void) { return NULL; }
void *gpui_ios_view_controller(void *window) { return NULL; }
static NSUInteger checks;
static void Check(BOOL value, NSString *message) { checks++; NSCAssert(value, @"%@", message); }
static void Drain(void) {
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:0.02];
  while ([end timeIntervalSinceNow] > 0)
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
}
static BOOL IsJSONBoolean(id value) {
  return [value isKindOfClass:NSNumber.class] &&
    CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
static NSDictionary *ProtocolReply(id value) {
  // Exercise the actual bridge's JSON boundary: boolValue also accepts 0/1,
  // while Rust requires genuine JSON booleans for these protocol fields.
  NSData *json = [NSJSONSerialization dataWithJSONObject:value
    options:NSJSONWritingFragmentsAllowed error:nil];
  Check(json != nil, @"Every successful inline reply must serialize as JSON");
  id decoded = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
  Check([decoded isKindOfClass:NSDictionary.class], @"Inline reply survives the bridge JSON round trip");
  NSDictionary *snapshot = decoded[@"snapshot"] ?: decoded;
  Check(IsJSONBoolean(snapshot[@"composing"]), @"Composing must cross the bridge as a JSON boolean, not 0/1");
  Check(IsJSONBoolean(snapshot[@"focused"]), @"Focused must cross the bridge as a JSON boolean, not 0/1");
  if (decoded[@"snapshot"] != nil)
    Check(IsJSONBoolean(decoded[@"cleared"]), @"Conditional clear must return a JSON boolean");
  return decoded;
}
static NSDictionary *Call(RishInlineComposer *host, NSString *method, NSDictionary *options) {
  __block NSDictionary *reply;
  RishResolveBlock resolve = ^(id value) { reply = @{@"value": ProtocolReply(value)}; };
  RishRejectBlock reject = ^(NSString *code, NSString *message, NSError *error) { reply = @{@"error": code}; };
  if ([method isEqual:@"sync"]) [host sync:options resolve:resolve reject:reject];
  else if ([method isEqual:@"snapshot"]) [host snapshot:options resolve:resolve reject:reject];
  else if ([method isEqual:@"clear"]) [host clearIfUnchanged:options resolve:resolve reject:reject];
  else [host close:options resolve:resolve reject:reject];
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:3];
  while (reply == nil && end.timeIntervalSinceNow > 0) Drain();
  Check(reply != nil, @"Every immediate inline request must settle");
  return reply;
}
static NSMutableDictionary *Options(NSString *session) {
  return [@{@"session_id": session, @"text_revision": @1, @"text": @"第一行\nsecond line",
    @"rect": @[@20, @560, @362, @80], @"viewport": @[@402, @874], @"scale": @3,
    @"visible": @YES, @"focus": NSNull.null, @"appearance": @"light", @"placeholder": @"发消息"} mutableCopy];
}
static void CheckPlaceholderAlignment(RishInlineComposer *host) {
  UITextView *editor = [host valueForKey:@"editor"];
  UILabel *placeholder = [host valueForKey:@"placeholder"];
  NSParagraphStyle *paragraph = editor.typingAttributes[NSParagraphStyleAttributeName];
  Check(paragraph.minimumLineHeight == 22 && paragraph.maximumLineHeight == 22,
    @"Explicit replacements and clears preserve the composer's text line metrics");
  Check(placeholder.numberOfLines == 1 && placeholder.lineBreakMode == NSLineBreakByTruncatingTail,
    @"Narrow composer placeholders remain on the same first line as the caret");
  NSParagraphStyle *placeholderParagraph = [placeholder.attributedText attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:nil];
  UIFont *placeholderFont = [placeholder.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:nil];
  Check(placeholderParagraph.minimumLineHeight == paragraph.minimumLineHeight &&
    placeholderParagraph.maximumLineHeight == paragraph.maximumLineHeight &&
    placeholderParagraph.lineSpacing == paragraph.lineSpacing &&
    [placeholderFont isEqual:editor.typingAttributes[NSFontAttributeName]],
    @"Placeholder and editable text share font and line metrics despite placeholder-only truncation");
  CGFloat padding = editor.textContainer.lineFragmentPadding;
  CGFloat left = editor.textContainerInset.left + padding;
  CGFloat width = MAX(0, editor.bounds.size.width - left - editor.textContainerInset.right - padding);
  Check(fabs(placeholder.frame.origin.x - left) < 0.01 &&
    fabs(placeholder.frame.origin.y - editor.textContainerInset.top) < 0.01 &&
    fabs(placeholder.frame.size.width - width) < 0.01 &&
    fabs(placeholder.frame.size.height - paragraph.minimumLineHeight) < 0.01,
    @"Placeholder uses text-container geometry and exactly one line, without extra centering space");
  CGRect textRect = [placeholder textRectForBounds:placeholder.bounds limitedToNumberOfLines:1];
  CGRect caret = [editor caretRectForPosition:editor.beginningOfDocument];
  Check(fabs(CGRectGetMidY(caret) - 2 - (placeholder.frame.origin.y + CGRectGetMidY(textRect))) <= 1,
    @"Caret has the intentional 2pt visual offset while text and placeholder retain their shared first line");
}
static BOOL HasRGB(UIColor *color, uint32_t rgb) {
  CGFloat red, green, blue, alpha;
  return [color getRed:&red green:&green blue:&blue alpha:&alpha] &&
    fabs(red - ((rgb >> 16) & 255) / 255.0) < 0.001 &&
    fabs(green - ((rgb >> 8) & 255) / 255.0) < 0.001 &&
    fabs(blue - (rgb & 255) / 255.0) < 0.001 && fabs(alpha - 1) < 0.001;
}
static void CheckAppearance(RishInlineComposer *host, BOOL dark) {
  UITextView *editor = [host valueForKey:@"editor"];
  UILabel *placeholder = [host valueForKey:@"placeholder"];
  uint32_t text = dark ? 0xEDF0E9 : 0x242722, muted = dark ? 0xA4AE9D : 0x71766D;
  Check(HasRGB(editor.textColor, text), @"Editable text color follows the explicit GPUI appearance despite opposite UIKit traits");
  Check(HasRGB(editor.tintColor, text), @"Caret follows the explicit GPUI appearance");
  Check(HasRGB(editor.typingAttributes[NSForegroundColorAttributeName], text),
    @"Subsequent keystrokes use the same explicit foreground as existing text");
  Check(HasRGB(placeholder.textColor, muted) &&
    HasRGB([placeholder.attributedText attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:nil], muted),
    @"Plain and attributed placeholder colors follow the explicit GPUI appearance");
  [editor.attributedText enumerateAttribute:NSForegroundColorAttributeName inRange:NSMakeRange(0, editor.text.length)
    options:0 usingBlock:^(id color, NSRange range, BOOL *stop) {
      Check(HasRGB(color, text), @"Every existing glyph retains a readable foreground after an appearance switch");
    }];
}

// Offscreen keyboard/focus inspection uses a subclass, not a UIWindow or
// synthesized responder event. Composition is simulated separately below.
@interface RishInlineTextView : UITextView
@property(nonatomic, copy) void (^changed)(void);
@property(nonatomic, copy) void (^detached)(void);
@property(nonatomic) BOOL hadWindow;
@end
@interface InlineFakeFocusedEditor : RishInlineTextView
@property(nonatomic) BOOL pretendFocus;
@property(nonatomic) BOOL pretendMarked;
@property(nonatomic) NSUInteger unmarks;
@end
@implementation InlineFakeFocusedEditor
- (BOOL)isFirstResponder { return self.pretendFocus; }
- (UITextRange *)markedTextRange { return self.pretendMarked ? [self textRangeFromPosition:self.beginningOfDocument toPosition:self.endOfDocument] : nil; }
- (void)unmarkText { self.unmarks++; self.pretendMarked = NO; }
@end

int main(void) {
  @autoreleasepool {
    NSString *session = NSUUID.UUID.UUIDString.lowercaseString;
    NSMutableDictionary *options = Options(session);
    Check(RishInlineSyncValid(options), @"Exact sync protocol is accepted");
    for (NSString *key in options.allKeys) {
      NSMutableDictionary *missing = [options mutableCopy]; [missing removeObjectForKey:key];
      Check(!RishInlineSyncValid(missing), @"Every sync key is required");
    }
    for (id invalid in @[@"1", @YES, @0, @1.5, @(-1), @(INFINITY), @(NAN)]) {
      NSMutableDictionary *bad = [options mutableCopy]; bad[@"text_revision"] = invalid;
      Check(!RishInlineSyncValid(bad), @"Text revisions must be finite positive integers");
    }
    NSMutableDictionary *bad = [options mutableCopy]; bad[@"rect"] = @[@0, @800, @402, @100];
    Check(!RishInlineSyncValid(bad), @"Rectangles cannot exceed the declared viewport");
    bad = [options mutableCopy]; bad[@"rect"] = @[@0, @0, @(NAN), @80];
    Check(!RishInlineSyncValid(bad), @"NaN geometry is rejected");
    bad = [options mutableCopy]; bad[@"visible"] = @1;
    Check(!RishInlineSyncValid(bad), @"Visibility must be a JSON boolean");
    bad = [options mutableCopy]; bad[@"extra"] = @YES;
    Check(!RishInlineSyncValid(bad), @"Additional sync keys are rejected");
    Check(RishInlineSessionValid(@{@"session_id": session, @"after_revision": @0}, YES) &&
      !RishInlineSessionValid(@{@"session_id": session, @"after_revision": @YES}, YES),
      @"Wait accepts an initial zero cursor but not booleans");
    bad = [options mutableCopy]; bad[@"text"] = [@"" stringByPaddingToLength:1024 * 1024 + 1 withString:@"a" startingAtIndex:0];
    Check(!RishInlineSyncValid(bad), @"Sync text is bounded to one MiB");

    UIView *root = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 402, 874)];
    UIViewController *controller = [UIViewController new]; controller.view = root;
    RishInlineComposer *host = [[RishInlineComposer alloc] initWithRootProvider:^UIView *{ return root; }];
    NSDictionary *snapshot = Call(host, @"sync", options)[@"value"];
    UITextView *editor = [host valueForKey:@"editor"];
    Check(editor.superview == root && controller.presentedViewController == nil && root.subviews.count == 1,
      @"Inline text view attaches directly to the GPUI root with no controller presentation");
    Check(CGRectEqualToRect(editor.frame, CGRectMake(20, 560, 362, 80)), @"Geometry is already safe-area adjusted");
    Check([snapshot[@"text"] isEqual:options[@"text"]] && [snapshot[@"status"] isEqual:@"ready"] &&
      [snapshot[@"content_height"] doubleValue] >= 80 && [snapshot[@"content_height"] doubleValue] <= 168,
      @"Initial snapshot exposes the draft and bounded natural height");
    Check(snapshot.count == 9, @"Snapshot has exactly the reviewed nine fields");
    CheckPlaceholderAlignment(host);
    editor.text = @"本地修改\nnewline"; editor.selectedRange = NSMakeRange(3, 0);
    [host textViewDidChange:editor]; Drain();
    NSDictionary *edited = Call(host, @"snapshot", @{@"session_id": session})[@"value"];
    options[@"rect"] = @[@20, @540, @362, @80];
    NSDictionary *layout = Call(host, @"sync", options)[@"value"];
    Check([layout[@"text"] isEqual:edited[@"text"]] && editor.selectedRange.location == 3,
      @"Equal text revision with old text never rewrites the native buffer or selection");
    Check([layout[@"revision"] isEqual:edited[@"revision"]], @"Position-only sync does not create revision loops");
    [editor setMarkedText:@"候选文字" selectedRange:NSMakeRange(2, 0)]; Drain();
    NSDictionary *marked = Call(host, @"snapshot", @{@"session_id": session})[@"value"];
    Check(editor.markedTextRange != nil && [marked[@"composing"] boolValue],
      @"Real offscreen UITextView marked text is visible in snapshots");
    Call(host, @"sync", options);
    Check(editor.markedTextRange != nil && [editor.text isEqual:marked[@"text"]],
      @"Real UIKit composition survives a layout sync with unchanged text revision");
    [editor unmarkText]; Drain();
    Check([host textView:editor shouldChangeTextInRange:NSMakeRange(editor.text.length, 0) replacementText:@"\n"],
      @"Return is accepted as a normal newline, not a submit action");
    NSString *largeInsert = [@"" stringByPaddingToLength:1024 * 1024 + 1 withString:@"a" startingAtIndex:0];
    Check(![host textView:editor shouldChangeTextInRange:NSMakeRange(editor.text.length, 0) replacementText:largeInsert],
      @"An oversized paste is rejected atomically without truncating the editing buffer");
    options[@"text_revision"] = @2; options[@"text"] = @"明确替换";
    snapshot = Call(host, @"sync", options)[@"value"];
    Check([snapshot[@"text"] isEqual:@"明确替换"] && [snapshot[@"applied_text_revision"] isEqual:@2],
      @"Only an explicit newer text revision replaces the draft");
    options[@"visible"] = @NO;
    snapshot = Call(host, @"sync", options)[@"value"];
    Check(editor.hidden && [snapshot[@"text"] isEqual:@"明确替换"] && ![snapshot[@"focused"] boolValue],
      @"Hiding preserves the draft and releases input focus");
    options[@"visible"] = @YES; Call(host, @"sync", options);

    NSDictionary *sentSnapshot = Call(host, @"snapshot", @{@"session_id": session})[@"value"];
    editor.text = @"发送之后又键入的新字"; editor.selectedRange = NSMakeRange(4, 0);
    // Intentionally do not call the delegate: clear must observe even a change
    // that has not reached its deferred notification yet.
    NSDictionary *clear = Call(host, @"clear", @{@"session_id": session,
      @"expected_revision": sentSnapshot[@"revision"], @"text_revision": @3})[@"value"];
    Check(![clear[@"cleared"] boolValue] && [editor.text isEqual:@"发送之后又键入的新字"] &&
      editor.selectedRange.location == 4 && [clear[@"snapshot"][@"applied_text_revision"] isEqual:@2],
      @"A keystroke during a persisted send prevents clearing and retains selection/applied revision");
    NSDictionary *fresh = clear[@"snapshot"];
    clear = Call(host, @"clear", @{@"session_id": session, @"expected_revision": fresh[@"revision"],
      @"text_revision": @3})[@"value"];
    Check([clear[@"cleared"] boolValue] && editor.text.length == 0 &&
      [clear[@"snapshot"][@"applied_text_revision"] isEqual:@3] &&
      [clear[@"snapshot"][@"revision"] unsignedLongLongValue] > [fresh[@"revision"] unsignedLongLongValue],
      @"Matching current text clears atomically and advances both revisions");
    [editor setMarkedText:@"未确认候选" selectedRange:NSMakeRange(2, 0)]; Drain();
    fresh = Call(host, @"snapshot", @{@"session_id": session})[@"value"];
    clear = Call(host, @"clear", @{@"session_id": session, @"expected_revision": fresh[@"revision"],
      @"text_revision": @4})[@"value"];
    Check(![clear[@"cleared"] boolValue] && editor.markedTextRange != nil &&
      [editor.text isEqual:fresh[@"text"]] && [clear[@"snapshot"][@"applied_text_revision"] isEqual:@3],
      @"Even a matching snapshot cannot clear unconfirmed IME candidates");
    [editor unmarkText]; Drain();
    fresh = Call(host, @"snapshot", @{@"session_id": session})[@"value"];
    clear = Call(host, @"clear", @{@"session_id": session, @"expected_revision": fresh[@"revision"],
      @"text_revision": @3})[@"value"];
    Check(![clear[@"cleared"] boolValue] && [editor.text isEqual:fresh[@"text"]],
      @"A non-newer external revision cannot replace the draft");
    Check(!RishInlineClearValid(@{@"session_id": session, @"expected_revision": @YES, @"text_revision": @4}) &&
      !RishInlineClearValid(@{@"session_id": session, @"expected_revision": @0, @"text_revision": @4, @"text": @""}),
      @"Clear has an exact bounded revision-only schema");

    __block NSUInteger firstWait = 0, secondWait = 0;
    snapshot = Call(host, @"snapshot", @{@"session_id": session})[@"value"];
    NSDictionary *waitOptions = @{@"session_id": session, @"after_revision": snapshot[@"revision"]};
    RishRejectBlock noError = ^(NSString *code, NSString *message, NSError *error) { Check(NO, code); };
    [host wait:waitOptions resolve:^(id value) { ProtocolReply(value); firstWait++; } reject:noError]; Drain();
    Check(firstWait == 0, @"Unchanged snapshot keeps one waiter pending");
    [host wait:waitOptions resolve:^(id value) { ProtocolReply(value); secondWait++; } reject:noError]; Drain();
    Check(firstWait == 1 && secondWait == 0, @"Replacing a waiter settles the old waiter once");
    NSDictionary *closed = Call(host, @"close", @{@"session_id": session})[@"value"]; Drain();
    Check(secondWait == 1 && [closed[@"status"] isEqual:@"closed"] && editor.superview == nil,
      @"Close removes only its editor and settles its waiter exactly once");
    Call(host, @"close", @{@"session_id": session}); Drain();
    Check(firstWait == 1 && secondWait == 1, @"Repeated close cannot double-complete either waiter");
    NSString *nextSession = NSUUID.UUID.UUIDString.lowercaseString;
    options = Options(nextSession); Call(host, @"sync", options);
    UITextView *next = [host valueForKey:@"editor"];
    Check([Call(host, @"close", @{@"session_id": session})[@"error"] isEqual:@"E_INLINE_COMPOSER_STALE"] &&
      next.superview == root && !next.hidden, @"A stale close cannot remove or hide a new session");

    snapshot = Call(host, @"snapshot", @{@"session_id": nextSession})[@"value"];
    __block NSUInteger heartbeat = 0;
    [host wait:@{@"session_id": nextSession, @"after_revision": snapshot[@"revision"]}
      resolve:^(id value) { NSDictionary *reply = ProtocolReply(value); heartbeat++; Check([reply[@"revision"] isEqual:snapshot[@"revision"]], @"Heartbeat returns the unchanged revision"); }
      reject:noError];
    NSDate *heartbeatDeadline = [NSDate dateWithTimeIntervalSinceNow:10.2];
    while (heartbeatDeadline.timeIntervalSinceNow > 0) Drain();
    Check(heartbeat == 1 && firstWait == 1 && secondWait == 1,
      @"Ten-second heartbeat and old timers each settle at most once");

    // Replace only the test's editing view with an offscreen focus/composition
    // double. The production coordinator still runs real sync/snapshot logic.
    InlineFakeFocusedEditor *focused = [[InlineFakeFocusedEditor alloc] initWithFrame:next.frame];
    focused.font = next.font; focused.text = @"拼音候选"; focused.pretendFocus = YES; focused.pretendMarked = YES;
    [next removeFromSuperview]; [root addSubview:focused]; [host setValue:focused forKey:@"editor"];
    snapshot = Call(host, @"snapshot", @{@"session_id": nextSession})[@"value"];
    Check([snapshot[@"composing"] boolValue] && focused.unmarks == 0,
      @"Snapshot reads marked state without forcing unmark or committing candidates");
    Call(host, @"sync", options);
    Check(focused.pretendMarked && focused.unmarks == 0 && [focused.text isEqual:@"拼音候选"],
      @"Layout-only sync preserves marked text");
    [NSNotificationCenter.defaultCenter postNotificationName:UIKeyboardWillChangeFrameNotification object:nil
      userInfo:@{UIKeyboardFrameEndUserInfoKey: [NSValue valueWithCGRect:CGRectMake(100, 400, 220, 200)]}];
    Drain(); snapshot = Call(host, @"snapshot", @{@"session_id": nextSession})[@"value"];
    Check([snapshot[@"keyboard_bottom"] doubleValue] == 0, @"Floating keyboard does not subtract its full height");
    [NSNotificationCenter.defaultCenter postNotificationName:UIKeyboardWillChangeFrameNotification object:nil
      userInfo:@{UIKeyboardFrameEndUserInfoKey: [NSValue valueWithCGRect:CGRectMake(100, 674, 220, 200)]}];
    Drain(); snapshot = Call(host, @"snapshot", @{@"session_id": nextSession})[@"value"];
    Check([snapshot[@"keyboard_bottom"] doubleValue] == 0, @"A narrow floating keyboard at the bottom is not a docked obstruction");
    [NSNotificationCenter.defaultCenter postNotificationName:UIKeyboardWillChangeFrameNotification object:nil
      userInfo:@{UIKeyboardFrameEndUserInfoKey: [NSValue valueWithCGRect:CGRectMake(0, 574, 402, 300)]}];
    Drain(); snapshot = Call(host, @"snapshot", @{@"session_id": nextSession})[@"value"];
    Check([snapshot[@"keyboard_bottom"] doubleValue] == 300, @"Docked keyboard reports the actual root intersection");
    focused.pretendFocus = NO;
    Check([Call(host, @"snapshot", @{@"session_id": nextSession})[@"value"][@"keyboard_bottom"] doubleValue] == 0,
      @"An unfocused editor never reports keyboard avoidance");
    root.frame = CGRectMake(0, 0, 844, 250); focused.pretendFocus = YES;
    options[@"viewport"] = @[@844, @250]; options[@"rect"] = @[@20, @100, @804, @80];
    Call(host, @"sync", options);
    [NSNotificationCenter.defaultCenter postNotificationName:UIKeyboardWillChangeFrameNotification object:nil
      userInfo:@{UIKeyboardFrameEndUserInfoKey: [NSValue valueWithCGRect:CGRectMake(0, 100, 844, 300)]}];
    Drain(); snapshot = Call(host, @"snapshot", @{@"session_id": nextSession})[@"value"];
    Check([snapshot[@"keyboard_bottom"] doubleValue] == 150, @"Short landscape only counts the visible keyboard intersection");
    [host setValue:next forKey:@"editor"]; [focused removeFromSuperview]; [root addSubview:next];
    [host close:@{@"session_id": nextSession} resolve:^(id value) { ProtocolReply(value); } reject:noError]; Drain();
    NSString *lifecycleSession = NSUUID.UUID.UUIDString.lowercaseString;
    root.frame = CGRectMake(0, 0, 402, 874);
    Call(host, @"sync", Options(lifecycleSession));
    snapshot = Call(host, @"snapshot", @{@"session_id": lifecycleSession})[@"value"];
    __block NSUInteger backgroundWait = 0;
    [host wait:@{@"session_id": lifecycleSession, @"after_revision": snapshot[@"revision"]}
      resolve:^(id value) { ProtocolReply(value); backgroundWait++; } reject:noError]; Drain();
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil]; Drain();
    Check(backgroundWait == 1 && [[host valueForKey:@"editor"] isHidden],
      @"Background hides input and settles its waiter without deleting the draft");
    Call(host, @"sync", Options(lifecycleSession));
    snapshot = Call(host, @"snapshot", @{@"session_id": lifecycleSession})[@"value"];
    __block NSUInteger detachWait = 0;
    [host wait:@{@"session_id": lifecycleSession, @"after_revision": snapshot[@"revision"]}
      resolve:^(id value) { NSDictionary *reply = ProtocolReply(value); detachWait++; Check([reply[@"status"] isEqual:@"closed"], @"Detach returns a closed snapshot"); }
      reject:noError]; Drain();
    [[host valueForKey:@"editor"] removeFromSuperview]; Drain();
    Check(detachWait == 1, @"Removing the inline view settles a pending waiter");
    __block NSUInteger disposeWait = 0;
    @autoreleasepool {
      RishInlineComposer *temporary = [[RishInlineComposer alloc] initWithRootProvider:^UIView *{ return root; }];
      NSString *temporarySession = NSUUID.UUID.UUIDString.lowercaseString;
      NSDictionary *current = Call(temporary, @"sync", Options(temporarySession))[@"value"];
      [temporary wait:@{@"session_id": temporarySession, @"after_revision": current[@"revision"]}
        resolve:^(id value) { NSDictionary *reply = ProtocolReply(value); disposeWait++; Check([reply[@"status"] isEqual:@"closed"] && [reply[@"text"] isEqual:@"最后草稿"], @"Disposal returns closed with the latest native draft"); }
        reject:noError]; Drain();
      [[temporary valueForKey:@"editor"] setText:@"最后草稿"];
      temporary = nil;
    }
    Drain(); Check(disposeWait == 1, @"Disposal settles its pending waiter once");

    NSString *alignmentSession = NSUUID.UUID.UUIDString.lowercaseString;
    options = Options(alignmentSession); options[@"text"] = @"";
    options[@"placeholder"] = @"让 Rish 帮你实现想法，让每个想法都能在这里开始";
    for (NSNumber *width in @[@80, @120, @362]) {
      options[@"rect"] = @[@20, @560, width, @56];
      Call(host, @"sync", options); CheckPlaceholderAlignment(host);
    }
    options[@"text_revision"] = @2; options[@"text"] = @"中文与 Latin\n第二行";
    snapshot = Call(host, @"sync", options)[@"value"]; CheckPlaceholderAlignment(host);
    NSParagraphStyle *storedParagraph = [[[host valueForKey:@"editor"] attributedText]
      attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:nil];
    Check(storedParagraph.minimumLineHeight == 22 && storedParagraph.maximumLineHeight == 22,
      @"External text replacement also applies the shared line metrics to existing glyphs");
    Call(host, @"clear", @{@"session_id": alignmentSession, @"expected_revision": snapshot[@"revision"], @"text_revision": @3});
    CheckPlaceholderAlignment(host);

    for (NSNumber *rootStyle in @[@(UIUserInterfaceStyleDark), @(UIUserInterfaceStyleLight)]) {
      UIView *themeRoot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 402, 874)];
      themeRoot.overrideUserInterfaceStyle = rootStyle.integerValue;
      RishInlineComposer *themeHost = [[RishInlineComposer alloc] initWithRootProvider:^UIView *{ return themeRoot; }];
      NSString *themeSession = NSUUID.UUID.UUIDString.lowercaseString;
      NSMutableDictionary *themeOptions = Options(themeSession);
      themeOptions[@"appearance"] = rootStyle.integerValue == UIUserInterfaceStyleDark ? @"light" : @"dark";
      Call(themeHost, @"sync", themeOptions);
      CheckAppearance(themeHost, [themeOptions[@"appearance"] isEqual:@"dark"]);
      UITextView *themeEditor = [themeHost valueForKey:@"editor"];
      themeEditor.selectedRange = NSMakeRange(1, 2);
      NSString *original = [themeEditor.text copy];
      NSRange selection = themeEditor.selectedRange;
      for (NSString *appearance in @[@"dark", @"light", @"dark"]) {
        themeOptions[@"appearance"] = appearance;
        Call(themeHost, @"sync", themeOptions); CheckAppearance(themeHost, [appearance isEqual:@"dark"]);
        Check([themeEditor.text isEqual:original] && NSEqualRanges(themeEditor.selectedRange, selection),
          @"Appearance-only sync preserves the exact draft and selection");
      }
      [themeEditor setMarkedText:@"拼音候选" selectedRange:NSMakeRange(1, 1)]; Drain();
      Check(themeEditor.markedTextRange != nil, @"The theme regression uses real UIKit marked text");
      original = [themeEditor.text copy]; selection = themeEditor.selectedRange;
      NSInteger markedStart = [themeEditor offsetFromPosition:themeEditor.beginningOfDocument toPosition:themeEditor.markedTextRange.start];
      NSInteger markedLength = [themeEditor offsetFromPosition:themeEditor.markedTextRange.start toPosition:themeEditor.markedTextRange.end];
      themeOptions[@"appearance"] = @"light";
      Call(themeHost, @"sync", themeOptions); CheckAppearance(themeHost, NO);
      Check([themeEditor.text isEqual:original] && NSEqualRanges(themeEditor.selectedRange, selection) &&
        themeEditor.markedTextRange != nil &&
        [themeEditor offsetFromPosition:themeEditor.beginningOfDocument toPosition:themeEditor.markedTextRange.start] == markedStart &&
        [themeEditor offsetFromPosition:themeEditor.markedTextRange.start toPosition:themeEditor.markedTextRange.end] == markedLength,
        @"Recoloring preserves the active IME buffer, marked range and selection without unmarking");
      Call(themeHost, @"sync", themeOptions); CheckAppearance(themeHost, NO);
      Check([themeEditor.text isEqual:original], @"Repeated geometry sync keeps the native draft intact");
      [themeEditor unmarkText]; Drain();
      NSDictionary *themeSnapshot = Call(themeHost, @"snapshot", @{@"session_id": themeSession})[@"value"];
      Call(themeHost, @"clear", @{@"session_id": themeSession,
        @"expected_revision": themeSnapshot[@"revision"], @"text_revision": @2});
      CheckAppearance(themeHost, NO);
      themeOptions[@"text_revision"] = @2; themeOptions[@"text"] = @""; themeOptions[@"appearance"] = @"dark";
      Call(themeHost, @"sync", themeOptions); CheckAppearance(themeHost, YES);
      Check(themeEditor.text.length == 0, @"Appearance switching also preserves an empty draft after clear");
    }
    printf("PASS: %lu inline composer checks, JSON protocol, root attachment, revisions, IME, wait/close and keyboard geometry\n", (unsigned long)checks);
  }
  return 0;
}
