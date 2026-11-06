#import "ProviderConfiguration.h"
#import "ProjectContextService.h"
#import "RishHarnessCatalog.h"

#import <RishNative/RishNativeModule.h>
#import <RishNative/RishInvalidating.h>

#include <math.h>

#include "rish_agent_core.h"

static NSString *const DSHPCRequestInvalid = @"E_CONTEXT_REQUEST_INVALID";
static NSString *const DSHPCResultInvalid = @"E_CONTEXT_RESULT_INVALID";
static NSString *const DSHPCBusy = @"E_CONTEXT_BUSY";
static NSString *const DSHPCCancelled = @"E_CONTEXT_CANCELLED";
static NSString *const DSHPCNative = @"E_CONTEXT_NATIVE";

static NSDictionary *DSHPCDictionary(id value) {
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSArray *DSHPCArray(id value) {
  return [value isKindOfClass:NSArray.class] ? value : nil;
}

static NSString *DSHPCString(id value) {
  return [value isKindOfClass:NSString.class] ? value : nil;
}

static BOOL DSHPCExactKeys(NSDictionary *value, NSArray<NSString *> *keys) {
  if (![value isKindOfClass:NSDictionary.class] || value.count != keys.count) {
    return NO;
  }
  return [[NSSet setWithArray:value.allKeys]
      isEqualToSet:[NSSet setWithArray:keys]];
}

static BOOL DSHPCSafeInteger(id value, uint64_t maximum, uint64_t *output) {
  if (![value isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
      [value isKindOfClass:NSDecimalNumber.class]) {
    return NO;
  }
  NSNumber *number = value;
  double bridged = number.doubleValue;
  if (!isfinite(bridged) || signbit(bridged) || floor(bridged) != bridged ||
      bridged > (double)maximum) return NO;
  uint64_t exact = number.unsignedLongLongValue;
  if ((double)exact != bridged || exact > maximum) return NO;
  if (output != nullptr) *output = exact;
  return YES;
}

static BOOL DSHPCBoolean(id value, BOOL *output) {
  if (![value isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
    return NO;
  }
  if (output != nullptr) *output = ((NSNumber *)value).boolValue;
  return YES;
}

// V2 projections share the hardened V1 candidate/item validators declared
// below; keep forward declarations next to the V2 boundary so the compiler
// cannot accidentally resolve an unvalidated dictionary helper.
static NSDictionary *DSHPCCandidate(id raw);
static NSDictionary *DSHPCIncluded(id raw);
static NSDictionary *DSHPCOmitted(id raw);

static NSString *DSHPCBoundedString(id value, NSUInteger maximumBytes,
                                    BOOL allowEmpty) {
  NSString *string = DSHPCString(value);
  NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
  if (string == nil || data == nil || data.length > maximumBytes ||
      (!allowEmpty && string.length == 0)) {
    return nil;
  }
  return [string copy];
}

static NSString *DSHPCCanonicalIdentifier(id value) {
  NSString *candidate = DSHPCString(value);
  if (candidate.length != 36 ||
      ![candidate isEqualToString:candidate.lowercaseString]) {
    return nil;
  }
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:candidate];
  NSString *canonical = uuid.UUIDString.lowercaseString;
  return [canonical isEqualToString:candidate] ? canonical : nil;
}

static BOOL DSHPCMatches(NSString *value, NSString *pattern) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSRange range = [value rangeOfString:pattern
                               options:NSRegularExpressionSearch];
  return range.location == 0 && range.length == value.length;
}

static NSString *DSHPCDigest(id value) {
  NSString *string = DSHPCString(value);
  return DSHPCMatches(string, @"[0-9a-f]{64}") ? [string copy] : nil;
}

static NSString *DSHPCHeadOid(id value) {
  if (value == NSNull.null) return (NSString *)NSNull.null;
  NSString *string = DSHPCString(value);
  return DSHPCMatches(string, @"[0-9a-f]{40}") ? [string copy] : nil;
}

static BOOL DSHPCTimestamp(id value) {
  NSString *string = DSHPCBoundedString(value, 64, NO);
  if (string == nil) return NO;
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                            NSISO8601DateFormatWithFractionalSeconds;
  if ([formatter dateFromString:string] != nil) return YES;
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
  return [formatter dateFromString:string] != nil;
}

// What a project-context result may say lives in the shared core
// (modules/rish/core, `rish_agent_project_context_bridge_reduce`).
static NSDictionary *DSHPCReduce(NSString *op, NSDictionary *fields) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_project_context_bridge_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  return [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] ? reply : nil;
}

static NSString *DSHPCSafeRelativePath(id value) {
  BOOL valid = [DSHPCReduce(@"safe_relative_path", @{
    @"value" : value ?: NSNull.null,
  })[@"valid"] isEqual:@YES];
  return valid ? [DSHPCString(value) copy] : nil;
}

static NSString *DSHPCGitBranch(id value) {
  if (value == NSNull.null) return (NSString *)NSNull.null;
  NSString *branch = DSHPCBoundedString(value, 1024, NO);
  if (branch == nil || [branch isEqualToString:@"@"] ||
      [branch rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet]
              .location != NSNotFound) {
    return nil;
  }
  NSString *fullName = [@"refs/heads/" stringByAppendingString:branch];
  int valid = 0;
  if (git_reference_name_is_valid(&valid, fullName.UTF8String) != 0 ||
      valid != 1) {
    return nil;
  }
  return [branch copy];
}

static NSString *DSHPCProjectName(id value) {
  NSString *name = DSHPCBoundedString(value, 120, NO);
  NSString *trimmed = [name stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (name == nil || ![trimmed isEqualToString:name] ||
      [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet]
              .location != NSNotFound ||
      [name containsString:@"/"] || [name containsString:@"\\"] ||
      [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
    return nil;
  }
  return [name copy];
}

static NSString *DSHPCCursor(id value, BOOL allowNull) {
  if (allowNull && (value == nil || value == NSNull.null)) {
    return (NSString *)NSNull.null;
  }
  NSString *cursor = DSHPCString(value);
  return cursor.length == 98 && DSHPCMatches(cursor, @"[A-Za-z0-9_-]{98}")
      ? [cursor copy] : nil;
}

static NSSet<NSString *> *DSHPCModels(void) {
  return DSHHarnessSupportedModels();
}

static NSSet<NSString *> *DSHPCOmissionReasons(void) {
  static NSSet<NSString *> *values = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    values = [NSSet setWithArray:@[
      @"secret_path", @"generated", @"lockfile", @"suspected_secret",
      @"binary", @"invalid_encoding", @"not_tracked", @"budget_exceeded",
      @"policy",
    ]];
  });
  return values;
}

