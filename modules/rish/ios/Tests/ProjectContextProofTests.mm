#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/RuntimeProofV3.h"

@interface DSHHostileProofDictionary : NSDictionary
@end

@implementation DSHHostileProofDictionary
- (NSUInteger)count { return 0; }
- (NSEnumerator *)keyEnumerator { return @[].objectEnumerator; }
- (id)objectForKey:(id)key { return nil; }
@end

@interface DSHHostileProofData : NSData
@end

@implementation DSHHostileProofData
- (NSUInteger)length { return 3; }
- (const void *)bytes { return "bad"; }
@end

@interface ProjectContextProofTests : XCTestCase
@end

@implementation ProjectContextProofTests

static NSString *const DSHSafeSourceSentinel =
    @"SAFE_SOURCE_SENTINEL: let answer = 42\n";
static NSString *const DSHSecretSentinel =
    @"SECRET_SENTINEL=sk-do-not-leak\n";
static NSString *const DSHPromptSentinel =
    @"PROMPT_SENTINEL: summarize the selected project";
static NSString *const DSHAttachmentSentinel =
    @"ATTACHMENT_SENTINEL: private attachment bytes";
static NSString *const DSHAssistantSentinel =
    @"ASSISTANT_SENTINEL: the answer is 42";
static NSString *const DSHReasoningSentinel =
    @"REASONING_SENTINEL: private chain";
static NSString *const DSHToolArgumentsSentinel =
    @"TOOL_ARGUMENTS_SENTINEL: {path: Sources/App.swift}";
static NSString *const DSHToolResultSentinel =
    @"TOOL_RESULT_SENTINEL: wrote 42 bytes";
static NSString *const DSHAbsolutePathSentinel =
    @"/private/var/mobile/Containers/Data/Application/SECRET/project";

- (NSData *)dataForString:(NSString *)value {
  return [[value dataUsingEncoding:NSUTF8StringEncoding] copy];
}

- (NSString *)digestForString:(NSString *)value {
  return DSHRuntimeProofV3SHA256Hex([self dataForString:value]);
}

- (NSDictionary *)validFields {
  NSString *snapshotEnvelope = [NSString stringWithFormat:
      @"RISH-PROJECT-CONTEXT/1\n%@", DSHSafeSourceSentinel];
  NSString *visibleHistory = [NSString stringWithFormat:
      @"user:%@", DSHPromptSentinel];
  NSString *roundZeroInput = [NSString stringWithFormat:
      @"round-0|%@|%@", visibleHistory, snapshotEnvelope];
  NSString *roundZeroBody = [NSString stringWithFormat:
      @"body-0|%@", roundZeroInput];
  NSString *finalInput = [NSString stringWithFormat:
      @"round-1|%@|%@|%@", visibleHistory, snapshotEnvelope,
      DSHAttachmentSentinel];
  NSString *finalBody = [NSString stringWithFormat:@"body-1|%@", finalInput];
  return @{
    @"attested_at" : @"2026-08-28T04:00:00.000Z",
    @"turn_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id_sha256" : [self digestForString:@"conversation-join"],
    @"project_id" : @"33333333-3333-4333-8333-333333333333",
    @"snapshot_id" : @"44444444-4444-4444-8444-444444444444",
    @"consent_receipt_id" : @"55555555-5555-4555-8555-555555555555",
    @"policy_version" : @"chat-read-v1.0.0",
    @"provider_host" : @"api.deepseek.com",
    @"model" : @"deepseek-v4-flash",
    @"thinking_mode" : @"high",
    @"branch" : @"feature/proof-v3",
    @"head_oid" : @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"included" : @[
      @{
        @"relative_path" : @"README.md",
        @"sha256" : [self digestForString:@"# fixture\n"],
        @"bytes" : @10,
        @"source" : @"tracked_file",
      },
      @{
        @"relative_path" : @"Sources/App.swift",
        @"sha256" : [self digestForString:DSHSafeSourceSentinel],
        @"bytes" : @38,
        @"source" : @"tracked_file",
      },
    ],
    @"omitted" : @[
      @{
        @"relative_path" : @".env",
        @"source" : @"tracked_file",
        @"reason" : @"secret_path",
      },
    ],
    @"snapshot_sha256" : [self digestForString:snapshotEnvelope],
    @"visible_history_sha256" : [self digestForString:visibleHistory],
    @"model_input_sha256" : [self digestForString:finalInput],
    @"request_body_sha256" : [self digestForString:finalBody],
    @"attachments" : @[
      @{
        @"opaque_id_sha256" : [self digestForString:@"attachment-id-1"],
        @"sha256" : [self digestForString:DSHAttachmentSentinel],
        @"bytes" : @47,
        @"media_type" : @"text/plain",
      },
    ],
    @"assistant_text_sha256" : [self digestForString:DSHAssistantSentinel],
    @"reasoning_text_sha256" : [self digestForString:DSHReasoningSentinel],
    @"finish_reason" : @"stop",
    @"provider_response_id" : @"resp_round_0002",
    @"provider_rounds" : @[
      @{
        @"round_id" : @"66666666-6666-4666-8666-666666666666",
        @"provider_request_id" : @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        @"provider_response_id" : @"resp_round_0001",
        @"round_index" : @0,
        @"model_input_sha256" : [self digestForString:roundZeroInput],
        @"request_body_sha256" : [self digestForString:roundZeroBody],
        @"finish_reason" : @"tool_calls",
        @"outcome" : @"succeeded",
      },
      @{
        @"round_id" : @"77777777-7777-4777-8777-777777777777",
        @"provider_request_id" : @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        @"provider_response_id" : @"resp_round_0002",
        @"round_index" : @1,
        @"model_input_sha256" : [self digestForString:finalInput],
        @"request_body_sha256" : [self digestForString:finalBody],
        @"finish_reason" : @"stop",
        @"outcome" : @"succeeded",
      },
    ],
    @"agent_tool_evidence" : @[
      @{
        @"call_id" : @"call_fixture_01",
        @"round_index" : @0,
        @"call_index" : @0,
        @"name" : @"write_file",
        @"arguments_sha256" : [self digestForString:DSHToolArgumentsSentinel],
        @"result_sha256" : [self digestForString:DSHToolResultSentinel],
        @"result_bytes" : @42,
        @"duration_ms" : @17,
        @"outcome" : @"ok",
        @"failure_code" : NSNull.null,
        @"approval_reference" : @"88888888-8888-4888-8888-888888888888",
      },
    ],
    @"outcome" : @"completed",
  };
}

