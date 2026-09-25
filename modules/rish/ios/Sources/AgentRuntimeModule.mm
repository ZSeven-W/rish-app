#import <Foundation/Foundation.h>
#import <React/RCTBridge.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <UIKit/UIKit.h>
#import <os/log.h>

#import "AgentExecutionLedger.h"
#import "AgentGitToolExecutor.h"
#import "AgentNativeWAL.h"
#import "AgentPreparedAttemptStore.h"
#import "AgentProviderRoundService.h"
#import "AgentRootResolver.h"
#import "AgentRoundJournal.h"
#import "AgentRuntimeCoordinator.h"
#import "AgentRuntimeToolContracts.h"
#import "AgentToolBatchService.h"
#import "AgentToolExecutionService.h"
#import "AgentTranscriptStore.h"
#import "AgentWorkspaceToolExecutor.h"
#import "DSHCompletionProviderTransport.h"
#import "LocalProjectAccess.h"
#import "LocalWorkspaceAccess.h"
#import "ProjectContextService.h"
#import "SessionSnapshotStore.h"
#import "DSHGitPushSupport.h"
#import "SessionWorkspaceCoordinator.h"

typedef NSDictionary *_Nullable (^DSHRuntimeModuleInvoke)(
    id<DSHAgentRuntimeCoordinating> coordinator, NSDictionary *request,
    NSError **error);

@interface DSHProjectContextService (DSHAgentRuntimeComposition)
@property(nonatomic, strong, readonly) DSHLocalProjectAccess *projectAccess;
@property(nonatomic, strong, readonly, nullable)
    DSHLocalWorkspaceAccess *workspaceAccess;
@end

@interface NSObject (DSHAgentRuntimeLocalRuntimeComposition)
@property(nonatomic, strong, readonly)
    DSHCompletionProviderTransport *completionProviderTransport;
@property(nonatomic, strong, readonly)
    DSHCompletionProviderTransport *claudeProviderTransport;
@property(nonatomic, strong, readonly)
    DSHCompletionProviderTransport *codexProviderTransport;
@property(nonatomic, strong, readonly)
    DSHCompletionProviderTransport *glmProviderTransport;
@property(nonatomic, strong, readonly)
    DSHProjectContextService *projectContextService;
@property(nonatomic, readonly) NSUInteger credentialGeneration;
- (nullable NSString *)credential;
- (nullable NSString *)credentialForHarnessId:(NSString *)harnessId
                                   generation:(NSUInteger *)generation;
- (nullable DSHCompletionProviderTransport *)providerTransportForHarnessId:(NSString *)harnessId;
@end

static DSHAgentNativeWAL *DSHRuntimeSharedWAL(void) {
  static DSHAgentNativeWAL *wal;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSError *error = nil;
    NSURL *support = [NSFileManager.defaultManager
        URLForDirectory:NSApplicationSupportDirectory
               inDomain:NSUserDomainMask
      appropriateForURL:nil create:YES error:&error];
    if (support == nil) return;
    NSURL *agentRoot = [support
        URLByAppendingPathComponent:@"agent-runtime" isDirectory:YES]
        .URLByStandardizingPath;
    wal = [[DSHAgentNativeWAL alloc]
        initWithRootURL:agentRoot
                  clock:^NSDate * { return NSDate.date; }
     identifierGenerator:^NSString * {
       return NSUUID.UUID.UUIDString.lowercaseString;
     }
              faultHook:nil];
  });
  return wal;
}

