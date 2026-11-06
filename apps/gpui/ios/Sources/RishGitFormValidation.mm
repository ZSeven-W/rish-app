#import "RishGitFormValidation.h"
#include "rish_agent_core.h"
#include <string.h>

static NSArray<NSString *> *RishGitFormKeys(NSString *kind) {
  if ([kind isEqual:@"commit"]) return @[@"message", @"author_name", @"author_email"];
  if ([kind isEqual:@"remote"]) return @[@"url"];
  return nil;
}

BOOL RishGitFormOptionsAreValid(id options) {
  if (![options isKindOfClass:NSDictionary.class] || [options count] != 8) return NO;
  for (NSString *key in @[@"kind", @"appearance", @"title", @"submit_label",
                          @"cancel_label", @"hint", @"invalid_message"]) {
    if (![options[key] isKindOfClass:NSString.class]) return NO;
  }
  if (![@[@"light", @"dark"] containsObject:options[@"appearance"]]) return NO;
  NSArray *keys = RishGitFormKeys(options[@"kind"]);
  NSArray *fields = options[@"fields"];
  if (keys == nil || ![fields isKindOfClass:NSArray.class] || fields.count != keys.count) return NO;
  for (NSUInteger index = 0; index < fields.count; ++index) {
    id field = fields[index];
    if (![field isKindOfClass:NSDictionary.class] || [field count] != 4) return NO;
    for (NSString *key in @[@"key", @"label", @"placeholder", @"value"]) {
      if (![field[key] isKindOfClass:NSString.class]) return NO;
    }
    if (![field[@"key"] isEqual:keys[index]]) return NO;
  }
  return YES;
}

static NSCharacterSet *RishGitWhitespace(void) {
  static NSCharacterSet *whitespace;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableCharacterSet *set = [NSMutableCharacterSet characterSetWithCharactersInString:
      @"\t\n\v\f\r \u00a0\u1680\u2000\u2001\u2002\u2003\u2004"
       "\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000"];
    [set addCharactersInRange:NSMakeRange(0x85, 1)];
    whitespace = [set copy];
  });
  return whitespace;
}

static BOOL RishGitSingleLine(NSString *value, NSUInteger maximumBytes) {
  NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
  return bytes != nil && bytes.length > 0 && bytes.length <= maximumBytes &&
    [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound &&
    [value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound;
}

static NSDictionary *RishGitRemoteFormValue(id text) {
  if (![text isKindOfClass:NSString.class] ||
      [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO] == nil) return nil;
  NSData *request = [NSJSONSerialization dataWithJSONObject:@{@"url": text, @"form": @YES} options:0 error:nil];
  char *raw = request == nil ? nullptr : rish_agent_git_remote_policy_reduce(
    static_cast<const char *>(request.bytes), request.length);
  if (raw == nullptr) return nil;
  NSData *bytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
  if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"ok"] isEqual:@YES] ||
      ![reply[@"value"] isKindOfClass:NSDictionary.class]) return nil;
  NSDictionary *value = reply[@"value"];
  if (![@[@"http", @"https"] containsObject:value[@"scheme"]] ||
      ![value[@"url"] isKindOfClass:NSString.class]) return nil;
  return @{@"url": value[@"url"]};
}

NSDictionary<NSString *, NSString *> *RishGitFormValues(NSString *kind, id values) {
  NSArray *keys = RishGitFormKeys(kind);
  if (keys == nil || ![values isKindOfClass:NSDictionary.class] || [values count] != keys.count)
    return nil;
  if ([kind isEqual:@"remote"]) return RishGitRemoteFormValue(values[@"url"]);
  NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:keys.count];
  for (NSString *key in keys) {
    if (![values[key] isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [values[key] stringByTrimmingCharactersInSet:RishGitWhitespace()];
    result[key] = [trimmed precomposedStringWithCanonicalMapping];
  }
  NSString *name = result[@"author_name"];
  NSString *email = result[@"author_email"];
  NSArray *emailParts = [email componentsSeparatedByString:@"@"];
  NSCharacterSet *brackets = [NSCharacterSet characterSetWithCharactersInString:@"<>"];
  if (!RishGitSingleLine(result[@"message"], 500) || !RishGitSingleLine(name, 120) ||
      !RishGitSingleLine(email, 254) ||
      [name rangeOfCharacterFromSet:brackets].location != NSNotFound ||
      [email rangeOfCharacterFromSet:brackets].location != NSNotFound ||
      [email rangeOfCharacterFromSet:RishGitWhitespace()].location != NSNotFound ||
      emailParts.count != 2 || [emailParts[0] length] == 0 || [emailParts[1] length] == 0)
    return nil;
  return [result copy];
}
