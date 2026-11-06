#import <Foundation/Foundation.h>
#import <RishNative/RishNativeModule.h>
#import <os/log.h>

#import "SessionSnapshotStore.h"
#import "WorkspaceClearanceStore.h"

#include <CoreFoundation/CoreFoundation.h>
#include <math.h>

static NSString *const DSHSessionBridgeInvalid = @"E_SESSION_INVALID";
static NSString *const DSHSessionBridgeCorrupt = @"E_SESSION_CORRUPT";
static NSString *const DSHSessionBridgeStorage = @"E_SESSION_STORAGE";
static NSString *const DSHSessionBridgeProtection = @"E_SESSION_PROTECTION";
static NSString *const DSHSessionBridgeBounds = @"E_SESSION_BOUNDS";
static NSString *const DSHSessionBridgeConflict = @"E_SESSION_CONFLICT";
static NSString *const DSHSessionBridgeNative = @"E_SESSION_NATIVE";
static NSString *const DSHSessionBridgePersistence = @"E_SESSION_PERSISTENCE";
static const NSUInteger DSHSessionBridgeMaximumRequestBytes =
    32U * 1024U * 1024U;

typedef NS_ENUM(NSInteger, DSHSessionBridgeOperation) {
  DSHSessionBridgeOperationLoad = 1,
  DSHSessionBridgeOperationCAS = 2,
  DSHSessionBridgeOperationQuery = 3,
  DSHSessionBridgeOperationClearance = 4,
  DSHSessionBridgeOperationClearanceQuery = 5,
};

typedef NS_ENUM(NSInteger, DSHSessionBridgeResultFailure) {
  DSHSessionBridgeResultFailureInvalid = 1,
  DSHSessionBridgeResultFailureCorrupt = 2,
  DSHSessionBridgeResultFailurePersistence = 3,
};