- (NSDictionary *)fieldsByReplacing:(NSString *)key value:(id)value {
  NSMutableDictionary *fields = [[self validFields] mutableCopy];
  fields[key] = value;
  return [fields copy];
}

- (NSDictionary *)proofByReplacing:(NSDictionary *)proof
                                key:(NSString *)key
                              value:(id)value {
  NSMutableDictionary *mutated = [proof mutableCopy];
  NSMutableDictionary *attestation = [proof[@"attestation"] mutableCopy];
  attestation[key] = value;
  mutated[@"attestation"] = [attestation copy];
  return [mutated copy];
}

- (void)assertError:(NSError *)error code:(NSString *)code {
  XCTAssertNotNil(error);
  XCTAssertEqualObjects(error.domain, DSHRuntimeProofV3ErrorDomain);
  XCTAssertEqualObjects(error.localizedDescription, code);
  for (NSString *sentinel in @[
         DSHSafeSourceSentinel, DSHSecretSentinel, DSHPromptSentinel,
         DSHAttachmentSentinel, DSHAssistantSentinel, DSHReasoningSentinel,
         DSHToolArgumentsSentinel, DSHToolResultSentinel,
         DSHAbsolutePathSentinel,
       ]) {
    XCTAssertFalse([error.localizedDescription containsString:sentinel]);
  }
}