static NSDictionary *DSHPCSelection(id raw) {
  NSDictionary *selection = DSHPCDictionary(raw);
  NSArray *keys = @[
    @"schema_version", @"project_id", @"conversation_id", @"provider",
    @"model", @"policy", @"selected_paths",
  ];
  uint64_t schema = 0;
  NSString *projectId = DSHPCCanonicalIdentifier(selection[@"project_id"]);
  NSString *conversationId =
      DSHPCCanonicalIdentifier(selection[@"conversation_id"]);
  NSString *model = DSHPCString(selection[@"model"]);
  NSArray *paths = DSHPCArray(selection[@"selected_paths"]);
  if (!DSHPCExactKeys(selection, keys) ||
      !DSHPCSafeInteger(selection[@"schema_version"], 1, &schema) ||
      schema != 1 || projectId == nil || conversationId == nil ||
      ![selection[@"provider"] isEqual:DSHProviderIdForModel(model)] ||
      ![DSHPCModels() containsObject:model] ||
      ![selection[@"policy"] isEqual:@"chat-read-v1"] || paths == nil ||
      paths.count > 5000) {
    return nil;
  }
  NSMutableArray<NSString *> *normalized =
      [NSMutableArray arrayWithCapacity:paths.count];
  NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:paths.count];
  for (id value in paths) {
    NSString *path = DSHPCSafeRelativePath(value);
    if (path == nil || [seen containsObject:path]) return nil;
    [seen addObject:path];
    [normalized addObject:path];
  }
  [normalized sortUsingSelector:@selector(compare:)];
  return @{
    @"schema_version": @1,
    @"project_id": projectId,
    @"conversation_id": conversationId,
    @"provider": DSHProviderIdForModel(model),
    @"model": [model copy],
    @"policy": @"chat-read-v1",
    @"selected_paths": [normalized copy],
  };
}

static NSDictionary *DSHPCWorkspaceRoot(id raw, BOOL projectRequired) {
  NSDictionary *root = DSHPCDictionary(raw);
  NSArray *keys = @[
    @"schema_version", @"workspace_id", @"binding_revision", @"project_id"
  ];
  uint64_t revision = 0;
  id project = root[@"project_id"];
  if (!DSHPCExactKeys(root, keys) ||
      !DSHPCSafeInteger(root[@"schema_version"], 1, nullptr) ||
      ![root[@"schema_version"] isEqual:@1] ||
      DSHPCCanonicalIdentifier(root[@"workspace_id"] ) == nil ||
      !DSHPCSafeInteger(root[@"binding_revision"], 9007199254740991ULL,
                        &revision) ||
      revision == 0 ||
      (project == NSNull.null
          ? projectRequired
          : DSHPCCanonicalIdentifier(project) == nil)) {
    return nil;
  }
  return @{
    @"schema_version" : @1,
    @"workspace_id" : [root[@"workspace_id"] copy],
    @"binding_revision" : @(revision),
    @"project_id" : project == NSNull.null ? NSNull.null : [project copy],
  };
}

static NSDictionary *DSHPCV2ProjectDescriptor(id raw,
                                              NSDictionary *expectedRoot) {
  NSDictionary *project = DSHPCDictionary(raw);
  NSArray *keys = @[
    @"schema_version", @"project_id", @"workspace_id",
    @"workspace_binding_revision", @"display_name", @"git_topology"
  ];
  uint64_t revision = 0;
  NSString *name = DSHPCProjectName(project[@"display_name"]);
  if (!DSHPCExactKeys(project, keys) ||
      !DSHPCSafeInteger(project[@"schema_version"], 2, nullptr) ||
      ![project[@"schema_version"] isEqual:@2] ||
      DSHPCCanonicalIdentifier(project[@"project_id"]) == nil ||
      DSHPCCanonicalIdentifier(project[@"workspace_id"]) == nil ||
      !DSHPCSafeInteger(project[@"workspace_binding_revision"],
                        9007199254740991ULL, &revision) ||
      revision == 0 || name == nil ||
      (![project[@"git_topology"] isEqual:@"legacy_embedded"] &&
       ![project[@"git_topology"] isEqual:@"private_split_gitdir"]) ||
      (expectedRoot != nil &&
       (![project[@"project_id"] isEqual:expectedRoot[@"project_id"]] ||
        ![project[@"workspace_id"] isEqual:expectedRoot[@"workspace_id"]] ||
        revision != [expectedRoot[@"binding_revision"] unsignedLongLongValue]))) {
    return nil;
  }
  return @{
    @"schema_version" : @2,
    @"project_id" : [project[@"project_id"] copy],
    @"workspace_id" : [project[@"workspace_id"] copy],
    @"workspace_binding_revision" : @(revision),
    @"display_name" : name,
    @"git_topology" : [project[@"git_topology"] copy],
  };
}

static NSDictionary *DSHPCV2CandidatePage(id raw, NSDictionary *expectedRoot) {
  NSDictionary *page = DSHPCDictionary(raw);
  NSArray *keys = @[
    @"schema_version", @"root", @"project", @"candidates", @"next_cursor"
  ];
  uint64_t schema = 0;
  NSDictionary *root = DSHPCWorkspaceRoot(page[@"root"], YES);
  NSArray *candidates = DSHPCArray(page[@"candidates"]);
  NSString *cursor = DSHPCCursor(page[@"next_cursor"], YES);
  if (!DSHPCExactKeys(page, keys) ||
      !DSHPCSafeInteger(page[@"schema_version"], 2, &schema) || schema != 2 ||
      root == nil || expectedRoot == nil || ![root isEqual:expectedRoot] ||
      candidates == nil || candidates.count > 100 || cursor == nil ||
      DSHPCV2ProjectDescriptor(page[@"project"], root) == nil) {
    return nil;
  }
  NSMutableArray *projected = [NSMutableArray arrayWithCapacity:candidates.count];
  NSMutableSet *paths = [NSMutableSet set];
  for (id value in candidates) {
    NSDictionary *candidate = DSHPCCandidate(value);
    if (candidate == nil || [paths containsObject:candidate[@"path"]]) return nil;
    [paths addObject:candidate[@"path"]];
    [projected addObject:candidate];
  }
  return @{
    @"schema_version" : @2,
    @"root" : root,
    @"project" : DSHPCV2ProjectDescriptor(page[@"project"], root),
    @"candidates" : [projected copy],
    @"next_cursor" : cursor,
  };
}