static NSDictionary *DSHRuntimeLoadSession(DSHSessionSnapshotStore *store,
                                           NSError **error) {
  NSDictionary *load = [store loadSessionSnapshotWithError:error];
  if (![load[@"status"] isEqualToString:@"present"] ||
      ![load[@"session_json"] isKindOfClass:NSString.class]) {
    if (error != nullptr && *error == nil) {
      *error = DSHAgentNativeStoreError(DSHAgentNativeStoreErrorConflict);
    }
    return nil;
  }
  NSData *data = [load[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding];
  id value = data == nil ? nil :
      [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![value isKindOfClass:NSDictionary.class]) {
    if (error != nullptr) {
      *error = DSHAgentNativeStoreError(DSHAgentNativeStoreErrorCorrupt);
    }
    return nil;
  }
  return value;
}

static NSDictionary *DSHRuntimeConversation(NSDictionary *session,
                                            NSString *conversationId) {
  for (NSDictionary *conversation in session[@"conversations"]) {
    if ([conversation[@"id"] isEqual:conversationId]) return conversation;
  }
  return nil;
}

static NSDictionary *DSHRuntimeAttempt(NSDictionary *conversation,
                                       NSString *attemptId) {
  for (NSDictionary *attempt in conversation[@"attempts"]) {
    if ([attempt[@"attempt_id"] isEqual:attemptId]) return attempt;
  }
  return nil;
}

static NSArray *DSHRuntimeVisibleHistory(DSHSessionSnapshotStore *store,
                                         NSDictionary *authority,
                                         NSError **error) {
  NSDictionary *session = DSHRuntimeLoadSession(store, error);
  NSDictionary *conversation = DSHRuntimeConversation(
      session, authority[@"conversation_id"]);
  if (conversation == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSMutableDictionary *byId = [NSMutableDictionary dictionary];
  for (NSDictionary *message in conversation[@"messages"]) {
    if ([message[@"id"] isKindOfClass:NSString.class]) {
      byId[message[@"id"]] = message;
    }
  }
  NSMutableArray *visible = [NSMutableArray array];
  for (NSString *messageId in authority[@"visible_message_ids"]) {
    NSDictionary *message = byId[messageId];
    if (![message isKindOfClass:NSDictionary.class]) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
      return nil;
    }
    NSMutableArray *attachments = [NSMutableArray array];
    for (NSDictionary *attachment in message[@"attachments"] ?: @[]) {
      [attachments addObject:@{
        @"schema_version" : attachment[@"schema_version"],
        @"id" : attachment[@"id"], @"kind" : attachment[@"kind"],
        @"name" : attachment[@"name"],
        @"mime_type" : attachment[@"mime_type"], @"size" : attachment[@"size"],
      }];
    }
    [visible addObject:@{ @"role" : message[@"role"],
                          @"content" : message[@"text"],
                          @"attachments" : attachments }];
  }
  return [visible copy];
}

static NSDictionary *DSHRuntimeContextBundle(
    DSHSessionSnapshotStore *store,
    DSHProjectContextService *service,
    NSDictionary *authority,
    NSError **error) {
  NSDictionary *session = DSHRuntimeLoadSession(store, error);
  NSDictionary *conversation = DSHRuntimeConversation(
      session, authority[@"conversation_id"]);
  NSDictionary *attempt = DSHRuntimeAttempt(conversation,
                                             authority[@"attempt_id"]);
  NSDictionary *context = attempt[@"project_context"];
  if (![context isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSDictionary *receipt = nil;
  NSDictionary *rootRef = @{
    @"schema_version" : @1,
    @"workspace_id" : authority[@"root"][@"workspace_id"],
    @"binding_revision" : authority[@"root"][@"workspace_binding_revision"],
    @"project_id" : authority[@"root"][@"project_id"],
  };
  NSDictionary *contextRequest = @{
    @"schema_version" : @2, @"snapshot_id" : context[@"snapshot_id"],
    @"consent_receipt_id" : context[@"consent_receipt_id"], @"root" : rootRef,
    @"conversation_id" : context[@"runtime_context_id"],
    @"model_id" : authority[@"model"], @"policy" : context[@"policy"],
  };
  // The protected native authority advances its transcript only after a real
  // provider/tool result. First launch still requires a fresh snapshot; later
  // rounds reuse its exact consented bytes, including after our own writes.
  BOOL continuation = [authority[@"transcript"][@"generation"] unsignedIntegerValue] > 0;
  NSData *envelope = continuation
      ? [service verifiedFrozenEnvelopeV2:contextRequest receipt:&receipt error:error]
      : [service verifiedEnvelopeV2:contextRequest receipt:&receipt error:error];
  if (envelope == nil) {
    if (error != nullptr && *error == nil) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    }
    return nil;
  }
  NSString *content = [[NSString alloc] initWithData:envelope encoding:NSUTF8StringEncoding];
  if (content == nil || ![context[@"context_bytes"] isEqual:@(envelope.length)] ||
      ![receipt[@"snapshot_sha256"] isEqual:context[@"snapshot_sha256"]] ||
      ![receipt[@"source_fingerprint"] isEqual:context[@"source_fingerprint"]]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  return @{
    @"project_context_sha256" : authority[@"project_context_sha256"],
    @"receipt" : @{
      @"schema_version" : @1, @"snapshot_id" : context[@"snapshot_id"],
      @"snapshot_sha256" : context[@"snapshot_sha256"],
      @"source_fingerprint" : context[@"source_fingerprint"],
      @"context_bytes" : context[@"context_bytes"],
      @"verified_at" : receipt[@"verified_at"],
    },
    @"messages" : @[@{ @"role" : @"system", @"content" : content,
                         @"attachments" : @[] }],
  };
}

static NSString *DSHRuntimeErrorCode(NSError *error) {
  // DSHCompletionToolsV2FromArray uses 2001...2008 only for local tool
  // definitions. Its response errors (2101+) are a separate failure family.
  if ([error.domain isEqual:@"DSHCompletionV2Error"] &&
      error.code >= 2001 && error.code <= 2008) {
    return @"E_AGENT_BAD_ARGUMENTS";
  }
  // Context-service error numbers are a different enum from Agent WAL errors.
  // Preserve value-free provenance rather than reporting storage as bad args.
  if ([error.domain isEqual:DSHProjectContextServiceErrorDomain]) {
    switch ((DSHProjectContextServiceErrorCode)error.code) {
      case DSHProjectContextServiceErrorInvalidArgument: return @"E_CONTEXT_REQUEST_INVALID";
      case DSHProjectContextServiceErrorProjectUnavailable: return @"E_PROJECT_NOT_FOUND";
      case DSHProjectContextServiceErrorChanged: return @"E_CONTEXT_CHANGED";
      case DSHProjectContextServiceErrorSecret: return @"E_CONTEXT_SECRET";
      case DSHProjectContextServiceErrorBudgetExceeded: return @"E_CONTEXT_BUDGET";
      case DSHProjectContextServiceErrorStorage: return @"E_CONTEXT_STORAGE";
      case DSHProjectContextServiceErrorTimeout: return @"E_CONTEXT_TIMEOUT";
      case DSHProjectContextServiceErrorConsent: return @"E_CONTEXT_CONSENT_INVALID";
      case DSHProjectContextServiceErrorIntegrity: return @"E_CONTEXT_INTEGRITY";
      case DSHProjectContextServiceErrorSnapshotMissing: return @"E_CONTEXT_SNAPSHOT_MISSING";
    }
    return @"E_CONTEXT_NATIVE";
  }
  id candidate = error.userInfo[@"code"];
  if ([candidate isKindOfClass:NSString.class] &&
      DSHAgentFailureCode(candidate)) return candidate;
  switch ((DSHAgentNativeStoreErrorCode)error.code) {
    case DSHAgentNativeStoreErrorInvalidArgument: return @"E_AGENT_BAD_ARGUMENTS";
    case DSHAgentNativeStoreErrorCorrupt: return @"E_AGENT_TRANSCRIPT";
    case DSHAgentNativeStoreErrorConflict: return @"E_AGENT_CONFLICT";
    case DSHAgentNativeStoreErrorCapacity: return @"E_AGENT_CAPACITY";
    case DSHAgentNativeStoreErrorOwnerLost:
      return @"E_AGENT_EXECUTION_AMBIGUOUS";
    case DSHAgentNativeStoreErrorNotFound: return @"E_AGENT_NOT_FOUND";
    case DSHAgentNativeStoreErrorPersistence:
    case DSHAgentNativeStoreErrorUnavailable:
      return @"E_AGENT_PERSISTENCE";
  }
  return @"E_AGENT_PERSISTENCE";
}

// Only fixed, display-only provenance crosses the bridge. Never include an
// NSError description/domain/userInfo or an NSException name/reason.
static NSString *DSHRuntimeFailureMessage(NSString *code, NSString *operation,
                                          NSError *error, BOOL exceptionCaught) {
  if (![code isEqual:@"E_AGENT_PERSISTENCE"] ||
      ![operation isEqual:@"complete_agent_round_v2"]) return code;
  NSString *kind = @"unknown";
  if (exceptionCaught) kind = @"exception";
  else if ([error.domain isEqual:DSHAgentNativeStoreErrorDomain]) {
    if (error.code == DSHAgentNativeStoreErrorPersistence) kind = @"persistence";
    else if (error.code == DSHAgentNativeStoreErrorUnavailable) kind = @"unavailable";
  }
  return [NSString stringWithFormat:
      @"E_AGENT_PERSISTENCE\nagent_runtime/v1 operation=complete_agent_round_v2 kind=%@", kind];
}

/// Round preview events (see DSHAgentProviderRoundService.previewSink).
static NSString *const DSHAgentRoundPreviewEventName = @"agentRoundPreview";

@interface AgentRuntimeModule : RCTEventEmitter <RCTBridgeModule>
@property(atomic, strong) id<DSHAgentRuntimeCoordinating> runtimeCoordinator;
@property(nonatomic, strong) DSHSessionWorkspaceCoordinator *serializationCoordinator;
@property(nonatomic) NSUInteger previewObserverCount;
/// Preview delivery pauses while the app is in the background: the round
/// keeps validating natively and its result replaces the preview anyway.
@property(nonatomic) BOOL previewSuspended;
- (instancetype)initWithCoordinator:(id<DSHAgentRuntimeCoordinating>)coordinator;
@end

@implementation AgentRuntimeModule

RCT_EXPORT_MODULE(AgentRuntime)

+ (BOOL)requiresMainQueueSetup { return NO; }

- (NSArray<NSString *> *)supportedEvents {
  return @[ DSHAgentRoundPreviewEventName ];
}

- (void)startObserving {
  @synchronized (self) { _previewObserverCount += 1; }
  os_log(OS_LOG_DEFAULT, "agent_preview_observers count=%{public}lu",
         (unsigned long)_previewObserverCount);
}

- (void)stopObserving {
  @synchronized (self) {
    _previewObserverCount = _previewObserverCount > 0 ? _previewObserverCount - 1 : 0;
  }
}

- (BOOL)hasPreviewObservers {
  @synchronized (self) { return _previewObserverCount > 0; }
}

- (void)publishRoundPreview:(NSDictionary *)event {
  if (![event isKindOfClass:NSDictionary.class]) return;
  BOOL suspended = NO;
  @synchronized (self) { suspended = _previewSuspended; }
  if (suspended) return;
  if (![self hasPreviewObservers]) {
    os_log(OS_LOG_DEFAULT, "agent_preview_dropped kind=%{public}@ seq=%{public}@",
           event[@"kind"], event[@"seq"]);
    return;
  }
  @try {
    [self sendEventWithName:DSHAgentRoundPreviewEventName body:event];
  } @catch (__unused NSException *exception) {
  }
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _serializationCoordinator = DSHSessionWorkspaceCoordinator.sharedCoordinator;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(applicationDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(applicationWillEnterForeground:)
                   name:UIApplicationWillEnterForegroundNotification object:nil];
  }
  return self;
}

- (void)dealloc {
  if ([_runtimeCoordinator isKindOfClass:DSHAgentRuntimeCoordinator.class])
    [((DSHAgentRuntimeCoordinator *)_runtimeCoordinator).executionService cancelRuntimeWork];
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)invalidate {
  if ([self.runtimeCoordinator isKindOfClass:DSHAgentRuntimeCoordinator.class])
    [((DSHAgentRuntimeCoordinator *)self.runtimeCoordinator).executionService cancelRuntimeWork];
  [super invalidate];
}

- (void)applicationDidEnterBackground:(__unused NSNotification *)notification {
  @synchronized (self) { _previewSuspended = YES; }
}

- (void)applicationWillEnterForeground:(__unused NSNotification *)notification {
  @synchronized (self) { _previewSuspended = NO; }
}

- (instancetype)initWithCoordinator:(id<DSHAgentRuntimeCoordinating>)coordinator {
  self = [self init];
  if (self != nil) _runtimeCoordinator = coordinator;
  return self;
}

- (id<DSHAgentRuntimeCoordinating>)buildRuntimeCoordinator:(NSError **)error {
  if (self.runtimeCoordinator != nil) {
    return self.runtimeCoordinator.isAvailable ? self.runtimeCoordinator : nil;
  }
  id localRuntime = [self.bridge moduleForName:@"LocalRuntime"
                         lazilyLoadIfNecessary:YES];
  DSHCompletionProviderTransport *transport =
      [localRuntime completionProviderTransport];
  DSHCompletionProviderTransport *claudeTransport =
      [localRuntime claudeProviderTransport];
  DSHCompletionProviderTransport *codexTransport =
      [localRuntime codexProviderTransport];
  DSHCompletionProviderTransport *glmTransport =
      [localRuntime glmProviderTransport];
  DSHProjectContextService *projectContext =
      [localRuntime projectContextService] ?: DSHSharedProjectContextService();
  DSHLocalWorkspaceAccess *workspaceAccess = projectContext.workspaceAccess;
  DSHLocalProjectAccess *projectAccess = projectContext.projectAccess;
  DSHAgentNativeWAL *wal = DSHRuntimeSharedWAL();
  DSHSessionSnapshotStore *sessions = [[DSHSessionSnapshotStore alloc]
      initWithError:error];
  if (localRuntime == nil || transport == nil || workspaceAccess == nil ||
      projectAccess == nil || wal == nil || sessions == nil) return nil;
  DSHAgentRootResolver *rootResolver = [[DSHAgentRootResolver alloc]
      initWithWorkspaceAccess:workspaceAccess projectAccess:projectAccess];
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc]
      initWithWAL:wal];
  DSHAgentRoundJournal *rounds = [[DSHAgentRoundJournal alloc] initWithWAL:wal];
  DSHAgentExecutionLedger *ledger = [[DSHAgentExecutionLedger alloc]
      initWithWAL:wal];
  DSHAgentPreparedAttemptStore *prepared = [[DSHAgentPreparedAttemptStore alloc]
      initWithWAL:wal rootResolver:rootResolver sessionSnapshotStore:sessions
      transcriptStore:transcripts];
  __weak id weakRuntime = localRuntime;
  DSHAgentProviderRoundCredentialProvider credentials =
      ^NSString *(NSString *harnessId, NSUInteger *generation) {
    id runtime = weakRuntime;
    if (runtime == nil) return nil;
    @synchronized (runtime) {
      return [runtime credentialForHarnessId:harnessId generation:generation];
    }
  };
  DSHAgentProviderRoundVisibleHistoryProvider history =
      ^NSArray *(NSDictionary *authority, NSError **providerError) {
    return DSHRuntimeVisibleHistory(sessions, authority, providerError);
  };
  DSHAgentProviderRoundContextReceiptProvider context =
      ^NSDictionary *(NSDictionary *authority, NSError **providerError) {
    return DSHRuntimeContextBundle(sessions, projectContext, authority,
                                   providerError);
  };
  DSHAgentProviderRoundService *roundService = [[DSHAgentProviderRoundService alloc]
      initWithWAL:wal preparedStore:prepared transcripts:transcripts rounds:rounds
      transport:transport claudeTransport:claudeTransport
      codexTransport:codexTransport glmTransport:glmTransport
      credentialProvider:credentials
      visibleHistoryProvider:history contextReceiptProvider:context];
  roundService.transportResolver = ^DSHCompletionProviderTransport *(NSString *harnessId) {
    return [weakRuntime providerTransportForHarnessId:harnessId];
  };
  __weak AgentRuntimeModule *weakSelf = self;
  roundService.previewSink = ^(NSDictionary *event) {
    [weakSelf publishRoundPreview:event];
  };
  DSHAgentWorkspaceToolExecutor *workspaceExecutor =
      [[DSHAgentWorkspaceToolExecutor alloc] initWithRootResolver:rootResolver];
  DSHAgentGitToolExecutor *gitExecutor = [[DSHAgentGitToolExecutor alloc]
      initWithRootResolver:rootResolver];
  // The agent's remote traffic goes where the panel's does: through the
  // proxy in the last committed session's preferences, which the core
  // validated when it was committed. A value that no longer reads is none.
  __weak DSHSessionSnapshotStore *weakSessions = sessions;
  gitExecutor.proxyProvider = ^NSString *{
    NSDictionary *loaded = [weakSessions loadSessionSnapshotWithError:nil];
    id json = loaded[@"session_json"];
    if (![json isKindOfClass:NSString.class]) return nil;
    NSDictionary *session = [NSJSONSerialization
        JSONObjectWithData:[(NSString *)json dataUsingEncoding:NSUTF8StringEncoding]
                   options:0 error:nil];
    id preferences = [session isKindOfClass:NSDictionary.class] ? session[@"preferences"] : nil;
    id raw = [preferences isKindOfClass:NSDictionary.class] ? preferences[@"git_https_proxy_url"] : nil;
    return DSHGitCanonicalProxyURL(raw, nil);
  };
  DSHAgentToolBatchService *batch = [[DSHAgentToolBatchService alloc]
      initWithWAL:wal ledger:ledger preparedStore:prepared
      transcripts:transcripts workspaceExecutor:workspaceExecutor
      gitExecutor:gitExecutor];
  DSHAgentToolExecutionService *execution = [[DSHAgentToolExecutionService alloc]
      initWithWAL:wal ledger:ledger preparedStore:prepared
      transcripts:transcripts workspaceExecutor:workspaceExecutor
      gitExecutor:gitExecutor];
  DSHAgentRuntimeCoordinator *coordinator = [[DSHAgentRuntimeCoordinator alloc]
      initWithWAL:wal preparedStore:prepared roundService:roundService
      batchService:batch executionService:execution transcripts:transcripts
      rounds:rounds ledger:ledger];
  if (!coordinator.isAvailable) return nil;
  self.runtimeCoordinator = coordinator;
  return coordinator;
}