- (void)testBuildsExactImmutableVersionThreeAttestationWithoutSentinelLeakage {
  NSError *error = nil;
  NSDictionary *proof = DSHBuildRuntimeProofV3([self validFields], &error);
  XCTAssertNil(error);
  XCTAssertNotNil(proof);
  NSSet *expectedRootKeys = [NSSet setWithArray:@[
    @"schema_version", @"attestation", @"attestation_sha256", @"diagnostics",
  ]];
  XCTAssertEqualObjects([NSSet setWithArray:proof.allKeys], expectedRootKeys);
  XCTAssertEqualObjects(proof[@"schema_version"], @3);
  NSDictionary *expectedDiagnostics = @{
    @"schema_version" : @1,
    @"updated_at" : @"2026-08-28T04:00:00.000Z",
  };
  XCTAssertEqualObjects(proof[@"diagnostics"], expectedDiagnostics);
  NSDictionary *attestation = proof[@"attestation"];
  NSSet *expectedAttestationKeys = [NSSet setWithArray:@[
    @"attested_at", @"turn_id", @"attempt_id",
    @"conversation_id_sha256", @"project_id", @"snapshot_id",
    @"consent_receipt_id", @"policy_version", @"provider_host",
    @"model", @"thinking_mode", @"branch", @"head_oid", @"included",
    @"omitted", @"snapshot_sha256", @"visible_history_sha256",
    @"model_input_sha256", @"request_body_sha256", @"attachments",
    @"assistant_text_sha256", @"reasoning_text_sha256", @"finish_reason",
    @"provider_response_id", @"provider_rounds", @"agent_tool_evidence",
    @"outcome",
  ]];
  XCTAssertEqualObjects([NSSet setWithArray:attestation.allKeys],
                        expectedAttestationKeys);
  XCTAssertEqualObjects(attestation[@"snapshot_sha256"],
                        [self validFields][@"snapshot_sha256"]);
  XCTAssertEqualObjects(attestation[@"visible_history_sha256"],
                        [self validFields][@"visible_history_sha256"]);
  XCTAssertEqualObjects(attestation[@"model_input_sha256"],
                        [self validFields][@"model_input_sha256"]);
  XCTAssertEqualObjects(attestation[@"request_body_sha256"],
                        [self validFields][@"request_body_sha256"]);
  XCTAssertEqualObjects(attestation[@"attachments"][0][@"sha256"],
                        [self digestForString:DSHAttachmentSentinel]);
  XCTAssertEqualObjects(attestation[@"assistant_text_sha256"],
                        [self digestForString:DSHAssistantSentinel]);
  XCTAssertEqualObjects(attestation[@"reasoning_text_sha256"],
                        [self digestForString:DSHReasoningSentinel]);
  NSArray *providerRounds = attestation[@"provider_rounds"];
  XCTAssertEqualObjects(providerRounds.lastObject[@"model_input_sha256"],
                        attestation[@"model_input_sha256"]);
  XCTAssertEqualObjects(providerRounds.lastObject[@"request_body_sha256"],
                        attestation[@"request_body_sha256"]);
  XCTAssertEqualObjects(providerRounds.lastObject[@"provider_response_id"],
                        attestation[@"provider_response_id"]);
  XCTAssertEqualObjects(providerRounds.lastObject[@"finish_reason"],
                        attestation[@"finish_reason"]);
  XCTAssertEqualObjects(attestation[@"agent_tool_evidence"][0][@"arguments_sha256"],
                        [self digestForString:DSHToolArgumentsSentinel]);
  XCTAssertEqualObjects(attestation[@"agent_tool_evidence"][0][@"result_sha256"],
                        [self digestForString:DSHToolResultSentinel]);
  XCTAssertEqual([proof[@"attestation_sha256"] length], 64u);

  NSData *json = DSHCanonicalRuntimeProofV3Data(proof, &error);
  XCTAssertNotNil(json);
  NSString *encoded = [[NSString alloc] initWithData:json
                                            encoding:NSUTF8StringEncoding];
  for (NSString *sentinel in @[
         DSHSafeSourceSentinel, DSHSecretSentinel, DSHPromptSentinel,
         DSHAttachmentSentinel, DSHAssistantSentinel, DSHReasoningSentinel,
         DSHToolArgumentsSentinel, DSHToolResultSentinel,
         DSHAbsolutePathSentinel,
       ]) {
    XCTAssertFalse([encoded containsString:sentinel], @"leaked %@", sentinel);
  }
  XCTAssertFalse([encoded containsString:@"model_transition_trace"]);
  XCTAssertFalse([proof isKindOfClass:NSMutableDictionary.class]);
  XCTAssertFalse([attestation isKindOfClass:NSMutableDictionary.class]);
  XCTAssertFalse([attestation[@"included"] isKindOfClass:NSMutableArray.class]);
  XCTAssertNotEqual(attestation[@"included"], [self validFields][@"included"]);
  XCTAssertThrows([(NSMutableDictionary *)proof setObject:@1 forKey:@"x"]);
  XCTAssertThrows([(NSMutableArray *)attestation[@"included"] addObject:@{}]);
}

- (void)testCanonicalBytesAndAttestationDigestAreDeterministic {
  NSError *error = nil;
  NSDictionary *first = DSHBuildRuntimeProofV3([self validFields], &error);
  NSDictionary *second = DSHBuildRuntimeProofV3([self validFields], &error);
  XCTAssertEqualObjects(first, second);
  XCTAssertEqualObjects(DSHCanonicalRuntimeProofV3Data(first, &error),
                        DSHCanonicalRuntimeProofV3Data(second, &error));
  XCTAssertEqualObjects(DSHRuntimeProofV3AttestationSHA256(first, &error),
                        first[@"attestation_sha256"]);
  XCTAssertEqualObjects(DSHValidateRuntimeProofV3(first, &error), first);
}

- (void)testAllowsExplicitUnbornAndDetachedGitStates {
  NSMutableDictionary *unborn = [[self validFields] mutableCopy];
  unborn[@"branch"] = NSNull.null;
  unborn[@"head_oid"] = NSNull.null;
  NSError *error = nil;
  XCTAssertNotNil(DSHBuildRuntimeProofV3([unborn copy], &error));
  XCTAssertNil(error);

  NSMutableDictionary *detached = [[self validFields] mutableCopy];
  detached[@"branch"] = NSNull.null;
  error = nil;
  XCTAssertNotNil(DSHBuildRuntimeProofV3([detached copy], &error));
  XCTAssertNil(error);
}

