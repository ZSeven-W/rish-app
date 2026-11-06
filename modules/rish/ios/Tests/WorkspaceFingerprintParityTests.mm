#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/DSHWorkspaceCanonical.h"

// The test target has no header search path into the core, so it is
// reached by relative path; the symbols come from the linked pod.
#include "../../../../modules/rish/core/include/rish_agent_core.h"

/// The root fingerprint binds a workspace authority to a physical directory.
/// Every authority already on a device carries one computed by
/// `DSHWorkspaceRootFingerprintSHA256`, so the shared core has to produce the
/// same bytes or every existing workspace becomes invalid.
///
/// Both implementations are still present, so this is a real parity test: the
/// same inputs go through each and the digests must be equal. It is not a
/// replica agreeing with itself.
@interface WorkspaceFingerprintParityTests : XCTestCase
@end

@implementation WorkspaceFingerprintParityTests

static NSString *Digest(unichar seed) {
  return [@"" stringByPaddingToLength:64
                           withString:[NSString stringWithCharacters:&seed length:1]
                      startingAtIndex:0];
}

- (NSDictionary *)core:(NSString *)op fields:(NSDictionary *)fields {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  XCTAssertNotNil(bytes);
  char *raw = rish_agent_workspace_fingerprint_reduce(
      (const char *)bytes.bytes, bytes.length);
  XCTAssertTrue(raw != NULL);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  XCTAssertTrue([reply isKindOfClass:NSDictionary.class]);
  return reply;
}

/// The same input through both must give the same digest, for every origin.
- (void)assertParityForInput:(NSDictionary *)input {
  NSError *error = nil;
  NSString *native = DSHWorkspaceRootFingerprintSHA256(input, &error);
  XCTAssertNotNil(native, @"native refused a shape it should accept: %@", input);
  XCTAssertNil(error);
  NSDictionary *reply = [self core:@"fingerprint" fields:@{ @"input" : input }];
  XCTAssertEqualObjects(reply[@"fingerprint"], native, @"%@", input);
}

- (void)testAnOwnedWorkspaceFingerprintsIdenticallyInBoth {
  [self assertParityForInput:@{
    @"schema_version" : @1,
    @"origin" : @"rish_created",
    @"workspace_id" : @"a1b2c3d4-1111-4111-8111-1111abcd1111",
    @"binding_revision" : @3,
    @"root_locator_kind" : @"documents_owned",
    @"device_id" : @"16777232",
    @"inode_id" : @"1234567",
    @"directory_name_sha256" : Digest('a'),
    @"authority_sha256" : Digest('b'),
  }];
  [self assertParityForInput:@{
    @"schema_version" : @1,
    @"origin" : @"imported",
    @"workspace_id" : @"a1b2c3d4-1111-4111-8111-1111abcd1111",
    @"binding_revision" : @1,
    @"root_locator_kind" : @"documents_owned",
    @"device_id" : @"0",
    @"inode_id" : @"18446744073709551615",
    @"directory_name_sha256" : Digest('c'),
    @"authority_sha256" : Digest('d'),
  }];
}

- (void)testAGrantedFolderFingerprintsIdenticallyInBoth {
  [self assertParityForInput:@{
    @"schema_version" : @1,
    @"origin" : @"granted_folder",
    @"workspace_id" : @"b2c3d4e5-2222-4222-8222-2222abcd2222",
    @"binding_revision" : @9007199254740991,
    @"root_locator_kind" : @"security_scoped",
    @"volume_identifier_sha256" : Digest('1'),
    @"resource_identifier_sha256" : Digest('2'),
    @"device_id" : @"1",
    @"inode_id" : @"2",
    @"bookmark_sha256" : Digest('3'),
    @"authority_sha256" : Digest('4'),
  }];
}

- (void)testALegacyProjectFingerprintsIdenticallyInBoth {
  [self assertParityForInput:@{
    @"schema_version" : @1,
    @"origin" : @"legacy_app_owned",
    @"workspace_id" : @"a1b2c3d4-1111-4111-8111-1111abcd1111",
    @"binding_revision" : @2,
    @"root_locator_kind" : @"legacy_app_owned",
    @"legacy_project_id" : @"b2c3d4e5-2222-4222-8222-2222abcd2222",
    @"project_metadata_sha256" : Digest('5'),
    @"projects_root_device_id" : @"1",
    @"projects_root_inode_id" : @"2",
    @"repository_device_id" : @"3",
    @"repository_inode_id" : @"4",
    @"git_device_id" : @"5",
    @"git_inode_id" : @"6",
  }];
}

/// Both must refuse the same malformed inputs. A core that accepted something
/// the native rule rejects would mint a fingerprint for a root the native side
/// would never recognise.
- (void)testBothRefuseTheSameMalformedInputs {
  NSDictionary *base = @{
    @"schema_version" : @1,
    @"origin" : @"rish_created",
    @"workspace_id" : @"a1b2c3d4-1111-4111-8111-1111abcd1111",
    @"binding_revision" : @3,
    @"root_locator_kind" : @"documents_owned",
    @"device_id" : @"16777232",
    @"inode_id" : @"1234567",
    @"directory_name_sha256" : Digest('a'),
    @"authority_sha256" : Digest('b'),
  };
  NSArray *mutations = @[
    @[@"device_id", @"01"],
    @[@"device_id", @"+1"],
    @[@"device_id", @16777232],
    @[@"inode_id", @""],
    @[@"binding_revision", @0],
    @[@"schema_version", @2],
    @[@"root_locator_kind", @"security_scoped"],
    @[@"workspace_id", @"A1B2C3D4-1111-4111-8111-1111ABCD1111"],
    @[@"directory_name_sha256", Digest('A')],
  ];
  for (NSArray *mutation in mutations) {
    NSMutableDictionary *input = [base mutableCopy];
    input[mutation[0]] = mutation[1];
    NSString *native = DSHWorkspaceRootFingerprintSHA256(input, nil);
    NSDictionary *reply = [self core:@"fingerprint" fields:@{ @"input" : input }];
    XCTAssertNil(native, @"native accepted %@", mutation);
    XCTAssertEqualObjects(reply[@"fingerprint"], NSNull.null, @"core accepted %@",
                          mutation);
  }
  // An eighth key on a shape that takes nine is still the wrong shape.
  NSMutableDictionary *extra = [base mutableCopy];
  extra[@"bookmark_sha256"] = Digest('3');
  XCTAssertNil(DSHWorkspaceRootFingerprintSHA256(extra, nil));
  XCTAssertEqualObjects([self core:@"fingerprint" fields:@{ @"input" : extra }]
                            [@"fingerprint"], NSNull.null);
}

@end
