#import <Foundation/Foundation.h>
#import "RishNameValidation.h"

static NSUInteger checks;

static void Check(BOOL condition, NSString *message) {
  checks += 1;
  NSCAssert(condition, @"%@", message);
}

static NSString *Repeat(NSString *text, NSUInteger count) {
  NSMutableString *result = [NSMutableString string];
  for (NSUInteger index = 0; index < count; ++index) [result appendString:text];
  return result;
}

static void Name(NSString *text, NSString *kind, RishNameValidationIssue expected) {
  RishNameValidationIssue actual = RishValidateName(text, kind);
  Check(actual == expected,
        [NSString stringWithFormat:@"%@ name %@: expected issue %ld, got %ld",
                                   kind, text, (long)expected, (long)actual]);
}

static NSMutableDictionary *Options(void) {
  return [@{
    @"kind": @"workspace", @"initial_text": @"", @"title": @"New workspace",
    @"label": @"Name", @"placeholder": @"Workspace name", @"hint": @"Choose a name",
    @"submit_label": @"Create", @"cancel_label": @"Cancel", @"empty_error": @"Required",
    @"invalid_error": @"Invalid name", @"long_error": @"Too long", @"appearance": @"light",
  } mutableCopy];
}

static void TestOptions(void) {
  for (NSString *kind in @[@"workspace", @"conversation"]) {
    for (NSString *appearance in @[@"light", @"dark"]) {
      NSMutableDictionary *options = Options();
      options[@"kind"] = kind;
      options[@"appearance"] = appearance;
      Check(RishNameOptionsAreValid(options), @"Both name kinds support both appearances");
    }
  }

  Check(!RishNameOptionsAreValid(nil), @"Missing options must fail");
  for (id options in @[NSNull.null, @[], @"workspace", @42, @{}]) {
    Check(!RishNameOptionsAreValid(options), @"Options must be a complete dictionary");
  }
  for (NSString *key in Options()) {
    NSMutableDictionary *missing = Options();
    [missing removeObjectForKey:key];
    Check(!RishNameOptionsAreValid(missing),
          [NSString stringWithFormat:@"Missing required key %@ must fail", key]);
    for (id value in @[NSNull.null, @42, @YES, @[], @{}]) {
      NSMutableDictionary *malformed = Options();
      malformed[key] = value;
      Check(!RishNameOptionsAreValid(malformed),
            [NSString stringWithFormat:@"Non-string %@ must fail", key]);
    }
  }
  NSMutableDictionary *extra = Options();
  extra[@"allow_empty"] = @"yes";
  Check(!RishNameOptionsAreValid(extra), @"The options schema is closed");
  NSMutableDictionary *nonStringKey = Options();
  nonStringKey[@1] = @"unexpected";
  Check(!RishNameOptionsAreValid(nonStringKey), @"Non-string extra keys must fail");
  for (NSString *kind in @[@"", @"Workspace", @"project"]) {
    NSMutableDictionary *options = Options();
    options[@"kind"] = kind;
    Check(!RishNameOptionsAreValid(options), @"Only exact supported name kinds are valid");
  }
  for (NSString *appearance in @[@"", @"Light", @"system"]) {
    NSMutableDictionary *options = Options();
    options[@"appearance"] = appearance;
    Check(!RishNameOptionsAreValid(options), @"Only exact supported appearances are valid");
  }
  NSMutableDictionary *initialInvalid = Options();
  initialInvalid[@"initial_text"] = @".";
  Check(RishNameOptionsAreValid(initialInvalid), @"Initial text is validated by the form, not the options schema");
}

static void TestNormalization(void) {
  Check([RishNormalizedName(@" \t\nCafe\u0301\u00a0 ") isEqual:@"Café"],
        @"Trim padding and compose decomposed accents");
  Check([RishNormalizedName(@"\u3000项目\u3000") isEqual:@"项目"], @"Trim Unicode whitespace");
  Check([RishNormalizedName(@"  alpha  beta  ") isEqual:@"alpha  beta"], @"Keep interior spaces");
  Check([RishNormalizedName(@"\u1100\u1161") isEqual:@"가"], @"Compose Hangul to NFC");
  Check([RishNormalizedName(@"🚀") isEqual:@"🚀"], @"Preserve supplementary scalars");
  Check([RishNormalizedName([NSString stringWithFormat:@"%C项目%C", (unichar)0x85, (unichar)0x85])
    isEqual:@"项目"],
        @"Rust Unicode whitespace policy owns normalization on iOS");
  Check(RishNormalizedName(nil) == nil, @"Missing native strings cannot cross the policy boundary");
  Name(@"valid", @"unknown", RishNameValidationIssueInvalid);

  for (NSString *kind in @[@"workspace", @"conversation"]) {
    for (NSString *empty in @[@"", @" ", @"\t\r\n", @"\u00a0\u3000"]) {
      Name(empty, kind, RishNameValidationIssueEmpty);
    }
    for (NSString *valid in @[@"a", @"My Work", @"项目", @"Résumé", @"phase.one", @" \nCafe\u0301\t "]) {
      Name(valid, kind, RishNameValidationIssueNone);
    }
  }
}