static NSDictionary *DSHPCV2Manifest(id raw, NSDictionary *expectedRoot,
                                     NSString *expectedSnapshotId,
                                     NSString *expectedConversationId,
                                     NSString *expectedModel) {
  NSDictionary *manifest = DSHPCDictionary(raw);
  NSDictionary *binding = manifest[@"provider_configuration"];
  manifest = DSHProviderRecordWithoutConfiguration(manifest, manifest[@"model_id"]);
  NSArray *keys = @[
    @"schema_version", @"snapshot_id", @"root", @"project", @"project_id",
    @"conversation_id", @"model_id", @"policy", @"branch", @"head_oid",
    @"clean", @"conflicted", @"captured_at", @"policy_version", @"included",
    @"omitted", @"context_bytes", @"estimated_tokens", @"snapshot_sha256",
    @"source_fingerprint"
  ];
  uint64_t contextBytes = 0;
  uint64_t estimatedTokens = 0;
  NSDictionary *root = DSHPCWorkspaceRoot(manifest[@"root"], YES);
  NSDictionary *project = DSHPCV2ProjectDescriptor(manifest[@"project"], root);
  NSString *snapshotId = DSHPCCanonicalIdentifier(manifest[@"snapshot_id"]);
  NSString *projectId = DSHPCCanonicalIdentifier(manifest[@"project_id"]);
  NSString *conversation = DSHPCCanonicalIdentifier(manifest[@"conversation_id"]);
  NSString *model = DSHPCString(manifest[@"model_id"]);
  NSString *branch = DSHPCGitBranch(manifest[@"branch"]);
  NSString *head = DSHPCHeadOid(manifest[@"head_oid"]);
  NSArray *included = DSHPCArray(manifest[@"included"]);
  NSArray *omitted = DSHPCArray(manifest[@"omitted"]);
  BOOL clean = NO;
  BOOL conflicted = NO;
  if (!DSHPCExactKeys(manifest, keys) ||
      !DSHPCSafeInteger(manifest[@"schema_version"], 2, nullptr) ||
      ![manifest[@"schema_version"] isEqual:@2] || snapshotId == nil ||
      (expectedSnapshotId != nil && ![snapshotId isEqual:expectedSnapshotId]) ||
      root == nil || expectedRoot == nil || ![root isEqual:expectedRoot] ||
      project == nil || projectId == nil ||
      ![projectId isEqual:root[@"project_id"]] ||
      conversation == nil ||
      (expectedConversationId != nil && ![conversation isEqual:expectedConversationId]) ||
      model == nil || ![DSHPCModels() containsObject:model] ||
      (expectedModel != nil && ![model isEqual:expectedModel]) ||
      ![manifest[@"policy"] isEqual:@"chat-read-v1"] ||
      (manifest[@"branch"] != NSNull.null && branch == nil) ||
      (manifest[@"head_oid"] != NSNull.null && head == nil) ||
      !DSHPCBoolean(manifest[@"clean"], &clean) ||
      !DSHPCBoolean(manifest[@"conflicted"], &conflicted) ||
      (clean && conflicted) || !DSHPCTimestamp(manifest[@"captured_at"]) ||
      ![manifest[@"policy_version"] isEqual:@"chat-read-v1.0.0"] ||
      included == nil || included.count > 32 || omitted == nil || omitted.count > 5000 ||
      !DSHPCSafeInteger(manifest[@"context_bytes"], 256 * 1024, &contextBytes) ||
      contextBytes == 0 ||
      !DSHPCSafeInteger(manifest[@"estimated_tokens"], 65536, &estimatedTokens) ||
      estimatedTokens != (contextBytes + 3) / 4 ||
      DSHPCDigest(manifest[@"snapshot_sha256"]) == nil ||
      DSHPCDigest(manifest[@"source_fingerprint"]) == nil) {
    return nil;
  }
  NSMutableArray *projectedIncluded = [NSMutableArray arrayWithCapacity:included.count];
  NSMutableSet *includedIds = [NSMutableSet set];
  for (id value in included) {
    NSDictionary *item = DSHPCIncluded(value);
    NSString *identity = item == nil ? nil
        : [NSString stringWithFormat:@"%@\n%@", item[@"path"], item[@"source"]];
    if (item == nil || [includedIds containsObject:identity]) return nil;
    [includedIds addObject:identity];
    [projectedIncluded addObject:item];
  }
  NSMutableArray *projectedOmitted = [NSMutableArray arrayWithCapacity:omitted.count];
  NSMutableSet *omittedIds = [NSMutableSet set];
  for (id value in omitted) {
    NSDictionary *item = DSHPCOmitted(value);
    NSString *identity = item == nil ? nil
        : [NSString stringWithFormat:@"%@\n%@", item[@"path"], item[@"reason"]];
    if (item == nil || [omittedIds containsObject:identity]) return nil;
    [omittedIds addObject:identity];
    [projectedOmitted addObject:item];
  }
  NSMutableDictionary *projected = [@{
    @"schema_version" : @2,
    @"snapshot_id" : snapshotId,
    @"root" : root,
    @"project" : project,
    @"project_id" : projectId,
    @"conversation_id" : conversation,
    @"model_id" : [model copy],
    @"policy" : @"chat-read-v1",
    @"branch" : branch,
    @"head_oid" : head,
    @"clean" : @(clean),
    @"conflicted" : @(conflicted),
    @"captured_at" : [manifest[@"captured_at"] copy],
    @"policy_version" : @"chat-read-v1.0.0",
    @"included" : [projectedIncluded copy],
    @"omitted" : [projectedOmitted copy],
    @"context_bytes" : @(contextBytes),
    @"estimated_tokens" : @(estimatedTokens),
    @"snapshot_sha256" : DSHPCDigest(manifest[@"snapshot_sha256"]),
    @"source_fingerprint" : DSHPCDigest(manifest[@"source_fingerprint"]),
  } mutableCopy];
  if (binding != nil) projected[@"provider_configuration"] = binding;
  return [projected copy];
}

static NSDictionary *DSHPCV2Consent(id raw, NSDictionary *expectedRoot,
                                    NSString *expectedSnapshotId) {
  NSDictionary *consent = DSHPCDictionary(raw);
  NSArray *keys = @[
    @"schema_version", @"consent_receipt_id", @"snapshot_id", @"root",
    @"workspace_id", @"workspace_binding_revision", @"snapshot_sha256",
    @"confirmed_at"
  ];
  uint64_t revision = 0;
  NSDictionary *root = DSHPCWorkspaceRoot(consent[@"root"], YES);
  NSString *snapshotId = DSHPCCanonicalIdentifier(consent[@"snapshot_id"]);
  if (!DSHPCExactKeys(consent, keys) ||
      !DSHPCSafeInteger(consent[@"schema_version"], 2, nullptr) ||
      ![consent[@"schema_version"] isEqual:@2] ||
      DSHPCCanonicalIdentifier(consent[@"consent_receipt_id"]) == nil ||
      snapshotId == nil || (expectedSnapshotId != nil &&
                            ![snapshotId isEqual:expectedSnapshotId]) ||
      root == nil || expectedRoot == nil || ![root isEqual:expectedRoot] ||
      ![consent[@"workspace_id"] isEqual:root[@"workspace_id"]] ||
      !DSHPCSafeInteger(consent[@"workspace_binding_revision"],
                        9007199254740991ULL, &revision) ||
      revision != [root[@"binding_revision"] unsignedLongLongValue] ||
      DSHPCDigest(consent[@"snapshot_sha256"]) == nil ||
      !DSHPCTimestamp(consent[@"confirmed_at"])) {
    return nil;
  }
  return @{
    @"schema_version" : @2,
    @"consent_receipt_id" : [consent[@"consent_receipt_id"] copy],
    @"snapshot_id" : snapshotId,
    @"root" : root,
    @"workspace_id" : [consent[@"workspace_id"] copy],
    @"workspace_binding_revision" : @(revision),
    @"snapshot_sha256" : DSHPCDigest(consent[@"snapshot_sha256"]),
    @"confirmed_at" : [consent[@"confirmed_at"] copy],
  };
}

static NSDictionary *DSHPCV2Inspection(id raw, NSDictionary *expectedRoot,
                                       NSString *expectedSnapshotId) {
  NSDictionary *inspection = DSHPCDictionary(raw);
  NSArray *manifestKeys = @[
    @"schema_version", @"snapshot_id", @"root", @"project", @"project_id",
    @"conversation_id", @"model_id", @"policy", @"branch", @"head_oid",
    @"clean", @"conflicted", @"captured_at", @"policy_version", @"included",
    @"omitted", @"context_bytes", @"estimated_tokens", @"snapshot_sha256",
    @"source_fingerprint"
  ];
  NSMutableArray *keys = [manifestKeys mutableCopy];
  [keys addObject:@"state"];
  if (!DSHPCExactKeys(inspection, keys) ||
      (![inspection[@"state"] isEqual:@"prepared"] &&
       ![inspection[@"state"] isEqual:@"confirmed"] &&
       ![inspection[@"state"] isEqual:@"stale"])) {
    return nil;
  }
  NSMutableDictionary *manifest = [inspection mutableCopy];
  [manifest removeObjectForKey:@"state"];
  NSDictionary *projected = DSHPCV2Manifest(manifest, expectedRoot,
                                            expectedSnapshotId, nil, nil);
  return projected == nil ? nil : @{
    @"schema_version" : @2,
    @"state" : [inspection[@"state"] copy],
    @"manifest" : projected,
  };
}

