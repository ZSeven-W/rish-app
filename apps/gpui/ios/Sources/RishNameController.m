#import "RishNameController.h"
#import "RishNameValidation.h"
#import "RishNativeTheme.h"

@interface RishNameController ()
@property(nonatomic, strong) UITextField *editor;
@property(nonatomic, strong) UILabel *helper;
@property(nonatomic, strong) UIStackView *content;
@property(nonatomic, strong) UIScrollView *scroll;
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIControl *scrim;
@property(nonatomic, strong) NSLayoutConstraint *cardHeight;
@property(nonatomic, strong) NSLayoutConstraint *baselineBottom;
@property(nonatomic, strong) UIButton *submitButton;
@property(nonatomic, strong) UIButton *cancelButton;
@property(nonatomic) BOOL hasEdited;
@property(nonatomic) BOOL settled;
@property(nonatomic) CGFloat lastContentHeight;
@property(nonatomic) CGSize lastViewportSize;
@end

@implementation RishNameController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.clearColor;
  self.view.opaque = NO;
  self.view.accessibilityViewIsModal = YES;
  self.title = self.options[@"title"];

  self.scrim = [UIControl new];
  self.scrim.translatesAutoresizingMaskIntoConstraints = NO;
  self.scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
  self.scrim.layer.backgroundColor = self.scrim.backgroundColor.CGColor;
  self.scrim.isAccessibilityElement = NO;
  [self.scrim addTarget:self action:@selector(cancel)
      forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.scrim];

  self.card = [UIView new];
  self.card.translatesAutoresizingMaskIntoConstraints = NO;
  RishNativeFill(self.card, RishNativePanel(self.view));
  self.card.layer.cornerRadius = 28;
  self.card.layer.borderWidth = 1;
  self.card.layer.borderColor = RishNativeLine(self.view).CGColor;
  self.card.layer.cornerCurve = kCACornerCurveContinuous;
  self.card.clipsToBounds = YES;
  self.card.accessibilityIdentifier = @"rish-name-card";
  [self.view addSubview:self.card];

  UIView *dragArea = [UIView new];
  dragArea.translatesAutoresizingMaskIntoConstraints = NO;
  [dragArea addGestureRecognizer:[[UIPanGestureRecognizer alloc]
    initWithTarget:self action:@selector(dragCard:)]];
  [self.card addSubview:dragArea];
  UIView *grabber = [UIView new];
  grabber.translatesAutoresizingMaskIntoConstraints = NO;
  grabber.backgroundColor = RishNativeLine(self.view);
  grabber.layer.backgroundColor = grabber.backgroundColor.CGColor;
  grabber.layer.cornerRadius = 2.5;
  [dragArea addSubview:grabber];

  UILabel *title = [UILabel new];
  title.text = self.title;
  title.font = RishNativeFont(20, UIFontWeightSemibold, UIFontTextStyleTitle2);
  title.textColor = RishNativeText(self.view);
  title.adjustsFontForContentSizeCategory = YES;
  title.numberOfLines = 0;
  title.accessibilityTraits = UIAccessibilityTraitHeader;
  [title setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                       forAxis:UILayoutConstraintAxisHorizontal];

  self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
  RishNativeButton(self.cancelButton, self.options[@"cancel_label"], NO);
  self.cancelButton.accessibilityIdentifier = @"rish-name-cancel";
  [self.cancelButton addTarget:self action:@selector(cancel)
             forControlEvents:UIControlEventTouchUpInside];
  [self.cancelButton setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                    forAxis:UILayoutConstraintAxisHorizontal];
  UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, self.cancelButton]];
  header.alignment = UIStackViewAlignmentCenter;
  header.spacing = 12;

  UILabel *label = [UILabel new];
  label.text = self.options[@"label"];
  label.font = RishNativeFont(13, UIFontWeightMedium, UIFontTextStyleSubheadline);
  label.adjustsFontForContentSizeCategory = YES;
  label.textColor = RishNativeMuted(self.view);
  label.numberOfLines = 0;

  UIView *fieldContainer = [UIView new];
  RishNativeField(fieldContainer, self.view);
  self.editor = [UITextField new];
  self.editor.translatesAutoresizingMaskIntoConstraints = NO;
  self.editor.font = RishNativeFont(15, UIFontWeightRegular, UIFontTextStyleBody);
  self.editor.textColor = RishNativeText(self.view);
  self.editor.tintColor = RishNativeText(self.view);
  self.editor.adjustsFontForContentSizeCategory = YES;
  self.editor.text = self.options[@"initial_text"];
  self.editor.placeholder = self.options[@"placeholder"];
  self.editor.accessibilityLabel = self.options[@"label"];
  self.editor.accessibilityIdentifier = @"rish-name-editor";
  self.editor.clearButtonMode = UITextFieldViewModeWhileEditing;
  self.editor.returnKeyType = UIReturnKeyDone;
  self.editor.enablesReturnKeyAutomatically = YES;
  self.editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
  self.editor.autocorrectionType = UITextAutocorrectionTypeNo;
  self.editor.spellCheckingType = UITextSpellCheckingTypeNo;
  self.editor.keyboardAppearance = [self.options[@"appearance"] isEqual:@"dark"] ?
    UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
  self.editor.delegate = self;
  [self.editor addTarget:self action:@selector(textChanged)
       forControlEvents:UIControlEventEditingChanged];
  [fieldContainer addSubview:self.editor];

  self.helper = [UILabel new];
  self.helper.font = RishNativeFont(13, UIFontWeightRegular, UIFontTextStyleFootnote);
  self.helper.adjustsFontForContentSizeCategory = YES;
  self.helper.numberOfLines = 0;
  self.helper.accessibilityIdentifier = @"rish-name-hint";

  self.submitButton = [UIButton buttonWithType:UIButtonTypeSystem];
  RishNativeButton(self.submitButton, self.options[@"submit_label"], YES);
  self.submitButton.accessibilityIdentifier = @"rish-name-submit";
  [self.submitButton addTarget:self action:@selector(submit)
             forControlEvents:UIControlEventTouchUpInside];

  self.content = [[UIStackView alloc] initWithArrangedSubviews:
    @[header, label, fieldContainer, self.helper, self.submitButton]];
  self.content.axis = UILayoutConstraintAxisVertical;
  self.content.spacing = 8;
  [self.content setCustomSpacing:16 afterView:header];
  [self.content setCustomSpacing:20 afterView:self.helper];
  self.content.translatesAutoresizingMaskIntoConstraints = NO;

  UIScrollView *scroll = [UIScrollView new];
  self.scroll = scroll;
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  scroll.alwaysBounceVertical = NO;
  [self.card addSubview:scroll];
  [scroll addSubview:self.content];
  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  UIKeyboardLayoutGuide *keyboard = self.view.keyboardLayoutGuide;
  keyboard.followsUndockedKeyboard = YES;
  // A complete baseline is present before keyboard tracking is initialized.
  // Required keyboard constraints can move the card, while its desired height
  // yields to the top safe area so short landscapes retain a scroll viewport.
  self.baselineBottom =
    [self.card.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8];
  self.baselineBottom.priority = UILayoutPriorityDefaultHigh;
  self.cardHeight = [self.card.heightAnchor constraintEqualToConstant:280];
  self.cardHeight.priority = UILayoutPriorityDefaultHigh - 1;
  NSLayoutConstraint *idealWidth = [self.card.widthAnchor constraintEqualToConstant:540];
  idealWidth.priority = UILayoutPriorityDefaultHigh;
  [NSLayoutConstraint activateConstraints:@[
    [self.scrim.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [self.scrim.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [self.scrim.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [self.scrim.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    self.baselineBottom, self.cardHeight, idealWidth,
    [self.card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
    [self.card.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:12],
    [self.card.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-12],
    [self.card.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor constant:12],
    [self.card.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-8],
    [dragArea.topAnchor constraintEqualToAnchor:self.card.topAnchor],
    [dragArea.leadingAnchor constraintEqualToAnchor:self.card.leadingAnchor],
    [dragArea.trailingAnchor constraintEqualToAnchor:self.card.trailingAnchor],
    [dragArea.heightAnchor constraintEqualToConstant:28],
    [grabber.centerXAnchor constraintEqualToAnchor:dragArea.centerXAnchor],
    [grabber.topAnchor constraintEqualToAnchor:dragArea.topAnchor constant:10],
    [grabber.widthAnchor constraintEqualToConstant:36],
    [grabber.heightAnchor constraintEqualToConstant:5],
    [scroll.topAnchor constraintEqualToAnchor:self.card.topAnchor constant:28],
    [scroll.leadingAnchor constraintEqualToAnchor:self.card.leadingAnchor constant:20],
    [scroll.trailingAnchor constraintEqualToAnchor:self.card.trailingAnchor constant:-20],
    [scroll.bottomAnchor constraintEqualToAnchor:self.card.bottomAnchor constant:-16],
    [self.content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
    [self.content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
    [self.content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
    [self.content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
    [self.content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
    [fieldContainer.heightAnchor constraintGreaterThanOrEqualToConstant:52],
    [self.editor.leadingAnchor constraintEqualToAnchor:fieldContainer.leadingAnchor constant:16],
    [self.editor.trailingAnchor constraintEqualToAnchor:fieldContainer.trailingAnchor constant:-12],
    [self.editor.topAnchor constraintEqualToAnchor:fieldContainer.topAnchor constant:12],
    [self.editor.bottomAnchor constraintEqualToAnchor:fieldContainer.bottomAnchor constant:-12],
    [self.cancelButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    [self.submitButton.heightAnchor constraintGreaterThanOrEqualToConstant:52],
  ]];
  // Track both docked and floating keyboards. A keyboard near the top leaves
  // the full scroll viewport available, rather than collapsing it to zero.
  [keyboard setConstraints:@[[self.card.bottomAnchor constraintEqualToAnchor:keyboard.topAnchor constant:-8]]
    activeWhenAwayFromEdge:NSDirectionalRectEdgeTop];
  [keyboard setConstraints:@[[self.card.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8]]
    activeWhenNearEdge:NSDirectionalRectEdgeTop];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardFrameChanged:)
    name:UIKeyboardWillChangeFrameNotification object:nil];
  [self updateValidation];
}

- (void)preparePresentation {
  [self loadViewIfNeeded];
  self.cardHeight.constant = [self desiredContentHeight];
}

- (CGFloat)desiredContentHeight {
  CGFloat width = MIN(540, self.view.bounds.size.width - self.view.safeAreaInsets.left -
    self.view.safeAreaInsets.right - 24) - 40;
  CGSize size = [self.content systemLayoutSizeFittingSize:CGSizeMake(MAX(1, width), 0)
    withHorizontalFittingPriority:UILayoutPriorityRequired
    verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
  return MAX(280, ceil(size.height) + 44);
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGFloat height = [self desiredContentHeight];
  if (fabs(height - self.lastContentHeight) > 1) {
    self.lastContentHeight = height;
    self.cardHeight.constant = height;
  }
  CGSize viewport = self.scroll.bounds.size;
  if (!CGSizeEqualToSize(viewport, self.lastViewportSize)) {
    self.lastViewportSize = viewport;
    if (self.editor.isFirstResponder) [self revealEditor];
  }
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (!self.settled) {
    [self.editor becomeFirstResponder];
    if (self.editor.text.length > 0) [self.editor selectAll:nil];
    [self revealEditor];
  }
}

- (void)revealEditor {
  CGRect field = [self.editor convertRect:self.editor.bounds toView:self.scroll];
  [self.scroll scrollRectToVisible:CGRectInset(field, 0, -12) animated:NO];
}

- (void)keyboardFrameChanged:(NSNotification *)notification {
  if (self.view.window == nil || self.settled) return;
  CGRect screenFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
  CGRect frame = [self.view convertRect:screenFrame fromCoordinateSpace:self.view.window.screen.coordinateSpace];
  CGRect safe = self.view.safeAreaLayoutGuide.layoutFrame;
  BOOL intersects = CGRectIntersectsRect(frame, self.view.bounds);
  // Also update the baseline for legacy hosts where keyboard tracking has not
  // activated. A floating keyboard near the top must not collapse the card.
  CGFloat overlap = intersects && CGRectGetMinY(frame) > CGRectGetMinY(safe) + 140 ?
    MAX(0, CGRectGetMaxY(safe) - CGRectGetMinY(frame)) : 0;
  self.baselineBottom.constant = -8 - overlap;
  NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
  UIViewAnimationOptions curve =
    [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16;
  [UIView animateWithDuration:duration delay:0
    options:curve | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
    animations:^{ [self.view layoutIfNeeded]; } completion:nil];
}

- (void)dragCard:(UIPanGestureRecognizer *)gesture {
  if (self.settled) return;
  CGFloat distance = MAX(0, [gesture translationInView:self.view].y);
  if (gesture.state == UIGestureRecognizerStateChanged) {
    self.card.transform = CGAffineTransformMakeTranslation(0, distance);
  } else if (gesture.state == UIGestureRecognizerStateEnded &&
      (distance > 64 || [gesture velocityInView:self.view].y > 800)) {
    [self cancel];
  } else if (gesture.state == UIGestureRecognizerStateEnded ||
             gesture.state == UIGestureRecognizerStateCancelled) {
    [UIView animateWithDuration:0.2 animations:^{ self.card.transform = CGAffineTransformIdentity; }];
  }
}

- (BOOL)accessibilityPerformEscape {
  [self cancel];
  return YES;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)textChanged {
  self.hasEdited = YES;
  [self updateValidation];
}

- (void)textFieldDidChangeSelection:(UITextField *)textField {
  [self updateValidation];
}

- (void)updateValidation {
  // Inspect a normalized copy only after IME composition has committed. Never
  // rewrite, truncate, or unmark the actual native editing buffer.
  BOOL composing = self.editor.markedTextRange != nil;
  RishNameValidationIssue issue = composing ? RishNameValidationIssueNone :
    RishValidateName(self.editor.text ?: @"", self.options[@"kind"]);
  BOOL showError = !composing && issue != RishNameValidationIssueNone &&
    (self.hasEdited || self.editor.text.length > 0);
  NSString *errorKey = issue == RishNameValidationIssueEmpty ? @"empty_error" :
    issue == RishNameValidationIssueTooLong ? @"long_error" : @"invalid_error";
  self.helper.text = self.options[showError ? errorKey : @"hint"];
  self.helper.textColor = showError ? UIColor.systemRedColor : RishNativeMuted(self.view);
  self.editor.accessibilityHint = self.helper.text;
  self.submitButton.enabled = !self.settled && !composing && issue == RishNameValidationIssueNone;
  [self.view setNeedsLayout];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
  [self submit];
  return NO;
}

- (void)submit {
  if (self.settled || self.editor.markedTextRange != nil) return;
  self.hasEdited = YES;
  [self updateValidation];
  if (!self.submitButton.enabled) {
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.helper);
    return;
  }
  [self complete:RishNormalizedName(self.editor.text)];
}

- (void)cancel { [self complete:NSNull.null]; }

- (void)complete:(id)value {
  if (self.settled) return;
  self.settled = YES;
  self.submitButton.enabled = NO;
  self.cancelButton.enabled = NO;
  self.editor.enabled = NO;
  void (^finish)(id) = self.finish;
  self.finish = nil;
  [self.editor resignFirstResponder];
  [self dismissViewControllerAnimated:YES completion:^{ if (finish) finish(value); }];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)controller {
  [self settleCancellation];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  // UIKit's adaptive delegate only reports interactive dismissal. An ancestor
  // can dismiss the chain programmatically too; it must release the bridge's
  // active editor while a temporary modal covering this sheet must not.
  if (self.isBeingDismissed || self.presentingViewController.isBeingDismissed ||
      self.presentingViewController == nil) [self settleCancellation];
}

- (void)settleCancellation {
  if (self.settled) return;
  self.settled = YES;
  void (^finish)(id) = self.finish;
  self.finish = nil;
  if (finish) finish(NSNull.null);
}
@end