static BOOL DSHSessionBridgeIsBoolean(id value) {
  return [value isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static NSNumber *DSHSessionBridgeCopySafeInteger(
    id value,
    BOOL allowZero,
    DSHSessionBridgeResultFailure *failure) {
  if (![value isKindOfClass:NSNumber.class] ||
      DSHSessionBridgeIsBoolean(value) ||
      [value isKindOfClass:NSDecimalNumber.class]) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  double number = [value doubleValue];
  if (!isfinite(number) || floor(number) != number || number < 0.0 ||
      number > 9007199254740991.0 || (!allowZero && number == 0.0) ||
      (number == 0.0 && signbit(number))) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  unsigned long long integer = [value unsignedLongLongValue];
  if ((double)integer != number) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  return [NSNumber numberWithUnsignedLongLong:integer];
}

static NSString *DSHSessionBridgeCopyString(
    id value,
    NSUInteger maximumBytes,
    BOOL allowEmpty,
    DSHSessionBridgeResultFailure *failure) {
  if (![value isKindOfClass:NSString.class]) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding
                       allowLossyConversion:NO];
  if (bytes == nil || bytes.length > maximumBytes ||
      (!allowEmpty && bytes.length == 0)) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  NSString *copy = [[NSString alloc] initWithData:bytes
                                          encoding:NSUTF8StringEncoding];
  if (copy == nil) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  return copy;
}

static NSString *DSHSessionBridgeCopyDigest(
    id value,
    DSHSessionBridgeResultFailure *failure) {
  NSString *string = DSHSessionBridgeCopyString(value, 64, NO, failure);
  if (string == nil || string.length != 64) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  NSCharacterSet *hex =
      [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
  if ([string rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  return string;
}

static NSDictionary *DSHSessionBridgeCaptureDictionary(
    id value,
    DSHSessionBridgeResultFailure *failure);
static BOOL DSHSessionBridgeHasExactCapturedKeys(
    NSDictionary *captured,
    NSArray<NSString *> *keys);
static NSDictionary *DSHSessionBridgeFreshDictionary(
    NSArray<NSString *> *keys,
    NSArray *values);

/// app UI owns the request containers supplied to an exported method and
/// may mutate or release them as soon as that method returns. Capture one
/// bounded, JSON-compatible, deeply immutable value synchronously, before the
/// request is retained by any queue. The JSON text held in fields such as
/// `candidate_json` remains an opaque string; it is never parsed or rewritten.
static NSDictionary *DSHSessionBridgeCaptureRequest(id value) {
  @try {
    if (![value isKindOfClass:NSDictionary.class] ||
        ![NSJSONSerialization isValidJSONObject:value]) {
      return nil;
    }
    NSError *encodeError = nil;
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:value
                                                       options:0
                                                         error:&encodeError];
    if (encoded == nil || encodeError != nil || encoded.length == 0 ||
        encoded.length > DSHSessionBridgeMaximumRequestBytes) {
      return nil;
    }
    NSError *decodeError = nil;
    id captured = [NSJSONSerialization JSONObjectWithData:encoded
                                                   options:0
                                                     error:&decodeError];
    if (decodeError != nil ||
        ![captured isKindOfClass:NSDictionary.class]) {
      return nil;
    }
    return captured;
  } @catch (__unused NSException *exception) {
    return nil;
  }
}

static NSString *DSHSessionBridgeCopyUUID(
    id value,
    DSHSessionBridgeResultFailure *failure) {
  NSString *string = DSHSessionBridgeCopyString(value, 36, NO, failure);
  if (string == nil || string.length != 36 ||
      ![string isEqualToString:string.lowercaseString]) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:string];
  if (uuid == nil || ![uuid.UUIDString.lowercaseString isEqualToString:string]) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  return string;
}

static NSString *DSHSessionBridgeCopyTimestamp(
    id value,
    DSHSessionBridgeResultFailure *failure) {
  NSString *string = DSHSessionBridgeCopyString(value, 24, NO, failure);
  if (string == nil || string.length != 24 ||
      [string characterAtIndex:19] != '.' ||
      [string characterAtIndex:23] != 'Z' ||
      [string characterAtIndex:4] != '-' ||
      [string characterAtIndex:7] != '-' ||
      [string characterAtIndex:10] != 'T' ||
      [string characterAtIndex:13] != ':' ||
      [string characterAtIndex:16] != ':') {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                            NSISO8601DateFormatWithFractionalSeconds;
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  NSDate *date = [formatter dateFromString:string];
  if (date == nil || ![[formatter stringFromDate:date] isEqualToString:string]) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  return string;
}

static NSDictionary *DSHSessionBridgeSanitizeClearanceReceipt(
    id value,
    DSHSessionBridgeResultFailure *failure) {
  NSDictionary *captured = DSHSessionBridgeCaptureDictionary(value, failure);
  NSArray<NSString *> *keys = @[
    @"schema_version", @"clearance_receipt_id", @"operation_id",
    @"workspace_id", @"binding_revision", @"committed_session_generation",
    @"committed_session_sha256", @"issued_at",
  ];
  if (captured == nil || !DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  NSNumber *schema = DSHSessionBridgeCopySafeInteger(
      captured[@"schema_version"], YES, failure);
  NSNumber *bindingRevision = DSHSessionBridgeCopySafeInteger(
      captured[@"binding_revision"], NO, failure);
  NSNumber *generation = DSHSessionBridgeCopySafeInteger(
      captured[@"committed_session_generation"], NO, failure);
  NSString *clearanceId = DSHSessionBridgeCopyUUID(
      captured[@"clearance_receipt_id"], failure);
  NSString *operationId = DSHSessionBridgeCopyUUID(
      captured[@"operation_id"], failure);
  NSString *workspaceId = DSHSessionBridgeCopyUUID(
      captured[@"workspace_id"], failure);
  NSString *digest = DSHSessionBridgeCopyDigest(
      captured[@"committed_session_sha256"], failure);
  NSString *issuedAt = DSHSessionBridgeCopyTimestamp(captured[@"issued_at"], failure);
  if (schema == nil || schema.unsignedIntegerValue != 1 ||
      bindingRevision == nil || generation == nil || clearanceId == nil ||
      operationId == nil || workspaceId == nil || digest == nil ||
      issuedAt == nil) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  return DSHSessionBridgeFreshDictionary(
      keys, @[schema, clearanceId, operationId, workspaceId, bindingRevision,
              generation, digest, issuedAt]);
}

/// Captures each key's value exactly once. The capture owns fresh immutable
/// key strings, so later mutations of a mutable/custom store result cannot
/// affect the projection. Unknown keys are retained only in this private
/// capture so schema/status precedence can match the TypeScript validator;
/// they are never included in a resolved result.
static NSDictionary *DSHSessionBridgeCaptureDictionary(
    id value,
    DSHSessionBridgeResultFailure *failure) {
  if (![value isKindOfClass:NSDictionary.class]) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  NSDictionary *dictionary = value;
  NSUInteger count = dictionary.count;
  NSArray *rawKeys = [dictionary allKeys];
  if (![rawKeys isKindOfClass:NSArray.class] || rawKeys.count != count) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  NSMutableDictionary *captured =
      [NSMutableDictionary dictionaryWithCapacity:rawKeys.count];
  for (id rawKey in rawKeys) {
    DSHSessionBridgeResultFailure keyFailure =
        DSHSessionBridgeResultFailureInvalid;
    NSString *key = DSHSessionBridgeCopyString(rawKey, 4096, NO, &keyFailure);
    if (key == nil || captured[key] != nil) {
      if (failure != nullptr) *failure = keyFailure;
      return nil;
    }
    id object = [dictionary objectForKey:rawKey];
    if (object == nil) {
      if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
      return nil;
    }
    captured[key] = object;
  }
  return [captured copy];
}

static BOOL DSHSessionBridgeHasExactCapturedKeys(
    NSDictionary *captured,
    NSArray<NSString *> *keys) {
  if (captured.count != keys.count) return NO;
  NSSet *actual = [NSSet setWithArray:captured.allKeys];
  return [actual isEqualToSet:[NSSet setWithArray:keys]];
}

static NSDictionary *DSHSessionBridgeFreshDictionary(
    NSArray<NSString *> *keys,
    NSArray *values) {
  return [[NSDictionary alloc] initWithObjects:values forKeys:keys];
}

static NSDictionary *DSHSessionBridgeSanitizeSnapshotRef(
    id value,
    DSHSessionBridgeResultFailure *failure) {
  NSDictionary *captured = DSHSessionBridgeCaptureDictionary(value, failure);
  NSArray<NSString *> *keys =
      @[@"schema_version", @"generation", @"session_sha256"];
  if (captured == nil || !DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  NSNumber *schema = DSHSessionBridgeCopySafeInteger(
      captured[@"schema_version"], YES, failure);
  NSNumber *generation = DSHSessionBridgeCopySafeInteger(
      captured[@"generation"], NO, failure);
  NSString *digest = DSHSessionBridgeCopyDigest(captured[@"session_sha256"],
                                                failure);
  if (schema == nil || schema.unsignedIntegerValue != 1 || generation == nil ||
      digest == nil) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  return DSHSessionBridgeFreshDictionary(
      keys, @[schema, generation, digest]);
}

static NSDictionary *DSHSessionBridgeSanitizeLegacyRef(
    id value,
    DSHSessionBridgeResultFailure *failure) {
  NSDictionary *captured = DSHSessionBridgeCaptureDictionary(value, failure);
  NSArray<NSString *> *keys = @[@"schema_version", @"legacy_bytes_sha256"];
  if (captured == nil || !DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  NSNumber *schema = DSHSessionBridgeCopySafeInteger(
      captured[@"schema_version"], YES, failure);
  NSString *digest = DSHSessionBridgeCopyDigest(
      captured[@"legacy_bytes_sha256"], failure);
  if (schema == nil || schema.unsignedIntegerValue != 1 || digest == nil) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  return DSHSessionBridgeFreshDictionary(keys, @[schema, digest]);
}

static NSDictionary *DSHSessionBridgeSanitizeAuthority(
    id value,
    DSHSessionBridgeResultFailure *failure) {
  NSDictionary *captured = DSHSessionBridgeCaptureDictionary(value, failure);
  if (captured == nil) return nil;
  DSHSessionBridgeResultFailure kindFailure =
      DSHSessionBridgeResultFailureInvalid;
  NSString *kind = DSHSessionBridgeCopyString(
      captured[@"kind"], 64, NO, &kindFailure);
  NSNumber *schema = DSHSessionBridgeCopySafeInteger(
      captured[@"schema_version"], YES, failure);
  if (schema == nil || schema.unsignedIntegerValue != 1 || kind == nil) {
    if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
    return nil;
  }
  if ([kind isEqualToString:@"missing"]) {
    NSArray<NSString *> *keys = @[@"schema_version", @"kind"];
    if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
      if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
      return nil;
    }
    return DSHSessionBridgeFreshDictionary(keys, @[schema, kind]);
  }
  if ([kind isEqualToString:@"legacy_present"]) {
    NSArray<NSString *> *keys = @[@"schema_version", @"kind", @"legacy"];
    if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
      if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
      return nil;
    }
    NSDictionary *legacy = DSHSessionBridgeSanitizeLegacyRef(
        captured[@"legacy"], failure);
    return legacy == nil
        ? nil
        : DSHSessionBridgeFreshDictionary(keys, @[schema, kind, legacy]);
  }
  if ([kind isEqualToString:@"present"]) {
    NSArray<NSString *> *keys = @[@"schema_version", @"kind", @"snapshot"];
    if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
      if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
      return nil;
    }
    NSDictionary *snapshot = DSHSessionBridgeSanitizeSnapshotRef(
        captured[@"snapshot"], failure);
    return snapshot == nil
        ? nil
        : DSHSessionBridgeFreshDictionary(keys, @[schema, kind, snapshot]);
  }
  if (failure != nullptr) *failure = DSHSessionBridgeResultFailureInvalid;
  return nil;
}

static NSString *DSHSessionBridgeResultFailureCode(
    DSHSessionBridgeResultFailure failure) {
  switch (failure) {
    case DSHSessionBridgeResultFailureInvalid:
      return DSHSessionBridgeInvalid;
    case DSHSessionBridgeResultFailureCorrupt:
      return DSHSessionBridgeCorrupt;
    case DSHSessionBridgeResultFailurePersistence:
      return DSHSessionBridgePersistence;
  }
  return DSHSessionBridgePersistence;
}

static NSDictionary *DSHSessionBridgeSanitizeResult(
    id value,
    DSHSessionBridgeOperation operation,
    NSString **failureCode) {
  DSHSessionBridgeResultFailure failure =
      DSHSessionBridgeResultFailurePersistence;
  NSDictionary *captured = DSHSessionBridgeCaptureDictionary(value, &failure);
  if (captured == nil) {
    if (failureCode != nullptr) {
      *failureCode = DSHSessionBridgeResultFailureCode(failure);
    }
    return nil;
  }
  id schemaValue = captured[@"schema_version"];
  id statusValue = captured[@"status"];
  if (![schemaValue isKindOfClass:NSNumber.class] ||
      DSHSessionBridgeIsBoolean(schemaValue) ||
      [schemaValue isKindOfClass:NSDecimalNumber.class] ||
      ![statusValue isKindOfClass:NSString.class]) {
    if (failureCode != nullptr) {
      *failureCode = DSHSessionBridgePersistence;
    }
    return nil;
  }
  double schemaNumber = [schemaValue doubleValue];
  if (!isfinite(schemaNumber) || schemaNumber != 1.0) {
    if (failureCode != nullptr) {
      *failureCode = DSHSessionBridgePersistence;
    }
    return nil;
  }
  DSHSessionBridgeResultFailure statusFailure =
      DSHSessionBridgeResultFailurePersistence;
  NSString *status = DSHSessionBridgeCopyString(
      statusValue, 128, NO, &statusFailure);
  if (status == nil) {
    if (failureCode != nullptr) {
      *failureCode = DSHSessionBridgePersistence;
    }
    return nil;
  }
  NSNumber *schema = @1;

  if (operation == DSHSessionBridgeOperationClearance) {
    if ([status isEqualToString:@"committed"]) {
      NSArray<NSString *> *keys = @[@"schema_version", @"status", @"receipt"];
      if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      NSDictionary *receipt = DSHSessionBridgeSanitizeClearanceReceipt(
          captured[@"receipt"], &failure);
      if (receipt == nil) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      return DSHSessionBridgeFreshDictionary(keys, @[schema, status, receipt]);
    }
    if ([status isEqualToString:@"not_committed"] ||
        [status isEqualToString:@"session_only"] ||
        [status isEqualToString:@"unknown"]) {
      NSArray<NSString *> *keys = @[@"schema_version", @"status", @"receipt"];
      if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys) ||
          captured[@"receipt"] != NSNull.null) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      return DSHSessionBridgeFreshDictionary(
          keys, @[schema, status, NSNull.null]);
    }
    if (failureCode != nullptr) *failureCode = DSHSessionBridgePersistence;
    return nil;
  }

  if (operation == DSHSessionBridgeOperationClearanceQuery) {
    if ([status isEqualToString:@"not_started"] ||
        [status isEqualToString:@"unknown"]) {
      NSArray<NSString *> *keys = @[@"schema_version", @"status"];
      if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      return DSHSessionBridgeFreshDictionary(keys, @[schema, status]);
    }
    if ([status isEqualToString:@"committed"]) {
      NSArray<NSString *> *keys = @[@"schema_version", @"status", @"receipt"];
      if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      NSDictionary *receipt = DSHSessionBridgeSanitizeClearanceReceipt(
          captured[@"receipt"], &failure);
      if (receipt == nil) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      return DSHSessionBridgeFreshDictionary(keys, @[schema, status, receipt]);
    }
    if (failureCode != nullptr) *failureCode = DSHSessionBridgePersistence;
    return nil;
  }

  if (operation == DSHSessionBridgeOperationLoad) {
    // Every load result also reports which process launch wrote the stored
    // envelope and which launch is reading it; UI hydration compares the two
    // to interrupt attempts left behind by a dead writer.
    if ([status isEqualToString:@"missing"]) {
      NSArray<NSString *> *keys = @[
        @"schema_version", @"status", @"snapshot", @"session_json",
        @"writer_launch_instance_id", @"current_launch_instance_id",
      ];
      if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      if (captured[@"snapshot"] != NSNull.null ||
          captured[@"session_json"] != NSNull.null ||
          captured[@"writer_launch_instance_id"] != NSNull.null) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeCorrupt;
        return nil;
      }
      NSString *currentLaunch = DSHSessionBridgeCopyUUID(
          captured[@"current_launch_instance_id"], &failure);
      if (currentLaunch == nil) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      return DSHSessionBridgeFreshDictionary(
          keys, @[schema, status, NSNull.null, NSNull.null, NSNull.null,
                  currentLaunch]);
    }
    if ([status isEqualToString:@"legacy_present"]) {
      NSArray<NSString *> *keys = @[
        @"schema_version", @"status", @"legacy", @"session_json",
        @"writer_launch_instance_id", @"current_launch_instance_id",
      ];
      if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      NSDictionary *legacy = DSHSessionBridgeSanitizeLegacyRef(
          captured[@"legacy"], &failure);
      NSString *writerLaunch = DSHSessionBridgeCopyUUID(
          captured[@"writer_launch_instance_id"], &failure);
      NSString *currentLaunch = DSHSessionBridgeCopyUUID(
          captured[@"current_launch_instance_id"], &failure);
      if (legacy == nil || writerLaunch == nil || currentLaunch == nil) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      NSString *sessionJSON = DSHSessionBridgeCopyString(
          captured[@"session_json"], 16U * 1024U * 1024U, NO, &failure);
      if (sessionJSON == nil) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeCorrupt;
        return nil;
      }
      return DSHSessionBridgeFreshDictionary(
          keys, @[schema, status, legacy, sessionJSON, writerLaunch,
                  currentLaunch]);
    }
    if ([status isEqualToString:@"present"]) {
      NSArray<NSString *> *keys = @[
        @"schema_version", @"status", @"snapshot", @"session_json",
        @"writer_launch_instance_id", @"current_launch_instance_id",
      ];
      if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      NSDictionary *snapshot = DSHSessionBridgeSanitizeSnapshotRef(
          captured[@"snapshot"], &failure);
      NSString *writerLaunch = DSHSessionBridgeCopyUUID(
          captured[@"writer_launch_instance_id"], &failure);
      NSString *currentLaunch = DSHSessionBridgeCopyUUID(
          captured[@"current_launch_instance_id"], &failure);
      if (snapshot == nil || writerLaunch == nil || currentLaunch == nil) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      NSString *sessionJSON = DSHSessionBridgeCopyString(
          captured[@"session_json"], 16U * 1024U * 1024U, NO, &failure);
      if (sessionJSON == nil) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeCorrupt;
        return nil;
      }
      return DSHSessionBridgeFreshDictionary(
          keys, @[schema, status, snapshot, sessionJSON, writerLaunch,
                  currentLaunch]);
    }
    if (failureCode != nullptr) *failureCode = DSHSessionBridgePersistence;
    return nil;
  }

  if (operation == DSHSessionBridgeOperationCAS) {
    if ([status isEqualToString:@"committed"]) {
      NSArray<NSString *> *keys =
          @[@"schema_version", @"status", @"snapshot"];
      if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      NSDictionary *snapshot = DSHSessionBridgeSanitizeSnapshotRef(
          captured[@"snapshot"], &failure);
      if (snapshot == nil) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      return DSHSessionBridgeFreshDictionary(keys, @[schema, status, snapshot]);
    }
    if ([status isEqualToString:@"conflict"] ||
        [status isEqualToString:@"not_committed"] ||
        [status isEqualToString:@"session_only"] ||
        [status isEqualToString:@"unknown"]) {
      NSArray<NSString *> *keys = @[@"schema_version", @"status", @"current"];
      if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      NSDictionary *current = DSHSessionBridgeSanitizeAuthority(
          captured[@"current"], &failure);
      if (current == nil) {
        if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
        return nil;
      }
      return DSHSessionBridgeFreshDictionary(keys, @[schema, status, current]);
    }
    if (failureCode != nullptr) *failureCode = DSHSessionBridgePersistence;
    return nil;
  }

  if ([status isEqualToString:@"not_started"] ||
      [status isEqualToString:@"unknown"]) {
    NSArray<NSString *> *keys = @[@"schema_version", @"status"];
    if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
      if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
      return nil;
    }
    return DSHSessionBridgeFreshDictionary(keys, @[schema, status]);
  }
  if ([status isEqualToString:@"committed"]) {
    NSArray<NSString *> *keys = @[@"schema_version", @"status", @"snapshot"];
    if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
      if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
      return nil;
    }
    NSDictionary *snapshot = DSHSessionBridgeSanitizeSnapshotRef(
        captured[@"snapshot"], &failure);
    if (snapshot == nil) {
      if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
      return nil;
    }
    return DSHSessionBridgeFreshDictionary(keys, @[schema, status, snapshot]);
  }
  if ([status isEqualToString:@"conflict"]) {
    NSArray<NSString *> *keys = @[@"schema_version", @"status", @"current"];
    if (!DSHSessionBridgeHasExactCapturedKeys(captured, keys)) {
      if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
      return nil;
    }
    NSDictionary *current = DSHSessionBridgeSanitizeAuthority(
        captured[@"current"], &failure);
    if (current == nil) {
      if (failureCode != nullptr) *failureCode = DSHSessionBridgeInvalid;
      return nil;
    }
    return DSHSessionBridgeFreshDictionary(keys, @[schema, status, current]);
  }
  if (failureCode != nullptr) *failureCode = DSHSessionBridgePersistence;
  return nil;
}

