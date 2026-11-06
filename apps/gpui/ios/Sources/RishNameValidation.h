#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, RishNameValidationIssue) {
  RishNameValidationIssueNone,
  RishNameValidationIssueEmpty,
  RishNameValidationIssueInvalid,
  RishNameValidationIssueTooLong,
};

BOOL RishNameOptionsAreValid(id options);
NSString *RishNormalizedName(NSString *text);
RishNameValidationIssue RishValidateName(NSString *text, NSString *kind);
