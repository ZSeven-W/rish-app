#import <Foundation/Foundation.h>

/// File text is preserved verbatim; normalization would change file contents.
BOOL RishFileEditorOptionsAreValid(id options);
BOOL RishFileEditorTextFits(NSString *text, NSUInteger maxBytes);
