#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^RishGuestCgiResolve)(NSDictionary *result);
typedef void (^RishGuestCgiReject)(NSString *code, NSString *message);

/// Experimental guest CGI service. A running service may use a system-granted
/// background task for an external Safari preview, bounded by the system grant
/// and a 120-second total cap (at most 115 seconds of preview plus five of
/// teardown). A shorter iOS grant produces a shorter preview. Grant denial or expiration stops the service;
/// this is not a persistent background server. It creates and owns one LocalGuest session
/// and exposes only loopback HTTP. It deliberately has no Node, filesystem
/// path, or shell API at the the UI boundary. stop tears down this owned
/// session and never shuts down a caller-owned guest.
/// Background preview denial/deadlines use the owned service teardown path.
@interface RishGuestCgiService : NSObject

- (instancetype)init;

/// Request keys: indexHtml (string), backendScript (string), and optional
/// initialData (JSON object/array). Values are staged into guest /tmp after
/// bounded base64 transfer and digest verification.
- (void)start:(NSDictionary *)request
       resolve:(RishGuestCgiResolve)resolve
        reject:(RishGuestCgiReject)reject;

- (void)stop:(NSString *)serviceId
      resolve:(RishGuestCgiResolve)resolve
       reject:(RishGuestCgiReject)reject;

/// Public status contains only service id, loopback URL, and lifecycle state.
- (NSDictionary *)status;

@end

NS_ASSUME_NONNULL_END
