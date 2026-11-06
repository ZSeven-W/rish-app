#import "RishComposerController.h"
#import "RishNativeTheme.h"

@interface RishComposerController ()
@property(nonatomic, strong) UITextView *editor;
@property(nonatomic, strong) UIButton *doneButton;
@property(nonatomic, strong) UIButton *cancelButton;
@property(nonatomic, weak) UIView *previousResponder;
@property(nonatomic) BOOL settled;
@end

static UIView *RishComposerFirstResponder(UIView *view) {
  if (view.isFirstResponder) return view;
  for (UIView *child in view.subviews) {
    UIView *responder = RishComposerFirstResponder(child);
    if (responder != nil) return responder;
  }
  return nil;
}

@implementation RishComposerController
- (void)viewDidLoad {
  [super viewDidLoad];
  RishNativeFill(self.view, RishNativeCanvas(self.view));
  self.view.accessibilityViewIsModal = YES;
  self.modalInPresentation = YES;
  // The legacy edit contract has no locale argument; retain the system-language
  // behavior of its former Cancel/Done UIBarButtonItems.
  BOOL chinese = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
  self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
  RishNativeButton(self.cancelButton, chinese ? @"取消" : @"Cancel", NO);
  self.cancelButton.accessibilityIdentifier = @"rish-composer-cancel";
  [self.cancelButton addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
  self.doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
  RishNativeButton(self.doneButton, chinese ? @"完成" : @"Done", YES);
  self.doneButton.accessibilityIdentifier = @"rish-composer-done";
  [self.doneButton addTarget:self action:@selector(done) forControlEvents:UIControlEventTouchUpInside];

  UILabel *title = [UILabel new];
  title.text = self.title;
  title.font = RishNativeFont(16, UIFontWeightSemibold, UIFontTextStyleHeadline);
  title.textColor = RishNativeText(self.view);
  title.adjustsFontForContentSizeCategory = YES;
  title.textAlignment = NSTextAlignmentCenter;
  title.lineBreakMode = NSLineBreakByTruncatingTail;
  title.accessibilityTraits = UIAccessibilityTraitHeader;
  [title setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
  [title setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];
  UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[self.cancelButton, title, self.doneButton]];
  header.translatesAutoresizingMaskIntoConstraints = NO;
  header.alignment = UIStackViewAlignmentCenter;
  header.spacing = 12;
  [self.view addSubview:header];
  for (UIButton *button in @[self.cancelButton, self.doneButton]) {
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
  }

  UIView *separator = [UIView new];
  separator.translatesAutoresizingMaskIntoConstraints = NO;
  RishNativeFill(separator, RishNativeLine(self.view));
  [self.view addSubview:separator];
  self.editor = [UITextView new];
  self.editor.translatesAutoresizingMaskIntoConstraints = NO;
  self.editor.delegate = self;
  self.editor.font = RishNativeFont(15, UIFontWeightRegular, UIFontTextStyleBody);
  self.editor.adjustsFontForContentSizeCategory = YES;
  self.editor.text = self.initialText;
  self.editor.textColor = RishNativeText(self.view);
  self.editor.tintColor = RishNativeText(self.view);
  RishNativeFill(self.editor, RishNativePanel(self.view));
  self.editor.accessibilityLabel = self.title;
  self.editor.accessibilityIdentifier = @"rish-composer-editor";
  self.editor.isAccessibilityElement = YES;
  self.editor.textContainerInset = UIEdgeInsetsMake(20, 16, 24, 16);
  self.editor.alwaysBounceVertical = YES;
  self.editor.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  self.editor.keyboardAppearance = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ?
    UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
  [self.view addSubview:self.editor];
  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  UILayoutGuide *column = RishNativeColumn(self.view, 720, 0);
  NSLayoutConstraint *baseline = [self.editor.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor];
  baseline.priority = UILayoutPriorityDefaultHigh;
  [NSLayoutConstraint activateConstraints:@[
    [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
    [header.leadingAnchor constraintEqualToAnchor:column.leadingAnchor constant:20],
    [header.trailingAnchor constraintEqualToAnchor:column.trailingAnchor constant:-20],
    [self.cancelButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    [self.cancelButton.widthAnchor constraintGreaterThanOrEqualToConstant:44],
    [self.doneButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    [self.doneButton.widthAnchor constraintGreaterThanOrEqualToConstant:44],
    [separator.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
    [separator.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
    [separator.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
    [separator.heightAnchor constraintEqualToConstant:0.5],
    [self.editor.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
    [self.editor.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
    [self.editor.trailingAnchor constraintEqualToAnchor:column.trailingAnchor], baseline,
    [self.editor.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor],
  ]];
  UIKeyboardLayoutGuide *keyboard = self.view.keyboardLayoutGuide;
  [keyboard setConstraints:@[[self.editor.bottomAnchor constraintEqualToAnchor:keyboard.topAnchor]]
    activeWhenAwayFromEdge:NSDirectionalRectEdgeTop];
  [keyboard setConstraints:@[[self.editor.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]]
    activeWhenNearEdge:NSDirectionalRectEdgeTop];
  [self updateValidation];
}
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  self.previousResponder = RishComposerFirstResponder(self.presentingViewController.view);
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (!self.settled) [self.editor becomeFirstResponder];
}
- (void)textViewDidChange:(UITextView *)textView { [self updateValidation]; }
- (void)textViewDidChangeSelection:(UITextView *)textView { [self updateValidation]; }
- (void)updateValidation {
  self.doneButton.enabled = !self.settled && self.editor.markedTextRange == nil;
}
- (void)complete:(id)value {
  if (self.settled) return;
  self.settled = YES;
  self.doneButton.enabled = NO;
  self.cancelButton.enabled = NO;
  self.editor.editable = NO;
  void (^finish)(id) = self.finish;
  self.finish = nil;
  [self.editor resignFirstResponder];
  __weak UIView *previousResponder = self.previousResponder;
  [self dismissViewControllerAnimated:YES completion:^{
    if (previousResponder.window != nil) [previousResponder becomeFirstResponder];
    if (finish) finish(value);
  }];
}
- (void)cancel { [self complete:NSNull.null]; }
- (void)done {
  // Composition stays entirely with UIKit; a tap never forces candidate text
  // into a committed buffer. The action becomes enabled after IME commitment.
  if (self.settled || self.editor.markedTextRange != nil) return;
  [self complete:[self.editor.text copy] ?: @""];
}
- (BOOL)accessibilityPerformEscape { [self cancel]; return YES; }
- (void)presentationControllerDidDismiss:(UIPresentationController *)controller { [self settleCancellation]; }
- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  if (self.isBeingDismissed || self.presentingViewController.isBeingDismissed ||
      self.presentingViewController == nil) [self settleCancellation];
}
- (void)settleCancellation {
  if (self.settled) return;
  self.settled = YES;
  void (^finish)(id) = self.finish;
  self.finish = nil;
  if (self.previousResponder.window != nil) [self.previousResponder becomeFirstResponder];
  if (finish) finish(NSNull.null);
}
@end