static NSDictionary *DSHPCV2VerifiedReceipt(id raw, NSDictionary *expectedRoot,
                                            NSString *expectedSnapshotId) {
  NSDictionary *receipt = DSHPCDictionary(raw);
  NSArray *keys = @[
    @"schema_version", @"snapshot_id", @"root", @"snapshot_sha256",
    @"source_fingerprint", @"context_bytes", @"verified_at"
  ];
  uint64_t bytes = 0;
  NSDictionary *root = DSHPCWorkspaceRoot(receipt[@"root"], YES);
  NSString *snapshotId = DSHPCCanonicalIdentifier(receipt[@"snapshot_id"]);
  if (!DSHPCExactKeys(receipt, keys) ||
      !DSHPCSafeInteger(receipt[@"schema_version"], 2, nullptr) ||
      ![receipt[@"schema_version"] isEqual:@2] || snapshotId == nil ||
      (expectedSnapshotId != nil && ![snapshotId isEqual:expectedSnapshotId]) ||
      root == nil || expectedRoot == nil || ![root isEqual:expectedRoot] ||
      DSHPCDigest(receipt[@"snapshot_sha256"]) == nil ||
      DSHPCDigest(receipt[@"source_fingerprint"]) == nil ||
      !DSHPCSafeInteger(receipt[@"context_bytes"], 256 * 1024, &bytes) ||
      bytes == 0 || !DSHPCTimestamp(receipt[@"verified_at"])) {
    return nil;
  }
  return @{
    @"schema_version" : @2,
    @"snapshot_id" : snapshotId,
    @"root" : root,
    @"snapshot_sha256" : DSHPCDigest(receipt[@"snapshot_sha256"]),
    @"source_fingerprint" : DSHPCDigest(receipt[@"source_fingerprint"]),
    @"context_bytes" : @(bytes),
    @"verified_at" : [receipt[@"verified_at"] copy],
  };
}

static NSDictionary *DSHPCV2DiscardResult(id raw, NSDictionary *expectedRoot,
                                          NSString *expectedSnapshotId) {
  NSDictionary *result = DSHPCDictionary(raw);
  NSArray *keys = @[
    @"schema_version", @"status", @"snapshot_id", @"root",
    @"workspace_id", @"workspace_binding_revision"
  ];
  uint64_t schema = 0;
  uint64_t revision = 0;
  NSDictionary *root = DSHPCWorkspaceRoot(result[@"root"], YES);
  if (!DSHPCExactKeys(result, keys) ||
      !DSHPCSafeInteger(result[@"schema_version"], 2, &schema) ||
      schema != 2 || root == nil || expectedRoot == nil ||
      ![root isEqual:expectedRoot] ||
      ![result[@"status"] isEqual:@"discarded"] ||
      ![result[@"snapshot_id"] isEqual:expectedSnapshotId] ||
      ![result[@"workspace_id"] isEqual:root[@"workspace_id"]] ||
      !DSHPCSafeInteger(result[@"workspace_binding_revision"],
                        9007199254740991ULL, &revision) ||
      revision != [root[@"binding_revision"] unsignedLongLongValue]) {
    return nil;
  }
  return @{
    @"schema_version" : @2,
    @"status" : @"discarded",
    @"snapshot_id" : [expectedSnapshotId copy],
    @"root" : root,
    @"workspace_id" : [root[@"workspace_id"] copy],
    @"workspace_binding_revision" : @(revision),
  };
}

static NSDictionary *DSHPCV2ListRequest(id raw) {
  NSDictionary *request = DSHPCDictionary(raw);
  NSArray *keys = @[@"schema_version", @"root", @"query", @"cursor"];
  uint64_t schema = 0;
  NSString *query = DSHPCString(request[@"query"]);
  NSData *queryData = [query dataUsingEncoding:NSUTF8StringEncoding
                              allowLossyConversion:NO];
  NSString *cursor = DSHPCCursor(request[@"cursor"], YES);
  NSDictionary *root = DSHPCWorkspaceRoot(request[@"root"], YES);
  if (!DSHPCExactKeys(request, keys) ||
      !DSHPCSafeInteger(request[@"schema_version"], 1, &schema) || schema != 1 ||
      root == nil || query == nil || queryData == nil || query.length > 256 ||
      queryData.length > 256 ||
      [query rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet]
              .location != NSNotFound || cursor == nil) {
    return nil;
  }
  return @{
    @"schema_version" : @1,
    @"root" : root,
    @"query" : [query copy],
    @"cursor" : cursor == (id)NSNull.null ? NSNull.null : [cursor copy],
  };
}

static NSDictionary *DSHPCV2Selection(id raw) {
  NSDictionary *selection = DSHPCDictionary(raw);
  NSArray *keys = @[
    @"schema_version", @"root", @"conversation_id", @"model_id", @"policy",
    @"selected_paths"
  ];
  uint64_t schema = 0;
  NSDictionary *root = DSHPCWorkspaceRoot(selection[@"root"], YES);
  NSString *conversation = DSHPCCanonicalIdentifier(selection[@"conversation_id"]);
  NSString *model = DSHPCString(selection[@"model_id"]);
  NSArray *paths = DSHPCArray(selection[@"selected_paths"]);
  if (!DSHPCExactKeys(selection, keys) ||
      !DSHPCSafeInteger(selection[@"schema_version"], 2, &schema) || schema != 2 ||
      root == nil || conversation == nil || ![DSHPCModels() containsObject:model] ||
      ![selection[@"policy"] isEqual:@"chat-read-v1"] || paths == nil ||
      paths.count > 5000) {
    return nil;
  }
  NSMutableArray<NSString *> *normalized =
      [NSMutableArray arrayWithCapacity:paths.count];
  NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:paths.count];
  for (id value in paths) {
    NSString *path = DSHPCSafeRelativePath(value);
    if (path == nil || [seen containsObject:path]) return nil;
    [seen addObject:path];
    [normalized addObject:path];
  }
  [normalized sortUsingSelector:@selector(compare:)];
  return @{
    @"schema_version" : @2,
    @"root" : root,
    @"conversation_id" : conversation,
    @"model_id" : [model copy],
    @"policy" : @"chat-read-v1",
    @"selected_paths" : [normalized copy],
  };
}

static NSDictionary *DSHPCV2SnapshotRequest(id raw) {
  NSDictionary *request = DSHPCDictionary(raw);
  NSArray *keys = @[@"schema_version", @"snapshot_id", @"root"];
  uint64_t schema = 0;
  NSString *snapshotId = DSHPCCanonicalIdentifier(request[@"snapshot_id"]);
  NSDictionary *root = DSHPCWorkspaceRoot(request[@"root"], YES);
  if (!DSHPCExactKeys(request, keys) ||
      !DSHPCSafeInteger(request[@"schema_version"], 2, &schema) || schema != 2 ||
      snapshotId == nil || root == nil) {
    return nil;
  }
  return @{
    @"schema_version" : @2,
    @"snapshot_id" : snapshotId,
    @"root" : root,
  };
}

