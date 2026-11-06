#import "RishFileEditorController.h"
#import "RishFileEditorValidation.h"
#import "RishNativeTheme.h"

@interface RishFileEditorController ()
@property(nonatomic, strong) UITextView *editor;
@property(nonatomic, strong) UIButton *saveButton;
@property(nonatomic, strong) UIButton *cancelButton;
@property(nonatomic, strong) UILabel *helper;
@property(nonatomic, strong) UIView *helperArea;
@property(nonatomic, weak) UIView *previousResponder;
@property(nonatomic) BOOL settled;
@end

static UIView *RishFirstResponderInView(UIView *view) {
  if (view.isFirstResponder) return view;
  for (UIView *child in view.subviews) {
    UIView *responder = RishFirstResponderInView(child);
    if (responder != nil) return responder;
  }
  return nil;
}

@implementation RishFileEditorController

- (void)viewDidLoad {
  [super viewDidLoad];
  UIColor *background = RishNativePanel(self.view);
  RishNativeFill(self.view, RishNativeCanvas(self.view));
  self.view.accessibilityViewIsModal = YES;
  self.modalInPresentation = YES;
  self.title = self.options[@"title"];

  self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
  RishNativeButton(self.cancelButton, self.options[@"cancel_label"], NO);
  self.cancelButton.accessibilityIdentifier = @"rish-file-cancel";
  [self.cancelButton addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];

  UILabel *title = [UILabel new];
  title.text = self.title;
  title.font = RishNativeFont(16, UIFontWeightSemibold, UIFontTextStyleHeadline);
  title.textColor = RishNativeText(self.view);
  title.adjustsFontForContentSizeCategory = YES;
  title.textAlignment = NSTextAlignmentCenter;
  title.lineBreakMode = NSLineBreakByTruncatingMiddle;
  title.accessibilityTraits = UIAccessibilityTraitHeader;
  [title setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                        forAxis:UILayoutConstraintAxisHorizontal];
  [title setContentHuggingPriority:UILayoutPriorityDefaultLow - 1
                         forAxis:UILayoutConstraintAxisHorizontal];

  self.saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
  RishNativeButton(self.saveButton, self.options[@"save_label"], YES);
  self.saveButton.accessibilityIdentifier = @"rish-file-save";
  [self.saveButton addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
  for (UIButton *button in @[self.cancelButton, self.saveButton]) {
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired
                                            forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentHuggingPriority:UILayoutPriorityDefaultHigh
                            forAxis:UILayoutConstraintAxisHorizontal];
  }

  UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:
    @[self.cancelButton, title, self.saveButton]];
  header.translatesAutoresizingMaskIntoConstraints = NO;
  header.alignment = UIStackViewAlignmentCenter;
  header.spacing = 12;
  [self.view addSubview:header];

  UIView *separator = [UIView new];
  separator.translatesAutoresizingMaskIntoConstraints = NO;
  separator.backgroundColor = RishNativeLine(self.view);
  separator.layer.backgroundColor = separator.backgroundColor.CGColor;
  [self.view addSubview:separator];

  self.editor = [UITextView new];
  self.editor.delegate = self;
  self.editor.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
    scaledFontForFont:[UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular]];
  self.editor.adjustsFontForContentSizeCategory = YES;
  RishNativeFill(self.editor, background);
  self.editor.textColor = RishNativeText(self.view);
  self.editor.tintColor = RishNativeText(self.view);
  self.editor.text = self.options[@"initial_text"];
  self.editor.accessibilityLabel = self.title;
  self.editor.accessibilityIdentifier = @"rish-file-editor";
  self.editor.textContainerInset = UIEdgeInsetsMake(20, 16, 24, 16);
  self.editor.alwaysBounceVertical = YES;
  self.editor.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  self.editor.keyboardAppearance = [self.options[@"appearance"] isEqual:@"dark"] ?
    UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
  self.editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
  self.editor.autocorrectionType = UITextAutocorrectionTypeNo;
  self.editor.spellCheckingType = UITextSpellCheckingTypeNo;
  self.editor.smartQuotesType = UITextSmartQuotesTypeNo;
  self.editor.smartDashesType = UITextSmartDashesTypeNo;
  self.editor.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;

  self.helper = [UILabel new];
  self.helper.translatesAutoresizingMaskIntoConstraints = NO;
  self.helper.font = RishNativeFont(13, UIFontWeightRegular, UIFontTextStyleFootnote);
  self.helper.adjustsFontForContentSizeCategory = YES;
  self.helper.numberOfLines = 0;
  self.helper.textColor = UIColor.systemRedColor;
  self.helper.text = self.options[@"too_long_message"];
  self.helper.accessibilityIdentifier = @"rish-file-error";
  self.helperArea = [UIView new];
  [self.helperArea addSubview:self.helper];

  UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[self.editor, self.helperArea]];
  content.translatesAutoresizingMaskIntoConstraints = NO;
  content.axis = UILayoutConstraintAxisVertical;
  [self.view addSubview:content];
  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  UILayoutGuide *column = RishNativeColumn(self.view, 960, 0);
  // A newly attached keyboard layout guide can have no active position yet.
  // Give the editor a complete initial viewport; keyboard tracking takes
  // precedence after UIKit knows the guide's position.
  NSLayoutConstraint *baselineBottom = [content.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor];
  baselineBottom.priority = UILayoutPriorityDefaultHigh;
  NSLayoutConstraint *helperBottom =
    [self.helper.bottomAnchor constraintEqualToAnchor:self.helperArea.bottomAnchor constant:-12];
  // UIStackView collapses the helper when there is no validation error.
  helperBottom.priority = UILayoutPriorityRequired - 1;
  [NSLayoutConstraint activateConstraints:@[
    [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
    [header.leadingAnchor constraintEqualToAnchor:column.leadingAnchor constant:20],
    [header.trailingAnchor constraintEqualToAnchor:column.trailingAnchor constant:-20],
    [self.cancelButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    [self.cancelButton.widthAnchor constraintGreaterThanOrEqualToConstant:44],
    [self.saveButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    [self.saveButton.widthAnchor constraintGreaterThanOrEqualToConstant:44],
    [separator.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
    [separator.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
    [separator.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
    [separator.heightAnchor constraintEqualToConstant:0.5],
    [content.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
    [content.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
    [content.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
    baselineBottom,
    [self.helper.leadingAnchor constraintEqualToAnchor:self.helperArea.leadingAnchor constant:20],
    [self.helper.trailingAnchor constraintEqualToAnchor:self.helperArea.trailingAnchor constant:-20],
    [self.helper.topAnchor constraintEqualToAnchor:self.helperArea.topAnchor constant:8],
    helperBottom,
  ]];
  UIKeyboardLayoutGuide *keyboard = self.view.keyboardLayoutGuide;
  [keyboard setConstraints:@[[content.bottomAnchor constraintEqualToAnchor:keyboard.topAnchor]]
    activeWhenAwayFromEdge:NSDirectionalRectEdgeTop];
  [keyboard setConstraints:@[[content.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]]
    activeWhenNearEdge:NSDirectionalRectEdgeTop];
  [self updateValidation];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  self.previousResponder = RishFirstResponderInView(self.presentingViewController.view);
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (!self.settled) [self.editor becomeFirstResponder];
}

- (void)textViewDidChange:(UITextView *)textView { [self updateValidation]; }
- (void)textViewDidChangeSelection:(UITextView *)textView { [self updateValidation]; }

- (void)updateValidation {
  // UIKit owns composition. Never truncate, normalize, or force unmark text.
  BOOL composing = self.editor.markedTextRange != nil;
  BOOL fits = composing || RishFileEditorTextFits(self.editor.text ?: @"",
    [self.options[@"max_bytes"] unsignedIntegerValue]);
  self.helperArea.hidden = fits;
  self.editor.accessibilityHint = fits ? nil : self.helper.text;
  self.saveButton.enabled = !self.settled && !composing && fits;
}

- (void)save {
  if (self.settled || self.editor.markedTextRange != nil) return;
  [self updateValidation];
  if (!self.saveButton.enabled) {
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.helper);
    return;
  }
  [self complete:[self.editor.text copy] ?: @""];
}

- (void)cancel { [self complete:NSNull.null]; }
- (BOOL)accessibilityPerformEscape { [self cancel]; return YES; }

- (void)complete:(id)value {
  if (self.settled) return;
  self.settled = YES;
  self.saveButton.enabled = NO;
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

- (void)presentationControllerDidDismiss:(UIPresentationController *)controller {
  [self settleCancellation];
}

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