static NSString *DSHSessionBridgeCodeForError(NSError *error) {
  // A nil result with no error stays E_SESSION_PERSISTENCE: the UI recovery
  // surface treats it as "storage did not confirm", and the os_log line in
  // performOperation: records the native domain and code for diagnosis.
  if (error == nil) return DSHSessionBridgePersistence;
  if ([error.domain isEqualToString:DSHWorkspaceClearanceStoreErrorDomain]) {
    switch ((DSHWorkspaceClearanceStoreErrorCode)error.code) {
      case DSHWorkspaceClearanceStoreErrorInvalidArgument:
        return DSHSessionBridgeInvalid;
      case DSHWorkspaceClearanceStoreErrorConflict:
        return DSHSessionBridgeConflict;
      case DSHWorkspaceClearanceStoreErrorNotFound:
        return @"E_WORKSPACE_NOT_FOUND";
      case DSHWorkspaceClearanceStoreErrorBusy:
        return @"E_WORKSPACE_BUSY";
      case DSHWorkspaceClearanceStoreErrorCorrupt:
      case DSHWorkspaceClearanceStoreErrorStorage:
      case DSHWorkspaceClearanceStoreErrorBounds:
        return DSHSessionBridgePersistence;
    }
  }
  if (![error.domain isEqualToString:DSHSessionSnapshotStoreErrorDomain]) {
    return DSHSessionBridgeNative;
  }
  switch ((DSHSessionSnapshotStoreErrorCode)error.code) {
    case DSHSessionSnapshotStoreErrorInvalidArgument:
      return DSHSessionBridgeInvalid;
    case DSHSessionSnapshotStoreErrorCorrupt:
      return DSHSessionBridgeCorrupt;
    case DSHSessionSnapshotStoreErrorStorage:
      return DSHSessionBridgeStorage;
    case DSHSessionSnapshotStoreErrorProtection:
      return DSHSessionBridgeProtection;
    case DSHSessionSnapshotStoreErrorBounds:
      return DSHSessionBridgeBounds;
    case DSHSessionSnapshotStoreErrorConflict:
      return DSHSessionBridgeConflict;
  }
  return DSHSessionBridgeNative;
}

