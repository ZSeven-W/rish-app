#import <XCTest/XCTest.h>
#import <ImageIO/ImageIO.h>
#import <PhotosUI/PhotosUI.h>
#import <CommonCrypto/CommonDigest.h>
#import "ShellAssistantAvatarImage.h"
#import "ShellAssistantAvatarPicker.h"
#import "ShellAssistantModule.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

@interface AvatarTestPresenter : UIViewController
@property(nonatomic, strong) UIViewController *captured;
@end
@implementation AvatarTestPresenter
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
  (void)animated; self.captured = controller; if (completion) completion();
}
@end

@interface ShellAssistantAvatarTests : XCTestCase
@property(nonatomic, strong) NSURL *root;
@property(nonatomic, strong) NSURL *assistant;
@end
@implementation ShellAssistantAvatarTests
- (void)setUp {
  [super setUp]; self.continueAfterFailure = NO;
  self.root = [[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
      [@"avatar-native-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES] URLByResolvingSymlinksInPath];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:NO
      attributes:@{NSFilePosixPermissions:@0700} error:nil]);
  self.assistant = [self.root URLByAppendingPathComponent:@"Assistant-v1" isDirectory:YES];
  ShellAssistantModule *module = [[ShellAssistantModule alloc] initWithDirectory:self.assistant];
  [module storageWithResolver:^(id value) { XCTAssertEqualObjects(value[@"schema_version"], @1); }
      rejecter:^(NSString *code, NSString *message, NSError *error) { XCTFail(@"%@", code); }];
}
- (void)tearDown { [NSFileManager.defaultManager removeItemAtURL:self.root error:nil]; [super tearDown]; }
- (NSURL *)source:(NSString *)name data:(NSData *)data {
  NSURL *url = [self.root URLByAppendingPathComponent:name];
  XCTAssertTrue([data writeToURL:url atomically:YES]); return url;
}
- (NSData *)imageWidth:(NSUInteger)width height:(NSUInteger)height type:(CFStringRef)type metadata:(NSDictionary *)metadata {
  CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, colors, kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(colors); XCTAssertTrue(context != NULL);
  CGContextSetRGBFillColor(context, 0.85, 0.1, 0.1, 1); CGContextFillRect(context, CGRectMake(0, 0, width, height));
  CGContextSetRGBFillColor(context, 0.1, 0.2, 0.85, 1); CGContextFillRect(context, CGRectMake(0, 0, width / 2, height / 2));
  CGImageRef image = CGBitmapContextCreateImage(context); CGContextRelease(context);
  NSMutableData *bytes = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)bytes, type, 1, NULL);
  XCTAssertTrue(destination != NULL); CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)metadata);
  XCTAssertTrue(CGImageDestinationFinalize(destination)); CFRelease(destination); CGImageRelease(image); return bytes;
}
- (NSURL *)output:(NSDictionary *)metadata {
  return [[self.assistant URLByAppendingPathComponent:@"avatars"] URLByAppendingPathComponent:
      [metadata[@"id"] stringByAppendingString:@".png"]];
}
- (NSDictionary *)import:(NSURL *)source {
  NSError *error = nil;
  NSDictionary *result = [ShellAssistantAvatarImage importImageAtURL:source intoAssistantDirectory:self.assistant error:&error];
  XCTAssertNotNil(result, @"%@", error); XCTAssertNil(error); return result;
}
- (void)testThumbnailIsBoundedPNGWithRelativeIdentityAndPrivateAtomicFile {
  NSData *source = [self imageWidth:1200 height:800 type:CFSTR("public.png") metadata:@{}];
  NSURL *url = [self source:@"source.png" data:source]; NSDictionary *result = [self import:url];
  XCTAssertEqualObjects(result[@"mime_type"], @"image/png"); XCTAssertEqual(result.count, 6U);
  NSString *identifier = result[@"id"];
  XCTAssertEqualObjects(identifier, [[NSUUID alloc] initWithUUIDString:identifier].UUIDString.lowercaseString);
  XCTAssertEqualObjects(result[@"width"], @512); XCTAssertLessThanOrEqual([result[@"height"] unsignedIntegerValue], 512U);
  NSURL *output = [self output:result]; NSData *png = [NSData dataWithContentsOfURL:output];
  XCTAttachment *fixture = [XCTAttachment attachmentWithData:png uniformTypeIdentifier:@"public.png"];
  fixture.name = @"avatar-picker-synthetic-fixture.png"; fixture.lifetime = XCTAttachmentLifetimeKeepAlways;
  [self addAttachment:fixture];
  XCTAssertEqualObjects(result[@"byte_length"], @(png.length)); XCTAssertLessThanOrEqual(png.length, 2U * 1024 * 1024);
  unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(png.bytes, (CC_LONG)png.length, hash);
  NSMutableString *hex = [NSMutableString string]; for (NSUInteger i = 0; i < sizeof hash; i++) [hex appendFormat:@"%02x", hash[i]];
  XCTAssertEqualObjects(result[@"sha256"], hex);
  struct stat file = {}, directory = {};
  XCTAssertEqual(lstat(output.fileSystemRepresentation, &file), 0); XCTAssertTrue(S_ISREG(file.st_mode));
  XCTAssertEqual(file.st_mode & 0777, 0600); XCTAssertEqual(file.st_nlink, 1U);
  XCTAssertEqual(lstat(output.URLByDeletingLastPathComponent.fileSystemRepresentation, &directory), 0);
  XCTAssertEqual(directory.st_mode & 0777, 0700);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], source);
  XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:output.URLByDeletingLastPathComponent.path error:nil].count, 1U);
  CGImageSourceRef decoded = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
  XCTAssertEqualObjects((__bridge NSString *)CGImageSourceGetType(decoded), @"public.png"); CFRelease(decoded);
}
- (void)testOrientationIsAppliedAndCameraMetadataIsStripped {
  NSDictionary *meta = @{(__bridge NSString *)kCGImagePropertyOrientation:@6,
    (__bridge NSString *)kCGImagePropertyGPSDictionary:@{
      (__bridge NSString *)kCGImagePropertyGPSLatitude:@37.3,
      (__bridge NSString *)kCGImagePropertyGPSLatitudeRef:@"N",
      (__bridge NSString *)kCGImagePropertyGPSLongitude:@121.9,
      (__bridge NSString *)kCGImagePropertyGPSLongitudeRef:@"W"},
    (__bridge NSString *)kCGImagePropertyExifDictionary:@{(__bridge NSString *)kCGImagePropertyExifUserComment:@"private camera note"}};
  NSURL *url = [self source:@"oriented.jpg" data:[self imageWidth:64 height:96 type:CFSTR("public.jpeg") metadata:meta]];
  CGImageSourceRef original = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  NSDictionary *originalProperties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(original, 0, NULL)); CFRelease(original);
  XCTAssertEqualObjects(originalProperties[(__bridge NSString *)kCGImagePropertyOrientation], @6);
  XCTAssertNotNil(originalProperties[(__bridge NSString *)kCGImagePropertyGPSDictionary]);
  XCTAssertEqualObjects(originalProperties[(__bridge NSString *)kCGImagePropertyExifDictionary][(__bridge NSString *)kCGImagePropertyExifUserComment], @"private camera note");
  NSDictionary *result = [self import:url];
  XCTAssertEqualObjects(result[@"width"], @96); XCTAssertEqualObjects(result[@"height"], @64);
  CGImageSourceRef decoded = CGImageSourceCreateWithURL((__bridge CFURLRef)[self output:result], NULL);
  NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(decoded, 0, NULL)); CFRelease(decoded);
  XCTAssertNil(props[(__bridge NSString *)kCGImagePropertyGPSDictionary]);
  XCTAssertNil(props[(__bridge NSString *)kCGImagePropertyExifDictionary]);
  XCTAssertNotEqualObjects(props[(__bridge NSString *)kCGImagePropertyOrientation], @6);
}
- (void)testImageInputLimitsAreCheckedBeforePixelDecode {
  NSData *one = [self imageWidth:1 height:1 type:CFSTR("public.png") metadata:@{}];
  for (NSArray<NSNumber *> *dimensions in @[@[@40000,@1], @[@12000,@12000]]) {
    NSMutableData *huge = [one mutableCopy];
    uint32_t width = htonl(dimensions[0].unsignedIntValue), height = htonl(dimensions[1].unsignedIntValue);
    [huge replaceBytesInRange:NSMakeRange(16, 4) withBytes:&width];
    [huge replaceBytesInRange:NSMakeRange(20, 4) withBytes:&height];
    uint32_t crc = htonl((uint32_t)crc32(0, (const Bytef *)huge.bytes + 12, 17));
    [huge replaceBytesInRange:NSMakeRange(29, 4) withBytes:&crc];
    NSError *error = nil;
    XCTAssertNil([ShellAssistantAvatarImage importImageAtURL:[self source:NSUUID.UUID.UUIDString data:huge]
        intoAssistantDirectory:self.assistant error:&error]);
    XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ASSISTANT_AVATAR_TOO_LARGE");
  }
}
- (void)testOversizedFileIsRejectedWithoutReadingItsContents {
  NSURL *file = [self.root URLByAppendingPathComponent:@"too-large.png"];
  int fd = open(file.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
  XCTAssertGreaterThanOrEqual(fd, 0); XCTAssertEqual(ftruncate(fd, 64LL * 1024 * 1024 + 1), 0); close(fd);
  NSError *error = nil;
  XCTAssertNil([ShellAssistantAvatarImage importImageAtURL:file intoAssistantDirectory:self.assistant error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ASSISTANT_AVATAR_TOO_LARGE");
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.assistant URLByAppendingPathComponent:@"avatars"].path]);
}
- (void)testNonImagesSymlinkInputsAndFIFOAreRejected {
  NSURL *text = [self source:@"not-image" data:[@"not an image" dataUsingEncoding:NSUTF8StringEncoding]];
  NSURL *image = [self source:@"image.png" data:[self imageWidth:16 height:16 type:CFSTR("public.png") metadata:@{}]];
  NSURL *link = [self.root URLByAppendingPathComponent:@"link.png"];
  XCTAssertEqual(symlink(image.fileSystemRepresentation, link.fileSystemRepresentation), 0);
  NSURL *fifo = [self.root URLByAppendingPathComponent:@"fifo"];
  XCTAssertEqual(mkfifo(fifo.fileSystemRepresentation, 0600), 0);
  for (NSURL *url in @[text, link, fifo, self.root]) {
    NSError *error = nil;
    XCTAssertNil([ShellAssistantAvatarImage importImageAtURL:url intoAssistantDirectory:self.assistant error:&error]);
    XCTAssertNotNil(error);
  }
}
- (void)testSymlinkOutputDirectoriesCannotRedirectAvatarWrites {
  NSURL *source = [self source:@"image.png" data:[self imageWidth:16 height:16 type:CFSTR("public.png") metadata:@{}]];
  NSURL *outside = [self.root URLByAppendingPathComponent:@"outside" isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:outside withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0755} error:nil]);
  NSURL *avatars = [self.assistant URLByAppendingPathComponent:@"avatars"];
  XCTAssertEqual(symlink(outside.fileSystemRepresentation, avatars.fileSystemRepresentation), 0);
  NSError *error = nil;
  XCTAssertNil([ShellAssistantAvatarImage importImageAtURL:source intoAssistantDirectory:self.assistant error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ASSISTANT_AVATAR_STORAGE");
  XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:outside.path error:nil].count, 0U);
  struct stat metadata = {}; XCTAssertEqual(stat(outside.fileSystemRepresentation, &metadata), 0); XCTAssertEqual(metadata.st_mode & 0777, 0755);
}
- (void)testPreviousAvatarIsRetainedAndFailedImportLeavesNoTemporaryFiles {
  NSURL *source = [self source:@"image.png" data:[self imageWidth:16 height:16 type:CFSTR("public.png") metadata:@{}]];
  NSDictionary *first = [self import:source]; NSData *firstBytes = [NSData dataWithContentsOfURL:[self output:first]];
  NSDictionary *second = [self import:source]; XCTAssertNotEqualObjects(first[@"id"], second[@"id"]);
  XCTAssertEqualObjects(first[@"sha256"], second[@"sha256"]);
  NSError *error = nil;
  XCTAssertNil([ShellAssistantAvatarImage importImageAtURL:[self source:@"bad" data:[NSData data]] intoAssistantDirectory:self.assistant error:&error]);
  XCTAssertEqualObjects(firstBytes, [NSData dataWithContentsOfURL:[self output:first]]);
  NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:[self.assistant URLByAppendingPathComponent:@"avatars"].path error:nil];
  XCTAssertEqual(files.count, 2U); for (NSString *file in files) XCTAssertTrue([file hasSuffix:@".png"]);
}
- (void)testAvatarImportDoesNotAssignOrRewriteAnyBotProfile {
  // The picker owns image import only. Profile ownership/CAS remains in Rust,
  // so a late photo result cannot select or overwrite any Bot natively.
  NSURL *store = [self.assistant URLByAppendingPathComponent:@"assistant-v1.json"];
  NSData *existing = [@"{\"revision\":31,\"profile\":{\"name\":\"Default Bot\"},\"bots\":[{\"id\":\"bot-b\",\"profile\":{\"name\":\"Other Bot\"}}]}"
      dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertTrue([existing writeToURL:store atomically:YES]);
  NSURL *source = [self source:@"image.png" data:[self imageWidth:16 height:16 type:CFSTR("public.png") metadata:@{}]];
  NSDictionary *first = [self import:source], *second = [self import:source];
  XCTAssertNotEqualObjects(first[@"id"], second[@"id"]);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:store], existing);
  XCTAssertNil(first[@"bot_id"]); XCTAssertNil(first[@"profile"]);
  XCTAssertNil(second[@"bot_id"]); XCTAssertNil(second[@"profile"]);
}
- (void)testPickerRequiresExplicitTypedUserAction {
  XCTAssertTrue(ShellAssistantAvatarRequestValid(@{@"schema_version":@1,@"userInitiated":@YES}));
  for (id request in @[@{}, @{@"schema_version":@1}, @{@"schema_version":@1,@"userInitiated":@NO},
      @{@"schema_version":@YES,@"userInitiated":@YES}, @{@"schema_version":@1.0,@"userInitiated":@YES},
      @{@"schema_version":@1,@"userInitiated":@1}, @{@"schema_version":@1,@"userInitiated":@YES,@"path":@"/tmp/x"}, NSNull.null]) {
    XCTAssertFalse(ShellAssistantAvatarRequestValid(request));
    ShellAssistantModule *module = [[ShellAssistantModule alloc] initWithDirectory:self.assistant];
    __block BOOL rejected = NO;
    [module pickAvatarWithRequest:request resolver:^(id value) { XCTFail(@"invalid picker request returned"); }
        rejecter:^(NSString *code, NSString *message, NSError *error) { rejected = YES; XCTAssertEqualObjects(code, @"E_ASSISTANT_AVATAR_INVALID"); }];
    XCTAssertTrue(rejected);
  }
}
- (void)testPickerCancellationResolvesNullOnceWithoutCreatingAvatar {
  XCTAssertTrue(NSThread.isMainThread);
  AvatarTestPresenter *presenter = [AvatarTestPresenter new]; ShellAssistantAvatarPicker *host = [ShellAssistantAvatarPicker new];
  XCTestExpectation *done = [self expectationWithDescription:@"cancel selected avatar"];
  __block NSUInteger completed = 0;
  [host presentFrom:presenter directory:self.assistant resolve:^(id value) { completed++; XCTAssertEqualObjects(value, NSNull.null); [done fulfill]; }
      reject:^(NSString *code, NSString *message, NSError *error) { XCTFail(@"%@", code); }];
  XCTAssertTrue(host.busy); PHPickerViewController *picker = (PHPickerViewController *)presenter.captured;
  XCTAssertTrue([picker isKindOfClass:PHPickerViewController.class]); XCTAssertEqual(picker.configuration.selectionLimit, 1);
  __block BOOL busyRejected = NO;
  [host presentFrom:presenter directory:self.assistant resolve:^(id value) { XCTFail(@"second picker started"); }
      reject:^(NSString *code, NSString *message, NSError *error) { busyRejected = YES; XCTAssertEqualObjects(code, @"E_ASSISTANT_AVATAR_BUSY"); }];
  XCTAssertTrue(busyRejected);
  [picker.delegate picker:picker didFinishPicking:@[]]; [picker.delegate picker:picker didFinishPicking:@[]];
  [self waitForExpectations:@[done] timeout:3]; XCTAssertEqual(completed, 1U); XCTAssertFalse(host.busy);
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.assistant URLByAppendingPathComponent:@"avatars"].path]);
}
@end
