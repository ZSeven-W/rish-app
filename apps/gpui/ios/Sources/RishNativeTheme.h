#import <UIKit/UIKit.h>

// Match GPUI's warm neutral palette. Resolve every layer fill explicitly: a
// dynamic UIColor alone can leave native overlays translucent on older hosts.
static inline UIColor *RishNativeColor(UIView *view, uint32_t light, uint32_t dark) {
  uint32_t rgb = view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
  return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0
    green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}
static inline UIColor *RishNativeCanvas(UIView *view) { return RishNativeColor(view, 0xF8F8F6, 0x151715); }
static inline UIColor *RishNativePanel(UIView *view) { return RishNativeColor(view, 0xFFFFFF, 0x20231F); }
static inline UIColor *RishNativeSurface(UIView *view) { return RishNativeColor(view, 0xF0F1EE, 0x1B1E1A); }
static inline UIColor *RishNativeLine(UIView *view) { return RishNativeColor(view, 0xE1E4DE, 0x373E34); }
static inline UIColor *RishNativeText(UIView *view) { return RishNativeColor(view, 0x242722, 0xEDF0E9); }
static inline UIColor *RishNativeMuted(UIView *view) { return RishNativeColor(view, 0x71766D, 0xA4AE9D); }
static inline UIColor *RishNativeAccent(UIView *view) { return RishNativeColor(view, 0x272B25, 0xE9EEE3); }
static inline UIColor *RishNativeOnAccent(UIView *view) { return RishNativeColor(view, 0xFFFFFF, 0x20231F); }

static inline UIFont *RishNativeFont(CGFloat size, UIFontWeight weight, UIFontTextStyle style) {
  return [[UIFontMetrics metricsForTextStyle:style]
    scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];
}
static inline void RishNativeFill(UIView *view, UIColor *color) {
  view.backgroundColor = color;
  view.layer.backgroundColor = color.CGColor;
  view.opaque = YES;
}
static inline void RishNativeField(UIView *view, UIView *themeView) {
  RishNativeFill(view, RishNativePanel(themeView));
  view.layer.cornerRadius = 12;
  view.layer.cornerCurve = kCACornerCurveContinuous;
  view.layer.borderWidth = 1;
  view.layer.borderColor = RishNativeLine(themeView).CGColor;
}
static inline void RishNativeButton(UIButton *button, NSString *title, BOOL primary) {
  UIButtonConfiguration *style = primary ? UIButtonConfiguration.filledButtonConfiguration :
    UIButtonConfiguration.plainButtonConfiguration;
  style.title = title;
  style.cornerStyle = UIButtonConfigurationCornerStyleFixed;
  style.background.cornerRadius = 12;
  style.contentInsets = NSDirectionalEdgeInsetsMake(10, primary ? 16 : 4, 10, primary ? 16 : 4);
  style.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
    NSMutableDictionary *updated = [attributes mutableCopy];
    updated[NSFontAttributeName] = RishNativeFont(15, UIFontWeightMedium, UIFontTextStyleBody);
    return updated;
  };
  button.configuration = style;
  button.titleLabel.adjustsFontForContentSizeCategory = YES;
  button.configurationUpdateHandler = ^(UIButton *control) {
    UIButtonConfiguration *updated = control.configuration;
    updated.baseForegroundColor = control.enabled ? (primary ? RishNativeOnAccent(control) :
      RishNativeMuted(control)) : RishNativeMuted(control);
    if (primary) updated.baseBackgroundColor = control.enabled ? RishNativeAccent(control) :
      RishNativeSurface(control);
    control.configuration = updated;
  };
}

// Width follows the current window, including iPad Split View. The content and
// controls stay the same size; extra width becomes breathing room, not zoom.
static inline UILayoutGuide *RishNativeColumn(UIView *view, CGFloat maximum, CGFloat inset) {
  UILayoutGuide *column = [UILayoutGuide new];
  [view addLayoutGuide:column];
  UILayoutGuide *safe = view.safeAreaLayoutGuide;
  NSLayoutConstraint *width = [column.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-inset * 2];
  width.priority = UILayoutPriorityDefaultHigh;
  [NSLayoutConstraint activateConstraints:@[
    [column.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
    [column.widthAnchor constraintLessThanOrEqualToConstant:maximum], width,
    [column.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:inset],
    [column.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-inset],
    [column.topAnchor constraintEqualToAnchor:safe.topAnchor],
    [column.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
  ]];
  return column;
}
