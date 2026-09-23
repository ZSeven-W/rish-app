#import "DSHGitPushSupport.h"

#import <Security/Security.h>
#import <arpa/inet.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#include <atomic>
#include <math.h>
#include <string.h>

NSString *const DSHGitPushCredentialService = @"dev.zseven.rish.git.https";
NSString *const DSHGitPushReceiptFilename = @"rish-push-receipts.json";

static NSString *const DSHGitPushReceiptTempFilename =
    @"rish-push-receipts.json.tmp";
static NSUInteger const DSHGitPushMaxReceipts = 25;
static NSUInteger const DSHGitPushMaxReceiptJournalBytes = 262144;
static NSTimeInterval const DSHGitPushDefaultTimeout = 60.0;
/// libgit2 socket bounds: a stalled connect or a silent server cannot hold
/// the worker past these, independent of the caller-side deadline.
static int const DSHGitPushConnectTimeoutMilliseconds = 20000;
static int const DSHGitPushServerTimeoutMilliseconds = 60000;

static NSError *DSHGitPushSupportError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:@"DSHGitPushSupport" code:code
      userInfo:@{ NSLocalizedDescriptionKey : message }];
}

// MARK: - Remote URL validation

static BOOL DSHGitPushHasControlCharacter(NSString *value) {
  for (NSUInteger index = 0; index < value.length; index += 1) {
    unichar character = [value characterAtIndex:index];
    if (character < 0x20 || character == 0x7F) return YES;
  }
  return NO;
}

static NSString *DSHGitPushStripBrackets(NSString *host) {
  if ([host hasPrefix:@"["] && [host hasSuffix:@"]"] && host.length > 2) {
    return [host substringWithRange:NSMakeRange(1, host.length - 2)];
  }
  return host;
}

static BOOL DSHGitPushIsIPLiteral(NSString *host) {
  const char *bytes = DSHGitPushStripBrackets(host).UTF8String;
  if (bytes == nullptr) return NO;
  struct in_addr ipv4 = {};
  struct in6_addr ipv6 = {};
  return inet_pton(AF_INET, bytes, &ipv4) == 1
    || inet_pton(AF_INET6, bytes, &ipv6) == 1;
}