static void DSHSessionBridgeReject(RishRejectBlock reject,
                                   NSString *code) {
  if (reject != nil) reject(code, code, nil);
}

@interface SessionSnapshotsModule : NSObject <RishNativeModule>
@property(nonatomic, strong) DSHSessionSnapshotStore *store;
@property(nonatomic, strong) DSHSessionWorkspaceCoordinator *coordinator;
@property(nonatomic, strong) dispatch_queue_t operationQueue;

// Native-only initializer used by focused bridge tests. It is intentionally
// not an exported app UI method.
- (instancetype)initWithStore:(DSHSessionSnapshotStore *)store;
@end

@implementation SessionSnapshotsModule

RISH_NATIVE_MODULE(SessionSnapshots)

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _coordinator = [DSHSessionWorkspaceCoordinator sharedCoordinator];
    _operationQueue = [DSHSessionWorkspaceCoordinator sharedQueue];

    NSError *supportError = nil;
    NSURL *support = [[NSFileManager defaultManager]
        URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask
        appropriateForURL:nil
        create:YES
        error:&supportError];
    if (support != nil) {
      NSURL *sessionURL = [support URLByAppendingPathComponent:@"sessions.json"
                                                     isDirectory:NO];
      _store = [[DSHSessionSnapshotStore alloc]
          initWithRootURL:support
               sessionURL:sessionURL
         launchInstanceId:nil
               coordinator:_coordinator
                 faultHook:nil];
    }
  }
  return self;
}

