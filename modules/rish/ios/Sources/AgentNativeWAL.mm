#import "AgentNativeWAL.h"
#import "AgentRuntimeToolContracts.h"
#import "AssistantTaskExecutor.h"
#import "RishHarnessCatalog.h"

#import "DSHWorkspaceCanonical.h"
#import "AgentExecutionLedger.h"
#import "AgentRoundJournal.h"

#import <TargetConditionals.h>

#include "rish_agent_core.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <string.h>
#include <unistd.h>

#include <algorithm>
#include <cstdlib>
#include <stdint.h>
#include <string>
#include <set>

NSErrorDomain const DSHAgentNativeStoreErrorDomain =
    @"dev.zseven.rish.agent-native-store";

const NSUInteger DSHAgentNativeWALMaxTranscriptBytes = 2 * 1024 * 1024;
const NSUInteger DSHAgentNativeWALMaxTranscriptCount = 128;
const NSUInteger DSHAgentNativeWALMaxLedgerRowsPerAttempt = 128;
const NSUInteger DSHAgentNativeWALMaxRoundRowsPerAttempt = 8;
const NSUInteger DSHAgentNativeWALMaxStoreBytes = 64 * 1024 * 1024;
const NSUInteger DSHAgentNativeWALMaxSingleWriteBytes = 32 * 1024;
const NSUInteger DSHAgentNativeWALMaxBatchWriteBytes = 512 * 1024;
const NSUInteger DSHAgentNativeWALMaxAttemptWriteBytes = 4 * 1024 * 1024;
const NSUInteger DSHAgentNativeWALMaxAuthorities = 128;
const NSUInteger DSHAgentNativeWALMaxOperationsPerAttempt = 256;
const NSUInteger DSHAgentNativeWALMaxOperations = 2048;
const NSUInteger DSHAgentNativeWALMaxOperationRecordBytes = 16 * 1024;
const NSUInteger DSHAgentNativeWALMaxOperationResultBytes = 768 * 1024;
const NSUInteger DSHAgentNativeWALMaxBatchesPerAttempt = 128;
const NSUInteger DSHAgentNativeWALMaxDeniedCallsPerAttempt = 128;
const NSUInteger DSHAgentNativeWALMaxDeniedCalls = 2048;

static const unsigned long long DSHAgentMaximumSafeInteger = 9007199254740991ULL;
static NSString *const DSHAgentWALFileName = @"agent-native-wal-v1.json";
static NSString *const DSHAgentWALTemporarySuffix = @".tmp";

static NSArray<NSString *> *DSHAgentWALV1Keys(void) {
  static NSArray<NSString *> *keys;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    keys = @[
      @"schema_version",
      @"generation",
      @"transcripts",
      @"rounds",
      @"ledger",
      @"reservations",
      @"cleanup",
      @"dispatch",
      @"batches",
    ];
  });
  return keys;
}

static BOOL DSHAgentIsBooleanNumber(id value) {
  return [value isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL DSHAgentFiniteJSONNumber(NSNumber *number) {
  if (number == nil || DSHAgentIsBooleanNumber(number)) return YES;
  const char *type = number.objCType;
  if (type == nullptr || type[0] == '\0') return NO;
  if (strchr("fd", type[0]) != nullptr) {
    const double value = number.doubleValue;
    if (!isfinite(value) || (value == 0 && signbit(value))) return NO;
    if (floor(value) == value &&
        fabs(value) > (double)DSHAgentMaximumSafeInteger) {
      return NO;
    }
    return YES;
  }
  return strchr("cCsSiIlLqQ", type[0]) != nullptr;
}

static BOOL DSHAgentJSONTree(id value,
                             NSUInteger depth,
                             NSUInteger *nodes,
                             NSMutableSet<NSValue *> *ancestors) {
  if (value == nil || nodes == nullptr || ancestors == nil || depth > 64 ||
      *nodes >= 30000) {
    return NO;
  }
  *nodes += 1;
  if (value == NSNull.null) return YES;
  if ([value isKindOfClass:NSString.class]) {
    return [value dataUsingEncoding:NSUTF8StringEncoding] != nil;
  }
  if ([value isKindOfClass:NSNumber.class]) {
    return DSHAgentFiniteJSONNumber(value);
  }
  const BOOL isDictionary = [value isKindOfClass:NSDictionary.class];
  const BOOL isArray = [value isKindOfClass:NSArray.class];
  if (!isDictionary && !isArray) return NO;

  NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)value];
  if ([ancestors containsObject:identity]) return NO;
  [ancestors addObject:identity];

  BOOL valid = YES;
  if (isDictionary) {
    for (id key in (NSDictionary *)value) {
      if (![key isKindOfClass:NSString.class] ||
          [key dataUsingEncoding:NSUTF8StringEncoding] == nil ||
          !DSHAgentJSONTree(((NSDictionary *)value)[key], depth + 1, nodes,
                            ancestors)) {
        valid = NO;
        break;
      }
    }
  } else {
    for (id child in (NSArray *)value) {
      if (!DSHAgentJSONTree(child, depth + 1, nodes, ancestors)) {
        valid = NO;
        break;
      }
    }
  }
  [ancestors removeObject:identity];
  return valid;
}

BOOL DSHAgentIsImmutableFoundationJSON(id value) {
  if (value == nil) return NO;
  NSUInteger nodes = 0;
  return DSHAgentJSONTree(value, 0, &nodes, [NSMutableSet set]);
}

BOOL DSHAgentExactDictionaryKeys(NSDictionary *value,
                                 NSArray<NSString *> *keys) {
  if (![value isKindOfClass:NSDictionary.class] ||
      ![keys isKindOfClass:NSArray.class] || value.count != keys.count) {
    return NO;
  }
  NSSet *allowed = [NSSet setWithArray:keys];
  for (id key in value) {
    if (![key isKindOfClass:NSString.class] || ![allowed containsObject:key]) {
      return NO;
    }
  }
  return YES;
}

BOOL DSHAgentExactDictionaryKeysWithOptional(NSDictionary *value,
                                             NSArray<NSString *> *keys,
                                             NSArray<NSString *> *optionalKeys) {
  if (![value isKindOfClass:NSDictionary.class] ||
      ![keys isKindOfClass:NSArray.class] ||
      ![optionalKeys isKindOfClass:NSArray.class]) {
    return NO;
  }
  NSSet *allowed = [NSSet setWithArray:
      [keys arrayByAddingObjectsFromArray:optionalKeys]];
  NSSet *required = [NSSet setWithArray:keys];
  for (id key in value) {
    if (![key isKindOfClass:NSString.class] || ![allowed containsObject:key]) {
      return NO;
    }
  }
  for (NSString *key in keys) {
    if (value[key] == nil) return NO;
  }
  (void)required;
  return YES;
}

BOOL DSHAgentCanonicalUUID(id value) {
  if (![value isKindOfClass:NSString.class] ||
      ((NSString *)value).length != 36) {
    return NO;
  }
  NSString *candidate = (NSString *)value;
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:candidate];
  return uuid != nil && [uuid.UUIDString.lowercaseString isEqualToString:candidate];
}

BOOL DSHAgentCanonicalSHA256(id value) {
  if (![value isKindOfClass:NSString.class] ||
      ((NSString *)value).length != 64) {
    return NO;
  }
  static NSCharacterSet *invalid;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    invalid = [[NSCharacterSet
        characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
  });
  return [((NSString *)value) rangeOfCharacterFromSet:invalid].location ==
      NSNotFound;
}

BOOL DSHAgentSafeInteger(id value, NSUInteger maximum, BOOL allowZero) {
  if (![value isKindOfClass:NSNumber.class] || DSHAgentIsBooleanNumber(value)) {
    return NO;
  }
  NSNumber *number = (NSNumber *)value;
  const double numeric = number.doubleValue;
  if (!isfinite(numeric) || floor(numeric) != numeric || signbit(numeric) ||
      numeric < 0 || numeric > (double)maximum ||
      numeric > (double)DSHAgentMaximumSafeInteger ||
      number.unsignedLongLongValue != (unsigned long long)numeric ||
      (!allowZero && numeric == 0)) {
    return NO;
  }
  return YES;
}

BOOL DSHAgentBoundedUTF8String(id value,
                               NSUInteger maximumBytes,
                               BOOL allowEmpty,
                               NSString **output) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *string = (NSString *)value;
  if (!allowEmpty && string.length == 0) return NO;
  NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil || data.length > maximumBytes) return NO;
  if (output != nullptr) *output = string;
  return YES;
}

BOOL DSHAgentCanonicalTimestamp(id value) {
  if (![value isKindOfClass:NSString.class] ||
      ![value dataUsingEncoding:NSUTF8StringEncoding]) return NO;
  NSString *timestamp = value;
  if (timestamp.length != 24) return NO;
  NSRegularExpression *pattern = [NSRegularExpression
      regularExpressionWithPattern:
          @"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"
                              options:0
                                error:nil];
  NSRange full = NSMakeRange(0, timestamp.length);
  if ([pattern firstMatchInString:timestamp options:0 range:full] == nil) return NO;
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                            NSISO8601DateFormatWithFractionalSeconds;
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  NSDate *date = [formatter dateFromString:timestamp];
  return date != nil && [[formatter stringFromDate:date] isEqual:timestamp];
}

BOOL DSHAgentFailureCode(id value) {
  if (!DSHAgentBoundedUTF8String(value, 128, NO, nullptr)) return NO;
  static NSSet<NSString *> *codes;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    codes = [NSSet setWithArray:@[
      @"E_AGENT_UNKNOWN_TOOL",
      @"E_AGENT_BAD_ARGUMENTS",
      @"E_AGENT_BAD_PATH",
      @"E_AGENT_NO_ROOT",
      @"E_AGENT_ROOT_STALE",
      @"E_AGENT_CAPABILITY",
      @"E_AGENT_APPROVAL",
      @"E_AGENT_TRANSCRIPT",
      @"E_AGENT_LEDGER",
      @"E_AGENT_ROUND_AMBIGUOUS",
      @"E_AGENT_EXECUTION_AMBIGUOUS",
      @"E_AGENT_RETRY_LINEAGE",
      @"E_AGENT_PERSISTENCE",
      @"E_AGENT_CONFLICT",
      @"E_AGENT_ROUND_LIMIT",
      @"E_AGENT_CANCELLED",
      @"E_AGENT_TOOL_FAILED",
      @"E_AGENT_NATIVE",
      @"E_AGENT_NOT_FOUND",
      @"E_AGENT_CAPACITY",
      @"E_COMPLETION_LENGTH",
      @"E_COMPLETION_CONTENT_FILTER",
      @"E_AGENT_DENIED_BY_USER",
      @"E_AGENT_PROVIDER_CREDENTIAL",
      @"E_AGENT_PROVIDER_FORBIDDEN",
      @"E_AGENT_PROVIDER_NOT_FOUND",
      @"E_AGENT_PROVIDER_RATE_LIMITED",
      @"E_AGENT_PROVIDER_REFUSED",
    ]];
  });
  return [codes containsObject:value];
}

NSError *DSHAgentNativeStoreError(DSHAgentNativeStoreErrorCode code) {
  NSString *stableCode = @"E_AGENT_PERSISTENCE";
  NSString *message = @"Agent native storage is unavailable.";
  switch (code) {
    case DSHAgentNativeStoreErrorInvalidArgument:
      stableCode = @"E_AGENT_BAD_ARGUMENTS";
      message = @"Agent request is invalid.";
      break;
    case DSHAgentNativeStoreErrorCorrupt:
      stableCode = @"E_AGENT_TRANSCRIPT";
      message = @"Agent native storage failed integrity validation.";
      break;
    case DSHAgentNativeStoreErrorConflict:
      stableCode = @"E_AGENT_CONFLICT";
      message = @"Agent native state changed concurrently.";
      break;
    case DSHAgentNativeStoreErrorCapacity:
      stableCode = @"E_AGENT_CAPACITY";
      message = @"Agent native storage capacity is exhausted.";
      break;
    case DSHAgentNativeStoreErrorOwnerLost:
      stableCode = @"E_AGENT_EXECUTION_AMBIGUOUS";
      message = @"Agent native task ownership is no longer provable.";
      break;
    case DSHAgentNativeStoreErrorNotFound:
      stableCode = @"E_AGENT_NOT_FOUND";
      message = @"Agent native record is unavailable.";
      break;
    case DSHAgentNativeStoreErrorPersistence:
      stableCode = @"E_AGENT_PERSISTENCE";
      message = @"Agent native storage could not be committed.";
      break;
    case DSHAgentNativeStoreErrorUnavailable:
      break;
  }
  return [NSError errorWithDomain:DSHAgentNativeStoreErrorDomain
                              code:code
                          userInfo:@{
                            @"code" : stableCode,
                            NSLocalizedDescriptionKey : message,
                          }];
}

void DSHSetAgentNativeStoreError(NSError **error,
                                 DSHAgentNativeStoreErrorCode code) {
  if (error != nullptr) *error = DSHAgentNativeStoreError(code);
}

NSData *DSHAgentCanonicalJSON(id value, NSError **error) {
  NSError *canonicalError = nil;
  NSData *data = DSHWorkspaceCanonicalJSONData(value, &canonicalError);
  if (data != nil) return data;
  if (error != nullptr) *error = DSHAgentNativeStoreError(
      DSHAgentNativeStoreErrorInvalidArgument);
  return nil;
}

