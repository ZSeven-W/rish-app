// Golden oracle for the shared Rust agent core (modules/rish/core).
//
// The Objective-C++ engine is the reference: this test runs every case in
// modules/rish/core/fixtures/canonical-corpus.json through
// DSHWorkspaceCanonicalJSONData, DSHAgentHJ, DSHAgentHB and
// DSHAgentParseArgumentsJSON and compares the results with
// canonical-golden.json. The Rust crate replays the same corpus against the
// same golden (crates/rish-agent-core/tests/golden.rs), so the two
// implementations are pinned to each other byte for byte.
//
// Regenerate the golden from the ObjC engine (never by hand):
//   export TEST_RUNNER_RISH_CORE_GOLDEN_OUT=/abs/path/modules/rish/core/fixtures/canonical-golden.json
//   xcodebuild test ... -only-testing:RishTests/AgentCoreGoldenTests

#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/AgentNativeWAL.h"
#import "../../../../modules/rish/ios/Sources/DSHWorkspaceCanonical.h"

@interface AgentCoreGoldenTests : XCTestCase
@end

@implementation AgentCoreGoldenTests

static NSDictionary *DSHGoldenLoadJSON(NSString *name) {
  NSBundle *bundle = [NSBundle bundleForClass:AgentCoreGoldenTests.class];
  NSURL *url = [bundle URLForResource:name withExtension:@"json"];
  if (url == nil) return nil;
  NSData *data = [NSData dataWithContentsOfURL:url];
  if (data == nil) return nil;
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSString *DSHGoldenHex(NSData *data) {
  NSMutableString *hex = [NSMutableString string];
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  for (NSUInteger index = 0; index < data.length; index += 1) [hex appendFormat:@"%02x", bytes[index]];
  return hex;
}

// Parses a JSON text exactly as the engine's inputs arrive (any fragment),
// then canonicalises. Returns nil when either step refuses, which the golden
// records as null so the Rust side must refuse the same inputs.
static NSString *DSHGoldenCanonicalOfText(NSString *text, id *parsedOut) {
  NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
  if (bytes == nil) return nil;
  NSError *error = nil;
  id parsed = [NSJSONSerialization JSONObjectWithData:bytes
                                              options:NSJSONReadingAllowFragments
                                                error:&error];
  if (parsed == nil) return nil;
  if (parsedOut != nil) *parsedOut = parsed;
  NSData *canonical = DSHWorkspaceCanonicalJSONData(parsed, &error);
  if (canonical == nil) return nil;
  return [[NSString alloc] initWithData:canonical encoding:NSUTF8StringEncoding];
}

static NSData *DSHGoldenBytesFromHex(NSString *hex) {
  NSMutableData *data = [NSMutableData dataWithCapacity:hex.length / 2];
  for (NSUInteger index = 0; index + 1 < hex.length; index += 2) {
    unsigned value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(index, 2)]];
    [scanner scanHexInt:&value];
    uint8_t byte = (uint8_t)value;
    [data appendBytes:&byte length:1];
  }
  return data;
}

- (NSDictionary *)goldenFromCorpus:(NSDictionary *)corpus {
  NSMutableDictionary *canonical = [NSMutableDictionary dictionary];
  for (NSDictionary *item in corpus[@"canonical"]) {
    id parsed = nil;
    NSString *text = DSHGoldenCanonicalOfText(item[@"json"], &parsed);
    NSString *hash = parsed == nil ? nil : DSHAgentHJ(@"golden", parsed, nil);
    canonical[item[@"name"]] = @{
      @"canonical" : text ?: NSNull.null,
      @"hash" : hash ?: NSNull.null,
    };
  }
  NSMutableDictionary *hashJSON = [NSMutableDictionary dictionary];
  for (NSDictionary *item in corpus[@"hash_json"]) {
    id parsed = nil;
    (void)DSHGoldenCanonicalOfText(item[@"json"], &parsed);
    NSString *hash = parsed == nil ? nil : DSHAgentHJ(item[@"tag"], parsed, nil);
    hashJSON[item[@"name"]] = hash ?: NSNull.null;
  }
  NSMutableDictionary *hashBytes = [NSMutableDictionary dictionary];
  for (NSDictionary *item in corpus[@"hash_bytes"]) {
    NSString *hash = DSHAgentHB(item[@"tag"], DSHGoldenBytesFromHex(item[@"bytes_hex"]), nil);
    hashBytes[item[@"name"]] = hash ?: NSNull.null;
  }
  NSMutableDictionary *arguments = [NSMutableDictionary dictionary];
  for (NSDictionary *item in corpus[@"arguments"]) {
    NSError *error = nil;
    NSDictionary *accepted = DSHAgentParseArgumentsJSON(item[@"json"], &error);
    arguments[item[@"name"]] = @(accepted != nil);
  }
  return @{
    @"schema_version" : @1,
    @"generator" : @"AgentCoreGoldenTests.mm (Objective-C++ engine)",
    @"canonical" : canonical,
    @"hash_json" : hashJSON,
    @"hash_bytes" : hashBytes,
    @"arguments" : arguments,
  };
}