static NSDictionary *DSHPCV2VerifiedRequest(id raw) {
  NSDictionary *request = DSHPCDictionary(raw);
  NSArray *keys = @[
    @"schema_version", @"snapshot_id", @"consent_receipt_id", @"root",
    @"conversation_id", @"model_id", @"policy"
  ];
  uint64_t schema = 0;
  NSString *snapshotId = DSHPCCanonicalIdentifier(request[@"snapshot_id"]);
  NSString *consentId =
      DSHPCCanonicalIdentifier(request[@"consent_receipt_id"]);
  NSString *conversation =
      DSHPCCanonicalIdentifier(request[@"conversation_id"]);
  NSString *model = DSHPCString(request[@"model_id"]);
  NSDictionary *root = DSHPCWorkspaceRoot(request[@"root"], YES);
  if (!DSHPCExactKeys(request, keys) ||
      !DSHPCSafeInteger(request[@"schema_version"], 2, &schema) || schema != 2 ||
      snapshotId == nil || consentId == nil || conversation == nil ||
      root == nil || ![DSHPCModels() containsObject:model] ||
      ![request[@"policy"] isEqual:@"chat-read-v1"]) {
    return nil;
  }
  return @{
    @"schema_version" : @2,
    @"snapshot_id" : snapshotId,
    @"consent_receipt_id" : consentId,
    @"root" : root,
    @"conversation_id" : conversation,
    @"model_id" : [model copy],
    @"policy" : @"chat-read-v1",
  };
}

static NSDictionary *DSHPCCandidate(id raw) {
  NSDictionary *candidate = DSHPCDictionary(raw);
  NSArray *keys = @[
    @"path", @"size", @"revision", @"git_state", @"eligible",
    @"omission_reason",
  ];
  NSString *path = DSHPCSafeRelativePath(candidate[@"path"]);
  uint64_t size = 0;
  NSString *revision = DSHPCString(candidate[@"revision"]);
  NSString *gitState = DSHPCString(candidate[@"git_state"]);
  BOOL eligible = NO;
  id omissionValue = candidate[@"omission_reason"];
  NSString *omission = omissionValue == NSNull.null
      ? (NSString *)NSNull.null : DSHPCString(omissionValue);
  BOOL revisionValid = DSHPCMatches(revision, @"[0-9a-f]{40}") ||
      DSHPCMatches(revision, @"[0-9a-f]{64}");
  NSSet *states = [NSSet setWithArray:
      @[@"unchanged", @"staged", @"unstaged", @"conflicted"]];
  if (!DSHPCExactKeys(candidate, keys) || path == nil ||
      !DSHPCSafeInteger(candidate[@"size"], 9007199254740991ULL, &size) ||
      !revisionValid || ![states containsObject:gitState] ||
      !DSHPCBoolean(candidate[@"eligible"], &eligible) || omission == nil ||
      (omission != (id)NSNull.null &&
       ![DSHPCOmissionReasons() containsObject:omission]) ||
      eligible != (omission == (id)NSNull.null)) {
    return nil;
  }
  return @{
    @"path": path,
    @"size": @(size),
    @"revision": [revision copy],
    @"git_state": [gitState copy],
    @"eligible": @(eligible),
    @"omission_reason": omission,
  };
}

static NSDictionary *DSHPCCandidatePage(id raw, NSString *expectedProjectId) {
  NSDictionary *page = DSHPCDictionary(raw);
  NSArray *keys = @[
    @"schema_version", @"project_id", @"candidates", @"next_cursor",
  ];
  uint64_t schema = 0;
  NSString *projectId = DSHPCCanonicalIdentifier(page[@"project_id"]);
  NSArray *candidates = DSHPCArray(page[@"candidates"]);
  NSString *cursor = DSHPCCursor(page[@"next_cursor"], YES);
  if (!DSHPCExactKeys(page, keys) ||
      !DSHPCSafeInteger(page[@"schema_version"], 1, &schema) || schema != 1 ||
      ![projectId isEqualToString:expectedProjectId] || candidates == nil ||
      candidates.count > 100 || cursor == nil) {
    return nil;
  }
  NSMutableArray *projected = [NSMutableArray arrayWithCapacity:candidates.count];
  NSMutableSet *paths = [NSMutableSet set];
  for (id rawCandidate in candidates) {
    NSDictionary *candidate = DSHPCCandidate(rawCandidate);
    if (candidate == nil || [paths containsObject:candidate[@"path"]]) return nil;
    [paths addObject:candidate[@"path"]];
    [projected addObject:candidate];
  }
  return @{
    @"schema_version": @1,
    @"project_id": projectId,
    @"candidates": [projected copy],
    @"next_cursor": cursor,
  };
}

static NSDictionary *DSHPCIncluded(id raw) {
  NSDictionary *item = DSHPCDictionary(raw);
  NSArray *keys = @[@"path", @"source", @"bytes", @"sha256"];
  NSString *path = DSHPCSafeRelativePath(item[@"path"]);
  NSString *source = DSHPCString(item[@"source"]);
  uint64_t bytes = 0;
  NSSet *sources = [NSSet setWithArray:
      @[@"tracked_file", @"staged_diff", @"worktree_diff"]];
  if (!DSHPCExactKeys(item, keys) || path == nil ||
      ![sources containsObject:source] ||
      !DSHPCSafeInteger(item[@"bytes"], 256 * 1024, &bytes) ||
      DSHPCDigest(item[@"sha256"]) == nil) {
    return nil;
  }
  return @{
    @"path": path, @"source": [source copy], @"bytes": @(bytes),
    @"sha256": DSHPCDigest(item[@"sha256"]),
  };
}

static NSDictionary *DSHPCOmitted(id raw) {
  NSDictionary *item = DSHPCDictionary(raw);
  if (!DSHPCExactKeys(item, @[@"path", @"reason"])) return nil;
  NSString *path = DSHPCSafeRelativePath(item[@"path"]);
  NSString *reason = DSHPCString(item[@"reason"]);
  if (path == nil || ![DSHPCOmissionReasons() containsObject:reason]) return nil;
  return @{@"path": path, @"reason": [reason copy]};
}