- (void)testRejectsAbsoluteTraversalAndInvalidGitBranchForms {
  NSArray<NSString *> *invalidBranches = @[
    DSHAbsolutePathSentinel, @"../main", @"feature/../secret", @"feature//x",
    @".hidden/main", @"feature/.lock", @"feature/main.lock", @"feature@{1}",
    @"feature\\main", @"feature main", @"@",
  ];
  for (NSString *branch in invalidBranches) {
    NSError *error = nil;
    XCTAssertNil(DSHBuildRuntimeProofV3(
        [self fieldsByReplacing:@"branch" value:branch], &error), @"%@", branch);
    [self assertError:error code:DSHRuntimeProofV3ErrorText];
  }
}

- (void)testOverallFailureOrCancellationMayFollowSucceededProviderRound {
  for (NSString *outcome in @[ @"failed", @"cancelled" ]) {
    NSMutableDictionary *fields = [[self validFields] mutableCopy];
    fields[@"outcome"] = outcome;
    fields[@"finish_reason"] = @"tool_calls";
    NSArray *sourceRounds = fields[@"provider_rounds"];
    NSMutableDictionary *lastRound = [sourceRounds.lastObject mutableCopy];
    lastRound[@"round_index"] = @0;
    lastRound[@"finish_reason"] = @"tool_calls";
    fields[@"provider_rounds"] = @[ [lastRound copy] ];
    NSMutableDictionary *tool = [fields[@"agent_tool_evidence"][0] mutableCopy];
    tool[@"outcome"] = outcome;
    tool[@"failure_code"] = [outcome isEqualToString:@"failed"]
        ? @"E_TOOL_FAILED" : @"E_TOOL_CANCELLED";
    fields[@"agent_tool_evidence"] = @[ [tool copy] ];
    NSError *error = nil;
    XCTAssertNotNil(DSHBuildRuntimeProofV3([fields copy], &error), @"%@", outcome);
    XCTAssertNil(error);
  }
}

