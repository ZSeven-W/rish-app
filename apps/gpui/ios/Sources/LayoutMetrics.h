#pragma once
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
/// Main thread only. Returns false without changing output if no key window
/// exists or count < 8. Values are UIKit points, then UIKit size-class enums:
/// width, height, safe top/right/bottom/left, horizontal class, vertical class.
/// Metrics describe the actual window; they do not infer folds or occlusions.
bool rish_gpui_layout_metrics(float *values, size_t count);
#ifdef __cplusplus
}
#endif