- (instancetype)initWithStore:(DSHSessionSnapshotStore *)store {
  self = [super init];
  if (self != nil) {
    _store = store;
    _coordinator = store.coordinator ?: [DSHSessionWorkspaceCoordinator sharedCoordinator];
    _operationQueue = [DSHSessionWorkspaceCoordinator sharedQueue];
  }
  return self;
}

- (void)performOperation:(DSHSessionBridgeOperation)operation
                 request:(id)request
                resolver:(RishResolveBlock)resolve
                rejecter:(RishRejectBlock)reject
                  invoke:(NSDictionary *(^)(DSHSessionSnapshotStore *store,
                                            id request,
                                            NSError **error))invoke {
  DSHSessionSnapshotStore *store = self.store;
  dispatch_queue_t queue = self.operationQueue ?: [DSHSessionWorkspaceCoordinator sharedQueue];
  dispatch_async(queue, ^{
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    NSError *error = nil;
    NSDictionary *result = nil;
    NSString *failureCode = nil;
    @try {
      if (store == nil) {
        failureCode = DSHSessionBridgeStorage;
      } else {
        result = invoke(store, request, &error);
        if (result == nil) {
          failureCode = DSHSessionBridgeCodeForError(error);
        } else {
          result = DSHSessionBridgeSanitizeResult(
              result, operation, &failureCode);
          if (result == nil && failureCode == nil) {
            failureCode = DSHSessionBridgePersistence;
          }
        }
      }
    } @catch (__unused NSException *exception) {
      failureCode = DSHSessionBridgeNative;
      result = nil;
    }
    os_log(OS_LOG_DEFAULT,
           "session_bridge op=%{public}ld elapsed_ms=%{public}.1f status=%{public}@ "
           "native=%{public}@:%{public}ld",
                (long)operation, (CFAbsoluteTimeGetCurrent() - began) * 1000.0,
                failureCode ?: (result[@"status"] ?: @"ok"),
                error.domain ?: @"-", (long)error.code);
    if (failureCode != nil) {
      DSHSessionBridgeReject(reject, failureCode);
    } else {
      resolve(result);
    }
  });
}

