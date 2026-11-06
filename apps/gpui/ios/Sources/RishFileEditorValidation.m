#import "RishFileEditorValidation.h"
#include <math.h>

BOOL RishFileEditorTextFits(NSString *text, NSUInteger maxBytes) {
  if (![text isKindOfClass:NSString.class] || maxBytes == 0 || maxBytes > 262144) return NO;
  NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
  return bytes != nil && bytes.length <= maxBytes;
}

BOOL RishFileEditorOptionsAreValid(id options) {
  if (![options isKindOfClass:NSDictionary.class] || [options count] != 7) return NO;
  NSArray *stringKeys = @[@"initial_text", @"title", @"appearance", @"save_label",
    @"cancel_label", @"too_long_message"];
  for (NSString *key in stringKeys) {
    if (![options[key] isKindOfClass:NSString.class]) return NO;
  }
  if (![@[@"light", @"dark"] containsObject:options[@"appearance"]]) return NO;
  NSNumber *limit = options[@"max_bytes"];
  if (![limit isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)limit) == CFBooleanGetTypeID()) return NO;
  double value = limit.doubleValue;
  if (!isfinite(value) || value < 1 || value > 262144 || floor(value) != value) return NO;
  return RishFileEditorTextFits(options[@"initial_text"], limit.unsignedIntegerValue);
}
