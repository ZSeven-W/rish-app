#import <Foundation/Foundation.h>
#import "RishFileEditorValidation.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
  checks += 1;
  NSCAssert(condition, @"%@", message);
}

static NSMutableDictionary *Options(void) {
  return [@{@"initial_text": @"", @"title": @"notes.md", @"appearance": @"light",
    @"save_label": @"Save", @"cancel_label": @"Cancel", @"max_bytes": @262144,
    @"too_long_message": @"This file exceeds the editing limit."} mutableCopy];
}

static void TestOptions(void) {
  Check(RishFileEditorOptionsAreValid(Options()), @"A blank file can be edited");
  for (NSString *appearance in @[@"light", @"dark"]) {
    NSMutableDictionary *options = Options();
    options[@"appearance"] = appearance;
    Check(RishFileEditorOptionsAreValid(options), @"Both appearances are valid");
  }
  for (id malformed in @[NSNull.null, @[], @"text", @1, @{}]) {
    Check(!RishFileEditorOptionsAreValid(malformed), @"Options must be a complete dictionary");
  }
  for (NSString *key in Options()) {
    NSMutableDictionary *missing = Options();
    [missing removeObjectForKey:key];
    Check(!RishFileEditorOptionsAreValid(missing), @"Missing keys are rejected");
    NSMutableDictionary *wrongType = Options();
    wrongType[key] = NSNull.null;
    Check(!RishFileEditorOptionsAreValid(wrongType), @"Wrong key types are rejected");
  }
  NSMutableDictionary *extra = Options();
  extra[@"path"] = @"unexpected";
  Check(!RishFileEditorOptionsAreValid(extra), @"The editor cannot accept a filesystem path");
  for (id invalid in @[@YES, @NO, @0, @(-1), @262145, @1.5, @"262144", @[]]) {
    NSMutableDictionary *options = Options();
    options[@"max_bytes"] = invalid;
    Check(!RishFileEditorOptionsAreValid(options), @"Only a bounded positive integer is valid");
  }
  for (NSString *invalid in @[@"system", @"Light", @""]) {
    NSMutableDictionary *options = Options();
    options[@"appearance"] = invalid;
    Check(!RishFileEditorOptionsAreValid(options), @"Appearance must be resolved before presentation");
  }
  NSMutableDictionary *oversized = Options();
  oversized[@"max_bytes"] = @2;
  oversized[@"initial_text"] = @"界";
  Check(!RishFileEditorOptionsAreValid(oversized), @"Initial text is subject to the same UTF-8 byte limit");
}

static void TestByteBoundaries(void) {
  Check(RishFileEditorTextFits(@"", 1), @"An empty existing file is valid");
  Check(RishFileEditorTextFits(@"界", 3), @"Chinese uses three UTF-8 bytes");
  Check(!RishFileEditorTextFits(@"界", 2), @"Do not count UTF-16 units as UTF-8 bytes");
  Check(RishFileEditorTextFits(@"🚀", 4), @"Supplementary Unicode uses four UTF-8 bytes");
  Check(!RishFileEditorTextFits(@"🚀", 3), @"Do not count graphemes as bytes");
  Check(RishFileEditorTextFits(@"e\u0301", 3), @"Decomposed file contents are preserved");
  Check(!RishFileEditorTextFits(@"e\u0301", 2), @"Validation must not normalize file contents");
  Check(RishFileEditorTextFits(@" \r\n\t", 4), @"Whitespace-only files are valid and untrimmed");
  Check(!RishFileEditorTextFits(@" \r\n\t", 3), @"Every whitespace byte counts");
  NSString *exact = [@"" stringByPaddingToLength:262144 withString:@"a" startingAtIndex:0];
  Check(RishFileEditorTextFits(exact, 262144), @"256 KiB boundary is accepted");
  Check(!RishFileEditorTextFits([exact stringByAppendingString:@"a"], 262144), @"Over-limit buffers are rejected without truncation");
  Check(!RishFileEditorTextFits(@"", 0), @"Zero limit is invalid");
  Check(!RishFileEditorTextFits(@"", 262145), @"Host limit cannot be bypassed");
  const unichar unpaired[] = {0xd800, 0xdc00};
  for (NSUInteger index = 0; index < 2; ++index) {
    NSString *malformed = [NSString stringWithCharacters:&unpaired[index] length:1];
    Check(!RishFileEditorTextFits(malformed, 262144), @"Unpaired UTF-16 cannot silently become an empty file");
  }
}

int main(void) {
  @autoreleasepool {
    TestOptions();
    TestByteBoundaries();
    printf("PASS: %lu file editor validation checks, closed options, empty text, UTF-8 and byte limits\n",
           (unsigned long)checks);
  }
  return 0;
}
