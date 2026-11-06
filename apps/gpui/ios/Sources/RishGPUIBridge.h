#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
/// args_json is a positional JSON array. Strings are copied before returning.
/// Every accepted call replies at most once, on an arbitrary native queue.
void rish_gpui_host_request(uint64_t request_id, const char *module,
                           const char *method, const char *args_json);
/// Rust callbacks must copy C strings during the callback; they are borrowed.
void rish_gpui_host_reply(uint64_t request_id, const char *json, bool is_error);
void rish_gpui_host_event(const char *name, const char *payload_json);
#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <Foundation/Foundation.h>
@class RishNativeBridge;
RishNativeBridge *RishGPUIBridgeShared(void);
void RishGPUIEmitEvent(NSString *name, id body);
#endif
