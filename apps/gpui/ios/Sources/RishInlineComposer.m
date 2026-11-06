#import "RishInlineComposer.h"
#import "RishInlineComposerValidation.h"
#include <math.h>

extern void *gpui_ios_get_window(void);
extern void *gpui_ios_view_controller(void *window);

static UIColor *InlineColor(uint32_t rgb) {
  return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0
    green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}

@interface RishInlineTextView : UITextView
@property(nonatomic, copy) void (^changed)(void);
@property(nonatomic, copy) void (^detached)(void);
@property(nonatomic) BOOL hadWindow;
@end
@implementation RishInlineTextView
- (CGRect)caretRectForPosition:(UITextPosition *)position {
  return CGRectOffset([super caretRectForPosition:position], 0, 2);
}
- (void)setMarkedText:(NSString *)text selectedRange:(NSRange)range {
  [super setMarkedText:text selectedRange:range]; if (self.changed) self.changed();
}
- (void)unmarkText { [super unmarkText]; if (self.changed) self.changed(); }
- (BOOL)becomeFirstResponder { BOOL result = [super becomeFirstResponder]; if (self.changed) self.changed(); return result; }
- (BOOL)resignFirstResponder { BOOL result = [super resignFirstResponder]; if (self.changed) self.changed(); return result; }
- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (self.window != nil) self.hadWindow = YES;
  else if (self.hadWindow && self.detached) self.detached();
}
- (void)didMoveToSuperview {
  [super didMoveToSuperview]; if (self.superview == nil && self.detached) self.detached();
}
@end

@interface RishInlineComposer ()
@property(nonatomic, copy) UIView *(^rootProvider)(void);
@property(nonatomic, weak) UIView *root;
@property(nonatomic, strong) RishInlineTextView *editor;
@property(nonatomic, strong) UILabel *placeholder;
@property(nonatomic, copy) NSDictionary *textAttributes;
@property(nonatomic, copy) NSString *session;
@property(nonatomic, copy) NSString *appearance;
@property(nonatomic) uint64_t revision;
@property(nonatomic) uint64_t appliedTextRevision;
@property(nonatomic) CGSize viewport;
@property(nonatomic) CGRect keyboardScreenFrame;
@property(nonatomic) BOOL keyboardKnown;
@property(nonatomic) BOOL closed;
@property(nonatomic) BOOL publishScheduled;
@property(nonatomic, copy) NSDictionary *lastSnapshot;
@property(nonatomic, copy) RishResolveBlock waiter;
@property(nonatomic, strong) NSObject *waitToken;
@end

