#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/ProjectContextPolicy.h"

#include <math.h>

#if DEBUG
extern void DSHProjectContextPolicyResetCredentialScanWorkForTesting(void);
extern NSUInteger DSHProjectContextPolicyCredentialScanWorkForTesting(void);
#endif

@interface DSHLengthOnlyCursorString : NSString {
  NSUInteger _reportedLength;
}
- (instancetype)initWithReportedLength:(NSUInteger)reportedLength;
@end

@implementation DSHLengthOnlyCursorString
- (instancetype)initWithReportedLength:(NSUInteger)reportedLength {
  self = [super init];
  if (self) {
    _reportedLength = reportedLength;
  }
  return self;
}

- (NSUInteger)length {
  return _reportedLength;
}

- (unichar)characterAtIndex:(NSUInteger)index {
  @throw [NSException exceptionWithName:@"UnexpectedCursorTraversal"
                                 reason:@"Oversized cursor was traversed before its length was rejected"
                               userInfo:nil];
}

- (void)getCharacters:(unichar *)buffer range:(NSRange)range {
  @throw [NSException exceptionWithName:@"UnexpectedCursorTraversal"
                                 reason:@"Oversized cursor was copied before its length was rejected"
                               userInfo:nil];
}
@end

@interface DSHMutableUnsignedNumber : NSNumber
@property(nonatomic) unsigned long long mutableValue;
- (instancetype)initWithValue:(unsigned long long)value;
@end

@implementation DSHMutableUnsignedNumber
- (instancetype)initWithValue:(unsigned long long)value {
  self = [super init];
  if (self) {
    _mutableValue = value;
  }
  return self;
}

- (const char *)objCType {
  return @encode(unsigned long long);
}

- (void)getValue:(void *)value size:(NSUInteger)size {
  if (size >= sizeof(_mutableValue)) {
    memcpy(value, &_mutableValue, sizeof(_mutableValue));
  }
}

- (unsigned long long)unsignedLongLongValue {
  return _mutableValue;
}

- (long long)longLongValue {
  return (long long)_mutableValue;
}

- (double)doubleValue {
  return (double)_mutableValue;
}

- (NSString *)stringValue {
  return [NSString stringWithFormat:@"%llu", _mutableValue];
}

- (NSComparisonResult)compare:(NSNumber *)other {
  unsigned long long right = other.unsignedLongLongValue;
  if (_mutableValue < right) return NSOrderedAscending;
  if (_mutableValue > right) return NSOrderedDescending;
  return NSOrderedSame;
}
@end

@interface DSHFlappingUnsignedNumber : DSHMutableUnsignedNumber
@end

@implementation DSHFlappingUnsignedNumber
- (NSString *)stringValue {
  return @"1";
}

- (unsigned long long)unsignedLongLongValue {
  return 9007199254740992ULL;
}

- (double)doubleValue {
  return 1.0;
}
@end

@interface DSHMisreportingCandidateArray : NSArray {
  id _repeatedObject;
  NSUInteger _actualEnumerationCount;
  NSUInteger _enumeratedObjectCount;
  unsigned long _mutationMarker;
}
@property(nonatomic, readonly) NSUInteger enumeratedObjectCount;
- (instancetype)initWithRepeatedObject:(id)object
                actualEnumerationCount:(NSUInteger)actualEnumerationCount;
@end

@implementation DSHMisreportingCandidateArray
- (instancetype)initWithRepeatedObject:(id)object
                actualEnumerationCount:(NSUInteger)actualEnumerationCount {
  self = [super init];
  if (self) {
    _repeatedObject = object;
    _actualEnumerationCount = actualEnumerationCount;
  }
  return self;
}

- (NSUInteger)count {
  return 1;
}

