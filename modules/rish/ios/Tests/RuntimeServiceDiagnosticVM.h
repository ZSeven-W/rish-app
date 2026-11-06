#import "RuntimeServiceVM.h"

/// Opt-in diagnostics for isolated native runtime tests only. Never prints
/// argv, environment values, file contents, HTTP bytes or random bytes.
@interface DSHRuntimeServiceDiagnosticVM : DSHRuntimeServiceVM
@end