RISH_NATIVE_METHOD(loadSessionSnapshot,
                 loadSessionSnapshotWithResolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  [self performOperation:DSHSessionBridgeOperationLoad
                 request:nil
                resolver:resolve
                rejecter:reject
                  invoke:^NSDictionary *(DSHSessionSnapshotStore *store,
                                         __unused id request,
                                         NSError **error) {
    return [store loadSessionSnapshotWithError:error];
  }];
}

RISH_NATIVE_METHOD(casPersistSession,
                 casPersistSessionRequest:(id)request
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *capturedRequest = DSHSessionBridgeCaptureRequest(request);
  if (capturedRequest == nil) {
    DSHSessionBridgeReject(reject, DSHSessionBridgeInvalid);
    return;
  }
  [self performOperation:DSHSessionBridgeOperationCAS
                 request:capturedRequest
                resolver:resolve
                rejecter:reject
                  invoke:^NSDictionary *(DSHSessionSnapshotStore *store,
                                         id forwardedRequest,
                                         NSError **error) {
    // Do not normalize, downgrade, or translate this captured envelope. The
    // store remains the strict authority for the exact versioned request.
    return [store casPersistSession:(NSDictionary *)forwardedRequest error:error];
  }];
}

RISH_NATIVE_METHOD(querySessionCommit,
                 querySessionCommitRequest:(id)request
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *capturedRequest = DSHSessionBridgeCaptureRequest(request);
  if (capturedRequest == nil) {
    DSHSessionBridgeReject(reject, DSHSessionBridgeInvalid);
    return;
  }
  [self performOperation:DSHSessionBridgeOperationQuery
                 request:capturedRequest
                resolver:resolve
                rejecter:reject
                  invoke:^NSDictionary *(DSHSessionSnapshotStore *store,
                                         id forwardedRequest,
                                         NSError **error) {
    // Query has its own exact contract and must not be routed through the
    // legacy session reader or a boolean persistence API.
    return [store querySessionCommit:(NSDictionary *)forwardedRequest error:error];
  }];
}