static void TestInvalidNames(void) {
  // These are checked against the real workspace reducer linked into the host test.
  for (NSString *invalid in @[@".", @"..", @".hidden", @".rish-cache", @"one/two", @"one\\two",
                              @"one:two", @"Rish Workspaces", @"RISH WORKSPACES", @"RÍSH Wórkspáces",
                              @"Ri\u0301sh Workspaces", @"  Rish Workspaces  ", @"a\u200bb", @"a\u2060b"]) {
    Name(invalid, @"workspace", RishNameValidationIssueInvalid);
  }
  for (NSString *valid in @[@"Rish Workspaces 2", @"my.rish-project", @"rish-project"]) {
    Name(valid, @"workspace", RishNameValidationIssueNone);
  }
  for (NSString *valid in @[@".", @"..", @".hidden", @"a/b\\c: title", @"RÍSH Wórkspáces"]) {
    Name(valid, @"conversation", RishNameValidationIssueNone);
  }
  Name(@"👩\u200d💻", @"conversation", RishNameValidationIssueNone);
  Name(@"👩\u200d💻", @"workspace", RishNameValidationIssueInvalid);

  // Interior controls cannot be removed by trimming. Include NUL to catch C-string truncation.
  const unichar forbidden[] = {0x0000, 0x0001, 0x0009, 0x000a, 0x000d, 0x001b,
                              0x007f, 0x0085, 0x009f, 0x2028, 0x2029};
  for (NSUInteger index = 0; index < sizeof(forbidden) / sizeof(forbidden[0]); ++index) {
    unichar characters[] = {'a', forbidden[index], 'b'};
    NSString *text = [NSString stringWithCharacters:characters length:3];
    Name(text, @"workspace", RishNameValidationIssueInvalid);
    Name(text, @"conversation", RishNameValidationIssueInvalid);
  }
  const unichar unpaired[] = {0xd800, 0xdc00};
  for (NSUInteger index = 0; index < sizeof(unpaired) / sizeof(unpaired[0]); ++index) {
    unichar characters[] = {'a', unpaired[index], 'b'};
    NSString *text = [NSString stringWithCharacters:characters length:3];
    Name(text, @"workspace", RishNameValidationIssueInvalid);
    Name(text, @"conversation", RishNameValidationIssueInvalid);
    Check(RishNormalizedName(text) == nil, @"Malformed UTF-16 is refused before Rust conversion");
  }
}

static void TestLengthLimits(void) {
  // Workspace limits apply to UTF-8 bytes after normalization, not UTF-16 units or glyphs.
  for (NSArray *example in @[@[@"a", @120], @[@"é", @60], @[@"界", @40], @[@"🚀", @30]]) {
    NSString *exact = Repeat(example[0], [example[1] unsignedIntegerValue]);
    Name(exact, @"workspace", RishNameValidationIssueNone);
    Name([exact stringByAppendingString:@"a"], @"workspace", RishNameValidationIssueTooLong);
  }
  Name([Repeat(@"a", 116) stringByAppendingString:@"🚀"], @"workspace", RishNameValidationIssueNone);
  Name([Repeat(@"a", 117) stringByAppendingString:@"🚀"], @"workspace", RishNameValidationIssueTooLong);
  Name(Repeat(@"e\u0301", 60), @"workspace", RishNameValidationIssueNone);
  Name(Repeat(@"e\u0301", 61), @"workspace", RishNameValidationIssueTooLong);
  Name([NSString stringWithFormat:@"  %@\n", Repeat(@"a", 120)], @"workspace", RishNameValidationIssueNone);

  // Conversation UI now enforces the persisted session's UTF-8 byte limit.
  // The old scalar limit accepted CJK/emoji titles that storage would reject.
  for (NSArray *example in @[@[@"a", @120], @[@"é", @60], @[@"界", @40], @[@"🚀", @30]]) {
    NSString *exact = Repeat(example[0], [example[1] unsignedIntegerValue]);
    Name(exact, @"conversation", RishNameValidationIssueNone);
    Name([exact stringByAppendingString:@"a"], @"conversation", RishNameValidationIssueTooLong);
  }
  Name(Repeat(@"e\u0301", 60), @"conversation", RishNameValidationIssueNone);
  Name(Repeat(@"e\u0301", 61), @"conversation", RishNameValidationIssueTooLong);
  // x + acute has no precomposed form. Counting follows NFC UTF-8 bytes.
  Name([@"x" stringByAppendingString:Repeat(@"\u0301", 59)], @"conversation", RishNameValidationIssueNone);
  Name([@"x" stringByAppendingString:Repeat(@"\u0301", 60)], @"conversation", RishNameValidationIssueTooLong);
  Name([NSString stringWithFormat:@"\t%@  ", Repeat(@"🚀", 30)], @"conversation", RishNameValidationIssueNone);
}

int main(void) {
  @autoreleasepool {
    TestOptions();
    TestNormalization();
    TestInvalidNames();
    TestLengthLimits();
    printf("PASS: %lu name validation checks, closed options, NFC, real workspace FFI, Unicode and length boundaries\n",
           (unsigned long)checks);
  }
  return 0;
}