- (void)testObjectiveCEngineMatchesTheSharedCoreGolden {
  NSDictionary *corpus = DSHGoldenLoadJSON(@"canonical-corpus");
  XCTAssertNotNil(corpus, @"canonical-corpus.json must be bundled with the tests");
  if (corpus == nil) return;
  NSDictionary *computed = [self goldenFromCorpus:corpus];

  NSString *outputPath = NSProcessInfo.processInfo.environment[@"RISH_CORE_GOLDEN_OUT"];
  if (outputPath.length > 0) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:computed
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&error];
    XCTAssertNotNil(data, @"golden must serialise: %@", error);
    NSMutableData *withNewline = [data mutableCopy];
    [withNewline appendBytes:"\n" length:1];
    XCTAssertTrue([withNewline writeToFile:outputPath options:NSDataWritingAtomic error:&error],
                  @"could not write golden to %@: %@", outputPath, error);
    NSLog(@"AGENT_CORE_GOLDEN_WRITTEN %@", outputPath);
    return;
  }

  NSDictionary *golden = DSHGoldenLoadJSON(@"canonical-golden");
  XCTAssertNotNil(golden, @"canonical-golden.json must be bundled; regenerate with RISH_CORE_GOLDEN_OUT");
  if (golden == nil) return;
  for (NSString *section in @[ @"canonical", @"hash_json", @"hash_bytes", @"arguments" ]) {
    NSDictionary *expected = golden[section];
    NSDictionary *actual = computed[section];
    XCTAssertEqualObjects([NSSet setWithArray:expected.allKeys], [NSSet setWithArray:actual.allKeys],
                          @"%@ case names differ from the golden; regenerate it", section);
    for (NSString *name in expected) {
      XCTAssertEqualObjects(actual[name], expected[name], @"%@/%@ drifted from the golden", section, name);
    }
  }
}

// The distinguishing ordering case must actually distinguish: UTF-16 unit
// order puts U+1F600 (D83D DE00) before U+FB01, code point order would not.
- (void)testKeyOrderIsUTF16NotCodePoint {
  NSData *input = [@"{\"\\ufb01\": 1, \"\\ud83d\\ude00\": 2}" dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
  NSData *canonical = DSHWorkspaceCanonicalJSONData(parsed, nil);
  NSString *text = [[NSString alloc] initWithData:canonical encoding:NSUTF8StringEncoding];
  XCTAssertEqualObjects(text, @"{\"\U0001F600\":2,\"\uFB01\":1}");
}

// Probe: where does an interior U+FEFF go? The golden shows "\ufeffbom"
// canonicalising to "bom"; this pins which stage drops it so the Rust core
// can mirror the exact behaviour instead of guessing.
- (void)testProbeInteriorByteOrderMark {
  NSString *direct = [NSString stringWithFormat:@"%Cbom", (unichar)0xFEFF];
  NSLog(@"BOM_PROBE direct.length=%lu utf8=%@", (unsigned long)direct.length,
        DSHGoldenHex([direct dataUsingEncoding:NSUTF8StringEncoding]));
  NSData *directCanonical = DSHWorkspaceCanonicalJSONData(direct, nil);
  NSLog(@"BOM_PROBE direct.canonical=%@", DSHGoldenHex(directCanonical));

  NSData *escaped = [@"\"\\ufeffbom\"" dataUsingEncoding:NSUTF8StringEncoding];
  NSString *parsed = [NSJSONSerialization JSONObjectWithData:escaped options:NSJSONReadingAllowFragments error:nil];
  NSLog(@"BOM_PROBE parsedFromEscape.length=%lu utf8=%@", (unsigned long)parsed.length,
        DSHGoldenHex([parsed dataUsingEncoding:NSUTF8StringEncoding]));
  NSData *parsedCanonical = DSHWorkspaceCanonicalJSONData(parsed, nil);
  NSLog(@"BOM_PROBE parsedFromEscape.canonical=%@", DSHGoldenHex(parsedCanonical));

  NSData *raw = [[NSString stringWithFormat:@"\"%Cbom\"", (unichar)0xFEFF] dataUsingEncoding:NSUTF8StringEncoding];
  NSString *parsedRaw = [NSJSONSerialization JSONObjectWithData:raw options:NSJSONReadingAllowFragments error:nil];
  NSLog(@"BOM_PROBE parsedFromRaw.length=%lu", (unsigned long)parsedRaw.length);

  NSData *middle = [@"\"a\\ufeffb\"" dataUsingEncoding:NSUTF8StringEncoding];
  NSString *parsedMiddle = [NSJSONSerialization JSONObjectWithData:middle options:NSJSONReadingAllowFragments error:nil];
  NSLog(@"BOM_PROBE parsedMiddle.length=%lu canonical=%@", (unsigned long)parsedMiddle.length,
        DSHGoldenHex(DSHWorkspaceCanonicalJSONData(parsedMiddle, nil)));
  XCTAssertNotNil(directCanonical);
}

@end
