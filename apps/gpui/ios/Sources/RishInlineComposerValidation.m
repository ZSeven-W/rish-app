#import "RishInlineComposerValidation.h"
#include <math.h>

static BOOL RishInlineBoolean(id value) {
  return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
static BOOL Number(id value, double minimum, double maximum, BOOL integer) {
  if (![value isKindOfClass:NSNumber.class] || RishInlineBoolean(value)) return NO;
  double number = [value doubleValue];
  return isfinite(number) && number >= minimum && number <= maximum && (!integer || floor(number) == number);
}
static BOOL UUID(id value) {
  if (![value isKindOfClass:NSString.class] || [value length] != 36) return NO;
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
  return uuid != nil && [uuid.UUIDString caseInsensitiveCompare:value] == NSOrderedSame;
}
static BOOL Text(id value, NSUInteger maximum) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
  return bytes != nil && bytes.length <= maximum;
}
static BOOL Keys(id value, NSArray *keys) {
  return [value isKindOfClass:NSDictionary.class] && [value count] == keys.count &&
    [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
BOOL RishInlineSessionValid(id value, BOOL waiting) {
  return Keys(value, waiting ? @[@"session_id", @"after_revision"] : @[@"session_id"]) &&
    UUID(value[@"session_id"]) && (!waiting || Number(value[@"after_revision"], 0, 9007199254740991.0, YES));
}
BOOL RishInlineClearValid(id value) {
  return Keys(value, @[@"session_id", @"expected_revision", @"text_revision"]) && UUID(value[@"session_id"]) &&
    Number(value[@"expected_revision"], 0, 9007199254740991.0, YES) &&
    Number(value[@"text_revision"], 1, 9007199254740991.0, YES);
}
BOOL RishInlineSyncValid(id value) {
  if (!Keys(value, @[@"session_id", @"text_revision", @"text", @"rect", @"viewport", @"scale",
      @"visible", @"focus", @"appearance", @"placeholder"]) || !UUID(value[@"session_id"]) ||
      !Number(value[@"text_revision"], 1, 9007199254740991.0, YES) || !Text(value[@"text"], 1024 * 1024) ||
      !Text(value[@"placeholder"], 16384) || !Number(value[@"scale"], 0.1, 16, NO) ||
      !RishInlineBoolean(value[@"visible"]) || !(value[@"focus"] == NSNull.null || RishInlineBoolean(value[@"focus"])) ||
      ![@[@"light", @"dark"] containsObject:value[@"appearance"]]) return NO;
  NSArray *rect = value[@"rect"], *viewport = value[@"viewport"];
  if (![rect isKindOfClass:NSArray.class] || rect.count != 4 ||
      ![viewport isKindOfClass:NSArray.class] || viewport.count != 2) return NO;
  for (id number in viewport) if (!Number(number, 1, 32768, NO)) return NO;
  for (id number in rect) if (!Number(number, 0, 32768, NO)) return NO;
  if ([value[@"visible"] boolValue] && ([rect[2] doubleValue] <= 0 || [rect[3] doubleValue] <= 0)) return NO;
  return [rect[0] doubleValue] + [rect[2] doubleValue] <= [viewport[0] doubleValue] + 0.5 &&
    [rect[1] doubleValue] + [rect[3] doubleValue] <= [viewport[1] doubleValue] + 0.5;
}