RISH_NATIVE_METHOD(persistSessionWithWorkspaceClearance,
                 persistSessionWithWorkspaceClearanceRequest:(id)request
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *capturedRequest = DSHSessionBridgeCaptureRequest(request);
  if (capturedRequest == nil) {
    DSHSessionBridgeReject(reject, DSHSessionBridgeInvalid);
    return;
  }
  [self performOperation:DSHSessionBridgeOperationClearance
                 request:capturedRequest
                resolver:resolve
                rejecter:reject
                  invoke:^NSDictionary *(DSHSessionSnapshotStore *store,
                                         id forwardedRequest,
                                         NSError **error) {
    return [store persistSessionWithWorkspaceClearance:
                         (NSDictionary *)forwardedRequest
                                                 error:error];
  }];
}

RISH_NATIVE_METHOD(queryWorkspaceClearance,
                 queryWorkspaceClearanceRequest:(id)request
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *capturedRequest = DSHSessionBridgeCaptureRequest(request);
  if (capturedRequest == nil) {
    DSHSessionBridgeReject(reject, DSHSessionBridgeInvalid);
    return;
  }
  [self performOperation:DSHSessionBridgeOperationClearanceQuery
                 request:capturedRequest
                resolver:resolve
                rejecter:reject
                  invoke:^NSDictionary *(DSHSessionSnapshotStore *store,
                                         id forwardedRequest,
                                         NSError **error) {
    return [store queryWorkspaceClearance:(NSDictionary *)forwardedRequest
                                     error:error];
  }];
}