- (void)invoke:(id)rawRequest resolver:(RCTPromiseResolveBlock)resolve
       rejecter:(RCTPromiseRejectBlock)reject providerWait:(BOOL)providerWait
           name:(NSString *)name
         block:(DSHRuntimeModuleInvoke)block {
  NSError *copyError = nil;
  NSDictionary *request = DSHAgentImmutableJSONCopy(rawRequest, &copyError);
  if (![request isKindOfClass:NSDictionary.class]) {
    if (reject != nil) reject(@"E_AGENT_BAD_ARGUMENTS",
                              @"E_AGENT_BAD_ARGUMENTS", nil);
    return;
  }
  if ([name isEqual:@"cancel_agent_attempt"] &&
      [self.runtimeCoordinator isKindOfClass:DSHAgentRuntimeCoordinator.class]) {
    // This only signals a matching native-registered full locator/root/owner;
    // the authoritative cancellation CAS remains on the coordinator below.
    [((DSHAgentRuntimeCoordinator *)self.runtimeCoordinator).executionService
        signalRuntimeCancellationRequest:request];
  }
  [self.serializationCoordinator performAsync:^{
    NSError *error = nil;
    id<DSHAgentRuntimeCoordinating> coordinator =
        [self buildRuntimeCoordinator:&error];
    // Provider waits and runtime effects leave this queue. Each owns separate
    // serialized preparation and settlement around its worker-only waiting.
    dispatch_block_t run = ^{
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    NSError *invokeError = error;
    NSDictionary *result = nil;
    BOOL exceptionCaught = NO;
    @try {
      result = coordinator == nil ? nil : block(coordinator, request, &invokeError);
      result = result == nil ? nil : DSHAgentImmutableJSONCopy(result, &invokeError);
    } @catch (__unused NSException *exception) {
      result = nil;
      exceptionCaught = YES;
      invokeError = DSHAgentNativeStoreError(DSHAgentNativeStoreErrorPersistence);
    }
    BOOL ok = [result isKindOfClass:NSDictionary.class];
    NSString *failureCode = ok ? nil : (coordinator == nil ? @"E_AGENT_NATIVE" :
        DSHRuntimeErrorCode(invokeError));
    // The public codes collapse several native failures into one value, so
    // record the native domain and code here: a device log is the only way
    // to tell a protection failure from a capacity or persistence failure
    // once the app has reported E_AGENT_PERSISTENCE.
    os_log(OS_LOG_DEFAULT,
           "agent_runtime op=%{public}@ elapsed_ms=%{public}.1f ok=%{public}d "
           "code=%{public}@ native=%{public}@:%{public}ld exception=%{public}d",
                name, (CFAbsoluteTimeGetCurrent() - began) * 1000.0, ok,
                failureCode ?: @"-", invokeError.domain ?: @"-",
                (long)invokeError.code, exceptionCaught);
    if (!ok) {
      NSString *code = failureCode;
      if (reject != nil) reject(code,
          DSHRuntimeFailureMessage(code, name, invokeError, exceptionCaught), nil);
    } else if (resolve != nil) {
      resolve(result);
    }
    };
    if (providerWait) {
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), run);
    } else {
      run();
    }
  }];
}

