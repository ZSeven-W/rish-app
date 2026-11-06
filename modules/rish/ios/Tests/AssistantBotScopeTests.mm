#import <XCTest/XCTest.h>
#import "AssistantTaskExecutor.h"

@interface DSHAssistantTaskExecutor (BotScopeTests)
- (NSDictionary *)invokeStore:(NSDictionary *)request error:(NSError **)error;
@end

// Only the store read is substituted: native authorization and context freezing
// run through the production executor. Rust store isolation has its own tests.
@interface AssistantBotScopeProbe : DSHAssistantTaskExecutor
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *requests;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *personas;
@property(nonatomic, copy) NSDictionary *overrideReply;
@end

@implementation AssistantBotScopeProbe
- (NSDictionary *)invokeStore:(NSDictionary *)request error:(NSError **)error {
  (void)error;
  [self.requests addObject:[request copy]];
  if (self.overrideReply) return self.overrideReply;
  NSDictionary *context = self.personas[request[@"conversation_id"]];
  return context ? @{@"authorized":@YES, @"assistant_context":context}
      : @{@"authorized":@NO};
}
@end

@interface AssistantBotScopeTests : XCTestCase
@end

@implementation AssistantBotScopeTests
- (AssistantBotScopeProbe *)probe {
  AssistantBotScopeProbe *probe = [[AssistantBotScopeProbe alloc]
      initWithRootResolver:(id)NSNull.null];
  probe.requests = [NSMutableArray array];
  probe.personas = [NSMutableDictionary dictionary];
  return probe;
}
- (NSDictionary *)persona:(NSString *)name conversation:(NSString *)identifier {
  return @{@"schema_version":@1, @"conversation_id":identifier, @"profile_revision":@8,
      @"name":name, @"notes":@"User-authored notes", @"soul":@"User-authored personality"};
}
- (void)testPrivateAndGroupLanesReauthorizeTheExactBotWithoutCaching {
  AssistantBotScopeProbe *probe = [self probe];
  NSArray *lanes = @[@"11111111-1111-4111-8111-111111111111",
      @"22222222-2222-4222-8222-222222222222", @"33333333-3333-4333-8333-333333333333",
      @"44444444-4444-4444-8444-444444444444"];
  for (NSUInteger i = 0; i < lanes.count; i++)
    probe.personas[lanes[i]] = [self persona:i % 2 == 0 ? @"Research Bot" : @"Planning Bot"
        conversation:lanes[i]];
  // Private A, private B, group A, group B, then A again. Names and IDs must
  // follow the committed lane on every call, not the preceding authorization.
  for (NSString *identifier in [lanes arrayByAddingObject:lanes[0]]) {
    NSDictionary *context = [probe assistantContextForConversation:@{@"id":identifier,
        @"title":@"Same visible chat name"} registryVersion:@5 error:nil];
    XCTAssertEqualObjects(context, probe.personas[identifier]);
    XCTAssertEqualObjects(context[@"conversation_id"], identifier);
    XCTAssertEqualObjects(probe.requests.lastObject,
        (@{@"action":@"authorize", @"conversation_id":identifier}));
  }
  XCTAssertEqual(probe.requests.count, 5U);
}
- (void)testForeignOrMissingPersonaCannotBeFrozen {
  AssistantBotScopeProbe *probe = [self probe];
  NSString *lane = @"11111111-1111-4111-8111-111111111111";
  for (NSDictionary *reply in @[@{@"authorized":@NO}, @{@"authorized":@YES},
      @{@"authorized":@YES, @"assistant_context":[self persona:@"Other Bot"
          conversation:@"22222222-2222-4222-8222-222222222222"]}]) {
    probe.overrideReply = reply;
    NSError *error = nil;
    XCTAssertNil([probe assistantContextForConversation:@{@"id":lane} registryVersion:@5 error:&error]);
    XCTAssertNotNil(error);
  }
}
- (void)testOrdinaryConversationCannotBorrowAnAuthorizedBotName {
  AssistantBotScopeProbe *probe = [self probe];
  NSString *lane = @"11111111-1111-4111-8111-111111111111";
  probe.personas[lane] = [self persona:@"Research Bot" conversation:lane];
  XCTAssertNotNil([probe assistantContextForConversation:@{@"id":lane} registryVersion:@5 error:nil]);
  NSDictionary *ordinary = @{@"id":@"22222222-2222-4222-8222-222222222222",
      @"title":@"Research Bot", @"bot_id":lane};
  XCTAssertNil([probe assistantContextForConversation:ordinary registryVersion:@5 error:nil]);
  XCTAssertEqual(probe.requests.count, 2U);
}
- (void)testRegistryFourNeverConsultsPrivateBotStore {
  AssistantBotScopeProbe *probe = [self probe];
  probe.overrideReply = @{@"authorized":@YES};
  XCTAssertFalse([probe authorizeConversation:@{@"id":@"11111111-1111-4111-8111-111111111111"}
      registryVersion:@4 error:nil]);
  XCTAssertEqual(probe.requests.count, 0U);
}
@end