static BOOL DSHGitPushIsPublicDNSName(NSString *host) {
  if (host.length == 0 || host.length > 253 || [host hasSuffix:@"."]
    || DSHGitPushHasControlCharacter(host)
    || [host isEqualToString:@"localhost"]
    || [host hasSuffix:@".local"] || [host hasSuffix:@".internal"]
    || DSHGitPushIsIPLiteral(host)) return NO;
  NSArray<NSString *> *labels = [host componentsSeparatedByString:@"."];
  if (labels.count < 2) return NO;
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
    @"abcdefghijklmnopqrstuvwxyz0123456789-"];
  for (NSString *label in labels) {
    if (label.length == 0 || label.length > 63 || [label hasPrefix:@"-"]
      || [label hasSuffix:@"-"]
      || [label rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
  }
  return YES;
}

/// Loopback, RFC 1918, link-local, and ULA literals plus "localhost". These
/// are the only hosts a plain http:// test remote may use.
static BOOL DSHGitPushIsPrivateLiteral(NSString *host) {
  if ([host isEqualToString:@"localhost"]) return YES;
  const char *bytes = DSHGitPushStripBrackets(host).UTF8String;
  if (bytes == nullptr) return NO;
  struct in_addr v4 = {};
  if (inet_pton(AF_INET, bytes, &v4) == 1) {
    uint32_t ip = ntohl(v4.s_addr);
    if ((ip & 0xFF000000u) == 0x7F000000u) return YES;  // 127/8
    if ((ip & 0xFF000000u) == 0x0A000000u) return YES;  // 10/8
    if ((ip & 0xFFF00000u) == 0xAC100000u) return YES;  // 172.16/12
    if ((ip & 0xFFFF0000u) == 0xC0A80000u) return YES;  // 192.168/16
    if ((ip & 0xFFFF0000u) == 0xA9FE0000u) return YES;  // 169.254/16
    return NO;
  }
  struct in6_addr v6 = {};
  if (inet_pton(AF_INET6, bytes, &v6) == 1) {
    if (IN6_IS_ADDR_LOOPBACK(&v6) || IN6_IS_ADDR_LINKLOCAL(&v6)) return YES;
    return (v6.s6_addr[0] & 0xFE) == 0xFC;  // ULA fc00::/7
  }
  return NO;
}

NSURL *DSHGitValidatedRemoteURL(id value, NSError **error) {
  NSString *input = [value isKindOfClass:NSString.class] ? value : @"";
  NSString *trimmed = [input stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (input.length == 0 || input.length > 4096 || DSHGitPushHasControlCharacter(input)
    || [input containsString:@"\\"] || ![input isEqualToString:trimmed]) {
    if (error != nil) *error = DSHGitPushSupportError(3002, @"Remote URL is invalid");
    return nil;
  }
  NSURLComponents *components = [NSURLComponents componentsWithString:input];
  NSString *scheme = components.scheme.lowercaseString;
  NSString *host = components.host.lowercaseString;
  NSString *path = components.path;
  BOOL httpsValid = [scheme isEqualToString:@"https"] && DSHGitPushIsPublicDNSName(host)
      && (components.port == nil || components.port.integerValue == 443);
  BOOL httpValid = [scheme isEqualToString:@"http"] && DSHGitPushIsPrivateLiteral(host)
      && (components.port == nil
          || (components.port.integerValue >= 1 && components.port.integerValue <= 65535));
  BOOL valid = (httpsValid || httpValid) && components.user == nil
    && components.password == nil && components.query == nil
    && components.fragment == nil && path.length > 1 && path.length <= 2048
    && !DSHGitPushHasControlCharacter(path);
  for (NSString *component in [path componentsSeparatedByString:@"/"]) {
    if ([component isEqualToString:@"."] || [component isEqualToString:@".."]) valid = NO;
  }
  if (!valid || components.URL == nil) {
    if (error != nil) *error = DSHGitPushSupportError(3002, @"Remote URL is invalid");
    return nil;
  }
  components.scheme = scheme;
  components.host = host;
  return components.URL;
}

BOOL DSHGitRemoteURLIsPlaintext(NSURL *url) {
  return [url.scheme.lowercaseString isEqualToString:@"http"];
}

// MARK: - Keychain credential store

static BOOL DSHGitPushValidUsername(NSString *username) {
  if (username.length == 0 || username.length > 255 || DSHGitPushHasControlCharacter(username)
    || [username rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location
      != NSNotFound) return NO;
  NSCharacterSet *forbidden = [NSCharacterSet characterSetWithCharactersInString:@":/@\\"];
  return [username rangeOfCharacterFromSet:forbidden].location == NSNotFound;
}

static BOOL DSHGitPushValidToken(NSString *token) {
  NSUInteger bytes = [token lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  return bytes >= 8 && bytes <= 4096 && !DSHGitPushHasControlCharacter(token)
    && [token rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location
      == NSNotFound;
}

BOOL DSHGitCredentialExpiryIsValid(NSInteger expirySeconds) {
  return expirySeconds == DSHGitCredentialExpiryOneHour ||
      expirySeconds == DSHGitCredentialExpiryOneDay ||
      expirySeconds == DSHGitCredentialExpirySevenDays;
}

NSString *DSHGitCredentialAccountForScope(NSString *scopeId, NSString *host) {
  return [NSString stringWithFormat:@"project:%@|host:%@", scopeId.lowercaseString,
      host.lowercaseString];
}

/// Items are generic passwords in the app's default Keychain access group
/// (the first `keychain-access-groups` entitlement), device-only and never
/// synchronised, matching the DEEPSEEK_API_KEY convention.
static NSMutableDictionary *DSHGitPushKeychainQuery(NSString *account) {
  return [@{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : DSHGitPushCredentialService,
    (__bridge id)kSecAttrAccount : account,
    (__bridge id)kSecAttrSynchronizable : @NO,
  } mutableCopy];
}

NSDictionary *DSHGitCredentialForScope(NSString *scopeId, NSString *host,
                                       NSError **error) {
  if (scopeId.length == 0 || host.length == 0) return nil;
  NSMutableDictionary *query = DSHGitPushKeychainQuery(
      DSHGitCredentialAccountForScope(scopeId, host));
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef result = nullptr;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
  if (status != errSecSuccess || result == nullptr) {
    if (result != nullptr) CFRelease(result);
    if (status != errSecSuccess && status != errSecItemNotFound && error != nil) {
      *error = DSHGitPushSupportError(3016, @"Git credential status is unavailable");
    }
    return nil;
  }
  NSData *data = CFBridgingRelease(result);
  if (data.length == 0 || data.length > 8192) return nil;
  NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![payload isKindOfClass:NSDictionary.class] ||
      ![payload[@"schema_version"] isEqual:@2]) return nil;
  NSString *username = [payload[@"username"] isKindOfClass:NSString.class]
      ? payload[@"username"] : nil;
  NSString *token = [payload[@"token"] isKindOfClass:NSString.class]
      ? payload[@"token"] : nil;
  NSNumber *expiresAt = [payload[@"expires_at"] isKindOfClass:NSNumber.class]
      ? payload[@"expires_at"] : nil;
  NSNumber *expirySeconds = [payload[@"expiry_seconds"] isKindOfClass:NSNumber.class]
      ? payload[@"expiry_seconds"] : nil;
  if (!DSHGitPushValidUsername(username) || !DSHGitPushValidToken(token) ||
      expiresAt == nil || expirySeconds == nil || expiresAt.doubleValue <= 0 ||
      !DSHGitCredentialExpiryIsValid(expirySeconds.integerValue)) return nil;
  if (expiresAt.doubleValue <= NSDate.date.timeIntervalSince1970) {
    (void)DSHGitDeleteCredentialForScope(scopeId, host, nil);
    return nil;
  }
  return @{ @"username" : username, @"token" : token, @"expires_at" : expiresAt,
            @"expiry_seconds" : expirySeconds };
}

BOOL DSHGitStoreCredentialForScope(NSString *scopeId, NSString *host,
                                   NSString *username, NSString *token,
                                   NSInteger expirySeconds, NSError **error) {
  if (!DSHGitPushValidUsername(username) || !DSHGitPushValidToken(token) ||
      !DSHGitCredentialExpiryIsValid(expirySeconds) ||
      scopeId.length == 0 || host.length == 0) {
    if (error != nil) *error = DSHGitPushSupportError(3012, @"Git credential is invalid");
    return NO;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{
    @"schema_version" : @2,
    @"username" : username,
    @"token" : token,
    @"expires_at" : @(floor(NSDate.date.timeIntervalSince1970) + expirySeconds),
    @"expiry_seconds" : @(expirySeconds),
  } options:NSJSONWritingSortedKeys error:nil];
  if (data == nil || data.length > 8192) {
    if (error != nil) *error = DSHGitPushSupportError(3012, @"Git credential is invalid");
    return NO;
  }
  NSMutableDictionary *query = DSHGitPushKeychainQuery(
      DSHGitCredentialAccountForScope(scopeId, host));
  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
    (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData : data });
  if (status == errSecItemNotFound) {
    query[(__bridge id)kSecValueData] = data;
    query[(__bridge id)kSecAttrAccessible]
      = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    status = SecItemAdd((__bridge CFDictionaryRef)query, nil);
  }
  if (status != errSecSuccess) {
    if (error != nil) *error = DSHGitPushSupportError(3013, @"Git credential cannot be saved");
    return NO;
  }
  return YES;
}

BOOL DSHGitDeleteCredentialForScope(NSString *scopeId, NSString *host,
                                    NSError **error) {
  OSStatus status = SecItemDelete((__bridge CFDictionaryRef)DSHGitPushKeychainQuery(
      DSHGitCredentialAccountForScope(scopeId, host)));
  if (status != errSecSuccess && status != errSecItemNotFound) {
    if (error != nil) *error = DSHGitPushSupportError(3014, @"Git credential cannot be cleared");
    return NO;
  }
  return YES;
}

BOOL DSHGitDeleteLegacyHostCredential(NSString *host, NSError **error) {
  OSStatus status = SecItemDelete((__bridge CFDictionaryRef)DSHGitPushKeychainQuery(
      host.lowercaseString));
  if (status != errSecSuccess && status != errSecItemNotFound) {
    if (error != nil) *error = DSHGitPushSupportError(3014, @"Git credential cannot be cleared");
    return NO;
  }
  return YES;
}

// MARK: - Bounded push runner

@implementation DSHGitPushCancelToken {
  std::atomic<bool> _cancelled;
}

- (instancetype)init {
  self = [super init];
  if (self) _cancelled = false;
  return self;
}

- (BOOL)cancelled {
  return _cancelled.load();
}

- (void)cancel {
  _cancelled.store(true);
}

@end

@implementation DSHGitPushRequest

- (instancetype)init {
  self = [super init];
  if (self) _timeout = DSHGitPushDefaultTimeout;
  return self;
}

@end

@implementation DSHGitPushResult
@end

/// Shared between the waiting caller and the worker: the caller flips the
/// deadline flag when it gives up, so the worker's next callback aborts.
@interface DSHGitPushControl : NSObject
@property(nonatomic, strong, nullable) DSHGitPushCancelToken *cancelToken;
- (BOOL)deadlinePassed;
- (void)markDeadlinePassed;
@end

@implementation DSHGitPushControl {
  std::atomic<bool> _deadlinePassed;
}

- (instancetype)init {
  self = [super init];
  if (self) _deadlinePassed = false;
  return self;
}

- (BOOL)deadlinePassed {
  return _deadlinePassed.load();
}

- (void)markDeadlinePassed {
  _deadlinePassed.store(true);
}

@end

typedef struct {
  __unsafe_unretained NSString *host;
  __unsafe_unretained NSString *username;
  __unsafe_unretained NSString *token;
  bool attempted;
} DSHGitPushCredentialState;

/// Native-private observer for the receive-pack report-status response. The
/// server-provided status text is reduced to booleans and is never retained,
/// logged, or projected into results.
typedef struct {
  const char *targetRef;
  size_t targetCount;
  size_t unexpectedCount;
  bool targetRejected;
  bool targetNonFastForward;
  bool malformed;
} DSHGitPushUpdateState;

typedef struct {
  DSHGitPushCredentialState credential;
  DSHGitPushUpdateState update;
  __unsafe_unretained DSHGitPushControl *control;
  bool interruptedByCancel;
  bool interruptedByDeadline;
  bool bytesMayHaveBeenSent;
} DSHGitPushCallbackState;

static int DSHGitPushAbortIfRequested(DSHGitPushCallbackState *state) {
  if (state == nullptr || state->control == nil) return 0;
  if (state->control.cancelToken != nil && state->control.cancelToken.cancelled) {
    state->interruptedByCancel = true;
    return GIT_EUSER;
  }
  if (state->control.deadlinePassed) {
    state->interruptedByDeadline = true;
    return GIT_EUSER;
  }
  return 0;
}

static int DSHGitPushCredentialCallback(git_credential **out,
                                         const char *url,
                                         const char *usernameFromURL,
                                         unsigned int allowedTypes,
                                         void *rawPayload) {
  (void)usernameFromURL;
  DSHGitPushCallbackState *state = static_cast<DSHGitPushCallbackState *>(rawPayload);
  if (DSHGitPushAbortIfRequested(state) != 0) return GIT_EUSER;
  DSHGitPushCredentialState *credential = &state->credential;
  if (credential->token == nil || credential->username == nil) return GIT_EAUTH;
  NSString *urlString = url == nullptr ? nil : [NSString stringWithUTF8String:url];
  NSURL *validated = DSHGitValidatedRemoteURL(urlString, nil);
  if (validated == nil ||
      ![validated.host.lowercaseString isEqualToString:credential->host]) {
    return GIT_EAUTH;
  }
  if (allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT) {
    if (credential->attempted) return GIT_EAUTH;
    credential->attempted = true;
    return git_credential_userpass_plaintext_new(
        out, credential->username.UTF8String, credential->token.UTF8String);
  }
  if (allowedTypes & GIT_CREDENTIAL_USERNAME) {
    return git_credential_username_new(out, credential->username.UTF8String);
  }
  return GIT_PASSTHROUGH;
}

static int DSHGitPushSidebandCallback(const char *message, int length,
                                       void *rawPayload) {
  (void)message;
  (void)length;
  return DSHGitPushAbortIfRequested(
      static_cast<DSHGitPushCallbackState *>(rawPayload));
}

static int DSHGitPushNegotiationCallback(const git_push_update **updates,
                                          size_t count, void *rawPayload) {
  (void)updates;
  (void)count;
  // Last cooperative checkpoint before the packfile is streamed.
  return DSHGitPushAbortIfRequested(
      static_cast<DSHGitPushCallbackState *>(rawPayload));
}

static int DSHGitPushTransferProgress(unsigned int current, unsigned int total,
                                       size_t bytes, void *rawPayload) {
  (void)current;
  (void)total;
  (void)bytes;
  DSHGitPushCallbackState *state = static_cast<DSHGitPushCallbackState *>(rawPayload);
  if (state != nullptr) state->bytesMayHaveBeenSent = true;
  return DSHGitPushAbortIfRequested(state);
}

static int DSHGitPushUpdateReference(const char *refname,
                                      const char *status,
                                      void *rawPayload) {
  DSHGitPushCallbackState *state = static_cast<DSHGitPushCallbackState *>(rawPayload);
  if (state == nullptr || state->update.targetRef == nullptr) return 0;
  if (refname == nullptr) {
    state->update.malformed = true;
    return 0;
  }
  if (strcmp(refname, state->update.targetRef) != 0) {
    state->update.unexpectedCount += 1;
    return 0;
  }
  state->update.targetCount += 1;
  if (status != nullptr) {
    state->update.targetRejected = true;
    // Compared, never copied: the server text stays out of every result.
    if (strstr(status, "non-fast-forward") != nullptr ||
        strstr(status, "fetch first") != nullptr) {
      state->update.targetNonFastForward = true;
    }
  }
  return 0;
}

static void DSHGitPushConfigureTransportBounds(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    git_libgit2_opts(GIT_OPT_SET_SERVER_CONNECT_TIMEOUT,
                     DSHGitPushConnectTimeoutMilliseconds);
    git_libgit2_opts(GIT_OPT_SET_SERVER_TIMEOUT,
                     DSHGitPushServerTimeoutMilliseconds);
  });
}

static NSString *DSHGitPushAdvertisedOID(git_remote *remote,
                                          const char *fullReference,
                                          int *codeOut) {
  const git_remote_head **heads = nullptr;
  size_t count = 0;
  int code = git_remote_ls(&heads, &count, remote);
  NSString *resolved = nil;
  if (code == 0) {
    for (size_t index = 0; index < count; index += 1) {
      if (heads[index] != nullptr && heads[index]->name != nullptr &&
          strcmp(heads[index]->name, fullReference) == 0) {
        char buffer[GIT_OID_SHA1_HEXSIZE + 1] = {};
        git_oid_tostr(buffer, sizeof(buffer), &heads[index]->oid);
        resolved = [NSString stringWithUTF8String:buffer];
        break;
      }
    }
  }
  if (codeOut != nullptr) *codeOut = code;
  return resolved;
}

static void DSHGitPushFillCallbacks(git_remote_callbacks *callbacks,
                                    DSHGitPushCallbackState *state,
                                    BOOL withCredentials) {
  if (withCredentials) callbacks->credentials = DSHGitPushCredentialCallback;
  callbacks->sideband_progress = DSHGitPushSidebandCallback;
  callbacks->push_transfer_progress = DSHGitPushTransferProgress;
  callbacks->push_update_reference = DSHGitPushUpdateReference;
  callbacks->push_negotiation = DSHGitPushNegotiationCallback;
  callbacks->payload = state;
}

/// Executes the whole network phase on the worker. Returns the settled
/// result; `state` reports interruptions and whether bytes may have left.
static DSHGitPushResult *DSHGitPushExecute(DSHGitPushRequest *request,
                                           DSHGitPushCallbackState *state) {
  DSHGitPushResult *result = [[DSHGitPushResult alloc] init];
  result.outcome = DSHGitPushOutcomeFailed;
  const char *fullReference = request.fullReference.UTF8String;
  BOOL withCredentials = request.token.length > 0 && request.username.length > 0;
  git_remote *remote = nullptr;
  int code = git_remote_lookup(&remote, request.repository,
                               request.remoteName.UTF8String);
  if (code == 0 && request.remoteURL.length > 0) {
    code = git_remote_set_instance_url(remote, request.remoteURL.UTF8String);
    if (code == 0) {
      code = git_remote_set_instance_pushurl(remote, request.remoteURL.UTF8String);
    }
  }
  git_push_options pushOptions = {};
  git_remote_connect_options connectOptions = {};
  if (code == 0) code = git_push_options_init(&pushOptions, GIT_PUSH_OPTIONS_VERSION);
  if (code == 0) {
    code = git_remote_connect_options_init(&connectOptions,
                                           GIT_REMOTE_CONNECT_OPTIONS_VERSION);
  }
  if (code == 0) {
    pushOptions.follow_redirects = GIT_REMOTE_REDIRECT_NONE;
    pushOptions.proxy_opts.type = request.proxyURL.length > 0
        ? GIT_PROXY_SPECIFIED : GIT_PROXY_NONE;
    pushOptions.proxy_opts.url = request.proxyURL.UTF8String;
    DSHGitPushFillCallbacks(&pushOptions.callbacks, state, withCredentials);
    // git_remote_upload replaces the connected remote's option set when
    // explicit push options are supplied. Keep both option sets identical so
    // the advertised-ref check and the upload share one closed policy.
    connectOptions.callbacks = pushOptions.callbacks;
    connectOptions.follow_redirects = pushOptions.follow_redirects;
    connectOptions.proxy_opts = pushOptions.proxy_opts;
    code = git_remote_connect_ext(remote, GIT_DIRECTION_PUSH, &connectOptions);
  }
  int advertisedCode = 0;
  NSString *advertisedBefore = code == 0
      ? DSHGitPushAdvertisedOID(remote, fullReference, &advertisedCode) : nil;
  if (code == 0) code = advertisedCode;
  result.advertisedOID = advertisedBefore;
  if (code != 0) {
    if (remote != nullptr) git_remote_free(remote);
    if (state->interruptedByCancel) result.outcome = DSHGitPushOutcomeCancelled;
    else if (state->interruptedByDeadline) result.outcome = DSHGitPushOutcomeTimedOut;
    else if (DSHGitProxyFailed(request.proxyURL)) result.outcome = DSHGitPushOutcomeProxyFailed;
    else if (code == GIT_EAUTH) result.outcome = DSHGitPushOutcomeAuthFailure;
    else result.outcome = DSHGitPushOutcomeFailed;
    return result;
  }
  id expected = request.expectedRemoteOID;
  if (expected != nil) {
    BOOL matches = (expected == NSNull.null && advertisedBefore == nil) ||
        ([expected isKindOfClass:NSString.class] &&
         [expected isEqualToString:advertisedBefore]);
    if (!matches) {
      git_remote_disconnect(remote);
      git_remote_free(remote);
      result.outcome = DSHGitPushOutcomeConflict;
      return result;
    }
  }
  NSString *refspecValue = [NSString stringWithFormat:@"%@:%@",
      request.fullReference, request.fullReference];
  char *rawRefspec = const_cast<char *>(refspecValue.UTF8String);
  git_strarray refspecs = { &rawRefspec, 1 };
  code = git_remote_upload(remote, &refspecs, &pushOptions);
  git_remote_disconnect(remote);
  if (code != 0) {
    git_remote_free(remote);
    if (code == GIT_ENONFASTFORWARD) {
      // Raised by libgit2 before any packfile bytes are produced.
      result.outcome = DSHGitPushOutcomeNonFastForward;
      return result;
    }
    result.effectMayHaveOccurred = state->bytesMayHaveBeenSent;
    if (state->interruptedByCancel) result.outcome = DSHGitPushOutcomeCancelled;
    else if (state->interruptedByDeadline) result.outcome = DSHGitPushOutcomeTimedOut;
    else if (DSHGitProxyFailed(request.proxyURL)) result.outcome = DSHGitPushOutcomeProxyFailed;
    else if (code == GIT_EAUTH) result.outcome = DSHGitPushOutcomeAuthFailure;
    else {
      result.outcome = DSHGitPushOutcomeFailed;
      // A lost response after the request went out cannot prove rejection.
      result.effectMayHaveOccurred = YES;
    }
    return result;
  }
  BOOL callbackShapeExact = !state->update.malformed &&
      state->update.unexpectedCount == 0 && state->update.targetCount == 1;
  if (!callbackShapeExact) {
    git_remote_free(remote);
    result.outcome = DSHGitPushOutcomeFailed;
    result.effectMayHaveOccurred = YES;
    return result;
  }
  if (state->update.targetRejected) {
    git_remote_free(remote);
    result.outcome = state->update.targetNonFastForward
        ? DSHGitPushOutcomeNonFastForward : DSHGitPushOutcomeRejected;
    return result;
  }
  // The server acknowledged the update. Read the reference back so the
  // receipt carries the OID the server now advertises.
  state->credential.attempted = false;
  int verifyCode = git_remote_connect_ext(remote, GIT_DIRECTION_FETCH,
                                          &connectOptions);
  NSString *observed = verifyCode == 0
      ? DSHGitPushAdvertisedOID(remote, fullReference, &verifyCode) : nil;
  if (git_remote_connected(remote)) git_remote_disconnect(remote);
  git_remote_free(remote);
  result.outcome = DSHGitPushOutcomeSuccess;
  result.verified = verifyCode == 0 && observed.length > 0;
  result.remoteOID = result.verified ? observed : request.localOID;
  return result;
}

DSHGitPushResult *DSHGitPushRun(DSHGitPushRequest *request) {
  DSHGitPushResult *invalid = [[DSHGitPushResult alloc] init];
  invalid.outcome = DSHGitPushOutcomeFailed;
  if (request == nil || request.repository == nullptr ||
      request.remoteName.length == 0 || request.fullReference.length == 0 ||
      request.localOID.length == 0 ||
      (request.remoteURL.length > 0 && request.host.length == 0)) {
    return invalid;
  }
  DSHGitPushConfigureTransportBounds();
  NSTimeInterval timeout = request.timeout > 0 ? request.timeout : DSHGitPushDefaultTimeout;
  DSHGitPushControl *control = [[DSHGitPushControl alloc] init];
  control.cancelToken = request.cancelToken;
  __block DSHGitPushResult *settledResult = nil;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  // The caller blocks on this work; keep the worker at the caller's tier so
  // the wait is not a priority inversion.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      DSHGitPushCallbackState state = {};
      state.credential.host = request.host;
      state.credential.username = request.username;
      state.credential.token = request.token;
      state.update.targetRef = request.fullReference.UTF8String;
      state.control = control;
      DSHGitPushResult *result = DSHGitPushExecute(request, &state);
      // The completion (receipt recording) settles before the waiting caller
      // is released, so a successful caller can read the receipt back.
      if (request.completion != nil) request.completion(result.outcome, result.remoteOID);
      settledResult = result;
      dispatch_semaphore_signal(semaphore);
    }
  });
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (true) {
    dispatch_time_t step = dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC);
    if (dispatch_semaphore_wait(semaphore, step) == 0) break;
    if (request.cancelToken != nil && request.cancelToken.cancelled) {
      // Give the worker one more poll to settle on the cancellation itself;
      // otherwise report it here while the worker aborts at its next callback.
      dispatch_time_t grace = dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC);
      if (dispatch_semaphore_wait(semaphore, grace) == 0) break;
      DSHGitPushResult *cancelled = [[DSHGitPushResult alloc] init];
      cancelled.outcome = DSHGitPushOutcomeCancelled;
      cancelled.effectMayHaveOccurred = YES;
      return cancelled;
    }
    if ([NSDate.date compare:deadline] != NSOrderedAscending) {
      [control markDeadlinePassed];
      DSHGitPushResult *timedOut = [[DSHGitPushResult alloc] init];
      timedOut.outcome = DSHGitPushOutcomeTimedOut;
      timedOut.effectMayHaveOccurred = YES;
      return timedOut;
    }
  }
  return settledResult ?: invalid;
}