static NSDictionary *DSHPCManifest(id raw, NSString *expectedProjectId,
                                   NSString *expectedSnapshotId,
                                   NSString *expectedModel) {
  NSDictionary *manifest = DSHPCDictionary(raw);
  NSDictionary *binding = manifest[@"provider_configuration"];
  manifest = DSHProviderRecordWithoutConfiguration(manifest, manifest[@"model"]);
  NSArray *keys = @[
    @"schema_version", @"snapshot_id", @"project_id", @"project_name",
    @"branch", @"head_oid", @"clean", @"conflicted", @"captured_at",
    @"policy_version", @"provider_host", @"model", @"included", @"omitted",
    @"context_bytes", @"estimated_tokens", @"snapshot_sha256",
    @"source_fingerprint",
  ];
  uint64_t schema = 0;
  uint64_t contextBytes = 0;
  uint64_t estimatedTokens = 0;
  NSString *snapshotId = DSHPCCanonicalIdentifier(manifest[@"snapshot_id"]);
  NSString *projectId = DSHPCCanonicalIdentifier(manifest[@"project_id"]);
  NSString *projectName = DSHPCProjectName(manifest[@"project_name"]);
  NSString *branch = DSHPCGitBranch(manifest[@"branch"]);
  NSString *headOid = DSHPCHeadOid(manifest[@"head_oid"]);
  BOOL clean = NO;
  BOOL conflicted = NO;
  NSString *model = DSHPCString(manifest[@"model"]);
  NSArray *included = DSHPCArray(manifest[@"included"]);
  NSArray *omitted = DSHPCArray(manifest[@"omitted"]);
  if (!DSHPCExactKeys(manifest, keys) ||
      !DSHPCSafeInteger(manifest[@"schema_version"], 1, &schema) || schema != 1 ||
      snapshotId == nil || projectId == nil || projectName == nil ||
      branch == nil || headOid == nil ||
      !DSHPCBoolean(manifest[@"clean"], &clean) ||
      !DSHPCBoolean(manifest[@"conflicted"], &conflicted) ||
      (clean && conflicted) || !DSHPCTimestamp(manifest[@"captured_at"]) ||
      ![manifest[@"policy_version"] isEqual:@"chat-read-v1.0.0"] ||
      ![manifest[@"provider_host"] isEqual:(binding == nil ? DSHProviderHostForModel(model) : [NSURL URLWithString:binding[@"endpoint_url"]].host)] ||
      ![DSHPCModels() containsObject:model] || included == nil ||
      included.count > 32 || omitted == nil || omitted.count > 5000 ||
      !DSHPCSafeInteger(manifest[@"context_bytes"], 256 * 1024,
                        &contextBytes) || contextBytes == 0 ||
      !DSHPCSafeInteger(manifest[@"estimated_tokens"], 65536,
                        &estimatedTokens) ||
      estimatedTokens != (contextBytes + 3) / 4 ||
      DSHPCDigest(manifest[@"snapshot_sha256"]) == nil ||
      DSHPCDigest(manifest[@"source_fingerprint"]) == nil ||
      (expectedProjectId != nil && ![projectId isEqual:expectedProjectId]) ||
      (expectedSnapshotId != nil && ![snapshotId isEqual:expectedSnapshotId]) ||
      (expectedModel != nil && ![model isEqual:expectedModel])) {
    return nil;
  }
  NSMutableArray *projectedIncluded =
      [NSMutableArray arrayWithCapacity:included.count];
  NSMutableSet *includedIdentity = [NSMutableSet set];
  for (id rawItem in included) {
    NSDictionary *item = DSHPCIncluded(rawItem);
    NSString *identity = item == nil ? nil :
        [NSString stringWithFormat:@"%@\n%@", item[@"path"], item[@"source"]];
    if (item == nil || [includedIdentity containsObject:identity]) return nil;
    [includedIdentity addObject:identity];
    [projectedIncluded addObject:item];
  }
  NSMutableArray *projectedOmitted =
      [NSMutableArray arrayWithCapacity:omitted.count];
  NSMutableSet *omittedIdentity = [NSMutableSet set];
  for (id rawItem in omitted) {
    NSDictionary *item = DSHPCOmitted(rawItem);
    NSString *identity = item == nil ? nil :
        [NSString stringWithFormat:@"%@\n%@", item[@"path"], item[@"reason"]];
    if (item == nil || [omittedIdentity containsObject:identity]) return nil;
    [omittedIdentity addObject:identity];
    [projectedOmitted addObject:item];
  }
  NSMutableDictionary *projected = [@{
    @"schema_version": @1,
    @"snapshot_id": snapshotId,
    @"project_id": projectId,
    @"project_name": projectName,
    @"branch": branch,
    @"head_oid": headOid,
    @"clean": @(clean),
    @"conflicted": @(conflicted),
    @"captured_at": [manifest[@"captured_at"] copy],
    @"policy_version": @"chat-read-v1.0.0",
    @"provider_host": binding == nil ? DSHProviderHostForModel(model) : [NSURL URLWithString:binding[@"endpoint_url"]].host,
    @"model": [model copy],
    @"included": [projectedIncluded copy],
    @"omitted": [projectedOmitted copy],
    @"context_bytes": @(contextBytes),
    @"estimated_tokens": @(estimatedTokens),
    @"snapshot_sha256": DSHPCDigest(manifest[@"snapshot_sha256"]),
    @"source_fingerprint": DSHPCDigest(manifest[@"source_fingerprint"]),
  } mutableCopy];
  if (binding != nil) projected[@"provider_configuration"] = binding;
  return [projected copy];
}

static NSDictionary *DSHPCConsent(id raw, NSString *expectedSnapshotId) {
  NSDictionary *consent = DSHPCDictionary(raw);
  NSArray *keys = @[
    @"schema_version", @"consent_receipt_id", @"snapshot_id",
    @"snapshot_sha256", @"confirmed_at",
  ];
  uint64_t schema = 0;
  NSString *receiptId =
      DSHPCCanonicalIdentifier(consent[@"consent_receipt_id"]);
  NSString *snapshotId = DSHPCCanonicalIdentifier(consent[@"snapshot_id"]);
  if (!DSHPCExactKeys(consent, keys) ||
      !DSHPCSafeInteger(consent[@"schema_version"], 1, &schema) || schema != 1 ||
      receiptId == nil || ![snapshotId isEqual:expectedSnapshotId] ||
      DSHPCDigest(consent[@"snapshot_sha256"]) == nil ||
      !DSHPCTimestamp(consent[@"confirmed_at"])) {
    return nil;
  }
  return @{
    @"schema_version": @1,
    @"consent_receipt_id": receiptId,
    @"snapshot_id": snapshotId,
    @"snapshot_sha256": DSHPCDigest(consent[@"snapshot_sha256"]),
    @"confirmed_at": [consent[@"confirmed_at"] copy],
  };
}

static NSDictionary *DSHPCInspection(id raw, NSString *expectedSnapshotId) {
  NSDictionary *inspection = DSHPCDictionary(raw);
  if (inspection == nil || inspection.count != 19) return nil;
  NSString *state = DSHPCString(inspection[@"state"]);
  NSSet *states = [NSSet setWithArray:@[@"prepared", @"confirmed", @"stale"]];
  if (![states containsObject:state]) return nil;
  NSMutableDictionary *rawManifest = [inspection mutableCopy];
  [rawManifest removeObjectForKey:@"state"];
  NSDictionary *manifest = DSHPCManifest(rawManifest, nil, expectedSnapshotId, nil);
  if (manifest == nil) return nil;
  return @{
    @"schema_version": @1,
    @"state": [state copy],
    @"manifest": manifest,
  };
}

static NSString *DSHPCServiceErrorCode(NSError *error) {
  if (![error.domain isEqual:DSHProjectContextServiceErrorDomain]) {
    return DSHPCNative;
  }
  switch ((DSHProjectContextServiceErrorCode)error.code) {
    case DSHProjectContextServiceErrorInvalidArgument:
      return DSHPCRequestInvalid;
    case DSHProjectContextServiceErrorProjectUnavailable:
      return @"E_PROJECT_NOT_FOUND";
    case DSHProjectContextServiceErrorChanged:
      return @"E_CONTEXT_CHANGED";
    case DSHProjectContextServiceErrorSecret:
      return @"E_CONTEXT_SECRET";
    case DSHProjectContextServiceErrorBudgetExceeded:
      return @"E_CONTEXT_BUDGET";
    case DSHProjectContextServiceErrorStorage:
      return @"E_CONTEXT_STORAGE";
    case DSHProjectContextServiceErrorTimeout:
      return @"E_CONTEXT_TIMEOUT";
    case DSHProjectContextServiceErrorConsent:
      return @"E_CONTEXT_CONSENT_INVALID";
    case DSHProjectContextServiceErrorIntegrity:
      return @"E_CONTEXT_INTEGRITY";
    case DSHProjectContextServiceErrorSnapshotMissing:
      return @"E_CONTEXT_SNAPSHOT_MISSING";
  }
  return DSHPCNative;
}