@implementation RishInlineComposer
- (instancetype)init {
  return [self initWithRootProvider:^UIView *{
    void *window = gpui_ios_get_window();
    if (window == NULL) return nil;
    UIViewController *controller = (__bridge UIViewController *)gpui_ios_view_controller(window);
    return controller.isViewLoaded ? controller.view : nil;
  }];
}
- (instancetype)initWithRootProvider:(UIView *(^)(void))provider {
  self = [super init];
  if (self) {
    _rootProvider = [provider copy];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:)
      name:UIKeyboardWillChangeFrameNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:)
      name:UIApplicationDidEnterBackgroundNotification object:nil];
  }
  return self;
}
- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  RishInlineTextView *editor = _editor;
  RishResolveBlock waiter = _waiter;
  NSMutableDictionary *closed = [_lastSnapshot mutableCopy];
  if (closed != nil) {
    closed[@"status"] = @"closed"; closed[@"focused"] = @NO; closed[@"keyboard_bottom"] = @0;
    closed[@"revision"] = @([closed[@"revision"] unsignedLongLongValue] + 1);
  }
  void (^cleanup)(void) = ^{
    editor.changed = nil; editor.detached = nil; editor.delegate = nil;
    [editor resignFirstResponder]; [editor removeFromSuperview];
    closed[@"text"] = editor.text ?: @"";
    closed[@"composing"] = editor.markedTextRange != nil ? @YES : @NO;
    if (waiter != nil && closed != nil) waiter(closed);
  };
  if (NSThread.isMainThread) cleanup(); else dispatch_async(dispatch_get_main_queue(), cleanup);
}
- (void)error:(RishRejectBlock)reject code:(NSString *)code {
  reject(code, [code isEqual:@"E_INLINE_COMPOSER_INVALID"] ? @"Inline composer request is invalid." :
    [code isEqual:@"E_INLINE_COMPOSER_STALE"] ? @"Inline composer session is no longer current." :
    @"Inline composer is unavailable.", nil);
}
- (BOOL)matches:(NSDictionary *)options reject:(RishRejectBlock)reject {
  if (![options[@"session_id"] isEqual:self.session]) {
    [self error:reject code:@"E_INLINE_COMPOSER_STALE"]; return NO;
  }
  return YES;
}
- (CGFloat)keyboardBottom {
  if (self.closed || self.editor.hidden || !self.editor.isFirstResponder || !self.keyboardKnown || self.root == nil)
    return 0;
  CGRect frame = self.keyboardScreenFrame;
  if (self.root.window != nil)
    frame = [self.root convertRect:frame fromCoordinateSpace:self.root.window.screen.coordinateSpace];
  CGRect viewport = CGRectIntersection(self.root.bounds, (CGRect){CGPointZero, self.viewport});
  if (CGRectIsNull(viewport) || CGRectIsEmpty(viewport)) return 0;
  CGRect intersection = CGRectIntersection(viewport, frame);
  // A floating keyboard does not occlude the bottom edge. Only its real
  // viewport intersection counts, including short landscape and rotation.
  if (CGRectIsNull(intersection) || CGRectIsEmpty(intersection) ||
      CGRectGetMinX(frame) > CGRectGetMinX(viewport) + 1 ||
      CGRectGetMaxX(frame) < CGRectGetMaxX(viewport) - 1 ||
      CGRectGetMaxY(frame) < CGRectGetMaxY(viewport) - 1 ||
      CGRectGetMinY(frame) >= CGRectGetMaxY(viewport)) return 0;
  return MIN(viewport.size.height, MAX(0, CGRectGetMaxY(viewport) - CGRectGetMinY(intersection)));
}
- (NSDictionary *)capture {
  CGFloat width = MAX(1, self.editor.bounds.size.width);
  CGFloat height = [self.editor sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height;
  if (!isfinite(height)) height = 80;
  // C comparisons box as NSNumber integers; the JSON protocol requires booleans.
  return @{@"session_id": self.session, @"status": self.closed ? @"closed" : @"ready",
    @"revision": @(self.revision), @"applied_text_revision": @(self.appliedTextRevision),
    @"text": self.editor.text ?: @"", @"composing": self.editor.markedTextRange != nil ? @YES : @NO,
    @"focused": !self.closed && !self.editor.hidden && self.editor.isFirstResponder ? @YES : @NO,
    @"keyboard_bottom": @([self keyboardBottom]), @"content_height": @(MIN(168, MAX(80, ceil(height))))};
}
- (void)settleWaiter:(NSDictionary *)snapshot {
  RishResolveBlock waiter = self.waiter;
  self.waiter = nil; self.waitToken = nil;
  if (waiter) waiter(snapshot);
}
- (NSDictionary *)publish {
  if (self.session == nil) return nil;
  NSMutableDictionary *snapshot = [[self capture] mutableCopy];
  NSMutableDictionary *previous = [self.lastSnapshot mutableCopy];
  [snapshot removeObjectForKey:@"revision"]; [previous removeObjectForKey:@"revision"];
  BOOL changed = ![snapshot isEqual:previous];
  if (changed) self.revision += 1;
  snapshot[@"revision"] = @(self.revision);
  self.lastSnapshot = [snapshot copy];
  self.placeholder.hidden = self.editor.text.length > 0 || self.editor.markedTextRange != nil;
  if (changed) [self settleWaiter:self.lastSnapshot];
  return self.lastSnapshot;
}
- (void)schedulePublish {
  if (self.publishScheduled) return;
  self.publishScheduled = YES;
  __weak RishInlineComposer *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    RishInlineComposer *self = weakSelf;
    if (!self) return;
    self.publishScheduled = NO;
    if (!self.closed && (self.editor.superview != self.root || (self.editor.hadWindow && self.editor.window == nil))) [self closeCurrent];
    else [self publish];
  });
}
- (void)closeCurrent {
  if (self.session == nil || self.closed) return;
  self.closed = YES;
  self.editor.changed = nil; self.editor.detached = nil;
  [self.editor resignFirstResponder];
  [self.editor removeFromSuperview];
  [self publish];
  [self settleWaiter:self.lastSnapshot];
}
- (void)createEditor:(UIView *)root session:(NSString *)session {
  [self closeCurrent];
  self.root = root; self.session = [session copy]; self.closed = NO;
  self.revision = 0; self.appliedTextRevision = 0; self.lastSnapshot = nil; self.appearance = nil;
  self.editor = [RishInlineTextView new];
  self.editor.delegate = self;
  self.editor.accessibilityIdentifier = @"rish-inline-composer";
  self.editor.backgroundColor = UIColor.clearColor;
  self.editor.opaque = NO;
  self.editor.font = [UIFont systemFontOfSize:15];
  self.editor.textContainerInset = UIEdgeInsetsMake(8, 0, 8, 0);
  self.editor.textContainer.lineFragmentPadding = 0;
  NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
  paragraph.minimumLineHeight = 22; paragraph.maximumLineHeight = 22;
  self.textAttributes = @{NSFontAttributeName: self.editor.font, NSParagraphStyleAttributeName: paragraph};
  self.editor.typingAttributes = self.textAttributes;
  self.editor.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  self.editor.returnKeyType = UIReturnKeyDefault;
  self.editor.scrollEnabled = YES;
  self.editor.alwaysBounceVertical = NO;
  self.editor.clipsToBounds = YES;
  self.placeholder = [UILabel new];
  self.placeholder.font = self.editor.font;
  self.placeholder.userInteractionEnabled = NO;
  self.placeholder.isAccessibilityElement = NO;
  self.placeholder.numberOfLines = 1;
  self.placeholder.lineBreakMode = NSLineBreakByTruncatingTail;
  [self.editor addSubview:self.placeholder];
  __weak RishInlineComposer *weakSelf = self;
  self.editor.changed = ^{ [weakSelf schedulePublish]; };
  self.editor.detached = ^{ [weakSelf schedulePublish]; };
  [root addSubview:self.editor];
}
- (void)sync:(NSDictionary *)options resolve:(RishResolveBlock)resolve reject:(RishRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!RishInlineSyncValid(options)) { [self error:reject code:@"E_INLINE_COMPOSER_INVALID"]; return; }
    UIView *root = self.rootProvider();
    if (root == nil) { [self closeCurrent]; [self error:reject code:@"E_INLINE_COMPOSER_UNAVAILABLE"]; return; }
    if ([self.session isEqual:options[@"session_id"]] && self.closed) {
      [self error:reject code:@"E_INLINE_COMPOSER_STALE"]; return;
    }
    if (![self.session isEqual:options[@"session_id"]]) [self createEditor:root session:options[@"session_id"]];
    if (self.root != root || self.editor.superview != root) {
      [self closeCurrent]; [self error:reject code:@"E_INLINE_COMPOSER_UNAVAILABLE"]; return;
    }
    self.viewport = CGSizeMake([options[@"viewport"][0] doubleValue], [options[@"viewport"][1] doubleValue]);
    NSArray *rect = options[@"rect"];
    CGRect requested = CGRectMake([rect[0] doubleValue], [rect[1] doubleValue], [rect[2] doubleValue], [rect[3] doubleValue]);
    CGRect frame = CGRectIntersection(root.bounds, requested);
    if (CGRectIsNull(frame)) frame = CGRectZero;
    self.editor.frame = frame;
    if (![self.appearance isEqual:options[@"appearance"]]) {
      self.appearance = options[@"appearance"];
      BOOL dark = [self.appearance isEqual:@"dark"];
      self.editor.overrideUserInterfaceStyle = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
      // UIKit's inherited traits can lag the override. Resolve the GPUI palette
      // directly from its explicit appearance, for existing and future text.
      UIColor *foreground = InlineColor(dark ? 0xEDF0E9 : 0x242722);
      self.editor.textColor = foreground;
      self.editor.tintColor = foreground;
      NSMutableDictionary *attributes = [self.textAttributes mutableCopy];
      attributes[NSForegroundColorAttributeName] = foreground;
      self.textAttributes = attributes;
      self.editor.typingAttributes = self.textAttributes;
      self.editor.keyboardAppearance = dark ? UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
      self.placeholder.textColor = InlineColor(dark ? 0xA4AE9D : 0x71766D);
    }
    NSMutableDictionary *placeholderAttributes = [self.textAttributes mutableCopy];
    placeholderAttributes[NSForegroundColorAttributeName] = self.placeholder.textColor;
    self.placeholder.attributedText = [[NSAttributedString alloc] initWithString:options[@"placeholder"]
      attributes:placeholderAttributes];
    self.placeholder.lineBreakMode = NSLineBreakByTruncatingTail;
    // UILabel centers vertically inside its frame. Give it the same single
    // line and container origin as editable text, including at narrow widths.
    UIEdgeInsets inset = self.editor.textContainerInset;
    CGFloat padding = self.editor.textContainer.lineFragmentPadding;
    NSParagraphStyle *paragraph = self.textAttributes[NSParagraphStyleAttributeName];
    self.placeholder.frame = CGRectMake(inset.left + padding, inset.top,
      MAX(0, frame.size.width - inset.left - inset.right - 2 * padding), paragraph.minimumLineHeight);
    self.editor.accessibilityLabel = options[@"placeholder"];
    uint64_t textRevision = [options[@"text_revision"] unsignedLongLongValue];
    if (textRevision > self.appliedTextRevision) {
      self.editor.attributedText = [[NSAttributedString alloc] initWithString:options[@"text"]
        attributes:self.textAttributes];
      self.editor.typingAttributes = self.textAttributes;
      self.appliedTextRevision = textRevision;
    }
    BOOL visible = [options[@"visible"] boolValue] && !CGRectIsEmpty(frame);
    self.editor.hidden = !visible;
    if (!visible || [options[@"focus"] isEqual:@NO]) [self.editor resignFirstResponder];
    else if ([options[@"focus"] isEqual:@YES]) [self.editor becomeFirstResponder];
    resolve([self publish]);
  });
}
- (void)snapshot:(NSDictionary *)options resolve:(RishResolveBlock)resolve reject:(RishRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!RishInlineSessionValid(options, NO)) { [self error:reject code:@"E_INLINE_COMPOSER_INVALID"]; return; }
    if ([self matches:options reject:reject]) resolve([self publish]);
  });
}
- (void)wait:(NSDictionary *)options resolve:(RishResolveBlock)resolve reject:(RishRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!RishInlineSessionValid(options, YES)) { [self error:reject code:@"E_INLINE_COMPOSER_INVALID"]; return; }
    if (![self matches:options reject:reject]) return;
    NSDictionary *snapshot = [self publish];
    [self settleWaiter:snapshot];
    if (self.closed || self.revision > [options[@"after_revision"] unsignedLongLongValue]) { resolve(snapshot); return; }
    NSObject *token = [NSObject new]; self.waitToken = token; self.waiter = [resolve copy];
    __weak RishInlineComposer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      RishInlineComposer *self = weakSelf;
      if (self.waitToken == token) { [self publish]; [self settleWaiter:self.lastSnapshot]; }
    });
  });
}
- (void)close:(NSDictionary *)options resolve:(RishResolveBlock)resolve reject:(RishRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!RishInlineSessionValid(options, NO)) { [self error:reject code:@"E_INLINE_COMPOSER_INVALID"]; return; }
    if (![self matches:options reject:reject]) return;
    [self closeCurrent]; resolve([self publish]);
  });
}
- (void)clearIfUnchanged:(NSDictionary *)options resolve:(RishResolveBlock)resolve reject:(RishRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!RishInlineClearValid(options)) { [self error:reject code:@"E_INLINE_COMPOSER_INVALID"]; return; }
    if (![self matches:options reject:reject]) return;
    // Flush even a text change whose delegate notification is still queued.
    // The comparison and replacement share this main-thread turn, so a later
    // keystroke can never be cleared using the earlier send's snapshot.
    NSDictionary *snapshot = [self publish];
    uint64_t textRevision = [options[@"text_revision"] unsignedLongLongValue];
    BOOL clear = !self.closed && self.editor.markedTextRange == nil &&
      self.revision == [options[@"expected_revision"] unsignedLongLongValue] &&
      textRevision > self.appliedTextRevision;
    if (clear) {
      self.editor.text = @"";
      self.editor.typingAttributes = self.textAttributes;
      self.appliedTextRevision = textRevision;
      snapshot = [self publish];
    }
    resolve(@{@"cleared": @(clear), @"snapshot": snapshot});
  });
}
- (void)obscure {
  dispatch_async(dispatch_get_main_queue(), ^{
    self.editor.hidden = YES; [self.editor resignFirstResponder]; [self publish];
  });
}
- (void)keyboardChanged:(NSNotification *)notification {
  NSValue *value = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
  if (![value isKindOfClass:NSValue.class]) return;
  CGRect frame = value.CGRectValue;
  if (!isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !isfinite(frame.size.width) || !isfinite(frame.size.height)) return;
  self.keyboardScreenFrame = frame; self.keyboardKnown = YES;
  [self schedulePublish];
}
- (void)background:(NSNotification *)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.editor resignFirstResponder]; self.editor.hidden = YES;
    [self publish]; [self settleWaiter:self.lastSnapshot];
  });
}
- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
  NSString *current = textView.text ?: @"";
  if (range.location > current.length || range.length > current.length - range.location) return NO;
  NSString *proposed = [current stringByReplacingCharactersInRange:range withString:text ?: @""];
  NSData *bytes = [proposed dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
  // Reject an oversized insertion atomically; never truncate or rewrite the
  // native composition buffer. Return remains a normal newline insertion.
  return bytes != nil && bytes.length <= 1024 * 1024;
}
- (void)textViewDidChange:(UITextView *)textView { [self schedulePublish]; }
- (void)textViewDidChangeSelection:(UITextView *)textView { [self schedulePublish]; }
- (void)textViewDidBeginEditing:(UITextView *)textView { [self schedulePublish]; }
- (void)textViewDidEndEditing:(UITextView *)textView { [self schedulePublish]; }
@end
