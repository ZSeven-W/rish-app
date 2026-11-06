#import "RishNameValidation.h"
#include "rish_agent_core.h"
#include <string.h>

BOOL RishNameOptionsAreValid(id options) {
  if (![options isKindOfClass:NSDictionary.class]) return NO;
  NSArray *keys = @[@"kind", @"initial_text", @"title", @"label", @"placeholder",
    @"hint", @"submit_label", @"cancel_label", @"empty_error", @"invalid_error",
    @"long_error", @"appearance"];
  if ([options count] != keys.count) return NO;
  for (NSString *key in keys) {
    if (![options[key] isKindOfClass:NSString.class]) return NO;
  }
  return [@[@"workspace", @"conversation"] containsObject:options[@"kind"]] &&
    [@[@"light", @"dark"] containsObject:options[@"appearance"]];
}

static NSDictionary *RishNamePolicy(NSString *text, NSString *kind) {
  // Refuse malformed UTF-16 before JSON encoding can replace it. Normalization
  // and all product rules belong to the shared Rust policy.
  if (![text isKindOfClass:NSString.class] || ![kind isKindOfClass:NSString.class] ||
      [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO] == nil) return nil;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:@{
    @"kind": kind, @"text": text,
  } options:0 error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_name_policy_reduce(
    bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil];
  if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"ok"] isEqual:@YES] ||
      ![reply[@"value"] isKindOfClass:NSDictionary.class]) return nil;
  NSDictionary *value = reply[@"value"];
  return [value[@"text"] isKindOfClass:NSString.class] ? value : nil;
}

NSString *RishNormalizedName(NSString *text) {
  return RishNamePolicy(text, @"conversation")[@"text"];
}

RishNameValidationIssue RishValidateName(NSString *text, NSString *kind) {
  id issue = RishNamePolicy(text, kind)[@"issue"];
  if (issue == NSNull.null) return RishNameValidationIssueNone;
  if ([issue isEqual:@"empty"]) return RishNameValidationIssueEmpty;
  if ([issue isEqual:@"too_long"]) return RishNameValidationIssueTooLong;
  return RishNameValidationIssueInvalid;
}