static void DSHPCReject(RishRejectBlock reject, NSString *code) {
  reject(code, code, nil);
}

typedef id _Nullable (^DSHPCServiceOperation)(NSError **error);
typedef id _Nullable (^DSHPCResultProjection)(id raw);

@interface DSHPCOperationScheduler : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) NSUInteger maximumPending;
@property(nonatomic) NSUInteger pending;
- (instancetype)initWithQueue:(dispatch_queue_t)queue
                maximumPending:(NSUInteger)maximumPending;
- (BOOL)reserve;
- (void)releaseReservation;
@end

@implementation DSHPCOperationScheduler
- (instancetype)initWithQueue:(dispatch_queue_t)queue
                maximumPending:(NSUInteger)maximumPending {
  self = [super init];
  if (self != nil) {
    _queue = queue;
    _maximumPending = MIN(MAX(maximumPending, 1), 16);
  }
  return self;
}
- (BOOL)reserve {
  @synchronized (self) {
    if (self.pending >= self.maximumPending) return NO;
    self.pending += 1;
    return YES;
  }
}
- (void)releaseReservation {
  @synchronized (self) {
    if (self.pending > 0) self.pending -= 1;
  }
}
@end

static DSHPCOperationScheduler *DSHPCSharedScheduler(void) {
  static DSHPCOperationScheduler *scheduler = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    scheduler = [[DSHPCOperationScheduler alloc]
        initWithQueue:dispatch_queue_create(
            "dev.zseven.rish.project-context-bridge", DISPATCH_QUEUE_SERIAL)
        maximumPending:16];
  });
  return scheduler;
}

@interface LocalProjectContextModule : NSObject <RishNativeModule, RishInvalidating>
@property(nonatomic, strong) DSHProjectContextService *service;
@property(nonatomic, strong) dispatch_queue_t operationQueue;
@property(nonatomic, strong) DSHPCOperationScheduler *scheduler;
@property(nonatomic) NSUInteger maxPending;
@property(nonatomic) NSUInteger pending;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL invalidated;

- (instancetype)initWithService:(DSHProjectContextService *)service
                   operationQueue:(dispatch_queue_t)operationQueue
                       maxPending:(NSUInteger)maxPending;
@end

@implementation LocalProjectContextModule


RISH_NATIVE_MODULE(LocalProjectContext)

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _service = DSHSharedProjectContextService();
    _scheduler = DSHPCSharedScheduler();
    _operationQueue = _scheduler.queue;
    _maxPending = _scheduler.maximumPending;
  }
  return self;
}

- (instancetype)initWithService:(DSHProjectContextService *)service
                   operationQueue:(dispatch_queue_t)operationQueue
                       maxPending:(NSUInteger)maxPending {
  self = [super init];
  if (self != nil) {
    _service = service;
    _operationQueue = operationQueue ?: dispatch_queue_create(
        "dev.zseven.rish.project-context-bridge.test", DISPATCH_QUEUE_SERIAL);
    _maxPending = MIN(MAX(maxPending, 1), 16);
    _scheduler = [[DSHPCOperationScheduler alloc]
        initWithQueue:_operationQueue maximumPending:_maxPending];
  }
  return self;
}

- (void)invalidate {
  @synchronized (self) {
    self.invalidated = YES;
    self.generation += 1;
  }
}

- (void)enqueueOperation:(DSHPCServiceOperation)operation
              projection:(DSHPCResultProjection)projection
                resolver:(RishResolveBlock)resolve
                rejecter:(RishRejectBlock)reject {
  __block NSUInteger generation = 0;
  NSString *immediateFailure = nil;
  @synchronized (self) {
    if (self.invalidated) {
      immediateFailure = DSHPCCancelled;
    } else if (![self.scheduler reserve]) {
      immediateFailure = DSHPCBusy;
    } else {
      self.pending += 1;
      generation = self.generation;
    }
  }
  if (immediateFailure != nil) {
    DSHPCReject(reject, immediateFailure);
    return;
  }
  dispatch_async(self.operationQueue, ^{
    BOOL cancelledBeforeStart = NO;
    @synchronized (self) {
      if (self.invalidated || generation != self.generation) {
        self.pending -= 1;
        cancelledBeforeStart = YES;
      }
    }
    if (cancelledBeforeStart) {
      [self.scheduler releaseReservation];
      DSHPCReject(reject, DSHPCCancelled);
      return;
    }
    NSError *serviceError = nil;
    id raw = nil;
    NSString *failure = nil;
    @try {
      raw = operation(&serviceError);
      if (raw == nil) {
        failure = serviceError == nil ? DSHPCNative
                                      : DSHPCServiceErrorCode(serviceError);
      }
    } @catch (__unused NSException *exception) {
      failure = DSHPCNative;
    }
    id result = nil;
    if (failure == nil) {
      @try {
        result = projection(raw);
      } @catch (__unused NSException *exception) {
        failure = DSHPCNative;
      }
      if (failure == nil && result == nil) failure = DSHPCResultInvalid;
    }
    BOOL cancelled = NO;
    @synchronized (self) {
      self.pending -= 1;
      cancelled = self.invalidated || generation != self.generation;
    }
    [self.scheduler releaseReservation];
    if (cancelled) {
      DSHPCReject(reject, DSHPCCancelled);
    } else if (failure != nil) {
      DSHPCReject(reject, failure);
    } else {
      resolve(result);
    }
  });
}

RISH_NATIVE_METHOD(listProjectContextCandidates,
                 listProjectContextCandidates:(id)projectIdValue
                 query:(id)queryValue
                 cursor:(id)cursorValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSString *projectId = nil;
  NSString *query = nil;
  NSData *queryData = nil;
  NSString *cursor = nil;
  @try {
    projectId = DSHPCCanonicalIdentifier(projectIdValue);
    query = DSHPCString(queryValue);
    queryData = [query dataUsingEncoding:NSUTF8StringEncoding];
    cursor = DSHPCCursor(cursorValue, YES);
  } @catch (__unused NSException *exception) {
    DSHPCReject(reject, DSHPCNative);
    return;
  }
  if (projectId == nil || query == nil || query.length > 256 ||
      queryData == nil || cursor == nil) {
    DSHPCReject(reject, DSHPCRequestInvalid);
    return;
  }
  NSString *queryCopy = [query copy];
  id cursorCopy = cursor == (id)NSNull.null ? nil : [cursor copy];
  [self enqueueOperation:^id(NSError **error) {
    return [self.service listCandidatesForProjectId:projectId
                                              query:queryCopy
                                             cursor:cursorCopy
                                              error:error];
  } projection:^id(id raw) {
    return DSHPCCandidatePage(raw, projectId);
  } resolver:resolve rejecter:reject];
}

RISH_NATIVE_METHOD(prepareProjectContext,
                 prepareProjectContext:(id)selectionValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *selection = nil;
  @try {
    selection = DSHPCSelection(selectionValue);
  } @catch (__unused NSException *exception) {
    DSHPCReject(reject, DSHPCNative);
    return;
  }
  if (selection == nil) {
    DSHPCReject(reject, DSHPCRequestInvalid);
    return;
  }
  [self enqueueOperation:^id(NSError **error) {
    return [self.service prepareSelection:selection error:error];
  } projection:^id(id raw) {
    return DSHPCManifest(raw, selection[@"project_id"], nil,
                         selection[@"model"]);
  } resolver:resolve rejecter:reject];
}

