#import "RishGitFormController.h"
#import "RishGitFormValidation.h"
#import "RishNativeTheme.h"

@interface RishGitFormController ()
@property(nonatomic, strong) NSArray<UITextField *> *editors;
@property(nonatomic, strong) UIButton *submitButton;
@property(nonatomic, strong) UIButton *cancelButton;
@property(nonatomic, strong) UILabel *helper;
@property(nonatomic, strong) UIScrollView *scroll;
@property(nonatomic, weak) UIView *previousResponder;
@property(nonatomic) BOOL hasEdited;
@property(nonatomic) BOOL settled;
@end

static UIView *RishGitFirstResponder(UIView *view) {
  if (view.isFirstResponder) return view;
  for (UIView *child in view.subviews) {
    UIView *responder = RishGitFirstResponder(child);
    if (responder != nil) return responder;
  }
  return nil;
}

@implementation RishGitFormController

- (void)viewDidLoad {
  [super viewDidLoad];
  RishNativeFill(self.view, RishNativeCanvas(self.view));
  self.view.accessibilityViewIsModal = YES;
  self.modalInPresentation = YES;
  self.title = self.options[@"title"];

  self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
  RishNativeButton(self.cancelButton, self.options[@"cancel_label"], NO);
  self.cancelButton.accessibilityIdentifier = @"rish-git-form-cancel";
  [self.cancelButton addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];

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

  self.submitButton = [UIButton buttonWithType:UIButtonTypeSystem];
  RishNativeButton(self.submitButton, self.options[@"submit_label"], YES);
  self.submitButton.accessibilityIdentifier = @"rish-git-form-submit";
  [self.submitButton addTarget:self action:@selector(submit) forControlEvents:UIControlEventTouchUpInside];
  for (UIButton *button in @[self.cancelButton, self.submitButton]) {
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
  }
  UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[self.cancelButton, title, self.submitButton]];
  header.translatesAutoresizingMaskIntoConstraints = NO;
  header.alignment = UIStackViewAlignmentCenter;
  header.spacing = 12;
  [self.view addSubview:header];

  self.scroll = [UIScrollView new];
  self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
  self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  self.scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  [self.view addSubview:self.scroll];
  UIStackView *content = [UIStackView new];
  content.translatesAutoresizingMaskIntoConstraints = NO;
  content.axis = UILayoutConstraintAxisVertical;
  content.spacing = 24;
  [self.scroll addSubview:content];
  NSMutableArray *editors = [NSMutableArray array];
  NSArray *fields = self.options[@"fields"];
  for (NSDictionary *field in fields) {
    UILabel *label = [UILabel new];
    label.text = field[@"label"];
    label.font = RishNativeFont(13, UIFontWeightMedium, UIFontTextStyleSubheadline);
    label.textColor = RishNativeMuted(self.view);
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    UIView *container = [UIView new];
    RishNativeField(container, self.view);
    UITextField *editor = [UITextField new];
    editor.translatesAutoresizingMaskIntoConstraints = NO;
    editor.font = RishNativeFont(15, UIFontWeightRegular, UIFontTextStyleBody);
    editor.adjustsFontForContentSizeCategory = YES;
    editor.textColor = RishNativeText(self.view);
    editor.tintColor = RishNativeText(self.view);
    editor.text = field[@"value"];
    editor.placeholder = field[@"placeholder"];
    editor.accessibilityLabel = field[@"label"];
    editor.accessibilityIdentifier = [@"rish-git-form-" stringByAppendingString:field[@"key"]];
    editor.clearButtonMode = UITextFieldViewModeWhileEditing;
    editor.autocorrectionType = UITextAutocorrectionTypeNo;
    editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    editor.spellCheckingType = UITextSpellCheckingTypeNo;
    editor.smartQuotesType = UITextSmartQuotesTypeNo;
    editor.smartDashesType = UITextSmartDashesTypeNo;
    editor.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    editor.keyboardAppearance = [self.options[@"appearance"] isEqual:@"dark"] ? UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
    editor.returnKeyType = editors.count + 1 < fields.count ? UIReturnKeyNext : UIReturnKeyDone;
    if ([field[@"key"] isEqual:@"author_email"]) editor.keyboardType = UIKeyboardTypeEmailAddress;
    if ([field[@"key"] isEqual:@"url"]) editor.keyboardType = UIKeyboardTypeURL;
    editor.delegate = self;
    [editor addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];
    [container addSubview:editor];
    [NSLayoutConstraint activateConstraints:@[
      [container.heightAnchor constraintGreaterThanOrEqualToConstant:54],
      [editor.topAnchor constraintEqualToAnchor:container.topAnchor constant:14],
      [editor.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-14],
      [editor.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
      [editor.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12],
    ]];
    UIStackView *group = [[UIStackView alloc] initWithArrangedSubviews:@[label, container]];
    group.axis = UILayoutConstraintAxisVertical;
    group.spacing = 10;
    [content addArrangedSubview:group];
    [editors addObject:editor];
  }
  self.editors = editors;
  self.helper = [UILabel new];
  self.helper.font = RishNativeFont(13, UIFontWeightRegular, UIFontTextStyleFootnote);
  self.helper.adjustsFontForContentSizeCategory = YES;
  self.helper.numberOfLines = 0;
  self.helper.accessibilityIdentifier = @"rish-git-form-hint";
  [content addArrangedSubview:self.helper];
  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  UILayoutGuide *headerColumn = RishNativeColumn(self.view, 640, 20);
  NSLayoutConstraint *baseline = [self.scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor];
  baseline.priority = UILayoutPriorityDefaultHigh;
  NSLayoutConstraint *width = [content.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-40];
  width.priority = UILayoutPriorityDefaultHigh;
  [NSLayoutConstraint activateConstraints:@[
    [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
    [header.leadingAnchor constraintEqualToAnchor:headerColumn.leadingAnchor],
    [header.trailingAnchor constraintEqualToAnchor:headerColumn.trailingAnchor],
    [self.cancelButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    [self.cancelButton.widthAnchor constraintGreaterThanOrEqualToConstant:44],
    [self.submitButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    [self.submitButton.widthAnchor constraintGreaterThanOrEqualToConstant:44],
    [self.scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:12],
    [self.scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [self.scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    baseline,
    [self.scroll.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor],
    [content.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:20],
    [content.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-28],
    [content.centerXAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.centerXAnchor],
    [content.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor constant:20],
    [content.trailingAnchor constraintLessThanOrEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor constant:-20],
    [self.scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor],
    [content.widthAnchor constraintLessThanOrEqualToConstant:640], width,
  ]];
  UIKeyboardLayoutGuide *keyboard = self.view.keyboardLayoutGuide;
  keyboard.followsUndockedKeyboard = YES;
  [keyboard setConstraints:@[[self.scroll.bottomAnchor constraintEqualToAnchor:keyboard.topAnchor]]
    activeWhenAwayFromEdge:NSDirectionalRectEdgeTop];
  [keyboard setConstraints:@[[self.scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]]
    activeWhenNearEdge:NSDirectionalRectEdgeTop];
  [self updateValidation];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  self.previousResponder = RishGitFirstResponder(self.presentingViewController.view);
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (!self.settled) [self.editors.firstObject becomeFirstResponder];
}

- (BOOL)isComposing {
  for (UITextField *editor in self.editors) if (editor.markedTextRange != nil) return YES;
  return NO;
}

- (NSDictionary *)currentValues {
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  NSArray *fields = self.options[@"fields"];
  for (NSUInteger index = 0; index < self.editors.count; ++index)
    values[fields[index][@"key"]] = self.editors[index].text ?: @"";
  return RishGitFormValues(self.options[@"kind"], values);
}

- (void)textChanged { self.hasEdited = YES; [self updateValidation]; }
- (void)textFieldDidChangeSelection:(UITextField *)textField { [self updateValidation]; }
- (void)textFieldDidBeginEditing:(UITextField *)textField {
  CGRect rect = [textField convertRect:textField.bounds toView:self.scroll];
  [self.scroll scrollRectToVisible:CGRectInset(rect, 0, -20) animated:YES];
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
  if ([self isComposing]) return NO;
  NSUInteger index = [self.editors indexOfObjectIdenticalTo:textField];
  if (index != NSNotFound && index + 1 < self.editors.count)
    [self.editors[index + 1] becomeFirstResponder];
  else [self submit];
  return NO;
}

- (void)updateValidation {
  BOOL composing = [self isComposing];
  BOOL valid = !composing && [self currentValues] != nil;
  BOOL showError = self.hasEdited && !composing && !valid;
  self.helper.text = self.options[showError ? @"invalid_message" : @"hint"];
  self.helper.textColor = showError ? UIColor.systemRedColor : RishNativeMuted(self.view);
  self.submitButton.enabled = !self.settled && valid;
}

- (void)submit {
  if (self.settled || [self isComposing]) return;
  NSDictionary *values = [self currentValues];
  if (values == nil) { self.hasEdited = YES; [self updateValidation]; return; }
  [self complete:values];
}
- (void)cancel { [self complete:NSNull.null]; }
- (BOOL)accessibilityPerformEscape { [self cancel]; return YES; }

- (void)complete:(id)value {
  if (self.settled) return;
  self.settled = YES;
  self.submitButton.enabled = NO;
  self.cancelButton.enabled = NO;
  for (UITextField *editor in self.editors) { editor.enabled = NO; [editor resignFirstResponder]; }
  void (^finish)(id) = self.finish;
  self.finish = nil;
  __weak UIView *previousResponder = self.previousResponder;
  [self dismissViewControllerAnimated:YES completion:^{
    if (previousResponder.window != nil) [previousResponder becomeFirstResponder];
    if (finish) finish(value);
  }];
}
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