- (void)testDiagnosticsUpdateCannotRefreshImmutableAttestation {
  NSError *error = nil;
  NSDictionary *proof = DSHBuildRuntimeProofV3([self validFields], &error);
  NSData *before = DSHCanonicalRuntimeProofV3Data(proof, &error);
  NSDictionary *updated = DSHRuntimeProofV3ByUpdatingDiagnosticsTimestamp(
      proof, @"2026-08-28T05:00:00.000Z", &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(updated[@"attestation"][@"attested_at"],
                        proof[@"attestation"][@"attested_at"]);
  XCTAssertEqualObjects(updated[@"attestation_sha256"],
                        proof[@"attestation_sha256"]);
  XCTAssertEqualObjects(DSHRuntimeProofV3AttestationSHA256(updated, &error),
                        proof[@"attestation_sha256"]);
  XCTAssertNotEqualObjects(DSHCanonicalRuntimeProofV3Data(updated, &error), before);

  NSMutableDictionary *withLegacyTrace = [updated mutableCopy];
  withLegacyTrace[@"model_transition_trace"] = @{
    @"recorded_at" : @"2026-08-28T05:00:00.000Z",
    @"entries" : @[],
  };
  error = nil;
  XCTAssertNil(DSHValidateRuntimeProofV3([withLegacyTrace copy], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorExactKeys];

  NSMutableDictionary *attestationWithTrace =
      [updated[@"attestation"] mutableCopy];
  attestationWithTrace[@"model_transition_trace"] = @[];
  NSMutableDictionary *nestedLegacyTrace = [updated mutableCopy];
  nestedLegacyTrace[@"attestation"] = [attestationWithTrace copy];
  error = nil;
  XCTAssertNil(DSHValidateRuntimeProofV3([nestedLegacyTrace copy], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorExactKeys];
}

- (void)testTamperingImmutableEvidenceFailsWithStableValueFreeCode {
  NSError *error = nil;
  NSDictionary *proof = DSHBuildRuntimeProofV3([self validFields], &error);
  NSDictionary *replacementByKey = @{
    @"snapshot_sha256" : [self digestForString:@"tampered snapshot"],
    @"consent_receipt_id" : @"99999999-9999-4999-8999-999999999999",
    @"request_body_sha256" : [self digestForString:@"tampered body"],
  };
  for (NSString *key in replacementByKey) {
    error = nil;
    XCTAssertNil(DSHValidateRuntimeProofV3(
        [self proofByReplacing:proof key:key value:replacementByKey[key]], &error));
    [self assertError:error code:DSHRuntimeProofV3ErrorAttestationDigest];
  }

  NSMutableArray *attachments =
      [proof[@"attestation"][@"attachments"] mutableCopy];
  NSMutableDictionary *attachment = [attachments[0] mutableCopy];
  attachment[@"sha256"] = [self digestForString:@"tampered attachment"];
  attachments[0] = [attachment copy];
  error = nil;
  XCTAssertNil(DSHValidateRuntimeProofV3(
      [self proofByReplacing:proof key:@"attachments" value:[attachments copy]],
      &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorAttestationDigest];

  NSMutableArray *tools =
      [proof[@"attestation"][@"agent_tool_evidence"] mutableCopy];
  NSMutableDictionary *tool = [tools[0] mutableCopy];
  tool[@"result_sha256"] = [self digestForString:@"tampered tool result"];
  tools[0] = [tool copy];
  error = nil;
  XCTAssertNil(DSHValidateRuntimeProofV3(
      [self proofByReplacing:proof key:@"agent_tool_evidence"
                       value:[tools copy]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorAttestationDigest];
}

- (void)testRejectsUnknownMissingAndWrongSchemaKeys {
  NSMutableDictionary *extra = [[self validFields] mutableCopy];
  extra[@"raw_prompt"] = DSHPromptSentinel;
  NSError *error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3([extra copy], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorExactKeys];

  NSMutableDictionary *missing = [[self validFields] mutableCopy];
  [missing removeObjectForKey:@"snapshot_sha256"];
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3([missing copy], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorExactKeys];

  NSDictionary *proof = DSHBuildRuntimeProofV3([self validFields], nil);
  NSMutableDictionary *wrongSchema = [proof mutableCopy];
  wrongSchema[@"schema_version"] = @2;
  error = nil;
  XCTAssertNil(DSHValidateRuntimeProofV3([wrongSchema copy], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorSchema];
}

- (void)testRejectsMalformedIdentifiersEnumsDigestsHostsAndTimestamps {
  NSArray<NSDictionary *> *cases = @[
    @{ @"key" : @"turn_id", @"value" : @"not-a-uuid",
       @"code" : DSHRuntimeProofV3ErrorIdentifier },
    @{ @"key" : @"attempt_id", @"value" : @"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
       @"code" : DSHRuntimeProofV3ErrorIdentifier },
    @{ @"key" : @"conversation_id_sha256", @"value" : @"sha1:0123abcd",
       @"code" : DSHRuntimeProofV3ErrorDigest },
    @{ @"key" : @"thinking_mode", @"value" : @"ultra",
       @"code" : DSHRuntimeProofV3ErrorEnum },
    @{ @"key" : @"outcome", @"value" : @"maybe",
       @"code" : DSHRuntimeProofV3ErrorEnum },
    @{ @"key" : @"provider_host", @"value" : @"https://api.deepseek.com/path",
       @"code" : DSHRuntimeProofV3ErrorText },
    @{ @"key" : @"attested_at", @"value" : @"today",
       @"code" : DSHRuntimeProofV3ErrorTimestamp },
    @{ @"key" : @"head_oid", @"value" : @"sha1:0123abcd",
       @"code" : DSHRuntimeProofV3ErrorDigest },
  ];
  for (NSDictionary *testCase in cases) {
    NSError *error = nil;
    XCTAssertNil(DSHBuildRuntimeProofV3(
        [self fieldsByReplacing:testCase[@"key"] value:testCase[@"value"]],
        &error), @"%@", testCase);
    [self assertError:error code:testCase[@"code"]];
  }
}

- (void)testRejectsAbsoluteTraversalDuplicateAndUnsortedPaths {
  NSArray *validIncluded = [self validFields][@"included"];
  NSArray *badPaths = @[
    @"/etc/passwd", @"../Secrets.txt", @"Sources/../Secrets.txt",
    @"Sources//App.swift", @"C:\\Secrets.txt", DSHAbsolutePathSentinel,
  ];
  for (NSString *path in badPaths) {
    NSMutableDictionary *row = [validIncluded[0] mutableCopy];
    row[@"relative_path"] = path;
    NSError *error = nil;
    XCTAssertNil(DSHBuildRuntimeProofV3(
        [self fieldsByReplacing:@"included" value:@[ [row copy] ]], &error));
    [self assertError:error code:DSHRuntimeProofV3ErrorPath];
  }

  NSError *error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"included"
                         value:@[ validIncluded[1], validIncluded[0] ]],
      &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorOrder];

  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"included"
                         value:@[ validIncluded[0], validIncluded[0] ]],
      &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorDuplicate];

  NSArray *rounds = [self validFields][@"provider_rounds"];
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds"
                         value:@[ rounds[1], rounds[0] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorOrder];
}

- (void)testRejectsDuplicateRoundsCallsAttachmentsAndNonContiguousIndices {
  NSArray *rounds = [self validFields][@"provider_rounds"];
  NSMutableDictionary *duplicateRound = [rounds[1] mutableCopy];
  duplicateRound[@"provider_request_id"] = rounds[0][@"provider_request_id"];
  NSError *error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds"
                         value:@[ rounds[0], [duplicateRound copy] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorDuplicate];

  NSArray *tools = [self validFields][@"agent_tool_evidence"];
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"agent_tool_evidence"
                         value:@[ tools[0], tools[0] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorDuplicate];

  NSMutableDictionary *wrongIndex = [tools[0] mutableCopy];
  wrongIndex[@"call_index"] = @1;
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"agent_tool_evidence"
                         value:@[ [wrongIndex copy] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorOrder];

  NSArray *attachments = [self validFields][@"attachments"];
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"attachments"
                         value:@[ attachments[0], attachments[0] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorDuplicate];
}

- (void)testProviderRoundsHaveExactUniqueCorrelationIdentifiers {
  NSArray *rounds = [self validFields][@"provider_rounds"];
  NSMutableDictionary *missingRoundId = [rounds[0] mutableCopy];
  [missingRoundId removeObjectForKey:@"round_id"];
  NSError *error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds"
                         value:@[ [missingRoundId copy], rounds[1] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorExactKeys];

  NSMutableDictionary *invalidRoundId = [rounds[0] mutableCopy];
  invalidRoundId[@"round_id"] = @"not-a-uuid";
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds"
                         value:@[ [invalidRoundId copy], rounds[1] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorIdentifier];

  NSMutableDictionary *invalidRequestId = [rounds[0] mutableCopy];
  invalidRequestId[@"provider_request_id"] = @"provider-opaque-is-not-a-uuid";
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds"
                         value:@[ [invalidRequestId copy], rounds[1] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorIdentifier];

  NSMutableDictionary *duplicateRoundId = [rounds[1] mutableCopy];
  duplicateRoundId[@"round_id"] = rounds[0][@"round_id"];
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds"
                         value:@[ rounds[0], [duplicateRoundId copy] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorDuplicate];

  NSMutableDictionary *duplicateResponse = [rounds[1] mutableCopy];
  duplicateResponse[@"provider_response_id"] =
      rounds[0][@"provider_response_id"];
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds"
                         value:@[ rounds[0], [duplicateResponse copy] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorDuplicate];
}

- (void)testProviderRoundResponseAndRootTerminalRelationsAreExact {
  NSArray *rounds = [self validFields][@"provider_rounds"];
  NSMutableDictionary *successWithoutResponse = [rounds[1] mutableCopy];
  successWithoutResponse[@"provider_response_id"] = NSNull.null;
  successWithoutResponse[@"finish_reason"] = NSNull.null;
  NSError *error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds"
                         value:@[ rounds[0], [successWithoutResponse copy] ]],
      &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorRelation];

  NSMutableDictionary *failedWithResponse = [rounds[1] mutableCopy];
  failedWithResponse[@"outcome"] = @"failed";
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds"
                         value:@[ rounds[0], [failedWithResponse copy] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorRelation];

  NSMutableDictionary *unknownRoundFinish = [rounds[1] mutableCopy];
  unknownRoundFinish[@"finish_reason"] = @"provider_unknown_reason";
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds"
                         value:@[ rounds[0], [unknownRoundFinish copy] ]],
      &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorEnum];

  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_response_id" value:@"resp_other"],
      &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorRelation];

  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"finish_reason" value:@"length"], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorRelation];

  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"finish_reason"
                         value:@"provider_unknown_reason"], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorEnum];
}