RISH_NATIVE_METHOD(confirmProjectContext,
                 confirmProjectContext:(id)snapshotIdValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSString *snapshotId = nil;
  @try {
    snapshotId = DSHPCCanonicalIdentifier(snapshotIdValue);
  } @catch (__unused NSException *exception) {
    DSHPCReject(reject, DSHPCNative);
    return;
  }
  if (snapshotId == nil) {
    DSHPCReject(reject, DSHPCRequestInvalid);
    return;
  }
  [self enqueueOperation:^id(NSError **error) {
    return [self.service confirmSnapshotId:snapshotId error:error];
  } projection:^id(id raw) {
    return DSHPCConsent(raw, snapshotId);
  } resolver:resolve rejecter:reject];
}

RISH_NATIVE_METHOD(inspectProjectContext,
                 inspectProjectContext:(id)snapshotIdValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSString *snapshotId = nil;
  @try {
    snapshotId = DSHPCCanonicalIdentifier(snapshotIdValue);
  } @catch (__unused NSException *exception) {
    DSHPCReject(reject, DSHPCNative);
    return;
  }
  if (snapshotId == nil) {
    DSHPCReject(reject, DSHPCRequestInvalid);
    return;
  }
  [self enqueueOperation:^id(NSError **error) {
    return [self.service inspectSnapshotId:snapshotId error:error];
  } projection:^id(id raw) {
    return DSHPCInspection(raw, snapshotId);
  } resolver:resolve rejecter:reject];
}

RISH_NATIVE_METHOD(discardProjectContext,
                 discardProjectContext:(id)snapshotIdValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSString *snapshotId = nil;
  @try {
    snapshotId = DSHPCCanonicalIdentifier(snapshotIdValue);
  } @catch (__unused NSException *exception) {
    DSHPCReject(reject, DSHPCNative);
    return;
  }
  if (snapshotId == nil) {
    DSHPCReject(reject, DSHPCRequestInvalid);
    return;
  }
  [self enqueueOperation:^id(NSError **error) {
    return [self.service discardSnapshotId:snapshotId error:error] ? @YES : nil;
  } projection:^id(id raw) {
    return [raw isEqual:@YES]
        ? @{@"schema_version": @1, @"status": @"discarded"} : nil;
  } resolver:resolve rejecter:reject];
}

RISH_NATIVE_METHOD(listCandidatesV2,
                 listCandidatesV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = nil;
  @try {
    request = DSHPCV2ListRequest(requestValue);
  } @catch (__unused NSException *exception) {
    DSHPCReject(reject, DSHPCNative);
    return;
  }
  if (request == nil) {
    DSHPCReject(reject, DSHPCRequestInvalid);
    return;
  }
  NSDictionary *root = request[@"root"];
  NSString *query = [request[@"query"] copy];
  id cursor = request[@"cursor"] == NSNull.null ? nil : [request[@"cursor"] copy];
  [self enqueueOperation:^id(NSError **error) {
    return [self.service listCandidatesV2:@{
      @"schema_version" : @1,
      @"root" : root,
      @"query" : query,
      @"cursor" : cursor ?: NSNull.null,
    } error:error];
  } projection:^id(id raw) {
    return DSHPCV2CandidatePage(raw, root);
  } resolver:resolve rejecter:reject];
}

RISH_NATIVE_METHOD(prepareCandidateV2,
                 prepareCandidateV2Request:(id)selectionValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *selection = nil;
  @try {
    selection = DSHPCV2Selection(selectionValue);
  } @catch (__unused NSException *exception) {
    DSHPCReject(reject, DSHPCNative);
    return;
  }
  if (selection == nil) {
    DSHPCReject(reject, DSHPCRequestInvalid);
    return;
  }
  NSDictionary *root = selection[@"root"];
  NSString *conversation = selection[@"conversation_id"];
  NSString *model = selection[@"model_id"];
  [self enqueueOperation:^id(NSError **error) {
    return [self.service prepareCandidateV2:selection error:error];
  } projection:^id(id raw) {
    return DSHPCV2Manifest(raw, root, nil, conversation, model);
  } resolver:resolve rejecter:reject];
}

RISH_NATIVE_METHOD(confirmSnapshotV2,
                 confirmSnapshotV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = nil;
  @try {
    request = DSHPCV2SnapshotRequest(requestValue);
  } @catch (__unused NSException *exception) {
    DSHPCReject(reject, DSHPCNative);
    return;
  }
  if (request == nil) {
    DSHPCReject(reject, DSHPCRequestInvalid);
    return;
  }
  NSDictionary *root = request[@"root"];
  NSString *snapshotId = request[@"snapshot_id"];
  [self enqueueOperation:^id(NSError **error) {
    return [self.service confirmSnapshotV2:request error:error];
  } projection:^id(id raw) {
    return DSHPCV2Consent(raw, root, snapshotId);
  } resolver:resolve rejecter:reject];
}

RISH_NATIVE_METHOD(inspectSnapshotV2,
                 inspectSnapshotV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = nil;
  @try {
    request = DSHPCV2SnapshotRequest(requestValue);
  } @catch (__unused NSException *exception) {
    DSHPCReject(reject, DSHPCNative);
    return;
  }
  if (request == nil) {
    DSHPCReject(reject, DSHPCRequestInvalid);
    return;
  }
  NSDictionary *root = request[@"root"];
  NSString *snapshotId = request[@"snapshot_id"];
  [self enqueueOperation:^id(NSError **error) {
    return [self.service inspectSnapshotV2:request error:error];
  } projection:^id(id raw) {
    return DSHPCV2Inspection(raw, root, snapshotId);
  } resolver:resolve rejecter:reject];
}

RISH_NATIVE_METHOD(discardProjectContextV2,
                 discardProjectContextV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = nil;
  @try {
    request = DSHPCV2SnapshotRequest(requestValue);
  } @catch (__unused NSException *exception) {
    DSHPCReject(reject, DSHPCNative);
    return;
  }
  if (request == nil) {
    DSHPCReject(reject, DSHPCRequestInvalid);
    return;
  }
  NSDictionary *root = request[@"root"];
  [self enqueueOperation:^id(NSError **error) {
    return [self.service discardSnapshotV2:request error:error];
  } projection:^id(id raw) {
    return DSHPCV2DiscardResult(raw, root, request[@"snapshot_id"]);
  } resolver:resolve rejecter:reject];
}

RISH_NATIVE_METHOD(verifiedSendProjectContextV2,
                 verifiedSendProjectContextV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = nil;
  @try {
    request = DSHPCV2VerifiedRequest(requestValue);
  } @catch (__unused NSException *exception) {
    DSHPCReject(reject, DSHPCNative);
    return;
  }
  if (request == nil) {
    DSHPCReject(reject, DSHPCRequestInvalid);
    return;
  }
  NSDictionary *root = request[@"root"];
  NSString *snapshotId = request[@"snapshot_id"];
  [self enqueueOperation:^id(NSError **error) {
    __block NSDictionary *receipt = nil;
    NSData *envelope = [self.service verifiedEnvelopeV2:request
                                                   receipt:&receipt
                                                     error:error];
    // The envelope is deliberately consumed inside native code. Only its
    // redacted receipt is projected through the app UI.
    return envelope == nil ? nil : receipt;
  } projection:^id(id raw) {
    return DSHPCV2VerifiedReceipt(raw, root, snapshotId);
  } resolver:resolve rejecter:reject];
}

@end