#define DSH_RUNTIME_EXPORT(js_name, objc_name, selector) \
  RCT_REMAP_METHOD(js_name, objc_name:(id)request \
                   resolver:(RCTPromiseResolveBlock)resolve \
                   rejecter:(RCTPromiseRejectBlock)reject) { \
    [self invoke:request resolver:resolve rejecter:reject \
        providerWait:([@#selector isEqualToString:@"completeAgentRoundV2"] || \
          ([@#selector isEqualToString:@"executeAgentTool"] && \
           [request isKindOfClass:NSDictionary.class] && DSHAgentIsRuntimeTool(request[@"name"])) || \
          ([@#selector isEqualToString:@"recoverAgentAttempt"] && \
           [request isKindOfClass:NSDictionary.class] && \
           [request[@"action"] isEqual:@"retry_failed_round"])) \
        name:@#js_name \
        block:^NSDictionary *(id<DSHAgentRuntimeCoordinating> coordinator, \
                              NSDictionary *value, NSError **error) { \
      return [coordinator selector:value error:error]; \
    }]; \
  }

DSH_RUNTIME_EXPORT(prepare_agent_attempt, prepareAgentAttemptRequest,
                   prepareAgentAttempt)
DSH_RUNTIME_EXPORT(complete_agent_round_v2, completeAgentRoundV2Request,
                   completeAgentRoundV2)
DSH_RUNTIME_EXPORT(prepare_agent_tool_batch, prepareAgentToolBatchRequest,
                   prepareAgentToolBatch)
DSH_RUNTIME_EXPORT(bind_agent_approval, bindAgentApprovalRequest,
                   bindAgentApproval)
DSH_RUNTIME_EXPORT(execute_agent_tool, executeAgentToolRequest,
                   executeAgentTool)
DSH_RUNTIME_EXPORT(cancel_agent_attempt, cancelAgentAttemptRequest,
                   cancelAgentAttempt)
DSH_RUNTIME_EXPORT(read_agent_round_presentations, readAgentRoundPresentationsRequest,
                   readAgentRoundPresentations)
DSH_RUNTIME_EXPORT(query_agent_attempt, queryAgentAttemptRequest,
                   queryAgentAttempt)
DSH_RUNTIME_EXPORT(query_agent_tool, queryAgentToolRequest, queryAgentTool)
DSH_RUNTIME_EXPORT(recover_agent_attempt, recoverAgentAttemptRequest,
                   recoverAgentAttempt)
DSH_RUNTIME_EXPORT(finalize_agent_attempt, finalizeAgentAttemptRequest,
                   finalizeAgentAttempt)
DSH_RUNTIME_EXPORT(discard_agent_attempt, discardAgentAttemptRequest,
                   discardAgentAttempt)
DSH_RUNTIME_EXPORT(interrupt_agent_attempt, interruptAgentAttemptRequest,
                   interruptAgentAttempt)
DSH_RUNTIME_EXPORT(query_agent_cleanup, queryAgentCleanupRequest,
                   queryAgentCleanup)

#undef DSH_RUNTIME_EXPORT

@end