- (void)testFailedAndCancelledProviderRoundsHaveNullTerminalEvidence {
  for (NSString *outcome in @[ @"failed", @"cancelled" ]) {
    NSMutableDictionary *fields = [[self validFields] mutableCopy];
    fields[@"outcome"] = outcome;
    fields[@"provider_response_id"] = NSNull.null;
    fields[@"finish_reason"] = NSNull.null;
    NSMutableArray *rounds = [fields[@"provider_rounds"] mutableCopy];
    NSMutableDictionary *last = [rounds.lastObject mutableCopy];
    last[@"outcome"] = outcome;
    last[@"provider_response_id"] = NSNull.null;
    last[@"finish_reason"] = NSNull.null;
    rounds[rounds.count - 1] = [last copy];
    fields[@"provider_rounds"] = [rounds copy];
    NSError *error = nil;
    XCTAssertNotNil(DSHBuildRuntimeProofV3([fields copy], &error), @"%@", outcome);
    XCTAssertNil(error);
  }
}

- (void)testToolEvidenceAndProviderToolCallRoundsAreBidirectionallyBound {
  NSArray *rounds = [self validFields][@"provider_rounds"];
  NSDictionary *tool = [self validFields][@"agent_tool_evidence"][0];

  NSMutableDictionary *toolOnStopRound = [tool mutableCopy];
  toolOnStopRound[@"round_index"] = @1;
  NSError *error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"agent_tool_evidence"
                         value:@[ [toolOnStopRound copy] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorRelation];

  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"agent_tool_evidence" value:@[]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorRelation];

  NSMutableDictionary *stopRoundWithTool = [rounds[0] mutableCopy];
  stopRoundWithTool[@"finish_reason"] = @"stop";
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds"
                         value:@[ [stopRoundWithTool copy], rounds[1] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorRelation];

  NSMutableDictionary *failedRoundWithTool = [rounds[0] mutableCopy];
  failedRoundWithTool[@"outcome"] = @"failed";
  failedRoundWithTool[@"provider_response_id"] = NSNull.null;
  failedRoundWithTool[@"finish_reason"] = NSNull.null;
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds"
                         value:@[ [failedRoundWithTool copy], rounds[1] ]],
      &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorRelation];
}