id DSHAgentImmutableJSONCopy(id value, NSError **error) {
  NSData *data = DSHAgentCanonicalJSON(value, error);
  if (data == nil) return nil;
  NSError *decodeError = nil;
  id copy = [NSJSONSerialization JSONObjectWithData:data options:0 error:&decodeError];
  if (!DSHAgentIsImmutableFoundationJSON(copy)) {
    if (error != nullptr) *error = DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  return copy;
}

static NSData *DSHAgentUTF8(NSString *value) {
  return [value dataUsingEncoding:NSUTF8StringEncoding];
}

NSString *DSHAgentHJ(NSString *tag, id value, NSError **error) {
  NSString *safeTag = nil;
  if (!DSHAgentBoundedUTF8String(tag, 128, NO, &safeTag)) {
    if (error != nullptr) *error = DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSError *canonicalError = nil;
  NSData *canonical = DSHAgentCanonicalJSON(value, &canonicalError);
  if (canonical == nil) {
    if (error != nullptr) *error = canonicalError;
    return nil;
  }
  NSMutableData *input = [NSMutableData dataWithData:
      DSHAgentUTF8([NSString stringWithFormat:@"rish.%@.v1\0", safeTag])];
  [input appendData:canonical];
  return DSHWorkspaceSHA256Hex(input);
}

NSString *DSHAgentHB(NSString *tag, NSData *bytes, NSError **error) {
  NSString *safeTag = nil;
  if (!DSHAgentBoundedUTF8String(tag, 128, NO, &safeTag) ||
      ![bytes isKindOfClass:NSData.class]) {
    if (error != nullptr) *error = DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSMutableData *input = [NSMutableData dataWithData:
      DSHAgentUTF8([NSString stringWithFormat:@"rish.%@.v1\0", safeTag])];
  uint64_t length = CFSwapInt64HostToBig((uint64_t)bytes.length);
  [input appendBytes:&length length:sizeof(length)];
  [input appendData:bytes];
  return DSHWorkspaceSHA256Hex(input);
}

namespace {

static bool DSHAgentDecimalMagnitudeWithinSafeInteger(const std::string &token) {
  size_t cursor = token.size() > 0 && token[0] == '-' ? 1 : 0;
  size_t dot = token.find('.', cursor);
  size_t exponentMark = token.find_first_of("eE", cursor);
  size_t significandEnd = exponentMark == std::string::npos
      ? token.size() : exponentMark;
  size_t fractionDigits = 0;
  std::string digits;
  digits.reserve(significandEnd - cursor);
  for (size_t index = cursor; index < significandEnd; index += 1) {
    if (token[index] == '.') {
      continue;
    }
    if (dot != std::string::npos && index > dot) fractionDigits += 1;
    digits.push_back(token[index]);
  }
  size_t firstSignificant = digits.find_first_not_of('0');
  if (firstSignificant == std::string::npos) return true;
  digits.erase(0, firstSignificant);
  long long exponent = 0;
  if (exponentMark != std::string::npos) {
    size_t index = exponentMark + 1;
    bool negative = false;
    if (index < token.size() && (token[index] == '+' || token[index] == '-')) {
      negative = token[index] == '-';
      index += 1;
    }
    // Exponents beyond this bound are already unambiguously outside/inside
    // the integer window; cap them to avoid integer overflow while parsing.
    long long magnitude = 0;
    while (index < token.size()) {
      unsigned digit = static_cast<unsigned>(token[index] - '0');
      if (magnitude < 100000) magnitude = magnitude * 10 + digit;
      if (magnitude > 100000) magnitude = 100000;
      index += 1;
    }
    exponent = negative ? -magnitude : magnitude;
  }
  long long decimalShift = exponent - static_cast<long long>(fractionDigits);
  long long integerDigits = decimalShift >= 0
      ? static_cast<long long>(digits.size()) + decimalShift
      : std::max<long long>(0, static_cast<long long>(digits.size()) + decimalShift);
  bool fractional = false;
  if (decimalShift < 0 &&
      static_cast<long long>(digits.size()) > integerDigits) {
    for (size_t index = static_cast<size_t>(integerDigits);
         index < digits.size(); index += 1) {
      if (digits[index] != '0') {
        fractional = true;
        break;
      }
    }
  }
  // Non-integral decimal/exponent lexemes with more than fifteen meaningful
  // digits cannot round-trip through the bridge's IEEE-754 number type. Exact
  // integral values are handled by the safe-integer comparison below and are
  // allowed at the 9007199254740991 boundary.
  if (fractional && (dot != std::string::npos || exponentMark != std::string::npos)) {
    std::string meaningful = digits;
    while (!meaningful.empty() && meaningful.back() == '0') meaningful.pop_back();
    if (meaningful.size() > 15) return false;
  }
  if (integerDigits < 16) return true;
  if (integerDigits > 16) return false;

  std::string integerPart;
  if (decimalShift >= 0) {
    integerPart = digits;
    integerPart.append(static_cast<size_t>(decimalShift), '0');
  } else {
    integerPart = digits.substr(0, 16);
  }
  if (integerPart.size() > 16) return false;
  if (integerPart.size() < 16) integerPart.append(16 - integerPart.size(), '0');
  const std::string safe = "9007199254740991";
  if (integerPart > safe) return false;
  if (integerPart < safe) return true;
  if (decimalShift < 0 && digits.size() > 16) {
    for (size_t index = 16; index < digits.size(); index += 1) {
      if (digits[index] != '0') return false;
    }
  }
  return true;
}

class DSHAgentStrictJSONScanner {
 public:
  explicit DSHAgentStrictJSONScanner(NSData *data)
      : data_(data), bytes_(static_cast<const uint8_t *>(data.bytes)),
        length_(data.length), position_(0), nodes_(0) {}

  bool run() {
    if (!parseValue(0)) return false;
    skipWhitespace();
    return position_ == length_;
  }

 private:
  void skipWhitespace() {
    while (position_ < length_) {
      uint8_t c = bytes_[position_];
      if (c != ' ' && c != '\n' && c != '\r' && c != '\t') break;
      position_ += 1;
    }
  }

  bool parseValue(size_t depth) {
    if (depth > 64 || nodes_ >= 30000) return false;
    skipWhitespace();
    if (position_ >= length_) return false;
    nodes_ += 1;
    switch (bytes_[position_]) {
      case '{': return parseObject(depth + 1);
      case '[': return parseArray(depth + 1);
      case '"': return parseString(nullptr, nullptr);
      case 't': return parseLiteral("true");
      case 'f': return parseLiteral("false");
      case 'n': return parseLiteral("null");
      default: return parseNumber();
    }
  }

  bool parseLiteral(const char *literal) {
    size_t index = 0;
    while (literal[index] != '\0') {
      if (position_ >= length_ || bytes_[position_] != literal[index]) return false;
      position_ += 1;
      index += 1;
    }
    return true;
  }

  bool parseString(size_t *start, size_t *end) {
    if (position_ >= length_ || bytes_[position_] != '"') return false;
    size_t begin = position_;
    position_ += 1;
    while (position_ < length_) {
      uint8_t c = bytes_[position_++];
      if (c == '"') {
        if (start != nullptr) *start = begin;
        if (end != nullptr) *end = position_;
        return true;
      }
      if (c < 0x20) return false;
      if (c != '\\') continue;
      if (position_ >= length_) return false;
      uint8_t escape = bytes_[position_++];
      if (escape == 'u') {
        if (position_ + 4 > length_) return false;
        for (size_t index = 0; index < 4; index += 1) {
          uint8_t hex = bytes_[position_++];
          if (!((hex >= '0' && hex <= '9') ||
                (hex >= 'a' && hex <= 'f') ||
                (hex >= 'A' && hex <= 'F'))) return false;
        }
      } else if (escape != '"' && escape != '\\' && escape != '/' &&
                 escape != 'b' && escape != 'f' && escape != 'n' &&
                 escape != 'r' && escape != 't') {
        return false;
      }
    }
    return false;
  }

  bool parseNumber() {
    size_t begin = position_;
    if (position_ < length_ && bytes_[position_] == '-') position_ += 1;
    if (position_ >= length_) return false;
    if (bytes_[position_] == '0') {
      position_ += 1;
      if (position_ < length_ && bytes_[position_] >= '0' &&
          bytes_[position_] <= '9') return false;
    } else if (bytes_[position_] >= '1' && bytes_[position_] <= '9') {
      while (position_ < length_ && bytes_[position_] >= '0' &&
             bytes_[position_] <= '9') position_ += 1;
    } else {
      return false;
    }
    bool integer = true;
    if (position_ < length_ && bytes_[position_] == '.') {
      integer = false;
      position_ += 1;
      size_t fractionStart = position_;
      while (position_ < length_ && bytes_[position_] >= '0' &&
             bytes_[position_] <= '9') position_ += 1;
      if (fractionStart == position_) return false;
    }
    if (position_ < length_ && (bytes_[position_] == 'e' ||
                               bytes_[position_] == 'E')) {
      integer = false;
      position_ += 1;
      if (position_ < length_ && (bytes_[position_] == '+' ||
                                 bytes_[position_] == '-')) position_ += 1;
      size_t exponentStart = position_;
      while (position_ < length_ && bytes_[position_] >= '0' &&
             bytes_[position_] <= '9') position_ += 1;
      if (exponentStart == position_) return false;
    }
    std::string token(reinterpret_cast<const char *>(bytes_ + begin),
                      position_ - begin);
    char *end = nullptr;
    errno = 0;
    // Foundation/JavaScript ultimately represent decoded JSON numbers as
    // IEEE-754 values.  Parse through long double first so an exponent or a
    // decimal cannot silently overflow/underflow or round an integer outside
    // the JSON safe-integer subset before the ordinary JSON decoder sees it.
    long double value = std::strtold(token.c_str(), &end);
    if (end == nullptr || *end != '\0' || errno == ERANGE ||
        !std::isfinite(value) ||
        (value == 0.0L && token.size() > 0 && token[0] == '-') ||
        !DSHAgentDecimalMagnitudeWithinSafeInteger(token)) {
      return false;
    }
    // An exponent/decimal which is mathematically an integer is subject to
    // the same safe-integer bound as an integer lexeme.  The absolute bound
    // above also rejects fractional values whose magnitude cannot be carried
    // by the bridge without becoming an unsafe integer.
    if (integer && std::fabs(value) > (long double)DSHAgentMaximumSafeInteger) {
      return false;
    }
    return true;
  }

  bool parseObject(size_t depth) {
    if (bytes_[position_] != '{') return false;
    position_ += 1;
    skipWhitespace();
    std::set<std::string> keys;
    if (position_ < length_ && bytes_[position_] == '}') {
      position_ += 1;
      return true;
    }
    while (position_ < length_) {
      size_t start = 0;
      size_t end = 0;
      if (!parseString(&start, &end)) return false;
      NSData *keyData = [data_ subdataWithRange:NSMakeRange(start, end - start)];
      NSError *keyError = nil;
      id keyObject = [NSJSONSerialization JSONObjectWithData:keyData
                                                        options:NSJSONReadingAllowFragments
                                                          error:&keyError];
      if (![keyObject isKindOfClass:NSString.class]) return false;
      NSData *keyUTF8 = [keyObject dataUsingEncoding:NSUTF8StringEncoding];
      std::string key(reinterpret_cast<const char *>(keyUTF8.bytes), keyUTF8.length);
      if (!keys.insert(key).second) return false;
      skipWhitespace();
      if (position_ >= length_ || bytes_[position_] != ':') return false;
      position_ += 1;
      if (!parseValue(depth)) return false;
      skipWhitespace();
      if (position_ < length_ && bytes_[position_] == '}') {
        position_ += 1;
        return true;
      }
      if (position_ >= length_ || bytes_[position_] != ',') return false;
      position_ += 1;
      skipWhitespace();
    }
    return false;
  }

  bool parseArray(size_t depth) {
    if (bytes_[position_] != '[') return false;
    position_ += 1;
    skipWhitespace();
    if (position_ < length_ && bytes_[position_] == ']') {
      position_ += 1;
      return true;
    }
    while (position_ < length_) {
      if (!parseValue(depth)) return false;
      skipWhitespace();
      if (position_ < length_ && bytes_[position_] == ']') {
        position_ += 1;
        return true;
      }
      if (position_ >= length_ || bytes_[position_] != ',') return false;
      position_ += 1;
      skipWhitespace();
    }
    return false;
  }

  NSData *data_;
  const uint8_t *bytes_;
  size_t length_;
  size_t position_;
  size_t nodes_;
};

}  // namespace

NSDictionary *DSHAgentParseArgumentsJSON(NSString *argumentsJSON,
                                          NSError **error) {
  NSString *arguments = nil;
  // The write payload itself is capped at 32768 bytes, but its JSON wrapper
  // (quotes, escaped bytes, and object keys) is not part of that payload
  // budget.  Keep a separate bounded parser envelope so a full-size payload
  // remains admissible without making arguments unbounded.
  // A 32768-byte UTF-8 payload may expand to six-byte \u00XX escapes for
  // control characters, in addition to the object wrapper and argument keys.
  // Keep the parser bounded at 256 KiB so the worst valid write remains
  // representable without accepting an unbounded provider string.
  if (!DSHAgentBoundedUTF8String(argumentsJSON, 256 * 1024, YES, &arguments)) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSData *bytes = [arguments dataUsingEncoding:NSUTF8StringEncoding];
  DSHAgentStrictJSONScanner scanner(bytes);
  if (!scanner.run()) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSError *decodeError = nil;
  id object = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:&decodeError];
  if (![object isKindOfClass:NSDictionary.class] ||
      DSHAgentCanonicalJSON(object, &decodeError) == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  return object;
}

static BOOL DSHAgentArgumentPathAllowed(NSString *path, BOOL allowEmpty) {
  if (!DSHAgentBoundedUTF8String(path, 512, allowEmpty, nullptr) ||
      [path hasPrefix:@"/"] || [path containsString:@"\\"] ||
      [path rangeOfString:@"\0"].location != NSNotFound ||
      ![path isEqualToString:path.precomposedStringWithCanonicalMapping]) {
    return NO;
  }
  for (NSString *component in [path componentsSeparatedByString:@"/"]) {
    if ([component isEqualToString:@".."] ||
        (component.length == 0 && !(allowEmpty && path.length == 0))) return NO;
  }
  return YES;
}

static BOOL DSHAgentArgumentWritePriorShape(id prior) {
  if (![prior isKindOfClass:NSDictionary.class]) return NO;
  NSString *kind = prior[@"kind"];
  if (![kind isKindOfClass:NSString.class]) return NO;
  if ([kind isEqualToString:@"absent"]) {
    return DSHAgentExactDictionaryKeys(prior, @[@"schema_version", @"kind"]) &&
        DSHAgentSafeInteger(prior[@"schema_version"], 1, NO);
  }
  if ([kind isEqualToString:@"known"]) {
    return DSHAgentExactDictionaryKeys(prior, @[
      @"schema_version", @"kind", @"revision",
    ]) && DSHAgentSafeInteger(prior[@"schema_version"], 1, NO) &&
        DSHAgentBoundedUTF8String(prior[@"revision"], 256, NO, nullptr);
  }
  return [kind isEqualToString:@"unknown"] &&
      DSHAgentExactDictionaryKeys(prior, @[
        @"schema_version", @"kind", @"failure_code",
      ]) && DSHAgentSafeInteger(prior[@"schema_version"], 1, NO) &&
      DSHAgentFailureCode(prior[@"failure_code"]);
}

static BOOL DSHAgentToolNameWellFormed(NSString *name, NSString **toolName) {
  if (!DSHAgentBoundedUTF8String(name, 64, NO, toolName)) return NO;
  NSCharacterSet *invalid = [[NSCharacterSet
      characterSetWithCharactersInString:
          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"]
      invertedSet];
  return [*toolName rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static BOOL DSHAgentToolArgumentsRefused(NSString **failureCode,
                                         NSString **reason,
                                         NSString *code,
                                         NSString *token) {
  if (failureCode != nullptr) *failureCode = code;
  if (reason != nullptr) *reason = token;
  return NO;
}

BOOL DSHAgentToolArgumentsAccepted(NSString *name,
                                   NSDictionary *arguments,
                                   NSString **failureCode,
                                   NSString **reason) {
  NSString *toolName = nil;
  if (!DSHAgentToolNameWellFormed(name, &toolName) ||
      ![arguments isKindOfClass:NSDictionary.class]) {
    return DSHAgentToolArgumentsRefused(failureCode, reason,
        @"E_AGENT_BAD_ARGUMENTS", @"arguments_do_not_match_tool_schema");
  }
  if (DSHAgentIsRuntimeTool(toolName)) {
    NSDictionary *validation = DSHAgentRuntimeContract(@"runtime_arguments", arguments, toolName);
    if ([validation[@"valid"] isEqual:@YES]) return YES;
    return DSHAgentToolArgumentsRefused(failureCode, reason,
        validation[@"failure_code"] ?: @"E_AGENT_BAD_ARGUMENTS",
        validation[@"reason"] ?: @"arguments_do_not_match_tool_schema");
  }
  if ([toolName isEqual:@"ask_user"]) {
    if (DSHAgentRuntimeContractValid(@"question_arguments", arguments)) return YES;
    return DSHAgentToolArgumentsRefused(failureCode, reason,
        @"E_AGENT_BAD_ARGUMENTS", @"arguments_do_not_match_tool_schema");
  }
  if ([toolName isEqualToString:@"write_file"] ||
      [toolName isEqualToString:@"read_file"] ||
      [toolName isEqualToString:@"list_dir"]) {
    NSString *path = arguments[@"path"];
    BOOL listDirectory = [toolName isEqualToString:@"list_dir"];
    BOOL exactPath = [toolName isEqualToString:@"write_file"]
        ? [path isKindOfClass:NSString.class]
        : (listDirectory
            ? (arguments.count == 0 || DSHAgentExactDictionaryKeys(arguments, @[@"path"]))
            : DSHAgentExactDictionaryKeys(arguments, @[@"path"]));
    if (listDirectory && path == nil) path = @"";
    if (!exactPath || ![path isKindOfClass:NSString.class]) {
      return DSHAgentToolArgumentsRefused(failureCode, reason,
          @"E_AGENT_BAD_ARGUMENTS", @"arguments_do_not_match_tool_schema");
    }
    if (!DSHAgentArgumentPathAllowed(path, listDirectory)) {
      return DSHAgentToolArgumentsRefused(failureCode, reason,
          @"E_AGENT_BAD_PATH",
          [path hasPrefix:@"/"]
              ? @"path_must_be_relative_to_workspace_root"
              : @"path_contains_disallowed_segment_or_character");
    }
  }
  if ([toolName isEqualToString:@"write_file"]) {
    id expectedRevision = arguments[@"expected_revision"];
    id expectedPrior = arguments[@"expected_prior"];
    NSData *contentBytes = [arguments[@"content"]
        isKindOfClass:NSString.class]
        ? [arguments[@"content"] dataUsingEncoding:NSUTF8StringEncoding]
        : nil;
    if ((!DSHAgentExactDictionaryKeys(arguments,
                                      @[@"path", @"content", @"expected_revision"]) &&
         !DSHAgentExactDictionaryKeys(arguments,
                                      @[@"path", @"content", @"expected_prior"])) ||
        ![arguments[@"content"] isKindOfClass:NSString.class] ||
        contentBytes == nil ||
        (expectedRevision != nil && expectedRevision != NSNull.null &&
         !DSHAgentBoundedUTF8String(expectedRevision, 256, NO, nullptr)) ||
        (expectedPrior != nil && !DSHAgentArgumentWritePriorShape(expectedPrior))) {
      return DSHAgentToolArgumentsRefused(failureCode, reason,
          @"E_AGENT_BAD_ARGUMENTS", @"arguments_do_not_match_tool_schema");
    }
    // Admission of a new call is separate from its durable identity/shape.
    // Keep malformed historical calls readable, but do not send a provider's
    // stringified sentinel to the executor as a stale file revision. It must
    // settle as repairable feedback, without silently changing it to null.
    if ([expectedRevision isEqual:@"null"] ||
        [expectedRevision isEqual:@"undefined"]) {
      return DSHAgentToolArgumentsRefused(failureCode, reason,
          @"E_AGENT_BAD_ARGUMENTS",
          @"expected_revision_must_be_json_null_or_a_read_file_revision");
    }
    if (contentBytes.length > DSHAgentNativeWALMaxSingleWriteBytes) {
      return DSHAgentToolArgumentsRefused(failureCode, reason,
          @"E_AGENT_BAD_ARGUMENTS", @"content_exceeds_single_write_limit");
    }
  } else if ([toolName isEqualToString:@"git_commit"] &&
             (!DSHAgentExactDictionaryKeys(arguments, @[@"message"]) ||
              !DSHAgentBoundedUTF8String(arguments[@"message"], 500, NO, nullptr))) {
    return DSHAgentToolArgumentsRefused(failureCode, reason,
        @"E_AGENT_BAD_ARGUMENTS", @"arguments_do_not_match_tool_schema");
  } else if ([toolName isEqualToString:@"git_push"] &&
             arguments.count != 0) {
    return DSHAgentToolArgumentsRefused(failureCode, reason,
        @"E_AGENT_BAD_ARGUMENTS", @"arguments_do_not_match_tool_schema");
  }
  return YES;
}

NSString *DSHAgentArgumentsSHA256(NSString *name,
                                  NSString *argumentsJSON,
                                  NSError **error) {
  // The digest binds a call's identity: any well-formed tool name over any
  // parseable argument object.  Whether the arguments are acceptable to the
  // tool (paths, schema, sizes) is a separate question answered by
  // DSHAgentToolArgumentsAccepted, so a refusal can settle as a tool result
  // the model sees instead of failing the round that carried it.
  NSString *toolName = nil;
  if (!DSHAgentToolNameWellFormed(name, &toolName)) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *arguments = DSHAgentParseArgumentsJSON(argumentsJSON, error);
  if (arguments == nil) return nil;
  return DSHAgentHJ(@"tool-arguments", @{
    @"name" : toolName,
    @"arguments" : arguments,
  }, error);
}

NSString *DSHAgentIdempotencyKeyForLocator(NSDictionary *locator,
                                           NSString *rootFingerprintSHA256,
                                           NSString *argumentsSHA256,
                                           NSError **error) {
  if (!DSHAgentExactDictionaryKeys(locator, @[
        @"schema_version", @"task_id", @"attempt_id", @"round_id",
        @"round_index", @"call_index", @"call_id", @"idempotency_key",
      ]) || ![locator[@"schema_version"] isEqual:@2] ||
      !DSHAgentCanonicalUUID(locator[@"task_id"]) ||
      !DSHAgentCanonicalUUID(locator[@"attempt_id"]) ||
      !DSHAgentCanonicalUUID(locator[@"round_id"]) ||
      !DSHAgentSafeInteger(locator[@"round_index"], 7, YES) ||
      !DSHAgentSafeInteger(locator[@"call_index"], 15, YES) ||
      !DSHAgentBoundedUTF8String(locator[@"call_id"], 128, NO, nullptr) ||
      !DSHAgentCanonicalSHA256(rootFingerprintSHA256) ||
      !DSHAgentCanonicalSHA256(argumentsSHA256)) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSCharacterSet *invalidCallId = [[NSCharacterSet
      characterSetWithCharactersInString:
          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"]
      invertedSet];
  if ([locator[@"call_id"] rangeOfCharacterFromSet:invalidCallId].location != NSNotFound) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  return DSHAgentHJ(@"tool-idempotency", @{
    @"task_id" : locator[@"task_id"],
    @"attempt_id" : locator[@"attempt_id"],
    @"round_id" : locator[@"round_id"],
    @"round_index" : locator[@"round_index"],
    @"call_index" : locator[@"call_index"],
    @"call_id" : locator[@"call_id"],
    @"root_fingerprint_sha256" : rootFingerprintSHA256,
    @"arguments_sha256" : argumentsSHA256,
  }, error);
}

// What a tool is allowed to report was ~190 lines here and is also
// `execution_ledger::feedback_string_valid` in the shared core, which the
// ledger already applies to every stored row.  Two copies of the contract
// between "a tool ran" and "the engine believes something" is one too many, so
// this is now the way a host reaches that one — `tool_feedback` on the
// WAL-state reducer.  An oversized report stays a capacity refusal, which a
// caller recovers from differently than a malformed one.
BOOL DSHAgentValidateNativeToolFeedbackString(NSString *feedbackJSON,
                                              NSError **error) {
  if (![feedbackJSON isKindOfClass:NSString.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return NO;
  }
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:@{
    @"op" : @"tool_feedback", @"value" : feedbackJSON,
  } options:0 error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_wal_state_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return NO;
  }
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  if (![reply isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return NO;
  }
  if ([reply[@"ok"] isEqual:@YES]) {
    if (error != nullptr) *error = nil;
    return YES;
  }
  NSInteger code = [reply[@"error"] isKindOfClass:NSNumber.class]
      ? [reply[@"error"] integerValue] : 0;
  if (code < DSHAgentNativeStoreErrorInvalidArgument ||
      code > DSHAgentNativeStoreErrorPersistence) {
    code = DSHAgentNativeStoreErrorInvalidArgument;
  }
  DSHSetAgentNativeStoreError(error, (DSHAgentNativeStoreErrorCode)code);
  return NO;
}

static BOOL DSHAgentDirectoryIsSafe(NSURL *url) {
  if (url == nil || !url.isFileURL) return NO;
  struct stat metadata = {};
  return lstat(url.fileSystemRepresentation, &metadata) == 0 &&
      S_ISDIR(metadata.st_mode) && !S_ISLNK(metadata.st_mode) &&
      metadata.st_nlink >= 2;
}

// Application-owned methods keep device-only metadata requirements testable on
// simulator filesystems. They never change the descriptor/identity checks.
@interface DSHAgentNativeWAL (ProtectionMetadata)
- (BOOL)requiresWALResourceMetadata;
- (NSFileManager *)walFileManager;
- (BOOL)setWALProtectionAtURL:(NSURL *)url error:(NSError **)error;
- (BOOL)getWALProtectionAtURL:(NSURL *)url value:(id *)value error:(NSError **)error;
- (BOOL)setWALBackupExcludedAtURL:(NSURL *)url error:(NSError **)error;
- (BOOL)getWALBackupExcludedAtURL:(NSURL *)url
                          value:(NSNumber **)value error:(NSError **)error;
@end

static BOOL DSHAgentVerifyFileProtectionDescriptor(DSHAgentNativeWAL *store,
                                                   int descriptor,
                                                   const struct stat *expected);

static BOOL DSHAgentEnsureDirectory(DSHAgentNativeWAL *store, NSURL *url) {
  if (url == nil || !url.isFileURL) return NO;
  NSURL *parentURL = url.URLByDeletingLastPathComponent;
  int parentDescriptor = open(parentURL.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  struct stat parentMetadata = {};
  if (parentDescriptor < 0 || fstat(parentDescriptor, &parentMetadata) != 0 ||
      !S_ISDIR(parentMetadata.st_mode) || parentMetadata.st_nlink < 2) {
    if (parentDescriptor >= 0) close(parentDescriptor);
    return NO;
  }
  struct stat metadata = {};
  BOOL existed = lstat(url.fileSystemRepresentation, &metadata) == 0;
  struct stat initialMetadata = metadata;
  if (existed) {
    if (!S_ISDIR(metadata.st_mode) || S_ISLNK(metadata.st_mode)) {
      close(parentDescriptor);
      return NO;
    }
  } else if (errno == ENOENT) {
    if (mkdir(url.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) {
      close(parentDescriptor);
      return NO;
    }
  } else {
    close(parentDescriptor);
    return NO;
  }
  // All security-sensitive mutation is performed through an opened
  // descriptor.  The final path is re-stat'ed through its opened parent both
  // before and after protection metadata changes, so a path swap cannot turn
  // chmod/protection application into mutation of an attacker-selected
  // directory.
  int descriptor = open(url.fileSystemRepresentation,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  if (descriptor < 0) {
    close(parentDescriptor);
    return NO;
  }
  struct stat opened = {};
  BOOL identityOK = fstat(descriptor, &opened) == 0 &&
      S_ISDIR(opened.st_mode) && !S_ISLNK(opened.st_mode) &&
      opened.st_nlink >= 2 &&
      (!existed || (opened.st_dev == initialMetadata.st_dev &&
                    opened.st_ino == initialMetadata.st_ino));
  struct stat fromParent = {};
  identityOK = identityOK &&
      fstatat(parentDescriptor, url.lastPathComponent.UTF8String, &fromParent,
              AT_SYMLINK_NOFOLLOW) == 0 &&
      S_ISDIR(fromParent.st_mode) && !S_ISLNK(fromParent.st_mode) &&
      fromParent.st_dev == opened.st_dev && fromParent.st_ino == opened.st_ino &&
      fchmod(descriptor, 0700) == 0;
  if (!identityOK) {
    if (parentDescriptor >= 0) close(parentDescriptor);
    close(descriptor);
    return NO;
  }
  NSError *attributeError = nil;
  // Keep the POSIX mode operation independent from the iOS metadata keys.
  // The simulator filesystem does not implement all NSFileProtection and
  // backup-resource keys, so those requests are best effort there; physical
  // iOS still requires UntilFirstAuthentication protection and backup exclusion.
  BOOL permissions = [[NSFileManager defaultManager]
      setAttributes:@{ NSFilePosixPermissions : @0700 }
       ofItemAtPath:url.path
              error:&attributeError];
  BOOL protection = [store setWALProtectionAtURL:url error:&attributeError];
  BOOL excluded = [store setWALBackupExcludedAtURL:url error:&attributeError];
  BOOL attributes = permissions &&
      (![store requiresWALResourceMetadata] || (protection && excluded));
  struct stat after = {};
  struct stat fromParentAfter = {};
  BOOL unchanged = fstat(descriptor, &after) == 0 &&
      fstatat(parentDescriptor, url.lastPathComponent.UTF8String, &fromParentAfter,
              AT_SYMLINK_NOFOLLOW) == 0 &&
      after.st_dev == opened.st_dev && after.st_ino == opened.st_ino &&
      S_ISDIR(fromParentAfter.st_mode) &&
      fromParentAfter.st_dev == opened.st_dev &&
      fromParentAfter.st_ino == opened.st_ino &&
      (after.st_mode & 0777) == 0700;
  BOOL protectionOK = unchanged &&
      DSHAgentVerifyFileProtectionDescriptor(store, descriptor, &opened);
  close(parentDescriptor);
  close(descriptor);
  return attributes && unchanged && protectionOK;
}

static BOOL DSHAgentWriteAll(int descriptor, NSData *data) {
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  NSUInteger offset = 0;
  while (offset < data.length) {
    ssize_t written = write(descriptor, bytes + offset, data.length - offset);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return NO;
    offset += (NSUInteger)written;
  }
  return fsync(descriptor) == 0;
}

static int DSHAgentOpenRootDescriptor(NSURL *rootURL) {
  if (rootURL == nil || !rootURL.isFileURL) return -1;
  int descriptor = open(rootURL.fileSystemRepresentation,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  if (descriptor < 0) return -1;
  int parentDescriptor = open(rootURL.URLByDeletingLastPathComponent.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  struct stat opened = {};
  struct stat fromParent = {};
  BOOL identityOK = parentDescriptor >= 0 && fstat(descriptor, &opened) == 0 &&
      S_ISDIR(opened.st_mode) && !S_ISLNK(opened.st_mode) &&
      opened.st_nlink >= 2 &&
      fstatat(parentDescriptor, rootURL.lastPathComponent.UTF8String, &fromParent,
              AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(fromParent.st_mode) &&
      !S_ISLNK(fromParent.st_mode) && fromParent.st_dev == opened.st_dev &&
      fromParent.st_ino == opened.st_ino;
  if (parentDescriptor >= 0) close(parentDescriptor);
  if (!identityOK) {
    close(descriptor);
    return -1;
  }
  return descriptor;
}

static BOOL DSHAgentRegularFileIdentity(struct stat metadata) {
  return S_ISREG(metadata.st_mode) && !S_ISLNK(metadata.st_mode) &&
      metadata.st_nlink == 1 && (metadata.st_mode & 0777) == 0600;
}

static BOOL DSHAgentVerifyFileProtectionDescriptor(DSHAgentNativeWAL *store,
                                                   int descriptor,
                                                   const struct stat *expected) {
  if (descriptor < 0) return NO;
  struct stat opened = {};
  if (fstat(descriptor, &opened) != 0 ||
      (expected != nullptr &&
       (opened.st_dev != expected->st_dev || opened.st_ino != expected->st_ino))) {
    return NO;
  }
  char resolvedPath[PATH_MAX] = {};
  if (fcntl(descriptor, F_GETPATH, resolvedPath) != 0) return NO;
  NSURL *descriptorURL = [NSURL fileURLWithPath:
      [[NSFileManager defaultManager]
          stringWithFileSystemRepresentation:resolvedPath
                                       length:strlen(resolvedPath)]];
  struct stat pathBefore = {};
  if (lstat(resolvedPath, &pathBefore) != 0 ||
      (!S_ISREG(pathBefore.st_mode) && !S_ISDIR(pathBefore.st_mode)) ||
      S_ISLNK(pathBefore.st_mode) || pathBefore.st_dev != opened.st_dev ||
      pathBefore.st_ino != opened.st_ino) {
    return NO;
  }
  if ([store requiresWALResourceMetadata]) {
    // An item created by an earlier build, or by a path that never applied
    // the policy, carries a different (or absent) protection class and no
    // backup exclusion. Re-apply the required metadata in place once and
    // read it back, the way the workspace store migrates a legacy class,
    // instead of refusing the store forever. The descriptor and path
    // identity are re-checked below, so the repair cannot be redirected.
    id protection = nil;
    BOOL protectionOK =
        [store getWALProtectionAtURL:descriptorURL value:&protection error:nil] &&
        [protection isEqual:NSFileProtectionCompleteUntilFirstUserAuthentication];
    if (!protectionOK) {
      protection = nil;
      protectionOK =
          [store setWALProtectionAtURL:descriptorURL error:nil] &&
          [store getWALProtectionAtURL:descriptorURL value:&protection error:nil] &&
          [protection isEqual:NSFileProtectionCompleteUntilFirstUserAuthentication];
    }
    NSNumber *excluded = nil;
    BOOL excludedOK =
        [store getWALBackupExcludedAtURL:descriptorURL value:&excluded error:nil] &&
        [excluded isKindOfClass:NSNumber.class] && excluded.boolValue;
    if (!excludedOK) {
      excluded = nil;
      excludedOK =
          [store setWALBackupExcludedAtURL:descriptorURL error:nil] &&
          [store getWALBackupExcludedAtURL:descriptorURL value:&excluded error:nil] &&
          [excluded isKindOfClass:NSNumber.class] && excluded.boolValue;
    }
    if (!protectionOK || !excludedOK) return NO;
  }
  struct stat after = {};
  struct stat pathAfter = {};
  int descriptorResult = fstat(descriptor, &after);
  int pathResult = lstat(resolvedPath, &pathAfter);
  BOOL descriptorIdentity = descriptorResult == 0 &&
      after.st_dev == opened.st_dev && after.st_ino == opened.st_ino;
  BOOL pathIdentity = pathResult == 0 &&
      pathAfter.st_dev == opened.st_dev && pathAfter.st_ino == opened.st_ino;
  BOOL modeIdentity = pathResult == 0 &&
      pathAfter.st_mode == pathBefore.st_mode;
  return descriptorIdentity && pathIdentity && modeIdentity;
}

static NSData *DSHAgentReadDescriptor(int descriptor,
                                      NSUInteger maximum,
                                      NSError **error) {
  NSMutableData *data = [NSMutableData dataWithCapacity:4096];
  uint8_t buffer[16 * 1024];
  while (YES) {
    ssize_t count = read(descriptor, buffer, sizeof(buffer));
    if (count < 0 && errno == EINTR) continue;
    if (count == 0) break;
    if (count < 0 || data.length > maximum - (NSUInteger)count) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCapacity);
      return nil;
    }
    [data appendBytes:buffer length:(NSUInteger)count];
  }
  return data;
}

static NSData *DSHAgentReadWALAtRoot(DSHAgentNativeWAL *store,
                                     int rootDescriptor,
                                     const char *name,
                                     NSError **error) {
  struct stat metadata = {};
  if (fstatat(rootDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno == ENOENT) return nil;
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  if (!DSHAgentRegularFileIdentity(metadata)) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  int descriptor = openat(rootDescriptor, name, O_RDONLY | O_NOFOLLOW);
  if (descriptor < 0) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  struct stat opened = {};
  BOOL valid = fstat(descriptor, &opened) == 0 &&
      DSHAgentRegularFileIdentity(opened) && opened.st_dev == metadata.st_dev &&
      opened.st_ino == metadata.st_ino &&
      DSHAgentVerifyFileProtectionDescriptor(store, descriptor, &opened);
  NSData *data = valid ? DSHAgentReadDescriptor(descriptor,
                                                DSHAgentNativeWALMaxStoreBytes,
                                                error) : nil;
  struct stat after = {};
  valid = valid && fstat(descriptor, &after) == 0 &&
      after.st_dev == opened.st_dev && after.st_ino == opened.st_ino &&
      after.st_size == opened.st_size;
  close(descriptor);
  if (!valid || data == nil) {
    if (error == nullptr || *error == nil) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    }
    return nil;
  }
  return data;
}

static NSRecursiveLock *DSHAgentLockForRoot(NSURL *rootURL) {
  static NSMutableDictionary<NSString *, NSRecursiveLock *> *locks;
  static NSLock *guard;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    locks = [NSMutableDictionary dictionary];
    guard = [[NSLock alloc] init];
  });
  NSString *key = rootURL.path.stringByStandardizingPath ?: @"<invalid>";
  [guard lock];
  NSRecursiveLock *lock = locks[key];
  if (lock == nil) {
    lock = [[NSRecursiveLock alloc] init];
    locks[key] = lock;
  }
  [guard unlock];
  return lock;
}

static NSMutableDictionary *DSHAgentFreshWALState(void) {
  return [@{
    @"schema_version" : @2,
    @"generation" : @0,
    @"authorities" : @[],
    @"operations" : @[],
    @"operation_results" : @[],
    @"transcripts" : @[],
    @"rounds" : @[],
    @"ledger" : @[],
    @"reservations" : @[],
    @"cleanup" : @[],
    @"dispatch" : @[],
    @"batches" : @[],
    @"denied_calls" : @[],
  } mutableCopy];
}


// The stored row shapes live in the shared core (modules/rish/core,
// `rish_agent_wal_state_reduce`). This side keeps the file, the descriptors,
// the locks and the transaction; every row the loader re-validates is judged
// there so both platforms accept exactly the same stored state.
static NSDictionary *DSHAgentWALCoreReduceWithEnvironment(NSString *op, id value,
                                                          NSDictionary *env) {
  NSMutableDictionary *envelope = [@{
    @"op" : op, @"value" : value ?: NSNull.null,
  } mutableCopy];
  if (env != nil) envelope[@"env"] = env;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
  if (bytes == nil) return nil;
  char *raw = rish_agent_wal_state_reduce((const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil];
  if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"ok"] isEqual:@YES]) {
    return nil;
  }
  return reply;
}

static NSDictionary *DSHAgentWALCoreReduce(NSString *op, id value) {
  return DSHAgentWALCoreReduceWithEnvironment(op, value, nil);
}

static BOOL DSHAgentWALCoreValid(NSString *op, id value, NSDictionary *env) {
  NSMutableDictionary *envelope = [@{
    @"op" : op, @"value" : value ?: NSNull.null,
  } mutableCopy];
  if (env != nil) envelope[@"env"] = env;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
  if (bytes == nil) return NO;
  char *raw = rish_agent_wal_state_reduce((const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return NO;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil];
  return [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] && [reply[@"valid"] isEqual:@YES];
}

// Catalogue answers the authority shape needs, collected from the strings
// the row actually carries.
static NSDictionary *DSHAgentWALCoreEnvironment(NSDictionary *authority) {
  NSMutableArray<NSString *> *models = [NSMutableArray array];
  NSMutableDictionary<NSString *, NSString *> *harnessByModel =
      [NSMutableDictionary dictionary];
  id model = authority[@"model"];
  if ([model isKindOfClass:NSString.class] && DSHHarnessIsSupportedModel(model)) {
    [models addObject:model];
    NSString *harness = DSHHarnessIdForModel(model);
    if (harness != nil) harnessByModel[model] = harness;
  }
  return @{
    @"supported_models" : [models copy],
    @"harness_by_model" : [harnessByModel copy],
    @"provider_ids" : @[],
    @"host_by_model" : @{},
    @"provider_bindings" : @[],
  };
}

@interface DSHAgentNativeWAL (DSHAgentNativeWALResidentState)
- (nullable NSDictionary *)loadStateLocked:(NSError **)error;
@end

// MARK: - the resident committed state
//
// The core holds each storage root's committed state behind an opaque handle
// (modules/rish/core, wal_resident.rs), so a transaction that already knows
// what is committed does not re-read and re-parse the file to find out.
//
// Two rules keep that sound. The handle belongs to the root, not to an
// instance, because several DSHAgentNativeWAL objects can address one root and
// there must never be two owners of one state. And the handle is only trusted
// while the file it was read from is still the file on disk: anything that
// replaces the WAL behind our back — a test fixture, a restore, a future tool
// — changes the identity below and the state is read again.

typedef NS_ENUM(NSUInteger, DSHAgentWALConfirmation) {
  // The bytes are durable.
  DSHAgentWALConfirmationCommitted = 0,
  // The bytes provably never replaced the committed file.
  DSHAgentWALConfirmationNotCommitted,
  // Neither could be established. The file may or may not be the candidate.
  DSHAgentWALConfirmationUnknown,
};

@interface DSHAgentWALResident : NSObject
@property(nonatomic) void *handle;
@property(nonatomic) dev_t device;
@property(nonatomic) ino_t inode;
@property(nonatomic) off_t size;
@property(nonatomic) struct timespec modified;
@property(nonatomic) BOOL missing;
@end

@implementation DSHAgentWALResident
- (void)dealloc {
  rish_agent_wal_close(_handle);
  _handle = NULL;
}
@end

static NSMutableDictionary<NSString *, DSHAgentWALResident *> *DSHAgentWALResidents(void) {
  static NSMutableDictionary<NSString *, DSHAgentWALResident *> *residents;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{ residents = [NSMutableDictionary dictionary]; });
  return residents;
}

static NSString *DSHAgentWALResidentKey(NSURL *rootURL) {
  return rootURL.path.stringByStandardizingPath ?: @"<invalid>";
}

/// The identity of the committed file right now, or a missing marker.
static BOOL DSHAgentWALFileIdentity(NSURL *rootURL, struct stat *metadata,
                                    BOOL *missing) {
  *missing = NO;
  int rootDescriptor = DSHAgentOpenRootDescriptor(rootURL);
  if (rootDescriptor < 0) return NO;
  BOOL ok = fstatat(rootDescriptor, DSHAgentWALFileName.UTF8String, metadata,
                    AT_SYMLINK_NOFOLLOW) == 0;
  if (!ok && errno == ENOENT) {
    *missing = YES;
    ok = YES;
    *metadata = (struct stat){};
  }
  close(rootDescriptor);
  return ok;
}

static BOOL DSHAgentWALResidentMatches(DSHAgentWALResident *resident,
                                       const struct stat *metadata,
                                       BOOL missing) {
  if (resident.missing != missing) return NO;
  if (missing) return YES;
  return resident.device == metadata->st_dev && resident.inode == metadata->st_ino &&
      resident.size == metadata->st_size &&
      resident.modified.tv_sec == metadata->st_mtimespec.tv_sec &&
      resident.modified.tv_nsec == metadata->st_mtimespec.tv_nsec;
}

static void DSHAgentWALForgetResident(NSURL *rootURL) {
  @synchronized (DSHAgentNativeWAL.class) {
    [DSHAgentWALResidents() removeObjectForKey:DSHAgentWALResidentKey(rootURL)];
  }
}

/// The committed state, from the resident handle when it still describes the
/// file on disk, and from the file itself otherwise.
static NSMutableDictionary *DSHAgentWALCommittedState(DSHAgentNativeWAL *wal,
                                                      NSError **error) {
  struct stat metadata = {};
  BOOL missing = NO;
  BOOL identified = DSHAgentWALFileIdentity(wal.rootURL, &metadata, &missing);
  NSString *key = DSHAgentWALResidentKey(wal.rootURL);
  if (identified) {
    @synchronized (DSHAgentNativeWAL.class) {
      DSHAgentWALResident *resident = DSHAgentWALResidents()[key];
      if (resident != nil && DSHAgentWALResidentMatches(resident, &metadata, missing)) {
        char *raw = rish_agent_wal_snapshot(resident.handle);
        if (raw != NULL) {
          NSData *bytes = [NSData dataWithBytes:raw length:strlen(raw)];
          rish_agent_string_free(raw);
          id state = [NSJSONSerialization JSONObjectWithData:bytes
              options:NSJSONReadingMutableContainers | NSJSONReadingMutableLeaves
                error:nil];
          if ([state isKindOfClass:NSDictionary.class]) return [state mutableCopy];
        }
        // The handle can no longer say what is committed; only the file can.
        [DSHAgentWALResidents() removeObjectForKey:key];
      }
    }
  }
  NSMutableDictionary *state = [[wal loadStateLocked:error] mutableCopy];
  if (state == nil || !identified) return state;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
  if (bytes == nil) return state;
  void *handle = rish_agent_wal_open((const char *)bytes.bytes, bytes.length);
  if (handle == NULL) return state;
  DSHAgentWALResident *resident = [[DSHAgentWALResident alloc] init];
  resident.handle = handle;
  resident.device = metadata.st_dev;
  resident.inode = metadata.st_ino;
  resident.size = metadata.st_size;
  resident.modified = metadata.st_mtimespec;
  resident.missing = missing;
  @synchronized (DSHAgentNativeWAL.class) { DSHAgentWALResidents()[key] = resident; }
  return state;
}

/// Hands the candidate to the resident handle and resolves it with what the
/// host learned. An unknown outcome drops the handle rather than guessing:
/// the next transaction reads the file again.
static void DSHAgentWALPublish(DSHAgentNativeWAL *wal, NSDictionary *candidate,
                               DSHAgentWALConfirmation confirmation) {
  NSString *key = DSHAgentWALResidentKey(wal.rootURL);
  DSHAgentWALResident *resident = nil;
  @synchronized (DSHAgentNativeWAL.class) { resident = DSHAgentWALResidents()[key]; }
  if (resident == nil) return;
  if (confirmation != DSHAgentWALConfirmationCommitted) {
    // Nothing was published, and an unknown outcome means the handle can no
    // longer describe the file either way.
    if (confirmation == DSHAgentWALConfirmationUnknown) {
      DSHAgentWALForgetResident(wal.rootURL);
    }
    return;
  }
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:candidate options:0 error:nil];
  BOOL published = NO;
  if (bytes != nil) {
    char *staged = rish_agent_wal_begin(resident.handle,
                                        (const char *)bytes.bytes, bytes.length);
    if (staged != NULL) {
      rish_agent_string_free(staged);
      const char *outcome = "committed";
      char *reply = rish_agent_wal_confirm(resident.handle, outcome, strlen(outcome));
      if (reply != NULL) {
        NSData *replyBytes = [NSData dataWithBytes:reply length:strlen(reply)];
        rish_agent_string_free(reply);
        id parsed = [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil];
        published = [parsed isKindOfClass:NSDictionary.class] &&
            [parsed[@"published"] isEqual:@YES];
      }
    }
  }
  if (!published) {
    DSHAgentWALForgetResident(wal.rootURL);
    return;
  }
  // The file the state now describes is the one the write just left behind.
  struct stat metadata = {};
  BOOL missing = NO;
  if (!DSHAgentWALFileIdentity(wal.rootURL, &metadata, &missing) || missing) {
    DSHAgentWALForgetResident(wal.rootURL);
    return;
  }
  resident.device = metadata.st_dev;
  resident.inode = metadata.st_ino;
  resident.size = metadata.st_size;
  resident.modified = metadata.st_mtimespec;
  resident.missing = NO;
}

static BOOL DSHAgentWALContainsForbiddenSafeKey(id value) {
  static NSSet<NSString *> *forbidden;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    forbidden = [NSSet setWithArray:@[
      @"arguments", @"content", @"path", @"raw_arguments", @"raw_result",
      @"tool_feedback", @"messages", @"native_envelope", @"precondition",
      @"settled_facts", @"patch", @"owner", @"arguments_json",
    ]];
  });
  if ([value isKindOfClass:NSDictionary.class]) {
    for (id key in (NSDictionary *)value) {
      if ([forbidden containsObject:key] ||
          DSHAgentWALContainsForbiddenSafeKey(((NSDictionary *)value)[key])) return YES;
    }
  } else if ([value isKindOfClass:NSArray.class]) {
    for (id child in (NSArray *)value) {
      if (DSHAgentWALContainsForbiddenSafeKey(child)) return YES;
    }
  }
  return NO;
}

static BOOL DSHAgentWALBatchShapeV2(NSDictionary *batch) {
  return DSHAgentWALCoreValid(@"batch_v2", batch, nil);
}

// The core judges every V3 rule and hands back the schema-2 projection; the
// round journal's own V2 entry validator still has the last word, so a V3 row
// can never be accepted on relations the projection would fail.
static BOOL DSHAgentWALRoundV3Shape(NSDictionary *row) {
  NSDictionary *reply = DSHAgentWALCoreReduce(@"round_v3", row);
  return [reply[@"valid"] isEqual:@YES] &&
      DSHAgentValidateRoundNativeEntryV2(reply[@"v2"], nullptr);
}

static NSDictionary *DSHAgentWALMigrateRoundV2ToV3(NSDictionary *row,
                                                    NSError **error) {
  if (![row[@"schema_version"] isEqual:@2] ||
      !DSHAgentValidateRoundNativeEntryV2(row, error)) return nil;
  NSDictionary *reply = DSHAgentWALCoreReduce(@"migrate_round", row);
  if (![reply[@"valid"] isEqual:@YES] ||
      !DSHAgentValidateRoundNativeEntryV2(reply[@"v2"], nullptr)) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  return reply[@"row"];
}

static NSDictionary *DSHAgentWALMigrateBatchV1ToV2(NSDictionary *batch,
                                                    NSError **error) {
  NSDictionary *reply = DSHAgentWALCoreReduce(@"migrate_batch", batch);
  if (![reply[@"valid"] isEqual:@YES]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  return reply[@"batch"];
}

static NSMutableDictionary *DSHAgentWALMigrateV1ToV2(NSDictionary *state,
                                                      NSError **error) {
  if (![state[@"schema_version"] isEqual:@1] ||
      !DSHAgentExactDictionaryKeys(state, DSHAgentWALV1Keys()) ||
      [state[@"generation"] unsignedLongLongValue] >=
          DSHAgentMaximumSafeInteger) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSMutableArray *rounds = [NSMutableArray arrayWithCapacity:
      [(NSArray *)state[@"rounds"] count]];
  for (NSDictionary *round in state[@"rounds"]) {
    NSDictionary *migrated = DSHAgentWALMigrateRoundV2ToV3(round, error);
    if (migrated == nil) return nil;
    [rounds addObject:migrated];
  }
  NSMutableArray *batches = [NSMutableArray arrayWithCapacity:
      [(NSArray *)state[@"batches"] count]];
  NSMutableDictionary<NSString *, NSNumber *> *batchCounts =
      [NSMutableDictionary dictionary];
  for (NSDictionary *batch in state[@"batches"]) {
    NSDictionary *migrated = DSHAgentWALMigrateBatchV1ToV2(batch, error);
    if (migrated == nil) return nil;
    NSString *attemptID = migrated[@"attempt_id"];
    NSUInteger count = [batchCounts[attemptID] unsignedIntegerValue] + 1;
    if (count > DSHAgentNativeWALMaxBatchesPerAttempt) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCapacity);
      return nil;
    }
    batchCounts[attemptID] = @(count);
    [batches addObject:migrated];
  }
  NSMutableDictionary *migrated = [state mutableCopy];
  migrated[@"schema_version"] = @2;
  migrated[@"generation"] = @([state[@"generation"] unsignedLongLongValue] + 1);
  migrated[@"authorities"] = @[];
  migrated[@"operations"] = @[];
  migrated[@"operation_results"] = @[];
  migrated[@"rounds"] = rounds;
  migrated[@"batches"] = batches;
  migrated[@"denied_calls"] = @[];
  return migrated;
}

/// Typed views created before WAL schema 2 may still hand the transaction
/// block a V2 round or legacy write-batch candidate. They are never persisted
/// beside V3/V2 rows: the WAL upgrades the complete candidate in-memory before
/// validation and the single atomic replacement.
static BOOL DSHAgentWALNormalizeTransactionCandidate(NSMutableDictionary *state,
                                                     NSError **error) {
  if (![state[@"schema_version"] isEqual:@2]) return YES;
  NSMutableArray *rounds = [NSMutableArray arrayWithCapacity:
      [(NSArray *)state[@"rounds"] count]];
  for (NSDictionary *round in state[@"rounds"]) {
    if ([round[@"schema_version"] isEqual:@3]) {
      if (!DSHAgentWALRoundV3Shape(round)) {
        DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
        return NO;
      }
      [rounds addObject:round];
      continue;
    }
    NSDictionary *migrated = DSHAgentWALMigrateRoundV2ToV3(round, error);
    if (migrated == nil) return NO;
    [rounds addObject:migrated];
  }
  NSMutableArray *batches = [NSMutableArray arrayWithCapacity:
      [(NSArray *)state[@"batches"] count]];
  for (NSDictionary *batch in state[@"batches"]) {
    if ([batch[@"schema_version"] isEqual:@2]) {
      if (!DSHAgentWALBatchShapeV2(batch)) {
        DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
        return NO;
      }
      [batches addObject:batch];
      continue;
    }
    NSDictionary *migrated = DSHAgentWALMigrateBatchV1ToV2(batch, error);
    if (migrated == nil) return NO;
    [batches addObject:migrated];
  }
  state[@"rounds"] = rounds;
  state[@"batches"] = batches;
  return YES;
}

static NSString *DSHAgentFindDispatchState(NSArray *dispatchRows,
                                           NSString *kind,
                                           NSDictionary *locator);

/// WAL bootstrap rejects malformed rows before a typed view can accidentally
/// use them. Full typed round/ledger validators are mandatory here; these
/// checks additionally cover the shared envelope, cross-store bindings, and
/// uniqueness relations.
// The typed round and execution-ledger entry validators stay native, so the
// loader hands the core one verdict per row alongside the state. A ledger row
// the native validator refuses comes back by index, and the native validator
// is asked again so the error it reports is its own.
static NSDictionary *DSHAgentWALRowVerdicts(NSDictionary *state) {
  const BOOL schemaV2 = [state[@"schema_version"] isEqual:@2];
  NSMutableArray<NSNumber *> *roundValid = [NSMutableArray array];
  for (id round in state[@"rounds"]) {
    BOOL valid = [round isKindOfClass:NSDictionary.class] &&
        (schemaV2 ? DSHAgentWALRoundV3Shape(round)
                  : DSHAgentValidateRoundNativeEntryV2(round, nullptr));
    [roundValid addObject:@(valid)];
  }
  NSMutableArray<NSNumber *> *ledgerValid = [NSMutableArray array];
  for (id ledger in state[@"ledger"]) {
    BOOL valid = [ledger isKindOfClass:NSDictionary.class] &&
        DSHAgentValidateExecutionLedgerEntryV2(ledger, nullptr);
    [ledgerValid addObject:@(valid)];
  }
  NSMutableArray<NSString *> *models = [NSMutableArray array];
  NSMutableDictionary<NSString *, NSString *> *harnessByModel =
      [NSMutableDictionary dictionary];
  for (id authority in state[@"authorities"]) {
    id model = [authority isKindOfClass:NSDictionary.class] ? authority[@"model"] : nil;
    if (![model isKindOfClass:NSString.class] || harnessByModel[model] != nil ||
        !DSHHarnessIsSupportedModel(model)) {
      continue;
    }
    NSString *harness = DSHHarnessIdForModel(model);
    if (harness == nil) continue;
    [models addObject:model];
    harnessByModel[model] = harness;
  }
  return @{
    @"supported_models" : [models copy],
    @"harness_by_model" : [harnessByModel copy],
    @"provider_ids" : @[],
    @"host_by_model" : @{},
    @"provider_bindings" : @[],
    @"round_valid" : [roundValid copy],
    @"ledger_valid" : [ledgerValid copy],
  };
}

static BOOL DSHAgentWALStateBasicValidation(NSDictionary *state,
                                            NSError **error) {
  NSDictionary *reply = DSHAgentWALCoreReduceWithEnvironment(
      @"state_basic", state, DSHAgentWALRowVerdicts(state));
  if ([reply[@"valid"] isEqual:@YES]) return YES;
  NSString *kind = reply[@"error_kind"];
  if ([kind isEqualToString:@"ledger"]) {
    NSArray *rows = state[@"ledger"];
    NSUInteger index = [reply[@"index"] unsignedIntegerValue];
    if (index < rows.count &&
        !DSHAgentValidateExecutionLedgerEntryV2(rows[index], error)) {
      return NO;
    }
  }
  DSHSetAgentNativeStoreError(error, [kind isEqualToString:@"capacity"]
      ? DSHAgentNativeStoreErrorCapacity
      : DSHAgentNativeStoreErrorCorrupt);
  return NO;
}

static NSString *DSHAgentFindDispatchState(NSArray *dispatchRows,
                                           NSString *kind,
                                           NSDictionary *locator) {
  for (NSDictionary *entry in dispatchRows) {
    if ([entry[@"kind"] isEqual:kind] && [entry[@"locator"] isEqual:locator]) {
      return entry[@"dispatch_state"];
    }
  }
  return nil;
}

@interface DSHAgentNativeWAL ()
@property(nonatomic, copy, readwrite) NSString *launchId;
@property(nonatomic, strong, readwrite) NSURL *rootURL;
@property(nonatomic, strong, readwrite) NSURL *walURL;
@property(nonatomic, strong) NSRecursiveLock *lock;
@property(nonatomic, copy) DSHAgentNativeWALClock clock;
@property(nonatomic, copy) DSHAgentNativeWALIdentifierGenerator generator;
@property(nonatomic, copy) DSHAgentNativeWALFaultHook faultHook;
@property(nonatomic, strong) NSMutableSet<NSString *> *liveTaskIds;
@property(nonatomic) BOOL storageReady;
@property(nonatomic) BOOL ownerReconciled;
- (BOOL)writeStateLocked:(NSDictionary *)state
            oldGeneration:(NSUInteger)oldGeneration
             confirmation:(DSHAgentWALConfirmation *)confirmation
                     error:(NSError **)error;
- (BOOL)faultAtStage:(NSString *)stage error:(NSError **)error;
@end

static BOOL DSHAgentWALCompactAcknowledgedEvidence(NSMutableDictionary *state) {
  NSMutableSet *acknowledgedAttempts = [NSMutableSet set];
  for (NSDictionary *cleanup in state[@"cleanup"]) {
    if ([cleanup[@"status"] isEqualToString:@"discarded"] &&
        [cleanup[@"attempt_id"] isKindOfClass:NSString.class]) {
      [acknowledgedAttempts addObject:cleanup[@"attempt_id"]];
    }
  }
  if (acknowledgedAttempts.count == 0) return NO;
  NSMutableSet *protectedAttempts = [NSMutableSet set];
  for (NSDictionary *authority in state[@"authorities"]) {
    [protectedAttempts addObject:authority[@"attempt_id"]];
  }
  for (NSDictionary *round in state[@"rounds"]) {
    if ([round[@"state"] isEqualToString:@"in_flight"] ||
        [round[@"state"] isEqualToString:@"cancel_requested"] ||
        [round[@"state"] isEqualToString:@"failed_retryable"] ||
        [round[@"state"] isEqualToString:@"unknown"] ||
        [round[@"state"] isEqualToString:@"ambiguous"]) {
      [protectedAttempts addObject:round[@"locator"][@"attempt_id"]];
    }
  }
  for (NSDictionary *ledger in state[@"ledger"]) {
    if ([ledger[@"state"] isEqualToString:@"intent"] ||
        [ledger[@"state"] isEqualToString:@"running"] ||
        [ledger[@"state"] isEqualToString:@"cancel_requested"] ||
        [ledger[@"state"] isEqualToString:@"unknown"] ||
        [ledger[@"state"] isEqualToString:@"ambiguous"]) {
      [protectedAttempts addObject:ledger[@"locator"][@"attempt_id"]];
    }
  }
  [acknowledgedAttempts minusSet:protectedAttempts];
  if (acknowledgedAttempts.count == 0) return NO;
  NSMutableSet *removedOperationIDs = [NSMutableSet set];
  NSMutableArray *operations = [NSMutableArray array];
  for (NSDictionary *operation in state[@"operations"]) {
    BOOL terminal = [operation[@"state"] isEqualToString:@"committed"] ||
        [operation[@"state"] isEqualToString:@"rejected"] ||
        [operation[@"state"] isEqualToString:@"conflict"];
    if (terminal && [acknowledgedAttempts containsObject:operation[@"attempt_id"]]) {
      [removedOperationIDs addObject:operation[@"operation_id"]];
    } else {
      [operations addObject:operation];
    }
  }
  NSMutableArray *results = [NSMutableArray array];
  for (NSDictionary *result in state[@"operation_results"]) {
    if (![removedOperationIDs containsObject:result[@"operation_id"]]) {
      [results addObject:result];
    }
  }
  NSMutableArray *batches = [NSMutableArray array];
  for (NSDictionary *batch in state[@"batches"]) {
    if (![acknowledgedAttempts containsObject:batch[@"attempt_id"]]) {
      [batches addObject:batch];
    }
  }
  NSMutableArray *denials = [NSMutableArray array];
  for (NSDictionary *denial in state[@"denied_calls"]) {
    if (![acknowledgedAttempts containsObject:denial[@"attempt_id"]]) {
      [denials addObject:denial];
    }
  }
  BOOL changed = operations.count != [(NSArray *)state[@"operations"] count] ||
      results.count != [(NSArray *)state[@"operation_results"] count] ||
      batches.count != [(NSArray *)state[@"batches"] count] ||
      denials.count != [(NSArray *)state[@"denied_calls"] count];
  if (changed) {
    state[@"operations"] = operations;
    state[@"operation_results"] = results;
    state[@"batches"] = batches;
    state[@"denied_calls"] = denials;
  }
  return changed;
}

// MARK: - the operation relation
//
// start, query and commit — and the three records that share the same
// transaction — are decided by the shared core over
// `rish_agent_wal_operation_reduce`. This side keeps the file, the
// descriptors, the lock, the transaction and the clock, and applies the
// returned change set only inside a transaction it has written and confirmed.
// The clock is read once per command rather than only on the paths that use
// it; the WAL's clock is a plain wall clock in production and a constant in
// every test that injects one.

static NSDictionary *DSHAgentWALOperationReduce(NSString *op, id state,
                                                NSDictionary *arguments,
                                                NSString *timestamp,
                                                NSDictionary *snapshot) {
  NSMutableDictionary *envelope = [@{
    @"op" : op,
    @"state" : state ?: NSNull.null,
    @"arguments" : arguments ?: @{},
  } mutableCopy];
  if (timestamp != nil) envelope[@"timestamp"] = timestamp;
  if (snapshot != nil) envelope[@"snapshot"] = snapshot;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  if (bytes == nil) return nil;
  char *raw = rish_agent_wal_operation_reduce((const char *)bytes.bytes,
                                              bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                               error:nil];
  if (![reply isKindOfClass:NSDictionary.class] ||
      ![reply[@"ok"] isEqual:@YES]) {
    return nil;
  }
  return reply;
}

/// Applies one reply inside the caller's transaction. Returns YES when the
/// transaction must commit; a replay is the explicit no-op result, so it
/// leaves the mutation error nil and consumes no generation.
static BOOL DSHAgentWALApplyOperationReply(NSMutableDictionary *state,
                                           NSDictionary *reply,
                                           NSDictionary *__strong *output,
                                           NSError **error) {
  if (reply == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return NO;
  }
  NSString *result = reply[@"result"];
  if ([result isEqualToString:@"commit"]) {
    NSDictionary *changes = reply[@"changes"];
    for (NSString *key in changes) state[key] = changes[key];
    if (output != nullptr) *output = reply[@"output"];
    return YES;
  }
  if ([result isEqualToString:@"replay"]) {
    if (output != nullptr) *output = reply[@"output"];
    return NO;
  }
  DSHSetAgentNativeStoreError(
      error, (DSHAgentNativeStoreErrorCode)[reply[@"error"] integerValue]);
  return NO;
}

static NSDictionary *DSHAgentWALFinishOperation(BOOL committed,
                                                NSDictionary *output,
                                                NSError **error) {
  if (!committed && output != nil && (error == nullptr || *error == nil)) {
    return DSHAgentImmutableJSONCopy(output, error);
  }
  return committed ? DSHAgentImmutableJSONCopy(output, error) : nil;
}

static NSDictionary *DSHAgentWALPerformOperation(DSHAgentNativeWAL *wal,
                                                 NSString *op,
                                                 NSDictionary *arguments,
                                                 NSError **error) {
  if (wal == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  __block NSDictionary *output = nil;
  BOOL committed = [wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    NSDictionary *reply = DSHAgentWALOperationReduce(
        op, state, arguments, [wal currentTimestamp], nil);
    return DSHAgentWALApplyOperationReply(state, reply, &output, mutationError);
  } error:error];
  return DSHAgentWALFinishOperation(committed, output, error);
}

NSDictionary *DSHAgentNativeWALStartOperation(
    DSHAgentNativeWAL *wal,
    NSString *operationKind,
    NSDictionary *request,
    NSString *taskId,
    NSString *attemptId,
    NSNumber *authorityRevision,
    NSError **error) {
  NSError *copyError = nil;
  NSDictionary *safeRequest = DSHAgentImmutableJSONCopy(request, &copyError);
  return DSHAgentWALPerformOperation(wal, @"start", @{
    @"operation_kind" : operationKind ?: NSNull.null,
    @"request" : safeRequest ?: NSNull.null,
    @"task_id" : taskId ?: NSNull.null,
    @"attempt_id" : attemptId ?: NSNull.null,
    @"authority_revision" : authorityRevision ?: NSNull.null,
  }, error);
}

NSDictionary *DSHAgentNativeWALStartTargetOperation(
    DSHAgentNativeWAL *wal,
    NSString *operationKind,
    NSDictionary *request,
    NSDictionary *target,
    NSString *taskId,
    NSString *attemptId,
    NSNumber *authorityRevision,
    NSError **error) {
  NSError *copyError = nil;
  NSDictionary *safeRequest = DSHAgentImmutableJSONCopy(request, &copyError);
  NSDictionary *safeTarget = DSHAgentImmutableJSONCopy(target, &copyError);
  return DSHAgentWALPerformOperation(wal, @"start_target", @{
    @"operation_kind" : operationKind ?: NSNull.null,
    @"request" : safeRequest ?: NSNull.null,
    @"target" : safeTarget ?: NSNull.null,
    @"task_id" : taskId ?: NSNull.null,
    @"attempt_id" : attemptId ?: NSNull.null,
    @"authority_revision" : authorityRevision ?: NSNull.null,
  }, error);
}

NSDictionary *DSHAgentNativeWALQueryOperation(
    DSHAgentNativeWAL *wal,
    NSString *operationId,
    NSString *requestSHA256,
    NSString *taskId,
    NSString *attemptId,
    NSError **error) {
  if (wal == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *state = [wal snapshotWithError:error];
  if (state == nil) return nil;
  NSDictionary *reply = DSHAgentWALOperationReduce(@"query", state, @{
    @"operation_id" : operationId ?: NSNull.null,
    @"request_sha256" : requestSHA256 ?: NSNull.null,
    @"task_id" : taskId ?: NSNull.null,
    @"attempt_id" : attemptId ?: NSNull.null,
  }, nil, nil);
  NSDictionary *output = nil;
  DSHAgentWALApplyOperationReply([NSMutableDictionary dictionary], reply,
                                 &output, error);
  return output == nil ? nil : DSHAgentImmutableJSONCopy(output, error);
}

static NSDictionary *DSHAgentWALCommitArguments(NSString *operationId,
                                                NSString *requestSHA256,
                                                NSString *taskId,
                                                NSString *attemptId,
                                                NSString *terminalState,
                                                NSString *resultStatus,
                                                NSDictionary *resultRef,
                                                NSNumber *resultRevision,
                                                NSDictionary *safeResult) {
  NSError *copyError = nil;
  NSDictionary *immutableRef = DSHAgentImmutableJSONCopy(resultRef, &copyError);
  NSDictionary *immutableResult = DSHAgentImmutableJSONCopy(safeResult,
                                                            &copyError);
  BOOL nullRevision = resultRevision == nil ||
      resultRevision == (id)NSNull.null;
  return @{
    @"operation_id" : operationId ?: NSNull.null,
    @"request_sha256" : requestSHA256 ?: NSNull.null,
    @"task_id" : taskId ?: NSNull.null,
    @"attempt_id" : attemptId ?: NSNull.null,
    @"terminal_state" : terminalState ?: NSNull.null,
    @"result_status" : resultStatus ?: NSNull.null,
    @"result_ref" : immutableRef ?: NSNull.null,
    @"result_revision" : nullRevision ? NSNull.null : resultRevision,
    @"safe_result" : immutableResult ?: NSNull.null,
  };
}

/// The commit is decided in two halves so the in-state variant can still let
/// the fault hook refuse exactly where it used to: after the relation has
/// settled that this is a fresh commit, and before anything is written.
static NSDictionary *DSHAgentWALCommitInState(NSMutableDictionary *state,
                                              DSHAgentNativeWAL *wal,
                                              NSDictionary *arguments,
                                              BOOL fault,
                                              BOOL *changed,
                                              NSError **error) {
  NSDictionary *prepared = DSHAgentWALOperationReduce(
      @"commit_prepare", state, arguments, [wal currentTimestamp], nil);
  if (prepared == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (![prepared[@"result"] isEqualToString:@"proceed"]) {
    NSDictionary *output = nil;
    DSHAgentWALApplyOperationReply(state, prepared, &output, error);
    return output;
  }
  if (changed != nullptr) *changed = YES;
  if (fault && ![wal faultAtStage:@"wal.operation.before_result_commit"
                            error:error]) {
    return nil;
  }
  NSDictionary *applied = DSHAgentWALOperationReduce(
      @"commit_apply", state, arguments, [wal currentTimestamp],
      prepared[@"snapshot"]);
  NSDictionary *output = nil;
  if (!DSHAgentWALApplyOperationReply(state, applied, &output, error) &&
      changed != nullptr) {
    *changed = NO;
  }
  return output;
}

NSDictionary *DSHAgentNativeWALCommitOperationInState(
    NSMutableDictionary *state,
    DSHAgentNativeWAL *wal,
    NSString *operationId,
    NSString *requestSHA256,
    NSString *taskId,
    NSString *attemptId,
    NSString *terminalState,
    NSString *resultStatus,
    NSDictionary *resultRef,
    NSNumber *resultRevision,
    NSDictionary *safeResult,
    NSError **error) {
  if (![state isKindOfClass:NSMutableDictionary.class] || wal == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *arguments = DSHAgentWALCommitArguments(
      operationId, requestSHA256, taskId, attemptId, terminalState,
      resultStatus, resultRef, resultRevision, safeResult);
  return DSHAgentWALCommitInState(state, wal, arguments, YES, nullptr, error);
}

NSDictionary *DSHAgentNativeWALCommitOperation(
    DSHAgentNativeWAL *wal,
    NSString *operationId,
    NSString *requestSHA256,
    NSString *taskId,
    NSString *attemptId,
    NSString *terminalState,
    NSString *resultStatus,
    NSDictionary *resultRef,
    NSNumber *resultRevision,
    NSDictionary *safeResult,
    NSError **error) {
  if (wal == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *arguments = DSHAgentWALCommitArguments(
      operationId, requestSHA256, taskId, attemptId, terminalState,
      resultStatus, resultRef, resultRevision, safeResult);
  __block NSDictionary *output = nil;
  BOOL committed = [wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    BOOL changed = NO;
    output = DSHAgentWALCommitInState(state, wal, arguments, NO, &changed,
                                      mutationError);
    return changed;
  } error:error];
  return DSHAgentWALFinishOperation(committed, output, error);
}

NSDictionary *DSHAgentNativeWALPrepareAuthorityOperation(
    DSHAgentNativeWAL *wal,
    NSDictionary *authority,
    NSDictionary *request,
    NSDictionary *safeResult,
    NSError **error) {
  NSError *copyError = nil;
  NSDictionary *immutableAuthority = DSHAgentImmutableJSONCopy(authority,
                                                               &copyError);
  NSDictionary *immutableRequest = DSHAgentImmutableJSONCopy(request,
                                                              &copyError);
  NSDictionary *immutableResult = DSHAgentImmutableJSONCopy(safeResult,
                                                             &copyError);
  return DSHAgentWALPerformOperation(wal, @"prepare_authority", @{
    @"authority" : immutableAuthority ?: NSNull.null,
    @"request" : immutableRequest ?: NSNull.null,
    @"safe_result" : immutableResult ?: NSNull.null,
    @"env" : DSHAgentWALCoreEnvironment(immutableAuthority) ?: NSNull.null,
  }, error);
}

NSDictionary *DSHAgentNativeWALRecordBatch(DSHAgentNativeWAL *wal,
                                           NSDictionary *batch,
                                           NSError **error) {
  NSError *copyError = nil;
  NSDictionary *immutableBatch = DSHAgentImmutableJSONCopy(batch, &copyError);
  return DSHAgentWALPerformOperation(wal, @"record_batch", @{
    @"batch" : immutableBatch ?: NSNull.null,
  }, error);
}

NSDictionary *DSHAgentNativeWALRecordDeniedCall(DSHAgentNativeWAL *wal,
                                                NSDictionary *deniedCall,
                                                NSError **error) {
  NSError *copyError = nil;
  NSDictionary *immutableCall = DSHAgentImmutableJSONCopy(deniedCall,
                                                           &copyError);
  return DSHAgentWALPerformOperation(wal, @"record_denied_call", @{
    @"denied_call" : immutableCall ?: NSNull.null,
  }, error);
}

static NSData *DSHAgentWALVerifiedBytes;

static BOOL DSHAgentWALBytesVerified(NSData *data) {
  @synchronized (DSHAgentNativeWAL.class) {
    return data != nil && DSHAgentWALVerifiedBytes != nil &&
        [DSHAgentWALVerifiedBytes isEqualToData:data];
  }
}

static void DSHAgentWALRememberVerifiedBytes(NSData *data) {
  @synchronized (DSHAgentNativeWAL.class) {
    DSHAgentWALVerifiedBytes = [data copy];
  }
}

@implementation DSHAgentNativeWAL

- (BOOL)requiresWALResourceMetadata {
#if TARGET_OS_SIMULATOR || TARGET_OS_OSX
  return NO;
#else
  return YES;
#endif
}

- (NSFileManager *)walFileManager {
  return NSFileManager.defaultManager;
}

- (BOOL)setWALProtectionAtURL:(NSURL *)url error:(NSError **)error {
  return [[self walFileManager]
      setAttributes:@{
        NSFileProtectionKey : NSFileProtectionCompleteUntilFirstUserAuthentication
      }
       ofItemAtPath:url.path error:error];
}

- (BOOL)getWALProtectionAtURL:(NSURL *)url value:(id *)value error:(NSError **)error {
  if (value != nullptr) *value = nil;
  // Read actual file attributes each time. NSURL resource caches are not
  // evidence that the currently pinned inode has the required policy.
  NSDictionary *attributes = [[self walFileManager]
      attributesOfItemAtPath:url.path error:error];
  if (attributes == nil) return NO;
  if (value != nullptr) *value = attributes[NSFileProtectionKey];
  return YES;
}

- (BOOL)setWALBackupExcludedAtURL:(NSURL *)url error:(NSError **)error {
  return [url setResourceValue:@YES
                       forKey:NSURLIsExcludedFromBackupKey error:error];
}

- (BOOL)getWALBackupExcludedAtURL:(NSURL *)url
                          value:(NSNumber **)value error:(NSError **)error {
  if (value != nullptr) *value = nil;
  [url removeCachedResourceValueForKey:NSURLIsExcludedFromBackupKey];
  return [url getResourceValue:value
                       forKey:NSURLIsExcludedFromBackupKey error:error];
}

- (instancetype)initWithRootURL:(NSURL *)rootURL
                           clock:(DSHAgentNativeWALClock)clock
              identifierGenerator:(DSHAgentNativeWALIdentifierGenerator)generator
                         faultHook:(DSHAgentNativeWALFaultHook)faultHook {
  self = [super init];
  if (self) {
    _rootURL = [rootURL copy];
    _walURL = [_rootURL URLByAppendingPathComponent:DSHAgentWALFileName];
    _clock = [clock copy];
    _generator = [generator copy];
    _faultHook = [faultHook copy];
    _lock = DSHAgentLockForRoot(_rootURL);
    _liveTaskIds = [NSMutableSet set];
    NSString *candidate = _generator != nil ? _generator() : nil;
    _launchId = DSHAgentCanonicalUUID(candidate)
        ? [candidate copy]
        : NSUUID.UUID.UUIDString.lowercaseString;
  }
  return self;
}

- (instancetype)initWithRootURL:(NSURL *)rootURL
                           clock:(DSHAgentNativeWALClock)clock
               launchIdGenerator:(DSHAgentNativeWALIdentifierGenerator)generator
                       faultHook:(DSHAgentNativeWALFaultHook)faultHook {
  return [self initWithRootURL:rootURL
                          clock:clock
             identifierGenerator:generator
                        faultHook:faultHook];
}

- (BOOL)faultAtStage:(NSString *)stage error:(NSError **)error {
  if (self.faultHook == nil) return YES;
  BOOL allowed = NO;
  @try {
    allowed = self.faultHook(stage);
  } @catch (__unused NSException *exception) {
    allowed = NO;
  }
  if (!allowed) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorPersistence);
    return NO;
  }
  return YES;
}

- (NSDictionary *)loadStateLocked:(NSError **)error {
  if (!DSHAgentDirectoryIsSafe(self.rootURL)) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  int rootDescriptor = DSHAgentOpenRootDescriptor(self.rootURL);
  if (rootDescriptor < 0) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  struct stat temporaryMetadata = {};
  if (fstatat(rootDescriptor, [[DSHAgentWALFileName
      stringByAppendingString:DSHAgentWALTemporarySuffix] UTF8String],
              &temporaryMetadata, AT_SYMLINK_NOFOLLOW) == 0) {
    close(rootDescriptor);
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (errno != ENOENT) {
    close(rootDescriptor);
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  struct stat fileMetadata = {};
  if (fstatat(rootDescriptor, DSHAgentWALFileName.UTF8String, &fileMetadata,
              AT_SYMLINK_NOFOLLOW) != 0) {
    BOOL missing = errno == ENOENT;
    close(rootDescriptor);
    if (missing) {
      if (error != nullptr) *error = nil;
      return DSHAgentFreshWALState();
    }
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  NSData *data = DSHAgentReadWALAtRoot(self, rootDescriptor,
                                       DSHAgentWALFileName.UTF8String,
                                       error);
  close(rootDescriptor);
  if (data == nil) return nil;
  if (data.length == 0 || data.length > DSHAgentNativeWALMaxStoreBytes) {
    DSHSetAgentNativeStoreError(error,
                                data.length > DSHAgentNativeWALMaxStoreBytes
                                    ? DSHAgentNativeStoreErrorCapacity
                                    : DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSError *decodeError = nil;
  id object = [NSJSONSerialization JSONObjectWithData:data
                                               options:NSJSONReadingMutableContainers |
                                                       NSJSONReadingMutableLeaves
                                                 error:&decodeError];
  if (!DSHAgentIsImmutableFoundationJSON(object) ||
      ![object isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  // Every operation loads the WAL several times and re-canonicalises the
  // whole file to prove it is byte-exact. The bytes we wrote ourselves, or
  // already proved once, need no second proof: compare bytes and skip the
  // re-encode and shape validation. The parse itself is always fresh, so the
  // mutable tree handed to callers is never shared.
  if (!DSHAgentWALBytesVerified(data)) {
    NSError *canonicalError = nil;
    NSData *canonical = DSHAgentCanonicalJSON(object, &canonicalError);
    if (canonical == nil || ![canonical isEqualToData:data] ||
        !DSHAgentWALStateBasicValidation(object, error)) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
      return nil;
    }
    DSHAgentWALRememberVerifiedBytes(data);
  }
  return [object mutableCopy];
}

- (BOOL)ensureStorageWithError:(NSError **)error {
  [self.lock lock];
  BOOL baseValid = self.rootURL != nil && self.rootURL.isFileURL &&
      self.clock != nil && self.launchId != nil;
  NSURL *parent = baseValid ? self.rootURL.URLByDeletingLastPathComponent : nil;
  BOOL parentSafe = baseValid && DSHAgentDirectoryIsSafe(parent);
  BOOL directoryReady = parentSafe && DSHAgentEnsureDirectory(self, self.rootURL);
  BOOL valid = baseValid && parentSafe && directoryReady;
  if (!valid) {
    [self.lock unlock];
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return NO;
  }
  NSError *loadError = nil;
  NSDictionary *state = [self loadStateLocked:&loadError];
  if (state == nil) {
    [self.lock unlock];
    if (error != nullptr) *error = loadError;
    return NO;
  }
  if ([state[@"schema_version"] isEqual:@1]) {
    NSMutableDictionary *migrated = DSHAgentWALMigrateV1ToV2(state, &loadError);
    if (migrated == nil) {
      [self.lock unlock];
      if (error != nullptr) *error = loadError;
      return NO;
    }
    DSHAgentWALConfirmation migrationConfirmation = DSHAgentWALConfirmationNotCommitted;
    if (![self writeStateLocked:migrated
                  oldGeneration:[state[@"generation"] unsignedIntegerValue]
                   confirmation:&migrationConfirmation
                           error:&loadError]) {
      DSHAgentWALForgetResident(self.rootURL);
      [self.lock unlock];
      if (error != nullptr) *error = loadError;
      return NO;
    }
    state = migrated;
  }
  self.storageReady = YES;
  [self.lock unlock];
  if (!self.ownerReconciled) {
    // Set the guard before entering reconciliation: reconciliation itself uses
    // the same WAL API and must not recursively bootstrap this instance.
    self.ownerReconciled = YES;
    if (![self reconcileOwnerLossWithError:error]) {
      self.ownerReconciled = NO;
      return NO;
    }
  }
  return YES;
}

- (BOOL)writeStateLocked:(NSDictionary *)state
                oldGeneration:(NSUInteger)oldGeneration
                 confirmation:(DSHAgentWALConfirmation *)confirmation
                         error:(NSError **)error {
  // Until the rename takes effect nothing can have replaced the file; after
  // it does, a later failure no longer proves that it did not.
  if (confirmation != nullptr) *confirmation = DSHAgentWALConfirmationNotCommitted;
  NSError *validationError = nil;
  if (!DSHAgentWALStateBasicValidation(state, &validationError)) {
    if (error != nullptr) *error = validationError;
    return NO;
  }
  NSNumber *generation = state[@"generation"];
  if (![generation isEqual:@(oldGeneration + 1)]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return NO;
  }
  NSData *data = DSHAgentCanonicalJSON(state, &validationError);
  if (data == nil || data.length > DSHAgentNativeWALMaxStoreBytes) {
    if (error != nullptr) *error = data == nil
        ? validationError
        : DSHAgentNativeStoreError(DSHAgentNativeStoreErrorCapacity);
    return NO;
  }
  if (![self faultAtStage:@"wal.before_prepare" error:error]) return NO;
  int rootDescriptor = DSHAgentOpenRootDescriptor(self.rootURL);
  if (rootDescriptor < 0) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return NO;
  }
  const char *temporaryName = [[DSHAgentWALFileName
      stringByAppendingString:DSHAgentWALTemporarySuffix] UTF8String];
  struct stat temporaryMetadata = {};
  if (fstatat(rootDescriptor, temporaryName, &temporaryMetadata,
              AT_SYMLINK_NOFOLLOW) == 0) {
    close(rootDescriptor);
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return NO;
  }
  if (errno != ENOENT) {
    close(rootDescriptor);
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return NO;
  }
  int descriptor = openat(rootDescriptor, temporaryName,
                          O_WRONLY | O_CREAT | O_EXCL | O_TRUNC | O_NOFOLLOW,
                          0600);
  if (descriptor < 0) {
    close(rootDescriptor);
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorPersistence);
    return NO;
  }
  BOOL written = DSHAgentWriteAll(descriptor, data);
  struct stat stagedMetadata = {};
  BOOL identity = fstat(descriptor, &stagedMetadata) == 0 &&
      DSHAgentRegularFileIdentity(stagedMetadata);
  if (fchmod(descriptor, 0600) != 0) identity = NO;
  if (close(descriptor) != 0) identity = NO;
  NSURL *temporaryURL = [self.walURL.URLByDeletingLastPathComponent
      URLByAppendingPathComponent:[self.walURL.lastPathComponent
          stringByAppendingString:DSHAgentWALTemporarySuffix]];
  NSError *attributeError = nil;
  BOOL permissions = [[NSFileManager defaultManager]
      setAttributes:@{ NSFilePosixPermissions : @0600 }
       ofItemAtPath:temporaryURL.path
              error:&attributeError];
  BOOL protection = [self setWALProtectionAtURL:temporaryURL error:&attributeError];
  BOOL excluded = [self setWALBackupExcludedAtURL:temporaryURL error:&attributeError];
  BOOL protectedFile = identity && permissions &&
      (![self requiresWALResourceMetadata] || (protection && excluded));
  int verifyDescriptor = openat(rootDescriptor, temporaryName,
                                O_RDONLY | O_NOFOLLOW);
  struct stat verifiedMetadata = {};
  BOOL verified = verifyDescriptor >= 0 && fstat(verifyDescriptor, &verifiedMetadata) == 0 &&
      DSHAgentRegularFileIdentity(verifiedMetadata) &&
      verifiedMetadata.st_dev == stagedMetadata.st_dev &&
      verifiedMetadata.st_ino == stagedMetadata.st_ino && protectedFile &&
      DSHAgentVerifyFileProtectionDescriptor(self, verifyDescriptor, &stagedMetadata);
  if (verifyDescriptor >= 0) close(verifyDescriptor);
  if (!written || !verified) {
    unlinkat(rootDescriptor, temporaryName, 0);
    close(rootDescriptor);
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorPersistence);
    return NO;
  }
  if (![self faultAtStage:@"wal.after_temp_write" error:error]) {
    close(rootDescriptor);
    return NO;
  }
  if (renameat(rootDescriptor, temporaryName, rootDescriptor,
               DSHAgentWALFileName.UTF8String) != 0) {
    close(rootDescriptor);
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorPersistence);
    return NO;
  }
  if (confirmation != nullptr) *confirmation = DSHAgentWALConfirmationUnknown;
  struct stat replacedMetadata = {};
  BOOL replaced = fstatat(rootDescriptor, DSHAgentWALFileName.UTF8String,
                          &replacedMetadata, AT_SYMLINK_NOFOLLOW) == 0 &&
      DSHAgentRegularFileIdentity(replacedMetadata) &&
      replacedMetadata.st_dev == stagedMetadata.st_dev &&
      replacedMetadata.st_ino == stagedMetadata.st_ino;
  if (![self faultAtStage:@"wal.after_replace" error:error]) {
    close(rootDescriptor);
    return NO;
  }
  BOOL synced = fsync(rootDescriptor) == 0;
  close(rootDescriptor);
  if (!replaced || !synced ||
      ![self faultAtStage:@"wal.after_directory_fsync" error:error]) return NO;
  DSHAgentWALRememberVerifiedBytes(data);
  if (confirmation != nullptr) *confirmation = DSHAgentWALConfirmationCommitted;
  return YES;
}

- (BOOL)performAtomicTransaction:(DSHAgentNativeWALMutation)mutation
                           error:(NSError **)error {
  if (mutation == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return NO;
  }
  if (![self ensureStorageWithError:error]) return NO;
  [self.lock lock];
  NSError *loadError = nil;
  NSMutableDictionary *state = DSHAgentWALCommittedState(self, &loadError);
  if (state == nil) {
    [self.lock unlock];
    if (error != nullptr) *error = loadError;
    return NO;
  }
  NSUInteger oldGeneration = [state[@"generation"] unsignedIntegerValue];
  NSError *mutationError = nil;
  BOOL changed = NO;
  @try {
    changed = mutation(state, &mutationError);
  } @catch (__unused NSException *exception) {
    changed = NO;
    mutationError = DSHAgentNativeStoreError(DSHAgentNativeStoreErrorPersistence);
  }
  if (!changed) {
    [self.lock unlock];
    // A nil mutation error is the explicit idempotent/no-op result. This is
    // useful for duplicate cleanup, owner probes, and exact replay checks:
    // no WAL generation is consumed and no bytes are rewritten.
    if (mutationError == nil) {
      if (error != nullptr) *error = nil;
      return YES;
    }
    if (error != nullptr) *error = mutationError;
    return NO;
  }
  NSError *normalizationError = nil;
  if (!DSHAgentWALNormalizeTransactionCandidate(state, &normalizationError)) {
    [self.lock unlock];
    if (error != nullptr) *error = normalizationError;
    return NO;
  }
  if (oldGeneration == DSHAgentMaximumSafeInteger) {
    [self.lock unlock];
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCapacity);
    return NO;
  }
  state[@"generation"] = @(oldGeneration + 1);
  NSError *commitError = nil;
  DSHAgentWALConfirmation confirmation = DSHAgentWALConfirmationNotCommitted;
  BOOL committed = [self writeStateLocked:state
                            oldGeneration:oldGeneration
                             confirmation:&confirmation
                                     error:&commitError];
  if (!committed && commitError.code == DSHAgentNativeStoreErrorCapacity &&
      confirmation == DSHAgentWALConfirmationNotCommitted &&
      DSHAgentWALCompactAcknowledgedEvidence(state)) {
    commitError = nil;
    committed = [self writeStateLocked:state
                          oldGeneration:oldGeneration
                           confirmation:&confirmation
                                   error:&commitError];
  }
  DSHAgentWALPublish(self, state, confirmation);
  [self.lock unlock];
  if (!committed && error != nullptr) *error = commitError;
  return committed;
}

- (NSDictionary *)snapshotWithError:(NSError **)error {
  if (![self ensureStorageWithError:error]) return nil;
  [self.lock lock];
  NSError *loadError = nil;
  NSDictionary *state = [self loadStateLocked:&loadError];
  id copy = state == nil ? nil : DSHAgentImmutableJSONCopy(state, &loadError);
  [self.lock unlock];
  if (copy == nil && error != nullptr) *error = loadError;
  return [copy isKindOfClass:NSDictionary.class] ? copy : nil;
}

- (NSString *)dispatchStateForKind:(NSString *)kind
                            locator:(NSDictionary *)locator
                              error:(NSError **)error {
  if ((![kind isEqualToString:@"round"] &&
       ![kind isEqualToString:@"execution"]) ||
      ![locator isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *state = [self snapshotWithError:error];
  if (state == nil) return nil;
  NSString *dispatchState = DSHAgentFindDispatchState(state[@"dispatch"], kind,
                                                      locator);
  if (dispatchState == nil && error != nullptr) *error = nil;
  return dispatchState;
}

- (BOOL)registerNativeTaskId:(NSString *)nativeTaskId error:(NSError **)error {
  if (!DSHAgentCanonicalUUID(nativeTaskId)) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return NO;
  }
  [self.lock lock];
  [self.liveTaskIds addObject:nativeTaskId];
  [self.lock unlock];
  return YES;
}

- (BOOL)unregisterNativeTaskId:(NSString *)nativeTaskId error:(NSError **)error {
  if (!DSHAgentCanonicalUUID(nativeTaskId)) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return NO;
  }
  [self.lock lock];
  [self.liveTaskIds removeObject:nativeTaskId];
  [self.lock unlock];
  return YES;
}

- (BOOL)isNativeTaskAlive:(NSString *)nativeTaskId launchId:(NSString *)launchId {
  if (!DSHAgentCanonicalUUID(nativeTaskId) ||
      !DSHAgentCanonicalUUID(launchId) || ![launchId isEqual:self.launchId]) {
    return NO;
  }
  [self.lock lock];
  BOOL alive = [self.liveTaskIds containsObject:nativeTaskId];
  [self.lock unlock];
  return alive;
}

- (BOOL)reconcileOwnerLossWithError:(NSError **)error {
  if (![self ensureStorageWithError:error]) return NO;
  __weak DSHAgentNativeWAL *weakSelf = self;
  BOOL result = [self performAtomicTransaction:^BOOL(NSMutableDictionary *state,
                                                    NSError **mutationError) {
    DSHAgentNativeWAL *strongSelf = weakSelf;
    BOOL changed = NO;
    NSMutableArray *rounds = [state[@"rounds"] mutableCopy];
    NSArray *dispatchRows = state[@"dispatch"];
    for (NSMutableDictionary *row in rounds) {
      if (![row isKindOfClass:NSMutableDictionary.class]) continue;
      NSString *status = row[@"state"];
      NSDictionary *owner = row[@"owner"];
      if (![status isEqualToString:@"in_flight"] &&
          ![status isEqualToString:@"cancel_requested"]) continue;
      if (owner == nil || (id)owner == NSNull.null) continue;
      NSString *launchId = owner[@"launch_id"];
      NSString *nativeTaskId = owner[@"native_task_id"];
      if ([strongSelf isNativeTaskAlive:nativeTaskId launchId:launchId]) continue;
      NSDictionary *before = row[@"transcript_before"];
      BOOL transcriptBound = NO;
      for (NSDictionary *transcript in state[@"transcripts"]) {
        if ([transcript[@"transcript_ref"] isEqual:before[@"transcript_ref"]] &&
            [transcript[@"attempt_id"] isEqual:row[@"locator"][@"attempt_id"]] &&
            [transcript[@"root_fingerprint_sha256"]
                isEqual:row[@"root_fingerprint_sha256"]] &&
            [transcript[@"generation"] isEqual:before[@"generation"]] &&
            [transcript[@"transcript_sha256"] isEqual:before[@"transcript_sha256"]] &&
            [transcript[@"transcript_bytes"] isEqual:before[@"transcript_bytes"]]) {
          transcriptBound = YES;
          break;
        }
      }
      if (!transcriptBound) {
        if (mutationError != nullptr) *mutationError = DSHAgentNativeStoreError(
            DSHAgentNativeStoreErrorCorrupt);
        return NO;
      }
      NSString *dispatchState = DSHAgentFindDispatchState(dispatchRows,
                                                            @"round",
                                                            row[@"locator"]);
      BOOL notDispatched = [dispatchState isEqualToString:@"not_dispatched"];
      row[@"state"] = notDispatched ? @"failed_retryable" : @"ambiguous";
      row[@"owner"] = NSNull.null;
      row[@"failure_code"] = notDispatched ? @"E_AGENT_PERSISTENCE"
                                             : @"E_AGENT_ROUND_AMBIGUOUS";
      row[@"completion_receipt"] = NSNull.null;
      row[@"terminal_kind"] = NSNull.null;
      NSUInteger revision = [row[@"row_revision"] unsignedIntegerValue];
      if (revision == DSHAgentMaximumSafeInteger) {
        if (mutationError != nullptr) *mutationError = DSHAgentNativeStoreError(
            DSHAgentNativeStoreErrorCapacity);
        return NO;
      }
      row[@"row_revision"] = @(revision + 1);
      row[@"updated_at"] = [strongSelf currentTimestamp];
      changed = YES;
    }
    state[@"rounds"] = rounds;
    NSMutableArray *ledger = [state[@"ledger"] mutableCopy];
    for (NSMutableDictionary *row in ledger) {
      if (![row isKindOfClass:NSMutableDictionary.class]) continue;
      NSString *status = row[@"state"];
      NSDictionary *owner = row[@"owner"];
      if (![status isEqualToString:@"running"] &&
          ![status isEqualToString:@"cancel_requested"]) continue;
      if (owner == nil || (id)owner == NSNull.null) continue;
      if ([strongSelf isNativeTaskAlive:owner[@"native_task_id"]
                                 launchId:owner[@"launch_id"]]) continue;
      NSDictionary *ledgerBefore = row[@"transcript_before"];
      BOOL ledgerTranscriptBound = NO;
      for (NSDictionary *transcript in state[@"transcripts"]) {
        if ([transcript[@"transcript_ref"] isEqual:ledgerBefore[@"transcript_ref"]] &&
            [transcript[@"attempt_id"] isEqual:row[@"locator"][@"attempt_id"]] &&
            [transcript[@"root_fingerprint_sha256"]
                isEqual:row[@"root_fingerprint_sha256"]] &&
            [transcript[@"generation"] isEqual:ledgerBefore[@"generation"]] &&
            [transcript[@"transcript_sha256"] isEqual:ledgerBefore[@"transcript_sha256"]] &&
            [transcript[@"transcript_bytes"] isEqual:ledgerBefore[@"transcript_bytes"]]) {
          ledgerTranscriptBound = YES;
          break;
        }
      }
      if (!ledgerTranscriptBound) {
        if (mutationError != nullptr) *mutationError = DSHAgentNativeStoreError(
            DSHAgentNativeStoreErrorCorrupt);
        return NO;
      }
      NSString *dispatchState = DSHAgentFindDispatchState(dispatchRows,
                                                            @"execution",
                                                            row[@"locator"]);
      if ([dispatchState isEqual:@"dispatched"] && DSHAgentIsAssistantMutationTool(row[@"name"])) {
        // Rust commits the assistant mutation and its receipt atomically. A
        // process death between that commit and WAL settlement must leave the
        // original CAS/transcript recoverable until the receipt is queried.
        // The dead owner blocks dispatch; retaining it never grants an effect.
        continue;
      }
      BOOL notDispatched = [dispatchState isEqualToString:@"not_dispatched"];
      row[@"state"] = notDispatched ? @"unknown" : @"ambiguous";
      row[@"owner"] = NSNull.null;
      row[@"settled_facts"] = NSNull.null;
      if (notDispatched) {
        row[@"transcript_after"] = NSNull.null;
        row[@"receipt"] = NSNull.null;
      } else {
        NSDictionary *before = row[@"transcript_before"];
        NSMutableDictionary *transcript = nil;
        NSUInteger transcriptIndex = NSNotFound;
        for (NSUInteger index = 0; index < [state[@"transcripts"] count]; index += 1) {
          NSMutableDictionary *candidate = [state[@"transcripts"][index] mutableCopy];
          if ([candidate[@"transcript_ref"] isEqual:before[@"transcript_ref"]]) {
            transcript = candidate;
            transcriptIndex = index;
            break;
          }
        }
        if (transcript == nil ||
            ![transcript[@"generation"] isEqual:before[@"generation"]] ||
            ![transcript[@"transcript_sha256"] isEqual:before[@"transcript_sha256"]] ||
            ![transcript[@"state"] isEqualToString:@"open"]) {
          // Without a matching protected transcript, native cannot create the
          // required ambiguous feedback; retain a conservative unknown row.
          row[@"state"] = @"unknown";
          row[@"transcript_after"] = NSNull.null;
          row[@"receipt"] = NSNull.null;
        } else {
          NSString *callId = row[@"locator"][@"call_id"];
          NSString *name = row[@"name"];
          NSDictionary *feedback = @{
            @"schema_version" : @1,
            @"name" : name,
            @"outcome" : @"ambiguous",
            @"payload" : @{
              @"schema_version" : @1,
              @"failure_code" : @"E_AGENT_EXECUTION_AMBIGUOUS",
            },
          };
          NSError *feedbackError = nil;
          NSData *feedbackBytes = DSHAgentCanonicalJSON(feedback, &feedbackError);
          if (feedbackBytes == nil) {
            row[@"state"] = @"unknown";
            row[@"transcript_after"] = NSNull.null;
            row[@"receipt"] = NSNull.null;
          } else {
            NSMutableArray *messages = [transcript[@"messages"] mutableCopy];
            [messages addObject:@{
              @"schema_version" : @1,
              @"role" : @"tool",
              @"round_index" : row[@"locator"][@"round_index"],
              @"call_id" : callId,
              @"content" : [[NSString alloc] initWithData:feedbackBytes
                                                    encoding:NSUTF8StringEncoding],
              @"truncated" : @NO,
            }];
            NSUInteger generation = [transcript[@"generation"] unsignedIntegerValue];
            if (generation == DSHAgentMaximumSafeInteger) {
              row[@"state"] = @"unknown";
              row[@"transcript_after"] = NSNull.null;
              row[@"receipt"] = NSNull.null;
            } else {
              generation += 1;
              NSDictionary *digestInput = @{
                @"schema_version" : @1,
                @"transcript_ref" : transcript[@"transcript_ref"],
                @"attempt_id" : transcript[@"attempt_id"],
                @"root_fingerprint_sha256" : transcript[@"root_fingerprint_sha256"],
                @"generation" : @(generation),
                @"messages" : messages,
              };
              NSString *transcriptDigest = DSHAgentHJ(@"agent-transcript",
                                                       digestInput,
                                                       &feedbackError);
              if (transcriptDigest == nil) {
                row[@"state"] = @"unknown";
                row[@"transcript_after"] = NSNull.null;
                row[@"receipt"] = NSNull.null;
              } else {
                transcript[@"messages"] = messages;
                transcript[@"generation"] = @(generation);
                transcript[@"transcript_sha256"] = transcriptDigest;
                NSData *digestBytes = DSHAgentCanonicalJSON(digestInput, &feedbackError);
                NSString *resultDigest = DSHAgentHB(@"tool-result", feedbackBytes,
                                                    &feedbackError);
                if (digestBytes == nil || resultDigest == nil ||
                    digestBytes.length > DSHAgentNativeWALMaxTranscriptBytes) {
                  row[@"state"] = @"unknown";
                  row[@"transcript_after"] = NSNull.null;
                  row[@"receipt"] = NSNull.null;
                  goto ambiguous_feedback_done;
                }
                transcript[@"transcript_bytes"] = @(digestBytes.length);
                transcript[@"updated_at"] = [strongSelf currentTimestamp];
                state[@"transcripts"][transcriptIndex] = transcript;
                row[@"transcript_after"] = @{
                  @"schema_version" : @1,
                  @"transcript_ref" : transcript[@"transcript_ref"],
                  @"generation" : @(generation),
                  @"transcript_sha256" : transcriptDigest,
                  @"transcript_bytes" : @(digestBytes.length),
                };
                row[@"receipt"] = @{
                  @"schema_version" : @1,
                  @"call_id" : callId,
                  @"name" : name,
                  @"arguments_sha256" : row[@"arguments_sha256"],
                  @"result_sha256" : resultDigest,
                  @"result_bytes" : @(feedbackBytes.length),
                  @"truncated" : @NO,
                  @"duration_ms" : @0,
                  @"outcome" : @"ambiguous",
                  @"failure_code" : @"E_AGENT_EXECUTION_AMBIGUOUS",
                  @"approval_reference" : NSNull.null,
                };
              }
            }
          }
        }
      }
ambiguous_feedback_done:
      NSUInteger revision = [row[@"row_revision"] unsignedIntegerValue];
      if (revision == DSHAgentMaximumSafeInteger) {
        if (mutationError != nullptr) *mutationError = DSHAgentNativeStoreError(
            DSHAgentNativeStoreErrorCapacity);
        return NO;
      }
      row[@"row_revision"] = @(revision + 1);
      row[@"updated_at"] = [strongSelf currentTimestamp];
      changed = YES;
    }
    state[@"ledger"] = ledger;
    return changed;
  } error:error];
  if (result) self.ownerReconciled = YES;
  // A failed reconciliation must fail bootstrap.  A readable old snapshot
  // does not prove that the owner-loss transition reached durable storage.
  return result;
}

- (NSString *)currentTimestamp {
  NSDate *date = self.clock != nil ? self.clock() : NSDate.date;
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                            NSISO8601DateFormatWithFractionalSeconds;
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  return [formatter stringFromDate:date] ?: @"1970-01-01T00:00:00.000Z";
}

- (NSString *)currentTimestampAddingInterval:(NSTimeInterval)interval {
  NSDate *date = self.clock != nil ? self.clock() : NSDate.date;
  date = [date dateByAddingTimeInterval:interval];
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                            NSISO8601DateFormatWithFractionalSeconds;
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  return [formatter stringFromDate:date] ?: @"1970-01-01T00:00:00.000Z";
}

- (NSDictionary *)ambiguousReceiptForLedgerRow:(NSDictionary *)row {
  NSString *name = [row[@"name"] isKindOfClass:NSString.class]
      ? row[@"name"] : @"unknown";
  NSString *callId = [row[@"locator"] isKindOfClass:NSDictionary.class]
      ? row[@"locator"][@"call_id"] : @"unknown";
  NSString *arguments = [row[@"arguments_sha256"] isKindOfClass:NSString.class]
      ? row[@"arguments_sha256"] : @"";
  NSDictionary *feedback = @{
    @"schema_version" : @1,
    @"name" : name,
    @"outcome" : @"ambiguous",
    @"payload" : @{
      @"schema_version" : @1,
      @"failure_code" : @"E_AGENT_EXECUTION_AMBIGUOUS",
    },
  };
  NSError *digestError = nil;
  NSData *feedbackData = DSHAgentCanonicalJSON(feedback, &digestError);
  NSString *resultDigest = DSHAgentHB(@"tool-result", feedbackData ?: NSData.data,
                                      &digestError) ?:
      @"0000000000000000000000000000000000000000000000000000000000000000";
  return @{
    @"schema_version" : @1,
    @"call_id" : callId,
    @"name" : name,
    @"arguments_sha256" : arguments,
    @"result_sha256" : resultDigest,
    @"result_bytes" : @(feedbackData.length),
    @"truncated" : @NO,
    @"duration_ms" : @0,
    @"outcome" : @"ambiguous",
    @"failure_code" : @"E_AGENT_EXECUTION_AMBIGUOUS",
    @"approval_reference" : NSNull.null,
  };
}

@end
