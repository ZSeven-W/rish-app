#import <XCTest/XCTest.h>
#import "AgentGitToolSupport.h"
#import "AgentNativeWAL.h"
#include <git2.h>
#include <string.h>

@interface AgentGitIndexPathTests : XCTestCase
@end

@implementation AgentGitIndexPathTests
- (void)setUp {
  [super setUp];
  XCTAssertGreaterThan(git_libgit2_init(), 0);
}
- (void)tearDown {
  git_libgit2_shutdown();
  [super tearDown];
}
- (int)addPath:(const char *)path mode:(uint32_t)mode toIndex:(git_index *)index {
  git_index_entry entry = {};
  entry.path = path;
  entry.mode = mode;
  int code = git_oid_fromstr(&entry.id, "1111111111111111111111111111111111111111");
  XCTAssertEqual(code, 0);
  if (code != 0) return code;
  return git_index_add(index, &entry);
}
- (void)testNonUTF8Libgit2IndexPathIsConflictAndDoesNotMutateTheIndex {
  const char invalidPaths[][4] = {
    {'x', (char)0xff, '\0', '\0'},
    {'x', (char)0xc0, (char)0xaf, '\0'},
  };
  for (const auto &path : invalidPaths) {
    XCTAssertNil([[NSString alloc] initWithBytes:path length:strlen(path)
        encoding:NSUTF8StringEncoding]);
    git_index *index = nullptr;
    XCTAssertEqual(git_index_new(&index), 0);
    if (index == nullptr) continue;
    @try {
      XCTAssertEqual([self addPath:"a.txt" mode:GIT_FILEMODE_BLOB toIndex:index], 0);
      int added = [self addPath:path mode:GIT_FILEMODE_BLOB toIndex:index];
      XCTAssertEqual(added, 0, @"libgit2 must retain the real byte path for this regression");
      if (added != 0) continue;
      XCTAssertEqual(git_index_entrycount(index), (size_t)2);
      const git_index_entry *before = git_index_get_bypath(index, path, 0);
      XCTAssertNotEqual(before, nullptr);
      if (before == nullptr) continue;
      XCTAssertEqual(memcmp(before->path, path, strlen(path) + 1), 0);
      git_oid originalOID = before->id;
      NSError *error = nil;
      XCTAssertNil(DSHAgentGitIndexDigest(index, &error));
      XCTAssertEqualObjects(error.domain, DSHAgentNativeStoreErrorDomain);
      XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
      XCTAssertEqual(git_index_entrycount(index), (size_t)2);
      const git_index_entry *after = git_index_get_bypath(index, path, 0);
      XCTAssertNotEqual(after, nullptr);
      if (after != nullptr) {
        XCTAssertEqual(memcmp(after->path, path, strlen(path) + 1), 0);
        XCTAssertTrue(git_oid_equal(&originalOID, &after->id));
        XCTAssertEqual(after->mode, (uint32_t)GIT_FILEMODE_BLOB);
      }
    } @finally {
      git_index_free(index);
    }
  }
}
- (void)testDecodableIndexEntriesStillUseTheSharedCoreModeRule {
  git_index *index = nullptr;
  XCTAssertEqual(git_index_new(&index), 0);
  if (index == nullptr) return;
  @try {
    XCTAssertEqual([self addPath:"main.py" mode:GIT_FILEMODE_BLOB toIndex:index], 0);
    NSError *error = nil;
    NSString *digest = DSHAgentGitIndexDigest(index, &error);
    XCTAssertEqual(digest.length, 64U);
    XCTAssertNil(error);
    // libgit2 accepts a staged symlink; the shared core refuses to commit it.
    XCTAssertEqual([self addPath:"link" mode:GIT_FILEMODE_LINK toIndex:index], 0);
    XCTAssertNil(DSHAgentGitIndexDigest(index, &error));
    XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
    XCTAssertEqual(git_index_entrycount(index), (size_t)2);
  } @finally {
    git_index_free(index);
  }
}
@end
