#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif

BOOL RishGitFormOptionsAreValid(id _Nullable options);
/// Produces only the reviewed non-secret fields, or nil for invalid input.
NSDictionary<NSString *, NSString *> *_Nullable RishGitFormValues(
    NSString *kind, id values);

#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