// MARK: - Receipt journal

static BOOL DSHGitPushValidOID(NSString *oid) {
  if (![oid isKindOfClass:NSString.class] || oid.length != 40) return NO;
  NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:
      @"0123456789abcdef"];
  return [oid rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

static BOOL DSHGitPushValidReceipt(NSDictionary *receipt) {
  if (![receipt isKindOfClass:NSDictionary.class] || receipt.count != 7 ||
      ![receipt[@"schema_version"] isEqual:@1] ||
      ![receipt[@"remote"] isEqual:@"origin"] ||
      ![receipt[@"host"] isKindOfClass:NSString.class] ||
      ((NSString *)receipt[@"host"]).length == 0 ||
      ((NSString *)receipt[@"host"]).length > 253 ||
      DSHGitPushHasControlCharacter(receipt[@"host"]) ||
      ![receipt[@"branch"] isKindOfClass:NSString.class] ||
      ((NSString *)receipt[@"branch"]).length == 0 ||
      ((NSString *)receipt[@"branch"]).length > 1024 ||
      DSHGitPushHasControlCharacter(receipt[@"branch"]) ||
      [((NSString *)receipt[@"branch"]) containsString:@".."] ||
      !DSHGitPushValidOID(receipt[@"local_oid"]) ||
      !DSHGitPushValidOID(receipt[@"remote_oid"]) ||
      ![receipt[@"pushed_at"] isKindOfClass:NSString.class] ||
      ((NSString *)receipt[@"pushed_at"]).length == 0 ||
      ((NSString *)receipt[@"pushed_at"]).length > 64 ||
      DSHGitPushHasControlCharacter(receipt[@"pushed_at"])) {
    return NO;
  }
  return YES;
}

NSDictionary *DSHGitPushReceipt(NSString *host, NSString *branch,
                                NSString *localOID, NSString *remoteOID,
                                NSString *pushedAt) {
  return @{
    @"schema_version" : @1,
    @"remote" : @"origin",
    @"host" : host ?: @"",
    @"branch" : branch ?: @"",
    @"local_oid" : localOID ?: @"",
    @"remote_oid" : remoteOID ?: @"",
    @"pushed_at" : pushedAt ?: @"",
  };
}

static NSArray<NSDictionary *> *DSHGitPushLoadReceiptsInternal(
    int directoryDescriptor, NSString *projectId, NSError **error) {
  if (directoryDescriptor < 0 || projectId.length == 0) {
    if (error != nil) *error = DSHGitPushSupportError(3020, @"Receipt storage is unavailable");
    return nil;
  }
  int descriptor = openat(directoryDescriptor, DSHGitPushReceiptFilename.UTF8String,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    if (errno == ENOENT) return @[];
    if (error != nil) *error = DSHGitPushSupportError(3020, @"Receipt storage is unavailable");
    return nil;
  }
  struct stat identity = {};
  BOOL safe = fstat(descriptor, &identity) == 0 && S_ISREG(identity.st_mode) &&
      identity.st_size >= 0 && identity.st_size <= (off_t)DSHGitPushMaxReceiptJournalBytes;
  NSData *data = nil;
  if (safe) {
    NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:descriptor
                                                          closeOnDealloc:YES];
    data = handle == nil ? nil : [handle readDataToEndOfFile];
    [handle closeFile];
    if (data.length > DSHGitPushMaxReceiptJournalBytes) data = nil;
  } else {
    close(descriptor);
  }
  NSDictionary *journal = data == nil ? nil
      : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSArray *receipts = [journal isKindOfClass:NSDictionary.class] ?
      journal[@"receipts"] : nil;
  if (![journal isKindOfClass:NSDictionary.class] ||
      ![journal[@"schema_version"] isEqual:@1] ||
      ![journal[@"project_id"] isEqual:projectId] ||
      ![receipts isKindOfClass:NSArray.class] ||
      receipts.count > DSHGitPushMaxReceipts) {
    if (error != nil) *error = DSHGitPushSupportError(3021, @"Receipt journal is invalid");
    return nil;
  }
  for (NSDictionary *receipt in receipts) {
    if (!DSHGitPushValidReceipt(receipt)) {
      if (error != nil) *error = DSHGitPushSupportError(3021, @"Receipt journal is invalid");
      return nil;
    }
  }
  return receipts;
}

