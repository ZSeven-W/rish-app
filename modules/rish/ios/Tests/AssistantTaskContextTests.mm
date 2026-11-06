#import <XCTest/XCTest.h>
#import "AssistantTaskExecutor.h"
#import "AgentRootResolver.h"

@interface DSHAssistantTaskExecutor (ContextTests)
- (NSDictionary *)contextForConversation:(NSDictionary *)conversation request:(NSDictionary *)request error:(NSError **)error;
@end

@interface AssistantTaskContextWorkspace : DSHLocalWorkspaceAccess
@property(nonatomic, copy) NSDictionary *descriptor;
@end
@implementation AssistantTaskContextWorkspace
- (NSDictionary *)resolveWorkspaceId:(NSString *)workspaceId expectedBindingRevision:(NSNumber *)revision
                 requiredCapabilities:(NSArray *)capabilities error:(NSError **)error {
  (void)capabilities;
  if (![workspaceId isEqual:self.descriptor[@"workspace_id"]] ||
      ![revision isEqual:self.descriptor[@"binding_revision"]]) return nil;
  if (error != nullptr) *error = nil;
  return @{@"workspace":self.descriptor};
}
@end

@interface AssistantTaskContextRoot : DSHAgentRootResolver
@property(nonatomic, copy) NSDictionary *frozen;
@end
@implementation AssistantTaskContextRoot
- (BOOL)validateFrozenRoot:(NSDictionary *)root error:(NSError **)error {
  (void)error;
  return [root isEqual:self.frozen];
}
@end

@interface AssistantTaskContextTests : XCTestCase
@end
@implementation AssistantTaskContextTests
- (void)testTaskContextUsesCommittedModelAndExactNativeWorkspaceDescriptor {
  NSString *workspaceID = @"11111111-1111-4111-8111-111111111111";
  NSString *conversationID = @"22222222-2222-4222-8222-222222222222";
  NSURL *unused = [NSURL fileURLWithPath:@"/unused-test-root" isDirectory:YES];
  AssistantTaskContextWorkspace *workspace = [[AssistantTaskContextWorkspace alloc]
      initWithPrivateRootURL:unused clock:^NSDate *{ return NSDate.date; }
      UUIDGenerator:^NSString *{ return NSUUID.UUID.UUIDString; }
      legacyResolver:^BOOL(NSString *projectID, NSDictionary **evidence, NSError **error) {
        (void)projectID; (void)evidence; (void)error; return NO;
      } faultHook:nil];
  workspace.descriptor = @{@"workspace_id":workspaceID, @"binding_revision":@7,
      @"display_name":@"Native workspace"};
  AssistantTaskContextRoot *resolver = [[AssistantTaskContextRoot alloc]
      initWithWorkspaceAccess:workspace projectAccess:nil];
  resolver.frozen = @{@"workspace_id":workspaceID, @"workspace_binding_revision":@7,
      @"project_id":NSNull.null, @"capabilities":@[@"file_read"]};
  DSHAssistantTaskExecutor *executor = [[DSHAssistantTaskExecutor alloc] initWithRootResolver:resolver];
  NSDictionary *binding = @{@"workspace_id":workspaceID, @"binding_revision":@7,
      @"project_id":NSNull.null};
  NSDictionary *conversation = @{@"id":conversationID, @"model_id":@"deepseek-v4-flash",
      @"workspace_binding":binding, @"workspace_descriptor":@{@"path":@"/untrusted"}};
  NSMutableDictionary *request = [@{@"conversation_id":conversationID, @"root":resolver.frozen,
      @"model_id":@"untrusted-model", @"workspace_descriptor":@{@"path":@"/untrusted"}} mutableCopy];
  NSDictionary *context = [executor contextForConversation:conversation request:request error:nil];
  XCTAssertEqualObjects(context[@"model_id"], @"deepseek-v4-flash");
  XCTAssertEqualObjects(context[@"workspace_binding"], binding);
  XCTAssertEqualObjects(context[@"workspace_descriptor"], workspace.descriptor);
  XCTAssertNil(context[@"workspace_descriptor"][@"path"]);
  NSMutableDictionary *stale = [resolver.frozen mutableCopy]; stale[@"workspace_binding_revision"] = @8;
  request[@"root"] = stale;
  XCTAssertNil([executor contextForConversation:conversation request:request error:nil]);
}

- (void)testRegistryFourCannotReachAssistantAuthorizationBridge {
  DSHAssistantTaskExecutor *executor = [[DSHAssistantTaskExecutor alloc]
      initWithRootResolver:(DSHAgentRootResolver *)(id)NSNull.null];
  NSError *error = nil;
  XCTAssertFalse([executor authorizeConversation:@{@"id":@"22222222-2222-4222-8222-222222222222"}
      registryVersion:@4 error:&error]);
  XCTAssertNotNil(error);
  XCTAssertFalse(DSHAgentIsAssistantTaskTool(@"write_file"));
  XCTAssertTrue(DSHAgentIsAssistantTaskTool(@"create_assistant_task"));
}
@end