- (void)testCompletedAttemptRequiresTerminalAssistantRoundAndToolOnlyIntermediates {
  NSMutableDictionary *terminalToolFields = [[self validFields] mutableCopy];
  terminalToolFields[@"finish_reason"] = @"tool_calls";
  NSMutableArray *terminalToolRounds =
      [terminalToolFields[@"provider_rounds"] mutableCopy];
  NSMutableDictionary *terminalToolRound =
      [terminalToolRounds.lastObject mutableCopy];
  terminalToolRound[@"finish_reason"] = @"tool_calls";
  terminalToolRounds[terminalToolRounds.count - 1] = [terminalToolRound copy];
  terminalToolFields[@"provider_rounds"] = [terminalToolRounds copy];
  NSMutableArray *terminalToolEvidence =
      [terminalToolFields[@"agent_tool_evidence"] mutableCopy];
  NSMutableDictionary *secondTool = [terminalToolEvidence[0] mutableCopy];
  secondTool[@"call_id"] = @"call_fixture_02";
  secondTool[@"round_index"] = @1;
  secondTool[@"call_index"] = @0;
  [terminalToolEvidence addObject:[secondTool copy]];
  terminalToolFields[@"agent_tool_evidence"] = [terminalToolEvidence copy];
  NSError *error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3([terminalToolFields copy], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorRelation];

  NSMutableDictionary *nonterminalStopFields = [[self validFields] mutableCopy];
  NSMutableArray *nonterminalStopRounds =
      [nonterminalStopFields[@"provider_rounds"] mutableCopy];
  NSMutableDictionary *nonterminalStop = [nonterminalStopRounds[0] mutableCopy];
  nonterminalStop[@"finish_reason"] = @"stop";
  nonterminalStopRounds[0] = [nonterminalStop copy];
  nonterminalStopFields[@"provider_rounds"] = [nonterminalStopRounds copy];
  nonterminalStopFields[@"agent_tool_evidence"] = @[];
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3([nonterminalStopFields copy], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorRelation];
}

- (void)testOmissionIdentityAndIncludedOmittedCrossRelationsAreExact {
  NSDictionary *omission = [self validFields][@"omitted"][0];
  NSError *error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"omitted" value:@[ omission, omission ]],
      &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorDuplicate];

  NSDictionary *included = [self validFields][@"included"][0];
  NSDictionary *crossConflict = @{
    @"relative_path" : included[@"relative_path"],
    @"source" : included[@"source"],
    @"reason" : @"policy",
  };
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"omitted" value:@[ crossConflict ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorRelation];

  NSMutableArray *samePathDifferentSource =
      [[self validFields][@"included"] mutableCopy];
  NSMutableDictionary *diff = [samePathDifferentSource[1] mutableCopy];
  diff[@"source"] = @"staged_diff";
  [samePathDifferentSource insertObject:[diff copy] atIndex:1];
  NSDictionary *proof = DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"included"
                         value:[samePathDifferentSource copy]], &error);
  XCTAssertNotNil(proof);
  XCTAssertNil(error);
}

- (void)testRejectsFractionalNegativeNonFiniteBooleanAndOverflowNumbers {
  NSArray *invalidNumbers = @[
    @(-1), @(-0.0), @1.0, @1.5, @(NAN), @(INFINITY), @YES,
    @9007199254740992ULL,
    [NSDecimalNumber decimalNumberWithString:
        @"1.0000000000000000000000001"],
  ];
  NSDictionary *included = [self validFields][@"included"][0];
  for (NSNumber *number in invalidNumbers) {
    NSMutableDictionary *row = [included mutableCopy];
    row[@"bytes"] = number;
    NSError *error = nil;
    XCTAssertNil(DSHBuildRuntimeProofV3(
        [self fieldsByReplacing:@"included" value:@[ [row copy] ]], &error));
    [self assertError:error code:DSHRuntimeProofV3ErrorNumber];
  }

  NSDictionary *tool = [self validFields][@"agent_tool_evidence"][0];
  for (NSNumber *number in invalidNumbers) {
    NSMutableDictionary *row = [tool mutableCopy];
    row[@"duration_ms"] = number;
    NSError *error = nil;
    XCTAssertNil(DSHBuildRuntimeProofV3(
        [self fieldsByReplacing:@"agent_tool_evidence" value:@[ [row copy] ]],
        &error));
    [self assertError:error code:DSHRuntimeProofV3ErrorNumber];
  }
}