static BOOL DSHGitPushWriteAll(int descriptor, const void *bytes, size_t length) {
  const uint8_t *cursor = static_cast<const uint8_t *>(bytes);
  size_t remaining = length;
  while (remaining > 0) {
    ssize_t written = write(descriptor, cursor, remaining);
    if (written < 0) {
      if (errno == EINTR) continue;
      return NO;
    }
    cursor += written;
    remaining -= (size_t)written;
  }
  return YES;
}

BOOL DSHGitPushRecordReceipt(int directoryDescriptor, NSString *projectId,
                             NSDictionary *receipt, NSError **error) {
  if (!DSHGitPushValidReceipt(receipt)) {
    if (error != nil) *error = DSHGitPushSupportError(3021, @"Receipt journal is invalid");
    return NO;
  }
  NSError *loadError = nil;
  NSArray<NSDictionary *> *existing = DSHGitPushLoadReceiptsInternal(
      directoryDescriptor, projectId, &loadError);
  if (existing == nil) {
    if (error != nil) *error = loadError ?: DSHGitPushSupportError(3020,
        @"Receipt storage is unavailable");
    return NO;
  }
  NSArray *receipts = [existing arrayByAddingObject:receipt];
  if (receipts.count > DSHGitPushMaxReceipts) {
    receipts = [receipts subarrayWithRange:
        NSMakeRange(receipts.count - DSHGitPushMaxReceipts, DSHGitPushMaxReceipts)];
  }
  NSDictionary *journal = @{
    @"schema_version" : @1,
    @"project_id" : projectId,
    @"receipts" : receipts,
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:journal
      options:NSJSONWritingSortedKeys error:nil];
  if (data == nil || data.length > DSHGitPushMaxReceiptJournalBytes) {
    if (error != nil) *error = DSHGitPushSupportError(3021, @"Receipt journal is invalid");
    return NO;
  }
  int descriptor = openat(directoryDescriptor,
      DSHGitPushReceiptTempFilename.UTF8String,
      O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (descriptor < 0 || !DSHGitPushWriteAll(descriptor, data.bytes, data.length) ||
      fsync(descriptor) != 0 || close(descriptor) != 0) {
    if (descriptor >= 0) close(descriptor);
    unlinkat(directoryDescriptor, DSHGitPushReceiptTempFilename.UTF8String, 0);
    if (error != nil) *error = DSHGitPushSupportError(3020, @"Receipt storage is unavailable");
    return NO;
  }
  if (renameat(directoryDescriptor, DSHGitPushReceiptTempFilename.UTF8String,
               directoryDescriptor, DSHGitPushReceiptFilename.UTF8String) != 0 ||
      fsync(directoryDescriptor) != 0) {
    unlinkat(directoryDescriptor, DSHGitPushReceiptTempFilename.UTF8String, 0);
    if (error != nil) *error = DSHGitPushSupportError(3020, @"Receipt storage is unavailable");
    return NO;
  }
  return YES;
}

NSArray<NSDictionary *> *DSHGitPushLoadReceipts(int directoryDescriptor,
                                                NSString *projectId,
                                                NSError **error) {
  return DSHGitPushLoadReceiptsInternal(directoryDescriptor, projectId, error);
}

BOOL DSHGitProxyFailed(NSString *proxyURL) {
  if (proxyURL.length == 0) return NO;
  const git_error *last = git_error_last();
  NSString *message = last != nullptr && last->message != nullptr
      ? [NSString stringWithUTF8String:last->message] : nil;
  if (message.length == 0) return NO;
  if ([message hasPrefix:@"proxy "]) return YES;
  NSString *host = [NSURLComponents componentsWithString:proxyURL].host;
  if (host.length == 0) return NO;
  return [message containsString:[@"failed to connect to " stringByAppendingString:host]] ||
      [message containsString:[@"failed to resolve address for " stringByAppendingString:host]];
}