- (id)objectAtIndex:(NSUInteger)index {
  return _repeatedObject;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer
                                    count:(NSUInteger)length {
  NSUInteger offset = (NSUInteger)state->state;
  if (offset >= _actualEnumerationCount) {
    @throw [NSException
        exceptionWithName:@"UnboundedCandidateEnumeration"
                   reason:@"Candidate policy enumerated past its fixed budget"
                 userInfo:nil];
  }
  if (length == 0) {
    return 0;
  }
  NSUInteger batch = MIN(length, _actualEnumerationCount - offset);
  for (NSUInteger index = 0; index < batch; index++) {
    buffer[index] = _repeatedObject;
  }
  state->itemsPtr = buffer;
  state->mutationsPtr = &_mutationMarker;
  state->state += batch;
  _enumeratedObjectCount += batch;
  return batch;
}

- (NSUInteger)enumeratedObjectCount {
  return _enumeratedObjectCount;
}
@end

@interface DSHMisreportingCandidateDictionary : NSDictionary {
  NSDictionary *_backing;
  NSArray<NSString *> *_enumeratedKeys;
  unsigned long _mutationMarker;
}
- (instancetype)initWithBacking:(NSDictionary *)backing;
@end

@implementation DSHMisreportingCandidateDictionary
- (instancetype)initWithBacking:(NSDictionary *)backing {
  self = [super init];
  if (self) {
    _backing = [backing copy];
    _enumeratedKeys = @[
      @"path", @"size", @"revision", @"git_state", @"eligible",
      @"omission_reason", @"path"
    ];
  }
  return self;
}

- (NSUInteger)count {
  return 6;
}

- (id)objectForKey:(id)key {
  return [_backing objectForKey:key];
}

- (NSEnumerator *)keyEnumerator {
  return [_enumeratedKeys objectEnumerator];
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer
                                    count:(NSUInteger)length {
  NSUInteger offset = (NSUInteger)state->state;
  if (offset >= _enumeratedKeys.count) {
    @throw [NSException
        exceptionWithName:@"UnboundedCandidateKeyEnumeration"
                   reason:@"Candidate policy enumerated past its schema budget"
                 userInfo:nil];
  }
  if (length == 0) {
    return 0;
  }
  NSUInteger batch = MIN(length, _enumeratedKeys.count - offset);
  for (NSUInteger index = 0; index < batch; index++) {
    buffer[index] = _enumeratedKeys[offset + index];
  }
  state->itemsPtr = buffer;
  state->mutationsPtr = &_mutationMarker;
  state->state += batch;
  return batch;
}
@end

@interface ProjectContextPolicyTests : XCTestCase
@property(nonatomic, strong) DSHProjectContextPolicy *policy;
@end

@implementation ProjectContextPolicyTests

- (void)setUp {
  [super setUp];
  self.policy = [[DSHProjectContextPolicy alloc] init];
  XCTAssertNotNil(self.policy);
}

- (NSDictionary<NSString *, id> *)candidateWithPath:(NSString *)path
                                                size:(NSUInteger)size
                                            revision:(NSString *)revision
                                             gitState:(NSString *)gitState
                                             eligible:(BOOL)eligible
                                        omissionReason:(id)omissionReason {
  return @{
    @"path" : path,
    @"size" : @(size),
    @"revision" : revision,
    @"git_state" : gitState,
    @"eligible" : @(eligible),
    @"omission_reason" : omissionReason,
  };
}

- (void)testPolicyConstantsAreFixed {
  XCTAssertEqualObjects(DSHProjectContextPolicyVersion, @"chat-read-v1.0.0");
  XCTAssertEqual(DSHProjectContextMaxEntries, (NSUInteger)5000);
  XCTAssertEqual(DSHProjectContextMaxDepth, (NSUInteger)24);
  XCTAssertEqual(DSHProjectContextMaxFiles, (NSUInteger)32);
  XCTAssertEqual(DSHProjectContextMaxFileBytes, (NSUInteger)(64 * 1024));
  XCTAssertEqual(DSHProjectContextMaxChangedPaths, (NSUInteger)100);
  XCTAssertEqual(DSHProjectContextMaxDiffBytes, (NSUInteger)(128 * 1024));
  XCTAssertEqual(DSHProjectContextMaxContextBytes, (NSUInteger)(256 * 1024));
  XCTAssertEqualWithAccuracy(DSHProjectContextDeadlineSeconds, 2.0, 0.0);
  XCTAssertEqual(DSHProjectContextMaxCandidatePageSize, (NSUInteger)100);
}

- (void)testPathPolicyDeniesSensitiveGeneratedLockAndBinaryPaths {
  NSArray<NSArray<NSString *> *> *cases = @[
    @[ @".env.production", DSHProjectContextOmissionReasonSecretPath ],
    @[ @"Config/CREDENTIALS.json", DSHProjectContextOmissionReasonSecretPath ],
    @[ @"Config/Secrets.production.json", DSHProjectContextOmissionReasonSecretPath ],
    @[ @"keys/id_rsa", DSHProjectContextOmissionReasonSecretPath ],
    @[ @"certificates/signing.PeM", DSHProjectContextOmissionReasonSecretPath ],
    @[ @"src/.GiT/config", DSHProjectContextOmissionReasonSecretPath ],
    @[ @".m2/settings.xml", DSHProjectContextOmissionReasonSecretPath ],
    @[ @"Pods/Library/source.m", DSHProjectContextOmissionReasonGenerated ],
    @[ @"web/node_modules/pkg/index.ts", DSHProjectContextOmissionReasonGenerated ],
    @[ @"release/DerivedData/log.txt", DSHProjectContextOmissionReasonGenerated ],
    @[ @"Podfile.lock", DSHProjectContextOmissionReasonLockfile ],
    @[ @"package-lock.json", DSHProjectContextOmissionReasonLockfile ],
    @[ @"npm-shrinkwrap.json", DSHProjectContextOmissionReasonLockfile ],
    @[ @"public/app.min.js", DSHProjectContextOmissionReasonBinary ],
    @[ @"public/app.js.map", DSHProjectContextOmissionReasonBinary ],
    @[ @"assets/logo.png", DSHProjectContextOmissionReasonBinary ],
    @[ @"artifacts/module.wasm", DSHProjectContextOmissionReasonBinary ],
    @[ @"bytecode/file.pyc", DSHProjectContextOmissionReasonBinary ],
    @[ @"data/unknown.custom", DSHProjectContextOmissionReasonPolicy ],
  ];

  for (NSArray<NSString *> *testCase in cases) {
    DSHProjectContextPathDecision *decision =
        [self.policy decisionForRelativePath:testCase[0]];
    XCTAssertFalse(decision.eligible, @"Expected %@ to be denied", testCase[0]);
    XCTAssertEqualObjects(decision.omissionReason, testCase[1]);
  }
}

- (void)testPathPolicyDeniesGeneratedAndSecretDirectoryComponentsCaseInsensitively {
  NSArray<NSArray<NSString *> *> *cases = @[
    @[ @"generated/Foo.swift", DSHProjectContextOmissionReasonGenerated ],
    @[ @"secret/config.json", DSHProjectContextOmissionReasonSecretPath ],
    @[ @"secrets/config.json", DSHProjectContextOmissionReasonSecretPath ],
    @[ @".env/config.json", DSHProjectContextOmissionReasonSecretPath ],
    @[ @"Generated/Foo.swift", DSHProjectContextOmissionReasonGenerated ],
    @[ @"Secrets/config.json", DSHProjectContextOmissionReasonSecretPath ],
  ];

  for (NSArray<NSString *> *testCase in cases) {
    DSHProjectContextPathDecision *decision =
        [self.policy decisionForRelativePath:testCase[0]];
    XCTAssertFalse(decision.eligible, @"Expected %@ to be denied", testCase[0]);
    XCTAssertEqualObjects(decision.omissionReason, testCase[1]);
  }
}

- (void)testPathPolicyUsesCanonicalUnicodeCaseFoldingForSensitiveDirectories {
  NSArray<NSString *> *paths = @[
    @"\u017fecrets/config.json",
    @"\u017fECRETS/config.json",
    @"\u017fEcrEt/config.json",
  ];

  for (NSString *path in paths) {
    DSHProjectContextPathDecision *decision =
        [self.policy decisionForRelativePath:path];
    XCTAssertFalse(decision.eligible, @"Expected %@ to be denied", path);
    XCTAssertEqualObjects(decision.omissionReason,
                          DSHProjectContextOmissionReasonSecretPath);
  }
}

- (void)testPathPolicyAppliesSensitiveRulesToEveryDirectoryComponent {
  NSArray<NSString *> *denied = @[
    @".env.production/config.json",
    @"credentials/aws.json",
    @"Config/.ENV.local/settings.json",
    @"Config/CREDENTIALS/aws.json",
    @"credentials.production.local/aws.json",
    @"secret.production.local/config.json",
  ];
  for (NSString *path in denied) {
    DSHProjectContextPathDecision *decision =
        [self.policy decisionForRelativePath:path];
    XCTAssertFalse(decision.eligible, @"Expected %@ to be denied", path);
    XCTAssertEqualObjects(decision.omissionReason,
                          DSHProjectContextOmissionReasonSecretPath);
  }

  for (NSString *path in @[
         @"docs/credentials-guide/config.json",
         @"src/secretary/config.json",
         @"environment/config.json",
         @"docs/credentials-guide.json",
         @"src/secrets-manager.swift",
         @"src/credential_store.swift",
       ]) {
    DSHProjectContextPathDecision *decision =
        [self.policy decisionForRelativePath:path];
    XCTAssertTrue(decision.eligible, @"Expected safe segment %@ to pass", path);
    XCTAssertNil(decision.omissionReason);
  }
}

- (void)testPathPolicyAcceptsSafeTrackedSourceAndPlainTextPaths {
  NSArray<NSString *> *paths = @[
    @"Sources/App.SWIFT",
    @"src/index.tsx",
    @"src/Program.cs",
    @"lib/widget.dart",
    @"web/App.vue",
    @"docs/README.private.md",
    @"LICENSE-MIT",
    @"Dockerfile",
    @"Makefile",
    @"Cargo.toml",
    @"package.json",
    @".gitignore",
  ];

  for (NSString *path in paths) {
    DSHProjectContextPathDecision *decision =
        [self.policy decisionForRelativePath:path];
    XCTAssertTrue(decision.eligible, @"Expected %@ to be allowed", path);
    XCTAssertNil(decision.omissionReason);
  }
}

- (void)testPathPolicyNormalizesUnicodeAndRejectsUnsafeRelativePathSyntax {
  NSString *decomposed = @"Sources/Cafe\u0301.swift";
  DSHProjectContextPathDecision *unicodeDecision =
      [self.policy decisionForRelativePath:decomposed];
  XCTAssertTrue(unicodeDecision.eligible);
  XCTAssertEqualObjects(unicodeDecision.normalizedPath, @"Sources/Caf\u00e9.swift");

  NSArray<NSString *> *unsafePaths = @[
    @"",
    @"/etc/passwd",
    @"C:/Windows/system.ini",
    @"src/../Secrets.swift",
    @"src/./Main.swift",
    @"src//Main.swift",
    @"src/Main.swift/",
    @"src\\Main.swift",
    @"src/Line\nBreak.swift",
  ];
  for (NSString *path in unsafePaths) {
    DSHProjectContextPathDecision *decision =
        [self.policy decisionForRelativePath:path];
    XCTAssertFalse(decision.eligible, @"Expected unsafe path to be denied: %@", path);
    XCTAssertEqualObjects(decision.omissionReason,
                          DSHProjectContextOmissionReasonPolicy);
  }
}

- (void)testContentPolicyAcceptsUTF8AndRejectsNULBinaryAndInvalidUTF8 {
  NSData *text = [@"let caf\u00e9 = \"safe\";\n" dataUsingEncoding:NSUTF8StringEncoding];
  DSHProjectContextContentDecision *textDecision =
      [self.policy decisionForContentData:text];
  XCTAssertTrue(textDecision.eligible);
  XCTAssertNil(textDecision.omissionReason);

  const unsigned char nulBytes[] = {'a', 0, 'b'};
  DSHProjectContextContentDecision *nulDecision =
      [self.policy decisionForContentData:[NSData dataWithBytes:nulBytes
                                                        length:sizeof(nulBytes)]];
  XCTAssertFalse(nulDecision.eligible);
  XCTAssertEqualObjects(nulDecision.omissionReason,
                        DSHProjectContextOmissionReasonBinary);

  const unsigned char binaryBytes[] = {'a', 1, 'b'};
  DSHProjectContextContentDecision *binaryDecision =
      [self.policy decisionForContentData:[NSData dataWithBytes:binaryBytes
                                                        length:sizeof(binaryBytes)]];
  XCTAssertFalse(binaryDecision.eligible);
  XCTAssertEqualObjects(binaryDecision.omissionReason,
                        DSHProjectContextOmissionReasonBinary);

  const unsigned char invalidUTF8[] = {0xc3, 0x28};
  DSHProjectContextContentDecision *encodingDecision =
      [self.policy decisionForContentData:[NSData dataWithBytes:invalidUTF8
                                                        length:sizeof(invalidUTF8)]];
  XCTAssertFalse(encodingDecision.eligible);
  XCTAssertEqualObjects(encodingDecision.omissionReason,
                        DSHProjectContextOmissionReasonInvalidEncoding);
}

- (void)testContentPolicyEnforcesFileByteBudgetBeforeSecretScanning {
  NSMutableData *atLimit =
      [NSMutableData dataWithLength:DSHProjectContextMaxFileBytes];
  memset(atLimit.mutableBytes, 'a', atLimit.length);
  DSHProjectContextContentDecision *atLimitDecision =
      [self.policy decisionForContentData:atLimit];
  XCTAssertTrue(atLimitDecision.eligible);
  XCTAssertNil(atLimitDecision.omissionReason);

  NSMutableData *overLimit = [atLimit mutableCopy];
  const unsigned char suffix = 'a';
  [overLimit appendBytes:&suffix length:1];
  DSHProjectContextContentDecision *overLimitDecision =
      [self.policy decisionForContentData:overLimit];
  XCTAssertFalse(overLimitDecision.eligible);
  XCTAssertEqualObjects(overLimitDecision.omissionReason,
                        DSHProjectContextOmissionReasonBudgetExceeded);

  NSMutableData *lateSecret = [atLimit mutableCopy];
  [lateSecret appendData:[@"-----BEGIN PRIVATE KEY-----"
                             dataUsingEncoding:NSUTF8StringEncoding]];
  DSHProjectContextContentDecision *lateSecretContent =
      [self.policy decisionForContentData:lateSecret];
  DSHProjectContextSecretDecision *lateSecretScan =
      [self.policy secretDecisionForData:lateSecret];
  XCTAssertFalse(lateSecretContent.eligible);
  XCTAssertEqualObjects(lateSecretContent.omissionReason,
                        DSHProjectContextOmissionReasonBudgetExceeded);
  XCTAssertFalse(lateSecretScan.suspectedSecret);
}

- (void)testSecretPolicyDetectsPrivateKeysKnownTokensJWTAssignmentsAndEntropy {
  NSString *overlongComment =
      [@"x" stringByPaddingToLength:257 withString:@"x" startingAtIndex:0];
  NSString *overlongCommentAssignment = [NSString
      stringWithFormat:@"config[/*%@*/\"password\"] = \"hunter2\"",
                       overlongComment];
  NSString *overlongQuotedComponent =
      [@"x" stringByPaddingToLength:129 withString:@"x" startingAtIndex:0];
  NSString *overlongQuotedDynamicAssignment = [NSString
      stringWithFormat:@"config[\"%@\" + password] = \"changeme\"",
                       overlongQuotedComponent];
  NSString *longDynamicPrefix =
      [@"x+" stringByPaddingToLength:520 withString:@"x+" startingAtIndex:0];
  NSString *longDynamicAssignment = [NSString
      stringWithFormat:@"config[%@password] = \"changeme\"",
                       longDynamicPrefix];
  NSString *overlongScopedKey = [[@"a" stringByPaddingToLength:120
                                                    withString:@"a"
                                               startingAtIndex:0]
      stringByAppendingString:@".password"];
  NSString *overlongScopedAssignment = [NSString
      stringWithFormat:@"config[\"%@\"] = \"hunter2\"", overlongScopedKey];
  NSArray<NSString *> *samples = @[
    @"-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----",
    @"token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890",
    @"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
    @"password = \"correct-horse-battery-staple\"",
    @"client_secret = \"correct horse battery staple\"",
    @"password = \"production-example-password\"",
    @"opaque = \"Q7zN2vK9pL4sR8wT6yH3mF5cB1xD0aE+\"",
    @"<settings><password>hunter2</password></settings>",
    @"<dict><key>password</key><string>hunter2</string></dict>",
    @"<settings><client_secret>hunter2</client_secret></settings>",
    @"<dict><key>client_secret</key><string>hunter2</string></dict>",
    @"<password><![CDATA[hunter2]]></password>",
    @"<maven:password>hunter2</maven:password>",
    @"{\"pass\\u0077ord\":\"hunter2\"}",
    @"config[\"password\"] = \"hunter2\"",
    @"db_password = \"hunter2\"",
    @"database.password = \"hunter2\"",
    @"<db_password>hunter2</db_password>",
    @"<password value=\"hunter2\"/>",
    @"<property name=\"password\" value=\"hunter2\"/>",
    @"<property name=\"pass&#119;ord\" value=\"hunter2\"/>",
    @"<password value=\"changeme\" value=\"hunter2\"/>",
    @"<property name=\"password\" value=\"changeme\" value=\"hunter2\"/>",
    @"<clientsecret>hunter2</clientsecret>",
    @"<配置:password>hunter2</配置:password>",
    @"config[`password`] = \"hunter2\"",
    @"config[/*comment*/\"password\"] = \"hunter2\"",
    @"config[\"pass\\x77ord\"] = \"hunter2\"",
    @"config[\"password\"] ||= \"hunter2\"",
    @"config[`prefix_${password}`] = \"changeme\"",
    overlongCommentAssignment,
    @"config[//x\n\"password\"] = \"hunter2\"",
    @"config[\"password\"] /*c*/ = \"hunter2\"",
    @"config[\"prefix_\" + password] = \"changeme\"",
    @"config[`password_${name}`] = \"hunter2\"",
    overlongQuotedDynamicAssignment,
    longDynamicAssignment,
    overlongScopedAssignment,
  ];

  for (NSString *sample in samples) {
    DSHProjectContextSecretDecision *decision = [self.policy
        secretDecisionForData:[sample dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertTrue(decision.suspectedSecret,
                  @"Expected a secret signal for detector fixture %lu",
                  (unsigned long)[samples indexOfObject:sample]);
    XCTAssertEqualObjects(decision.omissionReason,
                          DSHProjectContextOmissionReasonSuspectedSecret);
  }

  NSData *placeholder =
      [@"api_key = process.env.API_KEY\npassword = \"changeme\"\n"
          dataUsingEncoding:NSUTF8StringEncoding];
  DSHProjectContextSecretDecision *placeholderDecision =
      [self.policy secretDecisionForData:placeholder];
  XCTAssertFalse(placeholderDecision.suspectedSecret);
  XCTAssertNil(placeholderDecision.omissionReason);
}

- (void)testSecretPolicyOnlyExemptsExplicitCredentialPlaceholders {
  NSData *realAngleCredential =
      [@"password = \"<correct-horse-battery-staple>\""
          dataUsingEncoding:NSUTF8StringEncoding];
  DSHProjectContextSecretDecision *realDecision =
      [self.policy secretDecisionForData:realAngleCredential];
  XCTAssertTrue(realDecision.suspectedSecret);
  XCTAssertEqualObjects(realDecision.omissionReason,
                        DSHProjectContextOmissionReasonSuspectedSecret);

  NSArray<NSString *> *compositeCredentials = @[
    @"password = \"changeme\" + \"real-prod-secret\"",
    @"password = process.env.API_KEY ?: \"real-prod-secret\"",
    @"password: changeme, real-prod-secret",
    @"password = changeme; real-prod-secret",
    @"password: changeme, } real-prod-secret",
    @"password=changeme#real-prod-secret",
    @"password=\"\"real-prod-secret",
    @"password=\"changeme\"//real-prod-secret",
    @"password=\"changeme\"}",
    @"password =\n\"hunter2\"",
    @"{\"password\":\n \"hunter2\"}",
    @"password = \"changeme\"\n + \"real-prod-secret\"",
    @"password=\"changeme\"\n \n + \"hunter2\"",
    @"{\"password\":\"changeme\"\n \n + \"hunter2\"}",
    @"password\n=hunter2",
    @"{\"password\"\n:\"hunter2\"}",
    @"echo \"password\":null}",
    @"password=changeme\n  hunter2",
    @"const char *password = \"changeme\"\n\"real-prod-secret\";",
    @"config[\"password\"\n] = \"hunter2\"",
    @"config[\n\"password\"] = \"hunter2\"",
    @"config[\u00a0\"password\"] = \"hunter2\"",
    @"{\"password\":\"changeme\"\n\"real-prod-secret\"}",
    @"{\"password\":\"changeme\"\nreal-prod-secret}",
    @"password\u00a0=\u00a0changeme",
    @"<settings><password>changeme</token></settings>",
    @"{\"password\":\"changeme\",\"token\":\"real-prod\"}",
    @"\\\"password\":null}",
    @"password=",
    @"password=changemeReal",
    @"password=\"hunter2\"",
    @"password=\"x\"",
    @"token=abc",
  ];
  for (NSString *assignment in compositeCredentials) {
    DSHProjectContextSecretDecision *decision = [self.policy
        secretDecisionForData:[assignment dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertTrue(decision.suspectedSecret,
                  @"Expected the complete credential expression to be scanned: %@",
                  assignment);
    XCTAssertEqualObjects(decision.omissionReason,
                          DSHProjectContextOmissionReasonSuspectedSecret);
  }

  NSArray<NSString *> *approvedPlaceholders = @[
    @"password = \"<password>\"",
    @"secret = \"<secret>\"",
    @"token = \"<token>\"",
    @"api_key = \"<api-key>\"",
    @"password = \"<your-password>\"",
    @"password = \"${VAR_NAME}\"",
    @"password = \"{{VAR_NAME}}\"",
    @"password = \"example\"",
    @"password = \"dummy\"",
    @"password = \"test\"",
    @"password = \"\"",
    @"password = null",
    @"password=changeme # placeholder comment",
    @"<settings><client_secret>changeme</client_secret></settings>",
    @"<dict><key>client_secret</key><string>${CLIENT_SECRET}</string></dict>",
    @"<maven:password><![CDATA[changeme]]></maven:password>",
    @"<password value=\"changeme\"/>",
    @"<property name=\"db_password\" value=\"${DB_PASSWORD}\"/>",
    @"<property name=\"pass&#119;ord\" value=\"changeme\"/>",
    @"{\"db_password\":\"changeme\"}",
    @"{\"database.password\":\"changeme\"}",
    @"config[/*c*/\"password\"] /*c*/ = \"changeme\"",
  ];
  for (NSString *assignment in approvedPlaceholders) {
    DSHProjectContextSecretDecision *decision = [self.policy
        secretDecisionForData:[assignment dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertFalse(decision.suspectedSecret,
                   @"Expected an explicit placeholder: %@", assignment);
    XCTAssertNil(decision.omissionReason);
  }

  NSArray<NSString *> *safeNearMisses = @[
    @"notpassword = \"hunter2\"",
    @"password_hint = \"hunter2\"",
    @"tokenizer = \"hunter2\"",
    @"<notpassword>hunter2</notpassword>",
    @"<password_hint>hunter2</password_hint>",
    @"config[\"tokenizer\"] = \"hunter2\"",
    @"config[`user_${name}`] = \"hunter2\"",
    @"config[`prefix_${password}`]",
    @"config[\"prefix_\" + username] = \"hunter2\"",
    @"config[`username_${name}`] = \"hunter2\"",
  ];
  for (NSString *nearMiss in safeNearMisses) {
    DSHProjectContextSecretDecision *decision = [self.policy
        secretDecisionForData:[nearMiss dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertFalse(decision.suspectedSecret,
                   @"Credential grammar overmatched near-miss: %@", nearMiss);
    XCTAssertNil(decision.omissionReason);
  }
}

- (void)testStructuredCredentialScanIsLinearForMalformedMaximumInput {
  NSMutableString *malformed =
      [NSMutableString stringWithCapacity:DSHProjectContextMaxFileBytes];
  for (NSUInteger index = 0; index < 7281; index++) {
    [malformed appendString:@"<password"];
  }
  NSData *data = [malformed dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertEqual(data.length, (NSUInteger)65529);

#if DEBUG
  DSHProjectContextPolicyResetCredentialScanWorkForTesting();
#endif
  CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
  DSHProjectContextSecretDecision *decision =
      [self.policy secretDecisionForData:data];
  CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - startedAt;
#if DEBUG
  NSUInteger workUnits = DSHProjectContextPolicyCredentialScanWorkForTesting();
#endif

  XCTAssertFalse(decision.suspectedSecret);
  XCTAssertNil(decision.omissionReason);
#if DEBUG
  XCTAssertLessThanOrEqual(workUnits, data.length * 8,
                           @"Structured scan exceeded the linear work bound");
#endif
  XCTAssertLessThan(elapsed, DSHProjectContextDeadlineSeconds,
                    @"Malformed structured input exceeded the policy deadline");
}

- (void)testScalarCredentialScanIsLinearForMaximumScopedNearMiss {
  NSMutableString *scopedNearMiss =
      [NSMutableString stringWithCapacity:DSHProjectContextMaxFileBytes];
  while (scopedNearMiss.length < DSHProjectContextMaxFileBytes) {
    [scopedNearMiss appendString:@"a."];
  }
  NSData *data = [scopedNearMiss dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertEqual(data.length, DSHProjectContextMaxFileBytes);

#if DEBUG
  DSHProjectContextPolicyResetCredentialScanWorkForTesting();
#endif
  CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
  DSHProjectContextSecretDecision *decision =
      [self.policy secretDecisionForData:data];
  CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - startedAt;
#if DEBUG
  NSUInteger workUnits = DSHProjectContextPolicyCredentialScanWorkForTesting();
#endif

  XCTAssertFalse(decision.suspectedSecret);
  XCTAssertNil(decision.omissionReason);
#if DEBUG
  XCTAssertLessThanOrEqual(workUnits, data.length * 8,
                           @"Scalar scan exceeded the linear work bound");
#endif
  XCTAssertLessThan(elapsed, DSHProjectContextDeadlineSeconds,
                    @"Scoped scalar near-miss exceeded the policy deadline");
}

- (void)testBracketScanMakesLinearProgressForMaximumUnterminatedInput {
  NSString *unterminated =
      [@"[" stringByPaddingToLength:DSHProjectContextMaxFileBytes
                         withString:@"["
                    startingAtIndex:0];
  NSData *data = [unterminated dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertEqual(data.length, DSHProjectContextMaxFileBytes);
#if DEBUG
  DSHProjectContextPolicyResetCredentialScanWorkForTesting();
#endif
  CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
  DSHProjectContextSecretDecision *decision =
      [self.policy secretDecisionForData:data];
  CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - startedAt;
#if DEBUG
  NSUInteger workUnits = DSHProjectContextPolicyCredentialScanWorkForTesting();
#endif
  XCTAssertFalse(decision.suspectedSecret);
#if DEBUG
  XCTAssertLessThanOrEqual(workUnits, data.length * 8,
                           @"Bracket scan exceeded the linear work bound");
#endif
  XCTAssertLessThan(elapsed, DSHProjectContextDeadlineSeconds,
                    @"Unterminated bracket input exceeded the deadline");
}

- (void)testSecretPolicyScansAnAdversarialMaximumSizeLineWithinAWorkBound {
  NSString *braceTail = [@"}" stringByPaddingToLength:24
                                              withString:@"}"
                                         startingAtIndex:0];
  NSString *fixture =
      [NSString stringWithFormat:@"\"pwd\":null%@,", braceTail];
  NSMutableString *line =
      [NSMutableString stringWithCapacity:DSHProjectContextMaxFileBytes];
  for (NSUInteger index = 0; index < 1560; index++) {
    [line appendString:fixture];
  }
  [line deleteCharactersInRange:NSMakeRange(line.length - 1, 1)];
  while (line.length < DSHProjectContextMaxFileBytes) {
    [line appendString:@" "];
  }

#if DEBUG
  DSHProjectContextPolicyResetCredentialScanWorkForTesting();
#endif
  CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
  DSHProjectContextSecretDecision *decision = [self.policy
      secretDecisionForData:[line dataUsingEncoding:NSUTF8StringEncoding]];
  CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - startedAt;
#if DEBUG
  NSUInteger workUnits = DSHProjectContextPolicyCredentialScanWorkForTesting();
#endif

  XCTAssertFalse(decision.suspectedSecret);
  XCTAssertNil(decision.omissionReason);
#if DEBUG
  XCTAssertLessThanOrEqual(workUnits, DSHProjectContextMaxFileBytes * 8,
                           @"Credential scanning exceeded the linear work bound");
#endif
  XCTAssertLessThan(elapsed, 5.0,
                    @"64 KiB secret scanning exceeded the broad smoke bound");
}

- (void)testSecretScanNeverReadsBeyondTheFileByteLimit {
  NSMutableData *data = [NSMutableData dataWithLength:DSHProjectContextMaxFileBytes];
  NSData *secret = [@"-----BEGIN PRIVATE KEY-----" dataUsingEncoding:NSUTF8StringEncoding];
  [data appendData:secret];

  DSHProjectContextSecretDecision *decision =
      [self.policy secretDecisionForData:data];
  XCTAssertFalse(decision.suspectedSecret);
  XCTAssertNil(decision.omissionReason);
}

- (void)testSecretScanHandlesUTF8CodePointSplitAtItsByteBoundary {
  NSMutableData *data = [[@"-----BEGIN PRIVATE KEY-----\n"
      dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  NSUInteger paddingLength = DSHProjectContextMaxFileBytes - data.length - 1;
  NSMutableData *padding = [NSMutableData dataWithLength:paddingLength];
  memset(padding.mutableBytes, 'a', padding.length);
  [data appendData:padding];
  const unsigned char utf8[] = {0xc3, 0xa9};
  [data appendBytes:utf8 length:sizeof(utf8)];

  DSHProjectContextSecretDecision *decision =
      [self.policy secretDecisionForData:data];
  XCTAssertTrue(decision.suspectedSecret);
  XCTAssertEqualObjects(decision.omissionReason,
                        DSHProjectContextOmissionReasonSuspectedSecret);
}

- (void)testCursorRoundTripRejectsTamperingAndStaleFingerprintsWithoutValuesInErrors {
  NSString *fingerprint = [@"a" stringByPaddingToLength:64
                                             withString:@"a"
                                        startingAtIndex:0];
  NSError *error = nil;
  NSString *cursor = [self.policy encodeCursorForSourceFingerprint:fingerprint
                                                            offset:42
                                                             error:&error];
  XCTAssertNotNil(cursor);
  XCTAssertNil(error);

  NSUInteger offset = 0;
  XCTAssertTrue([self.policy decodeCursor:cursor
                        sourceFingerprint:fingerprint
                                   offset:&offset
                                    error:&error]);
  XCTAssertEqual(offset, (NSUInteger)42);
  XCTAssertNil(error);

  NSString *first = [cursor substringToIndex:1];
  NSString *replacement = [first isEqualToString:@"A"] ? @"B" : @"A";
  NSString *tampered = [replacement stringByAppendingString:[cursor substringFromIndex:1]];
  XCTAssertFalse([self.policy decodeCursor:tampered
                         sourceFingerprint:fingerprint
                                    offset:&offset
                                     error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidCursor);
  XCTAssertFalse([error.description containsString:fingerprint]);

  error = nil;
  NSString *staleFingerprint = [@"b" stringByPaddingToLength:64
                                                   withString:@"b"
                                              startingAtIndex:0];
  XCTAssertFalse([self.policy decodeCursor:cursor
                         sourceFingerprint:staleFingerprint
                                    offset:&offset
                                     error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorStaleCursor);
  XCTAssertFalse([error.description containsString:staleFingerprint]);
}

- (void)testCursorRejectsNonCanonicalBase64TextTampering {
  NSError *error = nil;
  NSString *cursor =
      [self.policy encodeCursorForSourceFingerprint:@"canonical-fingerprint"
                                             offset:7
                                              error:&error];
  XCTAssertNotNil(cursor);
  XCTAssertNil(error);

  NSString *alphabet =
      @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  unichar finalCharacter = [cursor characterAtIndex:cursor.length - 1];
  NSRange finalRange = [alphabet rangeOfString:[NSString stringWithCharacters:&finalCharacter
                                                                        length:1]];
  XCTAssertNotEqual(finalRange.location, NSNotFound);
  NSUInteger groupStart = (finalRange.location / 16) * 16;
  NSUInteger alternateIndex = groupStart + ((finalRange.location - groupStart + 1) % 16);
  NSString *alternate = [alphabet substringWithRange:NSMakeRange(alternateIndex, 1)];
  NSString *tampered = [[cursor substringToIndex:cursor.length - 1]
      stringByAppendingString:alternate];
  XCTAssertNotEqualObjects(tampered, cursor);

  NSUInteger offset = 0;
  XCTAssertFalse([self.policy decodeCursor:tampered
                         sourceFingerprint:@"canonical-fingerprint"
                                    offset:&offset
                                     error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidCursor);
}

- (void)testCursorRejectsWrongLengthAndIllegalTextBeforeTraversalOrDecode {
  NSString *fingerprint = @"cursor-boundary-fingerprint";
  NSError *error = nil;
  NSString *valid = [self.policy encodeCursorForSourceFingerprint:fingerprint
                                                           offset:1
                                                            error:&error];
  XCTAssertEqual(valid.length, (NSUInteger)98);

  NSUInteger offset = 0;
  NSString *shortCursor = [valid substringToIndex:valid.length - 1];
  XCTAssertFalse([self.policy decodeCursor:shortCursor
                         sourceFingerprint:fingerprint
                                    offset:&offset
                                     error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidCursor);

  NSString *illegal = [@"!" stringByAppendingString:[valid substringFromIndex:1]];
  XCTAssertFalse([self.policy decodeCursor:illegal
                         sourceFingerprint:fingerprint
                                    offset:&offset
                                     error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidCursor);

  NSString *padded = [valid stringByAppendingString:@"="];
  XCTAssertFalse([self.policy decodeCursor:padded
                         sourceFingerprint:fingerprint
                                    offset:&offset
                                     error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidCursor);

  NSString *overlong = [@"A" stringByPaddingToLength:(1024 * 1024)
                                           withString:@"A"
                                      startingAtIndex:0];
  XCTAssertFalse([self.policy decodeCursor:overlong
                         sourceFingerprint:fingerprint
                                    offset:&offset
                                     error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidCursor);

  DSHLengthOnlyCursorString *probe =
      [[DSHLengthOnlyCursorString alloc] initWithReportedLength:(1024 * 1024)];
  __block BOOL probeResult = YES;
  XCTAssertNoThrow(probeResult = [self.policy decodeCursor:probe
                                     sourceFingerprint:fingerprint
                                                offset:&offset
                                                 error:&error]);
  XCTAssertFalse(probeResult);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidCursor);

  for (id invalidCursor in @[ NSNull.null, @42 ]) {
    __block BOOL invalidResult = YES;
    XCTAssertNoThrow(invalidResult =
                         [self.policy decodeCursor:(NSString *)invalidCursor
                                sourceFingerprint:fingerprint
                                           offset:&offset
                                            error:&error]);
    XCTAssertFalse(invalidResult);
    XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidCursor);
    XCTAssertFalse(
        [error.description containsString:[invalidCursor description]]);
  }
}

- (void)testPublicStringInputsAreBoundedBeforeNormalization {
  XCTAssertEqual(DSHProjectContextMaxRelativePathCharacters, (NSUInteger)4096);
  XCTAssertEqual(DSHProjectContextMaxQueryCharacters, (NSUInteger)256);
  XCTAssertEqual(DSHProjectContextMaxSourceFingerprintCharacters,
                 (NSUInteger)256);
  const NSUInteger maxPathCharacters =
      DSHProjectContextMaxRelativePathCharacters;
  const NSUInteger maxQueryCharacters = DSHProjectContextMaxQueryCharacters;
  const NSUInteger maxFingerprintCharacters =
      DSHProjectContextMaxSourceFingerprintCharacters;

  NSString *pathSuffix = @".swift";
  NSString *pathAtLimit = [[@"a"
      stringByPaddingToLength:maxPathCharacters - pathSuffix.length
                   withString:@"a"
              startingAtIndex:0] stringByAppendingString:pathSuffix];
  XCTAssertEqual(pathAtLimit.length, maxPathCharacters);
  XCTAssertTrue([self.policy decisionForRelativePath:pathAtLimit].eligible);

  NSString *pathOverLimit = [@"a" stringByAppendingString:pathAtLimit];
  DSHProjectContextPathDecision *pathDecision =
      [self.policy decisionForRelativePath:pathOverLimit];
  XCTAssertFalse(pathDecision.eligible);
  XCTAssertEqualObjects(pathDecision.omissionReason,
                        DSHProjectContextOmissionReasonPolicy);

  DSHLengthOnlyCursorString *hostile =
      [[DSHLengthOnlyCursorString alloc] initWithReportedLength:(1024 * 1024)];
  __block DSHProjectContextPathDecision *hostilePathDecision = nil;
  XCTAssertNoThrow(hostilePathDecision =
                       [self.policy decisionForRelativePath:hostile]);
  XCTAssertFalse(hostilePathDecision.eligible);

  NSDictionary<NSString *, id> *candidate =
      [self candidateWithPath:@"README.md"
                         size:1
                     revision:@"revision"
                      gitState:@"unchanged"
                      eligible:YES
                 omissionReason:NSNull.null];
  NSString *queryAtLimit = [@"q" stringByPaddingToLength:maxQueryCharacters
                                               withString:@"q"
                                          startingAtIndex:0];
  NSError *error = nil;
  XCTAssertNotNil([self.policy candidatePageForCandidates:@[ candidate ]
                                                     query:queryAtLimit
                                         sourceFingerprint:@"bounded-query-fingerprint"
                                                    cursor:nil
                                                     limit:1
                                                     error:&error]);
  NSString *queryOverLimit = [queryAtLimit stringByAppendingString:@"q"];
  XCTAssertNil([self.policy candidatePageForCandidates:@[ candidate ]
                                                  query:queryOverLimit
                                      sourceFingerprint:@"bounded-query-fingerprint"
                                                 cursor:nil
                                                  limit:1
                                                  error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidArgument);

  __block NSDictionary<NSString *, id> *hostileQueryPage = nil;
  XCTAssertNoThrow(hostileQueryPage =
                       [self.policy candidatePageForCandidates:@[ candidate ]
                                                         query:hostile
                                             sourceFingerprint:@"bounded-query-fingerprint"
                                                        cursor:nil
                                                         limit:1
                                                         error:&error]);
  XCTAssertNil(hostileQueryPage);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidArgument);

  NSString *fingerprintAtLimit =
      [@"f" stringByPaddingToLength:maxFingerprintCharacters
                          withString:@"f"
                     startingAtIndex:0];
  XCTAssertNotNil([self.policy encodeCursorForSourceFingerprint:fingerprintAtLimit
                                                         offset:1
                                                          error:&error]);
  NSString *fingerprintOverLimit =
      [fingerprintAtLimit stringByAppendingString:@"f"];
  XCTAssertNil([self.policy encodeCursorForSourceFingerprint:fingerprintOverLimit
                                                      offset:1
                                                       error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidArgument);

  __block NSString *hostileCursor = nil;
  XCTAssertNoThrow(hostileCursor =
                       [self.policy encodeCursorForSourceFingerprint:hostile
                                                              offset:1
                                                               error:&error]);
  XCTAssertNil(hostileCursor);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidArgument);
}

- (void)testCandidatePagesAreMetadataOnlySortedBoundedAndDeterministic {
  NSMutableArray<NSDictionary<NSString *, id> *> *input = [NSMutableArray array];
  for (NSInteger index = 204; index >= 0; index--) {
    NSString *path = [NSString stringWithFormat:@"src/File%03ld.swift", (long)index];
    [input addObject:[self candidateWithPath:path
                                       size:(NSUInteger)(index + 1)
                                   revision:[NSString stringWithFormat:@"r%03ld", (long)index]
                                    gitState:@"unchanged"
                                    eligible:YES
                               omissionReason:NSNull.null]];
  }

  NSString *fingerprint = [@"c" stringByPaddingToLength:64
                                             withString:@"c"
                                        startingAtIndex:0];
  NSError *error = nil;
  NSDictionary<NSString *, id> *first =
      [self.policy candidatePageForCandidates:input
                                        query:@""
                            sourceFingerprint:fingerprint
                                       cursor:nil
                                        limit:250
                                        error:&error];
  XCTAssertNotNil(first);
  XCTAssertNil(error);
  NSArray<NSDictionary<NSString *, id> *> *firstCandidates = first[@"candidates"];
  XCTAssertEqual(firstCandidates.count, (NSUInteger)100);
  XCTAssertEqualObjects(firstCandidates.firstObject[@"path"], @"src/File000.swift");
  XCTAssertEqualObjects(firstCandidates.lastObject[@"path"], @"src/File099.swift");
  XCTAssertNotNil(first[@"next_cursor"]);
  XCTAssertNil(firstCandidates.firstObject[@"content"]);
  XCTAssertNil(firstCandidates.firstObject[@"sample"]);
  XCTAssertEqual(firstCandidates.firstObject.count, (NSUInteger)6);

  NSDictionary<NSString *, id> *repeated =
      [self.policy candidatePageForCandidates:input
                                        query:@""
                            sourceFingerprint:fingerprint
                                       cursor:nil
                                        limit:250
                                        error:&error];
  XCTAssertEqualObjects(repeated, first);

  NSDictionary<NSString *, id> *second =
      [self.policy candidatePageForCandidates:input
                                        query:@""
                            sourceFingerprint:fingerprint
                                       cursor:first[@"next_cursor"]
                                        limit:250
                                        error:&error];
  NSArray<NSDictionary<NSString *, id> *> *secondCandidates = second[@"candidates"];
  XCTAssertEqual(secondCandidates.count, (NSUInteger)100);
  XCTAssertEqualObjects(secondCandidates.firstObject[@"path"], @"src/File100.swift");
  XCTAssertEqualObjects(secondCandidates.lastObject[@"path"], @"src/File199.swift");

  NSDictionary<NSString *, id> *third =
      [self.policy candidatePageForCandidates:input
                                        query:@""
                            sourceFingerprint:fingerprint
                                       cursor:second[@"next_cursor"]
                                        limit:250
                                        error:&error];
  NSArray<NSDictionary<NSString *, id> *> *thirdCandidates = third[@"candidates"];
  XCTAssertEqual(thirdCandidates.count, (NSUInteger)5);
  XCTAssertEqualObjects(thirdCandidates.firstObject[@"path"], @"src/File200.swift");
  XCTAssertEqualObjects(thirdCandidates.lastObject[@"path"], @"src/File204.swift");
  XCTAssertEqualObjects(third[@"next_cursor"], NSNull.null);
}

- (void)testCandidatePaginationEnforcesTheEntryBudgetBeforeFilteringOrSorting {
  NSDictionary<NSString *, id> *candidate =
      [self candidateWithPath:@"Sources/App.swift"
                         size:1
                     revision:@"revision"
                      gitState:@"unchanged"
                      eligible:YES
                 omissionReason:NSNull.null];
  NSMutableArray<NSDictionary<NSString *, id> *> *candidates =
      [NSMutableArray arrayWithCapacity:DSHProjectContextMaxEntries + 1];
  for (NSUInteger index = 0; index < DSHProjectContextMaxEntries; index++) {
    [candidates addObject:candidate];
  }

  NSError *error = nil;
  NSDictionary<NSString *, id> *atLimit =
      [self.policy candidatePageForCandidates:candidates
                                        query:@""
                            sourceFingerprint:@"entry-budget-fingerprint"
                                       cursor:nil
                                        limit:1
                                        error:&error];
  XCTAssertNotNil(atLimit);
  XCTAssertNil(error);

  [candidates addObject:candidate];
  NSDictionary<NSString *, id> *overLimit =
      [self.policy candidatePageForCandidates:candidates
                                        query:@""
                            sourceFingerprint:@"entry-budget-fingerprint"
                                       cursor:nil
                                        limit:1
                                        error:&error];
  XCTAssertNil(overLimit);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorBudgetExceeded);
  XCTAssertEqualObjects(error.localizedDescription,
                        @"Project context policy budget exceeded.");
  XCTAssertFalse([error.description containsString:@"Sources/App.swift"]);
}

- (void)testCandidateSchemaRejectsInvalidDomainsAndAcceptsSafeIntegerSizeEdge {
  NSDictionary<NSString *, id> *valid =
      [self candidateWithPath:@"schema-marker.swift"
                         size:1
                     revision:@"revision"
                      gitState:@"unchanged"
                      eligible:YES
                 omissionReason:NSNull.null];
  NSMutableArray<NSDictionary<NSString *, id> *> *invalidCandidates =
      [NSMutableArray array];

  NSArray<id> *invalidSizes = @[
    @(-1), @(1.5), @(NAN), @(INFINITY), @YES,
    @(9007199254740992ULL),
    [NSDecimalNumber decimalNumberWithString:@"18446744073709551616"],
  ];
  for (id size in invalidSizes) {
    NSMutableDictionary<NSString *, id> *candidate = [valid mutableCopy];
    candidate[@"size"] = size;
    [invalidCandidates addObject:candidate];
  }

  NSMutableDictionary<NSString *, id> *numericEligible = [valid mutableCopy];
  numericEligible[@"eligible"] = [NSNumber numberWithInt:1];
  [invalidCandidates addObject:numericEligible];

  NSMutableDictionary<NSString *, id> *invalidState = [valid mutableCopy];
  invalidState[@"git_state"] = @"modified";
  [invalidCandidates addObject:invalidState];

  NSMutableDictionary<NSString *, id> *invalidReason = [valid mutableCopy];
  invalidReason[@"eligible"] = @NO;
  invalidReason[@"omission_reason"] = @"made_up";
  [invalidCandidates addObject:invalidReason];

  NSMutableDictionary<NSString *, id> *eligibleWithReason = [valid mutableCopy];
  eligibleWithReason[@"omission_reason"] = DSHProjectContextOmissionReasonSecretPath;
  [invalidCandidates addObject:eligibleWithReason];

  NSMutableDictionary<NSString *, id> *ineligibleWithoutReason = [valid mutableCopy];
  ineligibleWithoutReason[@"eligible"] = @NO;
  [invalidCandidates addObject:ineligibleWithoutReason];

  NSMutableDictionary<NSString *, id> *emptyPath = [valid mutableCopy];
  emptyPath[@"path"] = @"";
  [invalidCandidates addObject:emptyPath];

  NSMutableDictionary<NSString *, id> *nonStringPath = [valid mutableCopy];
  nonStringPath[@"path"] = @1;
  [invalidCandidates addObject:nonStringPath];

  for (NSString *unsafePath in @[
         @"/private/secret.swift", @"../secret.swift", @"src/../secret.swift",
         @"src/line\nbreak.swift"
       ]) {
    NSMutableDictionary<NSString *, id> *candidate = [valid mutableCopy];
    candidate[@"path"] = unsafePath;
    [invalidCandidates addObject:candidate];
  }

  NSMutableDictionary<NSString *, id> *emptyRevision = [valid mutableCopy];
  emptyRevision[@"revision"] = @"";
  [invalidCandidates addObject:emptyRevision];

  NSMutableDictionary<NSString *, id> *nonStringRevision = [valid mutableCopy];
  nonStringRevision[@"revision"] = @1;
  [invalidCandidates addObject:nonStringRevision];

  NSString *oversized = [@"x" stringByPaddingToLength:(1024 * 1024)
                                            withString:@"x"
                                       startingAtIndex:0];
  NSMutableDictionary<NSString *, id> *oversizedPath = [valid mutableCopy];
  oversizedPath[@"path"] = oversized;
  [invalidCandidates addObject:oversizedPath];

  NSMutableDictionary<NSString *, id> *oversizedRevision = [valid mutableCopy];
  oversizedRevision[@"revision"] = oversized;
  [invalidCandidates addObject:oversizedRevision];

  DSHLengthOnlyCursorString *hostileMetadata =
      [[DSHLengthOnlyCursorString alloc] initWithReportedLength:(1024 * 1024)];
  NSMutableDictionary<NSString *, id> *oversizedGitState = [valid mutableCopy];
  oversizedGitState[@"git_state"] = hostileMetadata;
  [invalidCandidates addObject:oversizedGitState];

  NSMutableDictionary<NSString *, id> *oversizedOmissionReason =
      [valid mutableCopy];
  oversizedOmissionReason[@"eligible"] = @NO;
  oversizedOmissionReason[@"omission_reason"] = hostileMetadata;
  [invalidCandidates addObject:oversizedOmissionReason];

  NSMutableDictionary<NSString *, id> *extraKey = [valid mutableCopy];
  extraKey[@"content"] = @"raw-secret-marker";
  [invalidCandidates addObject:extraKey];

  NSMutableDictionary<NSString *, id> *missingKey = [valid mutableCopy];
  [missingKey removeObjectForKey:@"revision"];
  [invalidCandidates addObject:missingKey];

  for (NSUInteger index = 0; index < invalidCandidates.count; index++) {
    NSError *error = nil;
    NSDictionary<NSString *, id> *page =
        [self.policy candidatePageForCandidates:@[ invalidCandidates[index] ]
                                          query:@""
                              sourceFingerprint:@"candidate-schema-fingerprint"
                                         cursor:nil
                                          limit:1
                                          error:&error];
    XCTAssertNil(page, @"Invalid candidate fixture %lu was accepted",
                 (unsigned long)index);
    XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidArgument);
    XCTAssertFalse([error.description containsString:@"schema-marker"]);
    XCTAssertFalse([error.description containsString:@"raw-secret-marker"]);
  }

  NSMutableDictionary<NSString *, id> *validEdge = [valid mutableCopy];
  validEdge[@"size"] = @(9007199254740991ULL);
  validEdge[@"eligible"] = @NO;
  validEdge[@"omission_reason"] =
      DSHProjectContextOmissionReasonBudgetExceeded;
  NSError *error = nil;
  NSDictionary<NSString *, id> *page =
      [self.policy candidatePageForCandidates:@[ validEdge ]
                                        query:@""
                            sourceFingerprint:@"candidate-schema-fingerprint"
                                       cursor:nil
                                        limit:1
                                        error:&error];
  XCTAssertNotNil(page);
  XCTAssertNil(error);
  XCTAssertEqualObjects([page[@"candidates"] firstObject][@"size"],
                        @(9007199254740991ULL));
}

- (void)testCandidatePageRejectsForgedEligibleMetadataForDeniedPaths {
  NSArray<NSString *> *forgedPaths = @[
    @".env.production",
    @".git/config",
    @"node_modules/pkg.js",
  ];
  for (NSString *path in forgedPaths) {
    NSDictionary<NSString *, id> *forged =
        [self candidateWithPath:path
                           size:1
                       revision:@"forged-revision"
                        gitState:@"unchanged"
                        eligible:YES
                   omissionReason:NSNull.null];
    NSError *error = nil;
    NSDictionary<NSString *, id> *page =
        [self.policy candidatePageForCandidates:@[ forged ]
                                          query:@""
                              sourceFingerprint:@"forged-policy-fingerprint"
                                         cursor:nil
                                          limit:1
                                          error:&error];
    XCTAssertNil(page, @"Denied path was returned as selectable: %@", path);
    XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidArgument);
    XCTAssertFalse([error.description containsString:path]);
  }
}

- (void)testCandidatePageEnforcesFileSizeEligibilityBoundary {
  NSDictionary<NSString *, id> *atLimit =
      [self candidateWithPath:@"Sources/AtLimit.swift"
                         size:DSHProjectContextMaxFileBytes
                     revision:@"at-limit"
                      gitState:@"unchanged"
                      eligible:YES
                 omissionReason:NSNull.null];
  NSError *error = nil;
  NSDictionary<NSString *, id> *atLimitPage =
      [self.policy candidatePageForCandidates:@[ atLimit ]
                                        query:@""
                            sourceFingerprint:@"size-bound-fingerprint"
                                       cursor:nil
                                        limit:1
                                        error:&error];
  XCTAssertNotNil(atLimitPage);
  XCTAssertNil(error);

  NSDictionary<NSString *, id> *forgedOverLimit =
      [self candidateWithPath:@"Sources/TooLarge.swift"
                         size:DSHProjectContextMaxFileBytes + 1
                     revision:@"too-large"
                      gitState:@"unchanged"
                      eligible:YES
                 omissionReason:NSNull.null];
  NSDictionary<NSString *, id> *forgedPage =
      [self.policy candidatePageForCandidates:@[ forgedOverLimit ]
                                        query:@""
                            sourceFingerprint:@"size-bound-fingerprint"
                                       cursor:nil
                                        limit:1
                                        error:&error];
  XCTAssertNil(forgedPage);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidArgument);

  NSDictionary<NSString *, id> *omittedOverLimit =
      [self candidateWithPath:@"Sources/TooLarge.swift"
                         size:DSHProjectContextMaxFileBytes + 1
                     revision:@"too-large"
                      gitState:@"unchanged"
                      eligible:NO
                 omissionReason:DSHProjectContextOmissionReasonBudgetExceeded];
  NSDictionary<NSString *, id> *omittedPage =
      [self.policy candidatePageForCandidates:@[ omittedOverLimit ]
                                        query:@""
                            sourceFingerprint:@"size-bound-fingerprint"
                                       cursor:nil
                                        limit:1
                                        error:&error];
  XCTAssertNotNil(omittedPage);
  XCTAssertEqualObjects([omittedPage[@"candidates"] firstObject][@"eligible"],
                        @NO);
  XCTAssertEqualObjects(
      [omittedPage[@"candidates"] firstObject][@"omission_reason"],
      DSHProjectContextOmissionReasonBudgetExceeded);

  NSDictionary<NSString *, id> *largeLockfile =
      [self candidateWithPath:@"package-lock.json"
                         size:DSHProjectContextMaxFileBytes + 1
                     revision:@"large-lockfile"
                      gitState:@"unchanged"
                      eligible:NO
                 omissionReason:DSHProjectContextOmissionReasonLockfile];
  NSDictionary<NSString *, id> *largeLockfilePage =
      [self.policy candidatePageForCandidates:@[ largeLockfile ]
                                        query:@""
                            sourceFingerprint:@"size-bound-fingerprint"
                                       cursor:nil
                                        limit:1
                                        error:&error];
  XCTAssertNotNil(largeLockfilePage);
  XCTAssertNil(error);
  XCTAssertEqualObjects(
      [largeLockfilePage[@"candidates"] firstObject][@"omission_reason"],
      DSHProjectContextOmissionReasonLockfile);
}

- (void)testCandidatePaginationDoesNotTrustContainerCountOverrides {
  NSDictionary<NSString *, id> *valid =
      [self candidateWithPath:@"Sources/Bounded.swift"
                         size:1
                     revision:@"bounded"
                      gitState:@"unchanged"
                      eligible:YES
                 omissionReason:NSNull.null];
  DSHMisreportingCandidateArray *candidates =
      [[DSHMisreportingCandidateArray alloc]
          initWithRepeatedObject:valid
          actualEnumerationCount:DSHProjectContextMaxEntries + 1];
  NSError *error = nil;
  __block NSDictionary<NSString *, id> *page = nil;
  XCTAssertNoThrow(page =
                       [self.policy candidatePageForCandidates:(NSArray *)candidates
                                                         query:@""
                                             sourceFingerprint:@"hostile-array-fingerprint"
                                                        cursor:nil
                                                         limit:1
                                                         error:&error]);
  XCTAssertNil(page);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorBudgetExceeded);
  XCTAssertLessThanOrEqual(candidates.enumeratedObjectCount,
                           DSHProjectContextMaxEntries + 1);

  DSHMisreportingCandidateDictionary *candidate =
      [[DSHMisreportingCandidateDictionary alloc] initWithBacking:valid];
  XCTAssertNoThrow(page = [self.policy
                       candidatePageForCandidates:@[ (NSDictionary *)candidate ]
                                            query:@""
                                sourceFingerprint:@"hostile-map-fingerprint"
                                           cursor:nil
                                            limit:1
                                            error:&error]);
  XCTAssertNil(page);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidArgument);
}

- (void)testCandidatePageDeepCopiesAndCanonicalizesMutableMetadata {
  NSMutableString *path = [@".env.production" mutableCopy];
  NSMutableString *revision = [@"mutable-revision" mutableCopy];
  NSMutableString *gitState = [@"unchanged" mutableCopy];
  NSMutableString *omissionReason =
      [DSHProjectContextOmissionReasonSecretPath mutableCopy];
  DSHMutableUnsignedNumber *size =
      [[DSHMutableUnsignedNumber alloc] initWithValue:10];
  NSDictionary<NSString *, id> *candidate = @{
    @"path" : path,
    @"size" : size,
    @"revision" : revision,
    @"git_state" : gitState,
    @"eligible" : @NO,
    @"omission_reason" : omissionReason,
  };

  NSError *error = nil;
  NSDictionary<NSString *, id> *page =
      [self.policy candidatePageForCandidates:@[ candidate ]
                                        query:@""
                            sourceFingerprint:@"deep-copy-fingerprint"
                                       cursor:nil
                                        limit:1
                                        error:&error];
  XCTAssertNotNil(page);
  XCTAssertNil(error);
  NSDictionary<NSString *, id> *snapshot = [page[@"candidates"] firstObject];

  [path setString:@"safe.swift"];
  [revision setString:@"changed-revision"];
  [gitState setString:@"staged"];
  [omissionReason setString:DSHProjectContextOmissionReasonPolicy];
  size.mutableValue = 20;

  XCTAssertEqualObjects(snapshot[@"path"], @".env.production");
  XCTAssertEqualObjects(snapshot[@"revision"], @"mutable-revision");
  XCTAssertEqualObjects(snapshot[@"git_state"], @"unchanged");
  XCTAssertEqualObjects(snapshot[@"omission_reason"],
                        DSHProjectContextOmissionReasonSecretPath);
  XCTAssertEqualObjects(snapshot[@"size"], @10);
  XCTAssertNotEqual(snapshot[@"path"], path);
  XCTAssertNotEqual(snapshot[@"size"], size);

  DSHFlappingUnsignedNumber *flappingSize =
      [[DSHFlappingUnsignedNumber alloc] initWithValue:1];
  NSDictionary<NSString *, id> *flappingCandidate = @{
    @"path" : @"Sources/Flapping.swift",
    @"size" : flappingSize,
    @"revision" : @"flapping-revision",
    @"git_state" : @"unchanged",
    @"eligible" : @YES,
    @"omission_reason" : NSNull.null,
  };
  NSDictionary<NSString *, id> *flappingPage =
      [self.policy candidatePageForCandidates:@[ flappingCandidate ]
                                        query:@""
                            sourceFingerprint:@"flapping-size-fingerprint"
                                       cursor:nil
                                        limit:1
                                        error:&error];
  XCTAssertNotNil(flappingPage);
  XCTAssertNil(error);
  XCTAssertEqualObjects([flappingPage[@"candidates"] firstObject][@"size"],
                        @1);
}

- (void)testCandidateCursorIsBoundToTheNormalizedSearchQuery {
  NSArray<NSDictionary<NSString *, id> *> *candidates = @[
    [self candidateWithPath:@"docs/Caf\u00e9-A.md"
                       size:1
                   revision:@"revision-a"
                    gitState:@"unchanged"
                    eligible:YES
               omissionReason:NSNull.null],
    [self candidateWithPath:@"docs/Caf\u00e9-B.md"
                       size:2
                   revision:@"revision-b"
                    gitState:@"unchanged"
                    eligible:YES
               omissionReason:NSNull.null],
  ];
  NSError *error = nil;
  NSDictionary<NSString *, id> *first =
      [self.policy candidatePageForCandidates:candidates
                                        query:@"CAFE\u0301"
                            sourceFingerprint:@"query-bound-fingerprint"
                                       cursor:nil
                                        limit:1
                                        error:&error];
  NSString *cursor = first[@"next_cursor"];
  XCTAssertNotNil(cursor);

  NSDictionary<NSString *, id> *sameNormalizedQuery =
      [self.policy candidatePageForCandidates:candidates
                                        query:@"caf\u00e9"
                            sourceFingerprint:@"query-bound-fingerprint"
                                       cursor:cursor
                                        limit:1
                                        error:&error];
  XCTAssertNotNil(sameNormalizedQuery);
  XCTAssertEqualObjects([sameNormalizedQuery[@"candidates"] firstObject][@"path"],
                        @"docs/Caf\u00e9-B.md");

  NSDictionary<NSString *, id> *crossQuery =
      [self.policy candidatePageForCandidates:candidates
                                        query:@"docs"
                            sourceFingerprint:@"query-bound-fingerprint"
                                       cursor:cursor
                                        limit:1
                                        error:&error];
  XCTAssertNil(crossQuery);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorInvalidCursor);
  XCTAssertFalse([error.description containsString:@"docs"]);
}

- (void)testCandidateSearchNormalizesUnicodeAndPreservesEligibilityMetadata {
  NSString *decomposedPath = @"docs/Cafe\u0301.md";
  NSDictionary<NSString *, id> *eligible =
      [self candidateWithPath:decomposedPath
                         size:17
                     revision:@"rev-safe"
                      gitState:@"staged"
                      eligible:YES
                 omissionReason:NSNull.null];
  NSDictionary<NSString *, id> *omitted =
      [self candidateWithPath:@"config/.env.production"
                         size:31
                     revision:@"rev-secret"
                      gitState:@"unstaged"
                      eligible:NO
                 omissionReason:DSHProjectContextOmissionReasonSecretPath];

  NSError *error = nil;
  NSDictionary<NSString *, id> *unicodePage =
      [self.policy candidatePageForCandidates:@[ omitted, eligible ]
                                        query:@"CAF\u00c9"
                            sourceFingerprint:@"fingerprint-unicode"
                                       cursor:nil
                                        limit:100
                                        error:&error];
  NSArray<NSDictionary<NSString *, id> *> *unicodeCandidates =
      unicodePage[@"candidates"];
  XCTAssertEqual(unicodeCandidates.count, (NSUInteger)1);
  XCTAssertEqualObjects(unicodeCandidates[0][@"path"], @"docs/Caf\u00e9.md");
  XCTAssertEqualObjects(unicodeCandidates[0][@"eligible"], @YES);
  XCTAssertEqualObjects(unicodeCandidates[0][@"omission_reason"], NSNull.null);

  NSDictionary<NSString *, id> *omittedPage =
      [self.policy candidatePageForCandidates:@[ eligible, omitted ]
                                        query:@".ENV"
                            sourceFingerprint:@"fingerprint-omitted"
                                       cursor:nil
                                        limit:100
                                        error:&error];
  NSArray<NSDictionary<NSString *, id> *> *omittedCandidates =
      omittedPage[@"candidates"];
  XCTAssertEqual(omittedCandidates.count, (NSUInteger)1);
  XCTAssertEqualObjects(omittedCandidates[0][@"eligible"], @NO);
  XCTAssertEqualObjects(omittedCandidates[0][@"omission_reason"],
                        DSHProjectContextOmissionReasonSecretPath);
  XCTAssertNil(omittedCandidates[0][@"content"]);
  XCTAssertNil(omittedCandidates[0][@"sample"]);
}

- (void)testCandidatePageRejectsCursorFromAStaleSourceFingerprint {
  NSArray<NSDictionary<NSString *, id> *> *input = @[
    [self candidateWithPath:@"README.md"
                       size:8
                   revision:@"rev-1"
                    gitState:@"unchanged"
                    eligible:YES
               omissionReason:NSNull.null],
    [self candidateWithPath:@"Sources/App.swift"
                       size:9
                   revision:@"rev-2"
                    gitState:@"unchanged"
                    eligible:YES
               omissionReason:NSNull.null],
  ];
  NSError *error = nil;
  NSDictionary<NSString *, id> *first =
      [self.policy candidatePageForCandidates:input
                                        query:@""
                            sourceFingerprint:@"fingerprint-a"
                                       cursor:nil
                                        limit:1
                                        error:&error];
  XCTAssertNotNil(first[@"next_cursor"]);

  NSDictionary<NSString *, id> *stale =
      [self.policy candidatePageForCandidates:input
                                        query:@""
                            sourceFingerprint:@"fingerprint-b"
                                       cursor:first[@"next_cursor"]
                                        limit:1
                                        error:&error];
  XCTAssertNil(stale);
  XCTAssertEqual(error.code, DSHProjectContextPolicyErrorStaleCursor);
  XCTAssertFalse([error.description containsString:@"fingerprint-a"]);
  XCTAssertFalse([error.description containsString:@"fingerprint-b"]);
}

@end
