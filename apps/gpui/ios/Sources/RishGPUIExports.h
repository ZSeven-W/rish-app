#pragma once
#import <Foundation/Foundation.h>

/// Only this compiled, reviewed table may select a module or a selector.
/// i=id, s=string, d=dictionary, a=array, n=number, b=boolean.
typedef struct {
  __unsafe_unretained NSString *module;
  __unsafe_unretained NSString *name;
  __unsafe_unretained NSString *selector;
  const char *types;
  BOOL synchronous;
} RishExport;
#include "Exports.inc"