- (void)testRejectsDeepOrOverNodeBudgetJSONBeforeSchemaTraversal {
  id nested = @"leaf";
  for (NSUInteger depth = 0; depth < 64; depth += 1) {
    nested = @[ nested ];
  }
  NSError *error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"included" value:@[ nested ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorBounds];

  NSMutableArray *manyNodes = [NSMutableArray arrayWithCapacity:40000];
  for (NSUInteger index = 0; index < 40000; index += 1) {
    [manyNodes addObject:NSNull.null];
  }
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"branch" value:[manyNodes copy]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorBounds];
}

- (void)testSHA256HelperRejectsMutableCustomAndWrongTypedData {
  XCTAssertEqualObjects(
      DSHRuntimeProofV3SHA256Hex(
          [[@"abc" dataUsingEncoding:NSUTF8StringEncoding] copy]),
      @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  XCTAssertNil(DSHRuntimeProofV3SHA256Hex(nil));
  XCTAssertNil(DSHRuntimeProofV3SHA256Hex(
      (NSData *)(id)@"not-data"));
  XCTAssertNil(DSHRuntimeProofV3SHA256Hex(
      [NSMutableData dataWithData:[@"abc" dataUsingEncoding:NSUTF8StringEncoding]]));
  XCTAssertNil(DSHRuntimeProofV3SHA256Hex([DSHHostileProofData new]));
}

- (void)testRejectsMalformedNestedRowsAndContradictoryOutcomes {
  NSDictionary *tool = [self validFields][@"agent_tool_evidence"][0];
  NSMutableDictionary *legacyDigest = [tool mutableCopy];
  legacyDigest[@"arguments_sha256"] = @"sha1:0123abcd";
  NSError *error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"agent_tool_evidence"
                         value:@[ [legacyDigest copy] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorDigest];

  NSMutableDictionary *successWithFailure = [tool mutableCopy];
  successWithFailure[@"failure_code"] = @"E_TOOL_FAILED";
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"agent_tool_evidence"
                         value:@[ [successWithFailure copy] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorEnum];

  NSMutableDictionary *failedWithoutCode = [tool mutableCopy];
  failedWithoutCode[@"outcome"] = @"failed";
  failedWithoutCode[@"failure_code"] = NSNull.null;
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"agent_tool_evidence"
                         value:@[ [failedWithoutCode copy] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorEnum];

  NSMutableDictionary *badAttachment =
      [[self validFields][@"attachments"][0] mutableCopy];
  badAttachment[@"media_type"] = @"TEXT/PLAIN; charset=utf-8";
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"attachments"
                         value:@[ [badAttachment copy] ]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorText];

  NSArray *validRounds = [self validFields][@"provider_rounds"];
  NSMutableDictionary *badRound = [validRounds.lastObject mutableCopy];
  badRound[@"request_body_sha256"] = [self digestForString:@"other body"];
  NSArray *rounds = @[
    [self validFields][@"provider_rounds"][0], [badRound copy]
  ];
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"provider_rounds" value:rounds], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorRelation];
}

- (void)testRejectsOversizedCollectionsAndText {
  NSMutableArray *attachments = [NSMutableArray array];
  for (NSUInteger index = 0;
       index < DSHRuntimeProofV3MaxAttachments + 1; index += 1) {
    NSString *identifier = [NSString stringWithFormat:@"attachment-%04lu",
                             (unsigned long)index];
    [attachments addObject:@{
      @"opaque_id_sha256" : [self digestForString:identifier],
      @"sha256" : [self digestForString:@"payload"],
      @"bytes" : @7,
      @"media_type" : @"text/plain",
    }];
  }
  [attachments sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                        NSDictionary *right) {
    return [left[@"opaque_id_sha256"] compare:right[@"opaque_id_sha256"]];
  }];
  NSError *error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"attachments" value:[attachments copy]], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorBounds];

  NSString *longModel = [[@"x" stringByPaddingToLength:257
                                             withString:@"x"
                                        startingAtIndex:0] copy];
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"model" value:longModel], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorText];
}

- (void)testRejectsMutableAndCustomFoundationInputsBeforeAliasing {
  NSError *error = nil;
  NSMutableDictionary *mutableTop = [[self validFields] mutableCopy];
  XCTAssertNil(DSHBuildRuntimeProofV3(mutableTop, &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorUntrustedContainer];

  NSMutableArray *mutableIncluded =
      [[self validFields][@"included"] mutableCopy];
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"included" value:mutableIncluded], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorUntrustedContainer];

  NSMutableString *mutableModel = [@"deepseek-v4-flash" mutableCopy];
  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      [self fieldsByReplacing:@"model" value:mutableModel], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorUntrustedContainer];

  error = nil;
  XCTAssertNil(DSHBuildRuntimeProofV3(
      (NSDictionary *)[DSHHostileProofDictionary new], &error));
  [self assertError:error code:DSHRuntimeProofV3ErrorUntrustedContainer];
}

@end