// Timing marks share the unified log with native operations. This method is
// synchronous and only logs; it never touches the shared queue, CAS, or store.
RISH_NATIVE_SYNC(markTiming:(id)label elapsed:(id)elapsedMs) {
  if (![label isKindOfClass:NSString.class] || ![elapsedMs isKindOfClass:NSNumber.class]) {
    return nil;
  }
  os_log(OS_LOG_DEFAULT, "shell_timing label=%{public}@ elapsed_ms=%{public}.1f",
         [(NSString *)label substringToIndex:MIN((NSUInteger)64, [(NSString *)label length])],
         [(NSNumber *)elapsedMs doubleValue]);
  return nil;
}

// Pure digest of the candidate bytes. The host executes this on the module
// queue, without touching the CAS lock or store state.
RISH_NATIVE_SYNC(sessionCandidateDigest:(id)candidate) {
  if (![candidate isKindOfClass:NSString.class]) return nil;
  CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
  NSString *digest = [DSHSessionSnapshotStore candidateDigestForSessionJSON:candidate];
  os_log(OS_LOG_DEFAULT,
         "session_candidate_digest bytes=%{public}lu ok=%{public}d elapsed_ms=%{public}.1f",
               (unsigned long)[(NSString *)candidate length], digest != nil,
               (CFAbsoluteTimeGetCurrent() - began) * 1000.0);
  return digest;
}

@end
