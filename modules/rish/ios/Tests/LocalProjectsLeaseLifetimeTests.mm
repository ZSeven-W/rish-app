#import <XCTest/XCTest.h>
#import "DSHTestStorageFixture.h"
#import "../Sources/LocalProjectAccess.h"

typedef void (^LPLifetimeResolve)(id);
typedef void (^LPLifetimeReject)(NSString *, NSString *, NSError *);

@interface LocalProjectsModule : NSObject
- (instancetype)initWithSupportURL:(nullable NSURL *)support
                    projectAccess:(DSHLocalProjectAccess *)projectAccess;
- (void)commitProject:(id)projectId message:(id)message authorName:(id)authorName
          authorEmail:(id)authorEmail resolver:(LPLifetimeResolve)resolve
             rejecter:(LPLifetimeReject)reject;
@end

// Observes ownership without extending the production lease's lifetime.
@interface LPLifetimeAccess : DSHLocalProjectAccess
@property(nonatomic, weak) DSHLocalProjectLease *observedLease;
@end

@implementation LPLifetimeAccess
- (NSDictionary *)readProjectMetadataFromLease:(DSHLocalProjectLease *)lease
                                         error:(NSError **)error {
  self.observedLease = lease;
  return [super readProjectMetadataFromLease:lease error:error];
}
@end

@interface LocalProjectsLeaseLifetimeTests : XCTestCase
@property(nonatomic, strong) NSURL *fixture;
@property(nonatomic, strong) LPLifetimeAccess *access;
@property(nonatomic, strong) LocalProjectsModule *module;
@property(nonatomic, copy) NSString *projectId;
@property(nonatomic, strong) NSURL *repositoryURL;
@end

@implementation LocalProjectsLeaseLifetimeTests
- (void)setUp {
  [super setUp];
  NSError *error = nil;
  self.fixture = DSHCreateTestStorageFixtureRoot(@"project-lease-lifetime", &error);
  XCTAssertNotNil(self.fixture, @"%@", error);
  self.projectId = NSUUID.UUID.UUIDString.lowercaseString;
  NSURL *projects = [self.fixture URLByAppendingPathComponent:@"projects" isDirectory:YES];
  NSURL *project = [projects URLByAppendingPathComponent:self.projectId isDirectory:YES];
  self.repositoryURL = [project URLByAppendingPathComponent:@"repo" isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.repositoryURL
      withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions : @0700}
      error:&error], @"%@", error);
  NSDictionary *metadata = @{
    @"schema_version" : @1, @"name" : @"Lease lifetime",
    @"created_at" : @"2026-10-15T00:00:00.000Z",
    @"updated_at" : @"2026-10-15T00:00:00.000Z", @"origin_url" : NSNull.null,
  };
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:metadata options:0 error:&error];
  XCTAssertTrue([bytes writeToURL:[project URLByAppendingPathComponent:@"project.json"]
      atomically:YES]);
  XCTAssertGreaterThan(git_libgit2_init(), 0);
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_init(&repository,
      self.repositoryURL.fileSystemRepresentation, 0), 0);
  git_repository_free(repository);
  self.access = [[LPLifetimeAccess alloc] initWithProjectsRootURL:projects];
  // No shared app storage or credentials are used by this fixture.
  self.module = [[LocalProjectsModule alloc] initWithSupportURL:nil projectAccess:self.access];
}

- (void)tearDown {
  self.module = nil;
  self.access = nil;
  if (self.fixture != nil) {
    [NSFileManager.defaultManager removeItemAtURL:self.fixture error:nil];
    git_libgit2_shutdown();
  }
  [super tearDown];
}

- (void)stageFixture {
  NSData *bytes = [@"fixture\n" dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertTrue([bytes writeToURL:[self.repositoryURL URLByAppendingPathComponent:@"file.txt"]
      atomically:YES]);
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_open(&repository,
      self.repositoryURL.fileSystemRepresentation), 0);
  git_index *index = nullptr;
  XCTAssertEqual(git_repository_index(&index, repository), 0);
  XCTAssertEqual(git_index_add_bypath(index, "file.txt"), 0);
  XCTAssertEqual(git_index_write(index), 0);
  git_index_free(index);
  git_repository_free(repository);
}

- (void)checkCommitReleasesLeaseExpectingSuccess:(BOOL)expectSuccess {
  XCTestExpectation *finished = [self expectationWithDescription:@"subsequent write lease"];
  dispatch_queue_t queue = [self.module valueForKey:@"projectQueue"];
  __block BOOL settled = NO;
  // Queue both items before execution so an idle worker cannot incidentally
  // drain its outer autorelease pool between the commit and the next writer.
  dispatch_suspend(queue);
  [self.module commitProject:self.projectId message:@"fixture commit"
      authorName:@"Fixture" authorEmail:@"fixture@rish.local"
      resolver:^(__unused id result) {
        XCTAssertTrue(expectSuccess);
        settled = YES;
      } rejecter:^(NSString *code, __unused NSString *message, __unused NSError *error) {
        XCTAssertFalse(expectSuccess);
        XCTAssertEqualObjects(code, @"git");
        settled = YES;
      }];
  dispatch_async(queue, ^{
    XCTAssertTrue(settled);
    @autoreleasepool {
      XCTAssertNil(self.access.observedLease,
          @"A completed bridge call must not retain its repository lease");
    }
    @autoreleasepool {
      NSError *error = nil;
      DSHLocalProjectLease *next = [self.access leaseProjectId:self.projectId
          mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:0.05 error:&error];
      XCTAssertNotNil(next, @"The next operation must acquire the lock: %@", error);
    }
    [finished fulfill];
  });
  dispatch_resume(queue);
  [self waitForExpectations:@[finished] timeout:5];
}

- (void)testCommitReleasesWriteLeaseBeforeNextQueuedOperation {
  [self stageFixture];
  [self checkCommitReleasesLeaseExpectingSuccess:YES];
}

- (void)testRejectedCommitReleasesWriteLeaseBeforeNextQueuedOperation {
  [self checkCommitReleasesLeaseExpectingSuccess:NO];
}
@end
