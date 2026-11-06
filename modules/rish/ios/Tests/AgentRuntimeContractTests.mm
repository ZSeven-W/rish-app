#import <XCTest/XCTest.h>
#import "AgentToolRegistry.h"
#import "AgentNativeWAL.h"
#import "AgentRuntimeToolContracts.h"
#import "RishGuestCgiFeature.h"

static NSDictionary *RuntimeContractRoot(BOOL guest) {
  NSMutableArray *capabilities = [@[@"file_read", @"file_write", @"git_status", @"git_commit", @"git_push"] mutableCopy];
  if (guest) [capabilities addObject:@"guest_service"];
  return @{@"schema_version":@1, @"kind":@"project",
      @"workspace_id":@"11111111-1111-4111-8111-111111111111", @"workspace_binding_revision":@1,
      @"project_id":@"22222222-2222-4222-8222-222222222222",
      @"root_fingerprint_sha256":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],
      @"capabilities":[capabilities copy]};
}

@interface AgentRuntimeContractTests : XCTestCase
@end
@implementation AgentRuntimeContractTests
- (void)testNativeRegistryVersionThreeExposesActualRuntimeToolsAndNullableWriteRevision {
  DSHAgentToolRegistry *registry = [DSHAgentToolRegistry new];
  NSDictionary *root = RuntimeContractRoot(DSH_GUEST_CGI_AVAILABLE);
  NSError *error = nil;
  // This is deliberately a frozen v3 compatibility contract, not the current
  // default registry. Its descriptors must be selected by the same identity.
  NSDictionary *projection = [registry registryForRoot:root version:@3 error:&error];
  XCTAssertNil(error); XCTAssertEqualObjects(projection[@"registry_version"], @3);
  XCTAssertEqual([projection[@"tools"] count], DSH_GUEST_CGI_AVAILABLE ? 13U : 7U);
  XCTAssertTrue([DSHAgentToolRegistry validateRegistryProjection:projection root:root error:nil]);
  NSDictionary *write = [registry nativeDescriptorForToolName:@"write_file" registry:projection error:nil];
  XCTAssertEqualObjects(write[@"parameters"][@"properties"][@"expected_revision"][@"type"], (@[@"string", @"null"]));
  NSDictionary *run = [registry nativeDescriptorForToolName:@"run_program" registry:projection error:nil];
  XCTAssertEqualObjects(run[@"parameters"][@"properties"][@"args"][@"type"], @"array");
  NSMutableDictionary *forged = [projection mutableCopy]; forged[@"registry_version"] = @2;
  XCTAssertFalse([DSHAgentToolRegistry validateRegistryProjection:DSHAgentImmutableJSONCopy(forged, nil) root:root error:nil]);
}
- (void)testCurrentRegistryVersionFourAddsDurableQuestionsWithoutChangingVersionThree {
  DSHAgentToolRegistry *registry = [DSHAgentToolRegistry new];
  NSDictionary *root = RuntimeContractRoot(DSH_GUEST_CGI_AVAILABLE);
  NSDictionary *current = [registry registryForRoot:root error:nil];
  NSDictionary *previous = [registry registryForRoot:root version:@3 error:nil];
  XCTAssertEqualObjects(current[@"registry_version"],@4);
  XCTAssertEqual([current[@"tools"] count],DSH_GUEST_CGI_AVAILABLE ? 14U : 8U);
  XCTAssertTrue([DSHAgentToolRegistry validateRegistryProjection:current root:root error:nil]);
  XCTAssertTrue([[current[@"tools"] valueForKey:@"name"] containsObject:@"ask_user"]);
  XCTAssertFalse([[previous[@"tools"] valueForKey:@"name"] containsObject:@"ask_user"]);
  XCTAssertNotEqualObjects(current[@"toolset_sha256"],previous[@"toolset_sha256"]);
  NSDictionary *question = [registry nativeDescriptorForToolName:@"ask_user" registry:current error:nil];
  XCTAssertEqualObjects(question[@"parameters"][@"required"],(@[@"question",@"input_mode",@"options"]));
  XCTAssertNil([registry nativeDescriptorForToolName:@"ask_user" registry:previous error:nil]);
}
- (void)testPreviousRegistryDigestsStillValidateWithoutAdmittingRuntimeTools {
  DSHAgentToolRegistry *registry = [DSHAgentToolRegistry new];
  for (NSNumber *version in @[@1, @2]) {
    BOOL guest = [version isEqual:@2] && DSH_GUEST_CGI_AVAILABLE;
    NSDictionary *root = RuntimeContractRoot(guest);
    NSDictionary *current = [registry registryForRoot:root error:nil];
    NSMutableArray *descriptors = [NSMutableArray array];
    NSMutableArray *order = [NSMutableArray array];
    if (guest) [order addObjectsFromArray:@[@"start_guest_cgi", @"stop_guest_cgi"]];
    [order addObjectsFromArray:@[@"git_commit", @"git_push", @"git_status", @"list_dir", @"read_file", @"write_file"]];
    for (NSString *name in order) {
      NSDictionary *descriptor = [registry nativeDescriptorForToolName:name error:nil];
      NSData *data = [NSJSONSerialization dataWithJSONObject:descriptor options:0 error:nil];
      NSMutableDictionary *legacy = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
      if ([name isEqual:@"write_file"]) legacy[@"parameters"][@"properties"][@"expected_revision"][@"type"] = @"string";
      [descriptors addObject:legacy];
    }
    NSString *digest = DSHAgentHJ(@"agent-toolset", @{@"registry_version":version, @"tools":descriptors}, nil);
    NSMutableArray *tools = [NSMutableArray array];
    for (NSDictionary *tool in current[@"tools"])
      if (!DSHAgentIsRuntimeTool(tool[@"name"]) && ![tool[@"name"] isEqual:@"ask_user"])
        [tools addObject:tool];
    NSDictionary *legacy = DSHAgentImmutableJSONCopy(@{@"schema_version":@2, @"registry_version":version,
        @"toolset_sha256":digest, @"tools":tools}, nil);
    XCTAssertTrue([DSHAgentToolRegistry validateRegistryProjection:legacy root:root error:nil], @"%@", version);
  }
}
- (void)testNativeRuntimeValidationUsesCoreForArgumentsAndDiagnosticFeedback {
  NSDictionary *arguments = @{@"environment_id":@"node-test", @"entry_path":@"src/server.js", @"args":@[], @"port":@3000};
  NSString *code = nil, *reason = nil;
  XCTAssertTrue(DSHAgentToolArgumentsAccepted(@"start_runtime_service", arguments, &code, &reason));
  NSMutableDictionary *bad = [arguments mutableCopy]; bad[@"port"] = @YES;
  XCTAssertFalse(DSHAgentToolArgumentsAccepted(@"start_runtime_service", bad, &code, &reason));
  XCTAssertEqualObjects(code, @"E_AGENT_BAD_ARGUMENTS");
  NSDictionary *feedback = @{@"schema_version":@1, @"name":@"run_program", @"outcome":@"failed",
      @"payload":@{@"schema_version":@1, @"failure_code":@"E_AGENT_TOOL_FAILED", @"reason":@"program_exited_nonzero",
        @"stdout":@"before failure", @"stderr":@"SyntaxError: fixture", @"truncated":@NO, @"exit_code":@1}};
  NSString *json = [[NSString alloc] initWithData:DSHAgentCanonicalJSON(feedback, nil) encoding:NSUTF8StringEncoding];
  XCTAssertTrue(DSHAgentValidateNativeToolFeedbackString(json, nil));
  NSMutableDictionary *legacyFailure = [feedback mutableCopy]; legacyFailure[@"name"] = @"write_file";
  json = [[NSString alloc] initWithData:DSHAgentCanonicalJSON(legacyFailure, nil) encoding:NSUTF8StringEncoding];
  XCTAssertFalse(DSHAgentValidateNativeToolFeedbackString(json, nil));
}
@end
