#import "LocalAttachmentStore.h"

#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <PhotosUI/PhotosUI.h>
#import <QuickLook/QuickLook.h>
#import <RishNative/RishNativeModule.h>
#import <RishNative/RishUIKit.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

static NSUInteger const LAMaxAttachmentCount = 6;
static uint64_t const LAMaxImageBytes = 8ULL * 1024 * 1024;
static uint64_t const LAMaxPDFBytes = 8ULL * 1024 * 1024;
static uint64_t const LAMaxTextBytes = 1ULL * 1024 * 1024;
static uint64_t const LAMaxTotalBytes = 24ULL * 1024 * 1024;
static uint64_t const LAMaxImageInputBytes = 32ULL * 1024 * 1024;
static uint64_t const LAMaxThumbnailBytes = 512ULL * 1024;
static uint64_t const LAMaxDecodedPixels = 80ULL * 1000 * 1000;
static NSTimeInterval const LAOrphanGracePeriod = 24.0 * 60.0 * 60.0;
static uint64_t const LAMaxStoreBytes = 256ULL * 1024 * 1024;
static NSUInteger const LAMaxStoreItems = 1000;

typedef NS_ENUM(NSInteger, LAPickerSource) {
  LAPickerSourceNone = 0,
  LAPickerSourceCamera = 1,
  LAPickerSourcePhotos = 2,
  LAPickerSourceFiles = 3,
  LAPickerSourcePreview = 4,
};

static NSError *LAError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:@"LocalAttachments"
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSRecursiveLock *LAStoreLock(void) {
  static NSRecursiveLock *lock;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    lock = [[NSRecursiveLock alloc] init];
    lock.name = @"dev.zseven.rish.attachment-store";
  });
  return lock;
}

static NSString *LAString(id value) {
  return [value isKindOfClass:NSString.class] ? value : nil;
}

static BOOL LAHasControlCharacter(NSString *value) {
  return [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location
    != NSNotFound;
}

static BOOL LAIsReservedName(NSString *name) {
  return [name caseInsensitiveCompare:@".git"] == NSOrderedSame
    || [name caseInsensitiveCompare:@".gitmodules"] == NSOrderedSame
    || [name caseInsensitiveCompare:@".trash"] == NSOrderedSame
    || [name caseInsensitiveCompare:@"manifest.json"] == NSOrderedSame
    || [name caseInsensitiveCompare:@"payload"] == NSOrderedSame
    || [name caseInsensitiveCompare:@"thumbnail.jpg"] == NSOrderedSame;
}

static BOOL LAValidDisplayName(NSString *name) {
  if (name == nil || name.length == 0 || [name isEqualToString:@"."]
    || [name isEqualToString:@".."] || [name containsString:@"/"]
    || [name containsString:@"\\"] || LAHasControlCharacter(name)
    || LAIsReservedName(name)) return NO;
  NSUInteger bytes = [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  return bytes > 0 && bytes <= NAME_MAX;
}

static NSString *LACanonicalAttachmentID(id value) {
  NSString *candidate = LAString(value);
  if (candidate.length != 36 || ![candidate isEqualToString:candidate.lowercaseString]) {
    return nil;
  }
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:candidate];
  NSString *canonical = uuid.UUIDString.lowercaseString;
  return [canonical isEqualToString:candidate] ? canonical : nil;
}

static BOOL LAValidBatchName(NSString *value) {
  if (![value hasPrefix:@"batch-"]) return NO;
  return LACanonicalAttachmentID([value substringFromIndex:6]) != nil;
}

static NSString *LASHA256(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index += 1) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return hex;
}

static BOOL LAEnsurePrivateDirectory(NSURL *url, BOOL create, NSError **error) {
  struct stat metadata = {};
  if (lstat(url.fileSystemRepresentation, &metadata) != 0) {
    if (!create || errno != ENOENT || mkdir(url.fileSystemRepresentation, 0700) != 0) {
      if (error != nil) *error = LAError(5001, @"The attachment store is unavailable");
      return NO;
    }
  } else if (!S_ISDIR(metadata.st_mode) || S_ISLNK(metadata.st_mode)) {
    if (error != nil) *error = LAError(5002, @"The attachment store is unsafe");
    return NO;
  }
  NSError *attributeError = nil;
  BOOL protectionApplied = chmod(url.fileSystemRepresentation, 0700) == 0
    && [[NSFileManager defaultManager] setAttributes:@{
    NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
  } ofItemAtPath:url.path error:&attributeError]
    && [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&attributeError];
  if (!protectionApplied) {
    if (error != nil) *error = attributeError
      ?: LAError(5002, @"The attachment store cannot be protected");
    return NO;
  }
  return YES;
}

static BOOL LAProtectItem(NSURL *url, mode_t mode, NSError **error) {
  if (chmod(url.fileSystemRepresentation, mode) != 0) {
    if (error != nil) *error = LAError(5009, @"Attachment permissions cannot be applied");
    return NO;
  }
  return [[NSFileManager defaultManager] setAttributes:@{
    NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
  } ofItemAtPath:url.path error:error];
}

static BOOL LAStoreUsage(NSURL *root, NSUInteger *itemCount,
                         uint64_t *byteCount, NSError **error) {
  NSArray<NSURL *> *children = [[NSFileManager defaultManager]
    contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:error];
  if (children == nil) return NO;
  NSUInteger count = 0;
  uint64_t bytes = 0;
  for (NSURL *child in children) {
    if (LACanonicalAttachmentID(child.lastPathComponent) == nil) continue;
    struct stat directoryMetadata = {};
    if (lstat(child.fileSystemRepresentation, &directoryMetadata) != 0
      || !S_ISDIR(directoryMetadata.st_mode) || S_ISLNK(directoryMetadata.st_mode)) continue;
    for (NSString *fileName in @[@"payload", @"manifest.json", @"thumbnail.jpg"]) {
      NSURL *file = [child URLByAppendingPathComponent:fileName];
      struct stat metadata = {};
      if (lstat(file.fileSystemRepresentation, &metadata) != 0) {
        if (errno == ENOENT && [fileName isEqualToString:@"thumbnail.jpg"]) continue;
        if (error != nil) *error = LAError(5006, @"Attachment storage is invalid");
        return NO;
      }
      if (!S_ISREG(metadata.st_mode) || S_ISLNK(metadata.st_mode)
        || metadata.st_size < 0 || (uint64_t)metadata.st_size > LAMaxStoreBytes - bytes) {
        if (error != nil) *error = LAError(5006, @"Attachment storage is invalid");
        return NO;
      }
      bytes += (uint64_t)metadata.st_size;
    }
    count += 1;
  }
  if (itemCount != nil) *itemCount = count;
  if (byteCount != nil) *byteCount = bytes;
  return YES;
}

static NSURL *LAApplicationSupportURL(BOOL create, NSError **error) {
  NSURL *support = [[NSFileManager defaultManager]
    URLForDirectory:NSApplicationSupportDirectory
           inDomain:NSUserDomainMask
  appropriateForURL:nil
             create:create
              error:error];
  if (support == nil) return nil;
  struct stat metadata = {};
  if (lstat(support.fileSystemRepresentation, &metadata) != 0
    || !S_ISDIR(metadata.st_mode) || S_ISLNK(metadata.st_mode)) {
    if (error != nil) *error = LAError(5003, @"Application Support is unavailable");
    return nil;
  }
  chmod(support.fileSystemRepresentation, 0700);
  [[NSFileManager defaultManager] setAttributes:@{
    NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
  } ofItemAtPath:support.path error:nil];
  return support;
}

static NSURL *LAAttachmentsRoot(BOOL create, NSError **error) {
  NSURL *support = LAApplicationSupportURL(create, error);
  if (support == nil) return nil;
  NSURL *root = [support URLByAppendingPathComponent:@"attachments" isDirectory:YES];
  return LAEnsurePrivateDirectory(root, create, error) ? root : nil;
}

static NSURL *LAAttachmentStagingRoot(NSError **error) {
  NSURL *support = LAApplicationSupportURL(YES, error);
  if (support == nil) return nil;
  NSURL *root = [support URLByAppendingPathComponent:@"attachment-staging" isDirectory:YES];
  return LAEnsurePrivateDirectory(root, YES, error) ? root : nil;
}

static void LACleanupStaleStagingBatches(void) {
  NSRecursiveLock *storeLock = LAStoreLock();
  [storeLock lock];
  @try {
    NSError *error = nil;
    NSURL *stagingRoot = LAAttachmentStagingRoot(&error);
    NSArray<NSURL *> *children = stagingRoot == nil ? nil
      : [[NSFileManager defaultManager] contentsOfDirectoryAtURL:stagingRoot
          includingPropertiesForKeys:nil options:0 error:&error];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (NSURL *child in children) {
      if (!LAValidBatchName(child.lastPathComponent)) continue;
      struct stat metadata = {};
      if (lstat(child.fileSystemRepresentation, &metadata) != 0
        || !S_ISDIR(metadata.st_mode) || S_ISLNK(metadata.st_mode)) continue;
      NSTimeInterval modified = (NSTimeInterval)metadata.st_mtimespec.tv_sec
        + ((NSTimeInterval)metadata.st_mtimespec.tv_nsec / 1000000000.0);
      if (now - modified <= LAOrphanGracePeriod) continue;
      [[NSFileManager defaultManager] removeItemAtURL:child error:nil];
    }
  } @finally {
    [storeLock unlock];
  }
}

static void LACleanupStalePreviewDirectories(void) {
  NSError *error = nil;
  NSURL *temporary = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
  NSURL *staging = [temporary URLByAppendingPathComponent:@"rish-attachment-preview"
                                               isDirectory:YES];
  if (!LAEnsurePrivateDirectory(staging, YES, &error)) return;
  NSArray<NSURL *> *children = [[NSFileManager defaultManager]
    contentsOfDirectoryAtURL:staging includingPropertiesForKeys:nil options:0 error:&error];
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  for (NSURL *child in children) {
    if (LACanonicalAttachmentID(child.lastPathComponent) == nil) continue;
    struct stat metadata = {};
    if (lstat(child.fileSystemRepresentation, &metadata) != 0
      || !S_ISDIR(metadata.st_mode) || S_ISLNK(metadata.st_mode)) continue;
    NSTimeInterval modified = (NSTimeInterval)metadata.st_mtimespec.tv_sec
      + ((NSTimeInterval)metadata.st_mtimespec.tv_nsec / 1000000000.0);
    if (now - modified <= 60.0 * 60.0) continue;
    [[NSFileManager defaultManager] removeItemAtURL:child error:nil];
  }
}

static BOOL LAValidManifestString(NSDictionary *manifest, NSString *key) {
  return [manifest[key] isKindOfClass:NSString.class]
    && ((NSString *)manifest[key]).length > 0;
}

static BOOL LAUnsignedIntegerNumber(id value) {
  if (![value isKindOfClass:NSNumber.class]
    || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
  double numeric = [value doubleValue];
  return isfinite(numeric) && numeric >= 0.0 && floor(numeric) == numeric;
}

static BOOL LAValidSHA256(NSString *value) {
  if (value.length != CC_SHA256_DIGEST_LENGTH * 2) return NO;
  NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
    @"0123456789abcdef"] invertedSet];
  return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static NSDictionary<NSString *, id> *LALoadManifestInternal(
    NSString *attachmentID, NSURL **payloadURL, NSData **payloadSnapshot,
    NSError **error) {
  NSString *canonicalID = LACanonicalAttachmentID(attachmentID);
  if (canonicalID == nil) {
    if (error != nil) *error = LAError(5004, @"Attachment identifier is invalid");
    return nil;
  }
  NSURL *root = LAAttachmentsRoot(NO, error);
  if (root == nil) return nil;
  NSURL *directory = [root URLByAppendingPathComponent:canonicalID isDirectory:YES];
  struct stat directoryMetadata = {};
  if (lstat(directory.fileSystemRepresentation, &directoryMetadata) != 0
    || !S_ISDIR(directoryMetadata.st_mode) || S_ISLNK(directoryMetadata.st_mode)) {
    if (error != nil) *error = LAError(5005, @"Attachment is unavailable");
    return nil;
  }
  NSURL *manifestURL = [directory URLByAppendingPathComponent:@"manifest.json"];
  NSURL *payload = [directory URLByAppendingPathComponent:@"payload"];
  struct stat manifestMetadata = {};
  struct stat payloadMetadata = {};
  if (lstat(manifestURL.fileSystemRepresentation, &manifestMetadata) != 0
    || !S_ISREG(manifestMetadata.st_mode) || S_ISLNK(manifestMetadata.st_mode)
    || manifestMetadata.st_size <= 0 || manifestMetadata.st_size > 64 * 1024
    || lstat(payload.fileSystemRepresentation, &payloadMetadata) != 0
    || !S_ISREG(payloadMetadata.st_mode) || S_ISLNK(payloadMetadata.st_mode)) {
    if (error != nil) *error = LAError(5006, @"Attachment storage is invalid");
    return nil;
  }
  NSData *manifestData = [NSData dataWithContentsOfURL:manifestURL
                                               options:NSDataReadingMappedIfSafe
                                                 error:error];
  id decoded = manifestData == nil ? nil
    : [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:error];
  NSDictionary *manifest = [decoded isKindOfClass:NSDictionary.class] ? decoded : nil;
  NSString *manifestID = LAString(manifest[@"id"]);
  NSString *kind = LAString(manifest[@"kind"]);
  NSString *name = LAString(manifest[@"name"]);
  NSString *mimeType = LAString(manifest[@"mime_type"]);
  NSString *sha256 = LAString(manifest[@"sha256"]);
  NSNumber *size = LAUnsignedIntegerNumber(manifest[@"size"])
    ? manifest[@"size"] : nil;
  NSNumber *schemaVersion = LAUnsignedIntegerNumber(manifest[@"schema_version"])
    ? manifest[@"schema_version"] : nil;
  BOOL validKind = [kind isEqualToString:@"image"] || [kind isEqualToString:@"text"]
    || [kind isEqualToString:@"pdf"];
  BOOL validMime = ([kind isEqualToString:@"image"]
      && ([mimeType isEqualToString:@"image/jpeg"] || [mimeType isEqualToString:@"image/png"]))
    || ([kind isEqualToString:@"text"] && [mimeType hasPrefix:@"text/"])
    || ([kind isEqualToString:@"pdf"] && [mimeType isEqualToString:@"application/pdf"]);
  uint64_t limit = [kind isEqualToString:@"text"] ? LAMaxTextBytes
    : ([kind isEqualToString:@"pdf"] ? LAMaxPDFBytes : LAMaxImageBytes);
  NSISO8601DateFormatter *dateFormatter = [[NSISO8601DateFormatter alloc] init];
  dateFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime
    | NSISO8601DateFormatWithFractionalSeconds;
  BOOL valid = schemaVersion.unsignedIntegerValue == 1
    && [manifestID isEqualToString:canonicalID]
    && validKind && LAValidDisplayName(name) && validMime
    && size.unsignedLongLongValue > 0
    && size.unsignedLongLongValue <= limit
    && size.unsignedLongLongValue == (uint64_t)payloadMetadata.st_size
    && LAValidSHA256(sha256)
    && LAValidManifestString(manifest, @"created_at")
    && [dateFormatter dateFromString:manifest[@"created_at"]] != nil;
  if (!valid) {
    if (error != nil) *error = LAError(5007, @"Attachment manifest is invalid");
    return nil;
  }
  NSData *payloadData = [NSData dataWithContentsOfURL:payload
                                              options:NSDataReadingMappedIfSafe
                                                error:error];
  if (payloadData == nil || ![LASHA256(payloadData) isEqualToString:sha256]) {
    if (error != nil && *error == nil) {
      *error = LAError(5008, @"Attachment integrity check failed");
    }
    return nil;
  }
  NSURL *thumbnailURL = [directory URLByAppendingPathComponent:@"thumbnail.jpg"];
  struct stat thumbnailMetadata = {};
  BOOL hasThumbnail = lstat(thumbnailURL.fileSystemRepresentation, &thumbnailMetadata) == 0;
  if (hasThumbnail) {
    NSNumber *thumbnailSize = LAUnsignedIntegerNumber(manifest[@"thumbnail_size"])
      ? manifest[@"thumbnail_size"] : nil;
    NSString *thumbnailSHA256 = LAString(manifest[@"thumbnail_sha256"]);
    if (![kind isEqualToString:@"image"] || !S_ISREG(thumbnailMetadata.st_mode)
      || S_ISLNK(thumbnailMetadata.st_mode) || thumbnailMetadata.st_size <= 0
      || thumbnailMetadata.st_size > LAMaxThumbnailBytes
      || thumbnailSize.unsignedLongLongValue != (uint64_t)thumbnailMetadata.st_size
      || !LAValidSHA256(thumbnailSHA256)) {
      if (error != nil) *error = LAError(5007, @"Attachment thumbnail manifest is invalid");
      return nil;
    }
    NSData *thumbnailData = [NSData dataWithContentsOfURL:thumbnailURL
                                                  options:NSDataReadingMappedIfSafe
                                                    error:error];
    if (thumbnailData == nil || ![LASHA256(thumbnailData) isEqualToString:thumbnailSHA256]) {
      if (error != nil && *error == nil) {
        *error = LAError(5008, @"Attachment thumbnail integrity check failed");
      }
      return nil;
    }
  } else if (errno != ENOENT
    || manifest[@"thumbnail_size"] != nil || manifest[@"thumbnail_sha256"] != nil) {
    if (error != nil) *error = LAError(5007, @"Attachment thumbnail storage is invalid");
    return nil;
  }
  if (payloadURL != nil) *payloadURL = payload;
  if (payloadSnapshot != nil) *payloadSnapshot = payloadData;
  return manifest;
}

NSData *RishLocalAttachmentReadPayload(
    NSString *attachmentID,
    NSDictionary<NSString *, id> **manifest,
    NSError **error) {
  NSRecursiveLock *lock = LAStoreLock();
  [lock lock];
  @try {
    NSData *payload = nil;
    NSDictionary *loaded = LALoadManifestInternal(
      attachmentID, nil, &payload, error);
    if (loaded == nil) return nil;
    if (manifest != nil) *manifest = loaded;
    return payload;
  } @finally {
    [lock unlock];
  }
}

NSURL *RishLocalAttachmentResolvePayload(
    NSString *attachmentID,
    NSDictionary<NSString *, id> **manifest,
    NSError **error) {
  NSRecursiveLock *lock = LAStoreLock();
  [lock lock];
  @try {
    NSURL *payload = nil;
    NSDictionary *loaded = LALoadManifestInternal(
      attachmentID, &payload, nil, error);
    if (loaded == nil) return nil;
    if (manifest != nil) *manifest = loaded;
    return payload;
  } @finally {
    [lock unlock];
  }
}

NSDictionary<NSString *, id> *RishLocalAttachmentLoadManifest(
    NSString *attachmentID,
    NSError **error) {
  NSRecursiveLock *lock = LAStoreLock();
  [lock lock];
  @try {
    return LALoadManifestInternal(attachmentID, nil, nil, error);
  } @finally {
    [lock unlock];
  }
}

static BOOL LAImageHasAlpha(UIImage *image) {
  CGImageRef cgImage = image.CGImage;
  if (cgImage == nil) return NO;
  CGImageAlphaInfo info = CGImageGetAlphaInfo(cgImage);
  return info == kCGImageAlphaPremultipliedLast
    || info == kCGImageAlphaPremultipliedFirst
    || info == kCGImageAlphaLast
    || info == kCGImageAlphaFirst;
}

static UIImage *LARenderImage(UIImage *image, CGFloat maximumDimension, BOOL opaque) {
  CGFloat pixelWidth = image.size.width * image.scale;
  CGFloat pixelHeight = image.size.height * image.scale;
  if (pixelWidth <= 0 || pixelHeight <= 0) return nil;
  CGFloat scale = MIN(1.0, maximumDimension / MAX(pixelWidth, pixelHeight));
  CGSize target = CGSizeMake(MAX(1.0, floor(pixelWidth * scale)),
                             MAX(1.0, floor(pixelHeight * scale)));
  UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
  format.scale = 1.0;
  format.opaque = opaque;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
    initWithSize:target format:format];
  return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    (void)context;
    [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
  }];
}

static NSString *LASafeImageName(NSString *suggested, NSString *extension) {
  NSString *base = [suggested stringByDeletingPathExtension];
  base = [base stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!LAValidDisplayName(base)) {
    base = [NSString stringWithFormat:@"Image-%@",
      [NSUUID.UUID.UUIDString.lowercaseString substringToIndex:8]];
  }
  NSString *name = [base stringByAppendingPathExtension:extension];
  return LAValidDisplayName(name) ? name
    : [NSString stringWithFormat:@"Image.%@", extension];
}

static NSDictionary *LANormalizedImage(UIImage *input, NSString *suggested,
                                        NSError **error) {
  CGImageRef cgImage = input.CGImage;
  uint64_t width = cgImage == nil ? 0 : CGImageGetWidth(cgImage);
  uint64_t height = cgImage == nil ? 0 : CGImageGetHeight(cgImage);
  if (width == 0 || height == 0 || width > 16384 || height > 16384
    || height > LAMaxDecodedPixels / width) {
    if (error != nil) *error = LAError(5010, @"The selected image is too large to decode safely");
    return nil;
  }
  BOOL alpha = LAImageHasAlpha(input);
  CGFloat dimension = 3072.0;
  UIImage *normalized = nil;
  NSData *payload = nil;
  for (NSUInteger resizeAttempt = 0; resizeAttempt < 7; resizeAttempt += 1) {
    normalized = LARenderImage(input, dimension, !alpha);
    if (normalized == nil) break;
    if (alpha) {
      payload = UIImagePNGRepresentation(normalized);
    } else {
      for (CGFloat quality = 0.92; quality >= 0.52; quality -= 0.08) {
        payload = UIImageJPEGRepresentation(normalized, quality);
        if (payload.length <= LAMaxImageBytes) break;
      }
    }
    if (payload.length > 0 && payload.length <= LAMaxImageBytes) break;
    dimension *= 0.78;
    payload = nil;
  }
  if (normalized == nil || payload.length == 0 || payload.length > LAMaxImageBytes) {
    if (error != nil) *error = LAError(5011, @"The image cannot be normalized within the 8 MB limit");
    return nil;
  }
  UIImage *thumbnailImage = LARenderImage(normalized, 320.0, YES);
  NSData *thumbnail = UIImageJPEGRepresentation(thumbnailImage, 0.72);
  if (thumbnail.length == 0 || thumbnail.length > LAMaxThumbnailBytes) thumbnail = nil;
  NSString *extension = alpha ? @"png" : @"jpg";
  return @{
    @"data": payload,
    @"kind": @"image",
    @"name": LASafeImageName(suggested, extension),
    @"mime_type": alpha ? @"image/png" : @"image/jpeg",
    @"thumbnail": thumbnail ?: NSNull.null,
  };
}

static NSDictionary *LANormalizedImageData(NSData *data, NSString *suggested,
                                            NSError **error) {
  if (data.length == 0 || data.length > LAMaxImageInputBytes) {
    if (error != nil) *error = LAError(5012, @"The selected image exceeds the input limit");
    return nil;
  }
  CGImageSourceRef source = CGImageSourceCreateWithData(
    (__bridge CFDataRef)data, nil);
  if (source == nil || CGImageSourceGetCount(source) == 0) {
    if (source != nil) CFRelease(source);
    if (error != nil) *error = LAError(5013, @"The selected file is not a valid image");
    return nil;
  }
  NSDictionary *properties = CFBridgingRelease(
    CGImageSourceCopyPropertiesAtIndex(source, 0, nil));
  uint64_t width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth]
    unsignedLongLongValue];
  uint64_t height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight]
    unsignedLongLongValue];
  if (width == 0 || height == 0 || width > 40000 || height > 40000
    || height > LAMaxDecodedPixels / width) {
    CFRelease(source);
    if (error != nil) *error = LAError(5010, @"The selected image is too large to decode safely");
    return nil;
  }
  NSDictionary *options = @{
    (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
    (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
    (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
    (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @3072,
  };
  CGImageRef downsampled = CGImageSourceCreateThumbnailAtIndex(
    source, 0, (__bridge CFDictionaryRef)options);
  CFRelease(source);
  if (downsampled == nil) {
    if (error != nil) *error = LAError(5013, @"The selected file is not a valid image");
    return nil;
  }
  UIImage *image = [UIImage imageWithCGImage:downsampled scale:1.0
                                  orientation:UIImageOrientationUp];
  CGImageRelease(downsampled);
  return LANormalizedImage(image, suggested, error);
}

static NSString *LADataURL(NSData *data) {
  if (data.length == 0 || data.length > LAMaxThumbnailBytes) return nil;
  return [NSString stringWithFormat:@"data:image/jpeg;base64,%@",
    [data base64EncodedStringWithOptions:0]];
}

@interface LocalAttachmentsModule : NSObject
  <RishNativeModule, PHPickerViewControllerDelegate, UIDocumentPickerDelegate,
   UIImagePickerControllerDelegate, UINavigationControllerDelegate,
   UIAdaptivePresentationControllerDelegate, QLPreviewControllerDataSource,
   QLPreviewControllerDelegate>
@property(nonatomic, strong) dispatch_queue_t attachmentQueue;
@property(nonatomic, copy) RishResolveBlock pendingResolve;
@property(nonatomic, copy) RishRejectBlock pendingReject;
@property(nonatomic) LAPickerSource pendingSource;
@property(nonatomic, strong) UIViewController *pendingController;
@property(nonatomic) BOOL pendingSelectionStarted;
@property(nonatomic, strong) NSURL *pendingPreviewURL;
@property(nonatomic, strong) NSURL *pendingPreviewRoot;
@end

@implementation LocalAttachmentsModule

RISH_NATIVE_MODULE(LocalAttachments)

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _attachmentQueue = dispatch_queue_create(
      "dev.zseven.rish.local-attachments", DISPATCH_QUEUE_SERIAL);
    _pendingSource = LAPickerSourceNone;
    dispatch_async(_attachmentQueue, ^{
      LACleanupStaleStagingBatches();
      LACleanupStalePreviewDirectories();
    });
  }
  return self;
}

- (BOOL)beginSource:(LAPickerSource)source
            resolve:(RishResolveBlock)resolve
             reject:(RishRejectBlock)reject {
  NSAssert(NSThread.isMainThread, @"attachment picker state must stay on main");
  if (self.pendingSource != LAPickerSourceNone) {
    reject(@"busy", @"Another attachment picker is already active", nil);
    return NO;
  }
  UIViewController *presenter = RishPresentedViewController();
  if (presenter == nil || [presenter isKindOfClass:UIAlertController.class]) {
    reject(@"presentation", @"The attachment picker cannot be presented right now", nil);
    return NO;
  }
  self.pendingSource = source;
  self.pendingResolve = resolve;
  self.pendingReject = reject;
  self.pendingSelectionStarted = NO;
  return YES;
}

- (void)presentPicker:(UIViewController *)picker
         fromPresenter:(UIViewController *)presenter {
  NSAssert(NSThread.isMainThread, @"picker presentation must stay on main");
  self.pendingController = picker;
  [presenter presentViewController:picker animated:YES completion:nil];
  picker.presentationController.delegate = self;
}

- (BOOL)isCurrentController:(UIViewController *)controller
                       source:(LAPickerSource)source {
  return self.pendingController == controller && self.pendingSource == source;
}

- (void)finishResult:(NSDictionary *)result error:(NSError *)error code:(NSString *)code {
  dispatch_async(dispatch_get_main_queue(), ^{
    RishResolveBlock resolve = self.pendingResolve;
    RishRejectBlock reject = self.pendingReject;
    NSURL *previewRoot = self.pendingPreviewRoot;
    NSError *finalError = error;
    if (previewRoot != nil) {
      NSError *cleanupError = nil;
      if (![[NSFileManager defaultManager] removeItemAtURL:previewRoot error:&cleanupError]
        && cleanupError.code != NSFileNoSuchFileError && finalError == nil) {
        finalError = LAError(5041, @"The private preview copy could not be removed");
      }
    }
    self.pendingResolve = nil;
    self.pendingReject = nil;
    self.pendingSource = LAPickerSourceNone;
    self.pendingController = nil;
    self.pendingSelectionStarted = NO;
    self.pendingPreviewURL = nil;
    self.pendingPreviewRoot = nil;
    if (finalError != nil) {
      if (reject != nil) reject(code ?: @"attachments", finalError.localizedDescription, finalError);
    } else if (resolve != nil) {
      resolve(result);
    }
  });
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
  if (presentationController.presentedViewController == self.pendingController
    && !self.pendingSelectionStarted) {
    if (self.pendingSource == LAPickerSourcePreview) {
      [self finishPreviewClosed];
    } else {
      [self finishCancelled];
    }
  }
}

- (void)invalidate {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.pendingSource == LAPickerSourceNone) return;
    NSError *error = LAError(5040, @"Attachment picker was interrupted by an app reload");
    if (self.pendingSource == LAPickerSourcePreview) {
      [self.pendingController dismissViewControllerAnimated:NO completion:^{
        [self finishResult:nil error:error code:@"interrupted"];
      }];
    } else {
      [self.pendingController dismissViewControllerAnimated:NO completion:nil];
      [self finishResult:nil error:error code:@"interrupted"];
    }
  });
}

- (void)finishPreviewClosed {
  [self finishResult:@{
    @"schema_version": @1,
    @"status": @"closed",
  } error:nil code:nil];
}

- (void)closePreview {
  if (self.pendingSource != LAPickerSourcePreview) return;
  UIViewController *controller = self.pendingController;
  [controller dismissViewControllerAnimated:YES completion:^{
    [self finishPreviewClosed];
  }];
}

- (NSDictionary<NSString *, NSURL *> *)preparePreviewForIdentifier:(id)identifierValue
                                                              error:(NSError **)error {
  NSString *identifier = LACanonicalAttachmentID(identifierValue);
  if (identifier == nil) {
    if (error != nil) *error = LAError(5042, @"Attachment identifier is invalid");
    return nil;
  }
  NSDictionary *manifest = nil;
  NSData *payload = RishLocalAttachmentReadPayload(identifier, &manifest, error);
  NSString *name = LAString(manifest[@"name"]);
  if (payload == nil || !LAValidDisplayName(name)) {
    if (error != nil && *error == nil) {
      *error = LAError(5043, @"Attachment preview data is invalid");
    }
    return nil;
  }
  NSURL *temporary = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
  NSURL *staging = [temporary URLByAppendingPathComponent:@"rish-attachment-preview"
                                               isDirectory:YES];
  if (!LAEnsurePrivateDirectory(staging, YES, error)) return nil;
  NSURL *root = [staging URLByAppendingPathComponent:NSUUID.UUID.UUIDString.lowercaseString
                                         isDirectory:YES];
  if (mkdir(root.fileSystemRepresentation, 0700) != 0
    || !LAProtectItem(root, 0700, error)) {
    if (error != nil && *error == nil) {
      *error = LAError(5044, @"A private preview directory could not be created");
    }
    [[NSFileManager defaultManager] removeItemAtURL:root error:nil];
    return nil;
  }
  NSURL *file = [root URLByAppendingPathComponent:name isDirectory:NO];
  if (![self writeData:payload toURL:file error:error]) {
    [[NSFileManager defaultManager] removeItemAtURL:root error:nil];
    return nil;
  }
  int rootDescriptor = open(root.fileSystemRepresentation,
    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (rootDescriptor < 0 || fsync(rootDescriptor) != 0) {
    if (rootDescriptor >= 0) close(rootDescriptor);
    if (error != nil) *error = LAError(5045, @"The private preview copy could not be committed");
    [[NSFileManager defaultManager] removeItemAtURL:root error:nil];
    return nil;
  }
  close(rootDescriptor);
  return @{@"root": root, @"file": file};
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
  (void)controller;
  return self.pendingSource == LAPickerSourcePreview && self.pendingPreviewURL != nil ? 1 : 0;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller
                    previewItemAtIndex:(NSInteger)index {
  (void)controller;
  return index == 0 ? self.pendingPreviewURL : nil;
}

- (QLPreviewItemEditingMode)previewController:(QLPreviewController *)controller
                    editingModeForPreviewItem:(id<QLPreviewItem>)previewItem {
  (void)controller;
  (void)previewItem;
  return QLPreviewItemEditingModeDisabled;
}

- (BOOL)previewController:(QLPreviewController *)controller
            shouldOpenURL:(NSURL *)url
           forPreviewItem:(id<QLPreviewItem>)previewItem {
  (void)controller;
  (void)url;
  (void)previewItem;
  return NO;
}

- (void)finishCancelled {
  [self finishResult:@{
    @"schema_version": @1,
    @"status": @"cancelled",
    @"attachments": @[],
  } error:nil code:nil];
}

- (BOOL)writeData:(NSData *)data toURL:(NSURL *)url error:(NSError **)error {
  if (![data writeToURL:url options:NSDataWritingAtomic error:error]) return NO;
  if (!LAProtectItem(url, 0600, error)) return NO;
  int descriptor = open(url.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    if (error != nil) *error = LAError(5014, @"Attachment data could not be secured");
    return NO;
  }
  BOOL synced = fsync(descriptor) == 0;
  close(descriptor);
  if (!synced && error != nil) *error = LAError(5015, @"Attachment data could not be committed");
  return synced;
}

- (NSArray<NSDictionary *> *)persistNormalizedItems:(NSArray<NSDictionary *> *)items
                                               error:(NSError **)error {
  NSRecursiveLock *storeLock = LAStoreLock();
  [storeLock lock];
  @try {
  if (items.count == 0 || items.count > LAMaxAttachmentCount) {
    if (error != nil) *error = LAError(5016, @"Choose between 1 and 6 attachments");
    return nil;
  }
  uint64_t totalBytes = 0;
  uint64_t estimatedStoreBytes = 0;
  for (NSDictionary *item in items) {
    NSData *data = item[@"data"];
    if (![data isKindOfClass:NSData.class] || data.length > LAMaxTotalBytes - totalBytes) {
      if (error != nil) *error = LAError(5017, @"Attachments exceed the 24 MB total limit");
      return nil;
    }
    totalBytes += data.length;
    NSData *thumbnail = [item[@"thumbnail"] isKindOfClass:NSData.class]
      ? item[@"thumbnail"] : nil;
    estimatedStoreBytes += data.length + thumbnail.length + 4096;
  }
  NSURL *root = LAAttachmentsRoot(YES, error);
  NSURL *stagingRoot = LAAttachmentStagingRoot(error);
  if (root == nil || stagingRoot == nil) return nil;
  NSUInteger existingItems = 0;
  uint64_t existingBytes = 0;
  if (!LAStoreUsage(root, &existingItems, &existingBytes, error)) return nil;
  if (existingItems > LAMaxStoreItems - items.count
    || estimatedStoreBytes > LAMaxStoreBytes - existingBytes) {
    if (error != nil) *error = LAError(5017, @"The attachment store has reached its 256 MB limit");
    return nil;
  }
  NSString *batchName = [NSString stringWithFormat:@"batch-%@",
    NSUUID.UUID.UUIDString.lowercaseString];
  NSURL *batch = [stagingRoot URLByAppendingPathComponent:batchName isDirectory:YES];
  if (mkdir(batch.fileSystemRepresentation, 0700) != 0) {
    if (error != nil) *error = LAError(5018, @"Attachment staging could not be created");
    return nil;
  }
  if (!LAProtectItem(batch, 0700, error)) {
    [[NSFileManager defaultManager] removeItemAtURL:batch error:nil];
    return nil;
  }
  NSMutableArray<NSDictionary *> *descriptors = [NSMutableArray array];
  NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime
    | NSISO8601DateFormatWithFractionalSeconds;
  NSString *createdAt = [formatter stringFromDate:NSDate.date];
  BOOL prepared = YES;
  for (NSDictionary *item in items) {
    NSString *identifier = NSUUID.UUID.UUIDString.lowercaseString;
    NSURL *directory = [batch URLByAppendingPathComponent:identifier isDirectory:YES];
    if (mkdir(directory.fileSystemRepresentation, 0700) != 0) {
      if (error != nil) *error = LAError(5019, @"An attachment could not be staged");
      prepared = NO;
      break;
    }
    if (!LAProtectItem(directory, 0700, error)) {
      prepared = NO;
      break;
    }
    NSData *payload = item[@"data"];
    NSData *thumbnail = [item[@"thumbnail"] isKindOfClass:NSData.class]
      ? item[@"thumbnail"] : nil;
    NSURL *payloadURL = [directory URLByAppendingPathComponent:@"payload"];
    NSURL *thumbnailURL = [directory URLByAppendingPathComponent:@"thumbnail.jpg"];
    NSURL *manifestURL = [directory URLByAppendingPathComponent:@"manifest.json"];
    NSMutableDictionary *manifest = [@{
      @"schema_version": @1,
      @"id": identifier,
      @"kind": item[@"kind"],
      @"name": item[@"name"],
      @"mime_type": item[@"mime_type"],
      @"size": @(payload.length),
      @"sha256": LASHA256(payload),
      @"created_at": createdAt,
    } mutableCopy];
    if (thumbnail != nil) {
      manifest[@"thumbnail_size"] = @(thumbnail.length);
      manifest[@"thumbnail_sha256"] = LASHA256(thumbnail);
    }
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest
      options:NSJSONWritingSortedKeys error:error];
    if (manifestData == nil
      || ![self writeData:payload toURL:payloadURL error:error]
      || (thumbnail != nil
        && ![self writeData:thumbnail toURL:thumbnailURL error:error])
      || ![self writeData:manifestData toURL:manifestURL error:error]) {
      prepared = NO;
      break;
    }
    int directoryDescriptor = open(directory.fileSystemRepresentation,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (directoryDescriptor < 0 || fsync(directoryDescriptor) != 0) {
      if (directoryDescriptor >= 0) close(directoryDescriptor);
      if (error != nil) *error = LAError(5020, @"An attachment could not be committed");
      prepared = NO;
      break;
    }
    close(directoryDescriptor);
    NSMutableDictionary *descriptor = [@{
      @"schema_version": @1,
      @"id": identifier,
      @"kind": item[@"kind"],
      @"name": item[@"name"],
      @"mime_type": item[@"mime_type"],
      @"size": @(payload.length),
    } mutableCopy];
    NSString *thumbnailDataURL = LADataURL(thumbnail);
    if (thumbnailDataURL != nil) descriptor[@"thumbnail_data_url"] = thumbnailDataURL;
    [identifiers addObject:identifier];
    [descriptors addObject:descriptor];
  }
  NSMutableArray<NSString *> *published = [NSMutableArray array];
  if (prepared) {
    NSDictionary *transaction = @{
      @"schema_version": @1,
      @"created_at": createdAt,
      @"attachment_ids": identifiers,
      // Publication is atomic per attachment directory. A crash can leave a
      // partial batch; prune(referencedIds) reclaims those unreferenced UUIDs
      // after the 24-hour draft grace period.
      @"publication": @"per_item_atomic",
    };
    NSData *transactionData = [NSJSONSerialization dataWithJSONObject:transaction
      options:NSJSONWritingSortedKeys error:error];
    NSURL *transactionURL = [batch URLByAppendingPathComponent:@"transaction.json"];
    if (transactionData == nil
      || ![self writeData:transactionData toURL:transactionURL error:error]) {
      prepared = NO;
    }
  }
  int batchDescriptor = prepared ? open(batch.fileSystemRepresentation,
    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) : -1;
  int rootDescriptor = prepared ? open(root.fileSystemRepresentation,
    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) : -1;
  if (prepared && (batchDescriptor < 0 || rootDescriptor < 0)) {
    if (error != nil) *error = LAError(5021, @"The attachment store cannot publish items");
    prepared = NO;
  }
  if (prepared && fsync(batchDescriptor) != 0) {
    if (error != nil) *error = LAError(5020, @"Attachment transaction journal could not be committed");
    prepared = NO;
  }
  if (prepared) {
    for (NSString *identifier in identifiers) {
      if (renameatx_np(batchDescriptor, identifier.fileSystemRepresentation,
          rootDescriptor, identifier.fileSystemRepresentation, RENAME_EXCL) != 0) {
        if (error != nil) *error = LAError(5022, @"Attachments could not be published atomically");
        prepared = NO;
        break;
      }
      [published addObject:identifier];
    }
  }
  if (rootDescriptor >= 0) {
    if (prepared && fsync(rootDescriptor) != 0) {
      if (error != nil) *error = LAError(5022, @"Attachment publication could not be committed");
      prepared = NO;
    }
    close(rootDescriptor);
  }
  if (batchDescriptor >= 0) close(batchDescriptor);
  if (!prepared) {
    BOOL rollbackComplete = YES;
    for (NSString *identifier in published) {
      NSURL *publishedURL = [root URLByAppendingPathComponent:identifier isDirectory:YES];
      if (![[NSFileManager defaultManager] removeItemAtURL:publishedURL error:nil]) {
        rollbackComplete = NO;
      }
    }
    int rollbackRoot = open(root.fileSystemRepresentation,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (rollbackRoot < 0 || fsync(rollbackRoot) != 0 || !rollbackComplete) {
      if (error != nil) *error = LAError(5022,
        @"Attachment publication failed and left recoverable orphan data");
    }
    if (rollbackRoot >= 0) close(rollbackRoot);
    [descriptors removeAllObjects];
  }
  [[NSFileManager defaultManager] removeItemAtURL:batch error:nil];
  return prepared ? descriptors : nil;
  } @finally {
    [storeLock unlock];
  }
}

- (NSDictionary *)normalizedFileAtURL:(NSURL *)source error:(NSError **)error {
  NSString *name = source.lastPathComponent;
  if (!LAValidDisplayName(name)) {
    if (error != nil) *error = LAError(5023, @"The selected file name is reserved or unsafe");
    return nil;
  }
  NSNumber *symbolic = nil;
  NSNumber *regular = nil;
  NSNumber *size = nil;
  UTType *contentType = nil;
  BOOL read = [source getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:error]
    && [source getResourceValue:&regular forKey:NSURLIsRegularFileKey error:error]
    && [source getResourceValue:&size forKey:NSURLFileSizeKey error:error]
    && [source getResourceValue:&contentType forKey:NSURLContentTypeKey error:error];
  if (!read || symbolic.boolValue || !regular.boolValue || contentType == nil) {
    if (error != nil && *error == nil) *error = LAError(5024, @"The selected item is not a regular file");
    return nil;
  }
  BOOL image = [contentType conformsToType:UTTypeImage];
  BOOL pdf = [contentType conformsToType:UTTypePDF];
  BOOL text = [contentType conformsToType:UTTypeText];
  uint64_t inputLimit = image ? LAMaxImageInputBytes
    : (pdf ? LAMaxPDFBytes : (text ? LAMaxTextBytes : 0));
  if (inputLimit == 0 || size.unsignedLongLongValue == 0
    || size.unsignedLongLongValue > inputLimit) {
    if (error != nil) *error = LAError(5025, @"Only images, text files, and PDFs within their size limits are supported");
    return nil;
  }
  NSData *data = [NSData dataWithContentsOfURL:source
                                       options:NSDataReadingMappedIfSafe
                                         error:error];
  if (data == nil || data.length != size.unsignedLongLongValue) return nil;
  if (image) return LANormalizedImageData(data, name, error);
  if (pdf) {
    const unsigned char *bytes = static_cast<const unsigned char *>(data.bytes);
    if (data.length < 5 || memcmp(bytes, "%PDF-", 5) != 0) {
      if (error != nil) *error = LAError(5026, @"The selected PDF has an invalid signature");
      return nil;
    }
    return @{
      @"data": data,
      @"kind": @"pdf",
      @"name": name,
      @"mime_type": @"application/pdf",
      @"thumbnail": NSNull.null,
    };
  }
  if ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] == nil
    || [data rangeOfData:[NSData dataWithBytes:"\0" length:1]
                 options:0 range:NSMakeRange(0, data.length)].location != NSNotFound) {
    if (error != nil) *error = LAError(5027, @"Text attachments must contain valid UTF-8 text");
    return nil;
  }
  NSString *mimeType = contentType.preferredMIMEType;
  if (![mimeType hasPrefix:@"text/"]) mimeType = @"text/plain";
  return @{
    @"data": data,
    @"kind": @"text",
    @"name": name,
    @"mime_type": mimeType,
    @"thumbnail": NSNull.null,
  };
}

- (void)processNormalizedCandidates:(NSArray<NSDictionary *> *)candidates {
  dispatch_async(self.attachmentQueue, ^{
    if (candidates.count == 0 || candidates.count > LAMaxAttachmentCount) {
      [self finishResult:nil error:LAError(5028, @"Choose no more than 6 attachments")
                    code:@"limit"];
      return;
    }
    NSError *error = nil;
    NSMutableArray<NSDictionary *> *normalized = [NSMutableArray array];
    for (NSDictionary *candidate in candidates) {
      NSDictionary *item = nil;
      if ([candidate[@"image"] isKindOfClass:UIImage.class]) {
        item = LANormalizedImage(candidate[@"image"], candidate[@"name"], &error);
      } else if ([candidate[@"image_data"] isKindOfClass:NSData.class]) {
        item = LANormalizedImageData(candidate[@"image_data"], candidate[@"name"], &error);
      } else if ([candidate[@"file_url"] isKindOfClass:NSURL.class]) {
        NSURL *source = candidate[@"file_url"];
        BOOL scoped = [source startAccessingSecurityScopedResource];
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        __block NSDictionary *coordinatedItem = nil;
        __block NSError *coordinatedError = nil;
        [coordinator coordinateReadingItemAtURL:source
                                       options:NSFileCoordinatorReadingWithoutChanges
                                         error:&coordinatedError
                                    byAccessor:^(NSURL *coordinatedURL) {
          coordinatedItem = [self normalizedFileAtURL:coordinatedURL error:&coordinatedError];
        }];
        if (scoped) [source stopAccessingSecurityScopedResource];
        item = coordinatedItem;
        error = coordinatedError;
      }
      if (item == nil) {
        error = error ?: LAError(5029, @"An attachment could not be prepared");
        break;
      }
      [normalized addObject:item];
    }
    NSArray *descriptors = error == nil
      ? [self persistNormalizedItems:normalized error:&error] : nil;
    if (descriptors == nil) {
      [self finishResult:nil error:error ?: LAError(5030, @"Attachments could not be saved")
                    code:@"attachments"];
      return;
    }
    [self finishResult:@{
      @"schema_version": @1,
      @"status": @"selected",
      @"attachments": descriptors,
    } error:nil code:nil];
  });
}

- (void)finishWithNormalizedItems:(NSArray<NSDictionary *> *)normalized {
  NSError *error = nil;
  NSArray *descriptors = [self persistNormalizedItems:normalized error:&error];
  if (descriptors == nil) {
    [self finishResult:nil error:error ?: LAError(5030, @"Attachments could not be saved")
                  code:@"attachments"];
    return;
  }
  [self finishResult:@{
    @"schema_version": @1,
    @"status": @"selected",
    @"attachments": descriptors,
  } error:nil code:nil];
}

- (void)loadPhotoResults:(NSArray<PHPickerResult *> *)results
          typeIdentifiers:(NSArray<NSString *> *)typeIdentifiers
                    index:(NSUInteger)index
               inputBytes:(uint64_t)inputBytes
               normalized:(NSMutableArray<NSDictionary *> *)normalized {
  if (index >= results.count) {
    dispatch_async(self.attachmentQueue, ^{
      [self finishWithNormalizedItems:normalized];
    });
    return;
  }
  PHPickerResult *result = results[index];
  NSItemProvider *provider = result.itemProvider;
  [provider loadFileRepresentationForTypeIdentifier:typeIdentifiers[index]
    completionHandler:^(NSURL *url, NSError *providerError) {
      __block NSData *encoded = nil;
      __block NSError *readError = providerError;
      if (url != nil && readError == nil) {
        struct stat metadata = {};
        if (lstat(url.fileSystemRepresentation, &metadata) != 0
          || !S_ISREG(metadata.st_mode) || S_ISLNK(metadata.st_mode)
          || metadata.st_size <= 0 || metadata.st_size > LAMaxImageInputBytes
          || (uint64_t)metadata.st_size > 64ULL * 1024 * 1024 - inputBytes) {
          readError = LAError(5033, @"Selected photos exceed the safe input limit");
        } else {
          encoded = [NSData dataWithContentsOfURL:url
                                          options:NSDataReadingMappedIfSafe
                                            error:&readError];
        }
      }
      dispatch_async(self.attachmentQueue, ^{
        @autoreleasepool {
          if (encoded == nil || readError != nil) {
            [self finishResult:nil error:readError
              ?: LAError(5033, @"A selected photo could not be read") code:@"photos"];
            return;
          }
          NSError *normalizeError = nil;
          NSDictionary *item = LANormalizedImageData(
            encoded, provider.suggestedName ?: @"Photo", &normalizeError);
          if (item == nil) {
            [self finishResult:nil error:normalizeError
              ?: LAError(5034, @"A selected photo could not be loaded") code:@"photos"];
            return;
          }
          [normalized addObject:item];
          [self loadPhotoResults:results typeIdentifiers:typeIdentifiers
            index:index + 1 inputBytes:inputBytes + encoded.length
            normalized:normalized];
        }
      });
    }];
}

RISH_NATIVE_METHOD(present,
                 presentSource:(id)sourceValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSString *sourceName = LAString(sourceValue);
  LAPickerSource source = [sourceName isEqualToString:@"camera"] ? LAPickerSourceCamera
    : ([sourceName isEqualToString:@"photos"] ? LAPickerSourcePhotos
      : ([sourceName isEqualToString:@"files"] ? LAPickerSourceFiles : LAPickerSourceNone));
  if (source == LAPickerSourceNone) {
    reject(@"validation", @"Attachment source must be camera, photos, or files", nil);
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (source == LAPickerSourceCamera
      && ![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
      reject(@"camera_unavailable",
        @"Camera is unavailable on this device. The iOS Simulator does not provide a camera.", nil);
      return;
    }
    if (![self beginSource:source resolve:resolve reject:reject]) return;
    UIViewController *presenter = RishPresentedViewController();
    if (source == LAPickerSourceCamera) {
      UIImagePickerController *picker = [[UIImagePickerController alloc] init];
      picker.sourceType = UIImagePickerControllerSourceTypeCamera;
      picker.mediaTypes = @[UTTypeImage.identifier];
      picker.delegate = self;
      [self presentPicker:picker fromPresenter:presenter];
      return;
    }
    if (source == LAPickerSourcePhotos) {
      PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc]
        initWithPhotoLibrary:PHPhotoLibrary.sharedPhotoLibrary];
      configuration.filter = PHPickerFilter.imagesFilter;
      configuration.selectionLimit = LAMaxAttachmentCount;
      PHPickerViewController *picker = [[PHPickerViewController alloc]
        initWithConfiguration:configuration];
      picker.delegate = self;
      [self presentPicker:picker fromPresenter:presenter];
      return;
    }
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
      initForOpeningContentTypes:@[UTTypeImage, UTTypeText, UTTypePDF] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentPicker:picker fromPresenter:presenter];
  });
}

- (void)picker:(PHPickerViewController *)picker
    didFinishPicking:(NSArray<PHPickerResult *> *)results {
  if (![self isCurrentController:picker source:LAPickerSourcePhotos]) return;
  self.pendingSelectionStarted = results.count > 0;
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (results.count == 0) {
    [self finishCancelled];
    return;
  }
  if (results.count > LAMaxAttachmentCount) {
    [self finishResult:nil error:LAError(5031, @"Choose no more than 6 photos") code:@"limit"];
    return;
  }
  NSMutableArray<NSString *> *typeIdentifiers = [NSMutableArray arrayWithCapacity:results.count];
  for (PHPickerResult *result in results) {
    NSItemProvider *provider = result.itemProvider;
    NSString *typeIdentifier = nil;
    for (NSString *registered in provider.registeredTypeIdentifiers) {
      UTType *type = [UTType typeWithIdentifier:registered];
      if ([type conformsToType:UTTypeImage]) {
        typeIdentifier = registered;
        break;
      }
    }
    if (typeIdentifier == nil) {
      [self finishResult:nil
        error:LAError(5032, @"A selected photo has no readable image data") code:@"photos"];
      return;
    }
    [typeIdentifiers addObject:typeIdentifier];
  }
  [self loadPhotoResults:results typeIdentifiers:typeIdentifiers index:0
              inputBytes:0 normalized:[NSMutableArray array]];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
  if (![self isCurrentController:picker source:LAPickerSourceCamera]) return;
  [picker dismissViewControllerAnimated:YES completion:nil];
  [self finishCancelled];
}

- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
  if (![self isCurrentController:picker source:LAPickerSourceCamera]) return;
  self.pendingSelectionStarted = YES;
  UIImage *image = info[UIImagePickerControllerOriginalImage];
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (image == nil) {
    [self finishResult:nil error:LAError(5035, @"The camera did not return an image")
                  code:@"camera"];
    return;
  }
  [self processNormalizedCandidates:@[@{
    @"image": image,
    @"name": @"Camera Photo",
  }]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
  if (![self isCurrentController:controller source:LAPickerSourceFiles]) return;
  [self finishCancelled];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  if (![self isCurrentController:controller source:LAPickerSourceFiles]) return;
  self.pendingSelectionStarted = urls.count > 0;
  if (urls.count == 0) {
    [self finishCancelled];
    return;
  }
  if (urls.count > LAMaxAttachmentCount) {
    [self finishResult:nil error:LAError(5036, @"Choose no more than 6 files") code:@"limit"];
    return;
  }
  NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
  for (NSURL *url in urls) [candidates addObject:@{@"file_url": url}];
  [self processNormalizedCandidates:candidates];
}

RISH_NATIVE_METHOD(discard,
                 discardIdentifiers:(id)identifiersValue
                 discardResolver:(RishResolveBlock)resolve
                 discardRejecter:(RishRejectBlock)reject) {
  NSArray *values = [identifiersValue isKindOfClass:NSArray.class] ? identifiersValue : nil;
  if (values == nil || values.count > 1000) {
    reject(@"validation", @"Attachment identifiers are invalid", nil);
    return;
  }
  dispatch_async(self.attachmentQueue, ^{
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    for (id value in values) {
      NSString *identifier = LACanonicalAttachmentID(value);
      if (identifier == nil) {
        reject(@"validation", @"Attachment identifier is invalid", nil);
        return;
      }
      [identifiers addObject:identifier];
    }
    NSRecursiveLock *storeLock = LAStoreLock();
    [storeLock lock];
    @try {
    NSError *error = nil;
    NSURL *root = LAAttachmentsRoot(YES, &error);
    NSUInteger discarded = 0;
    for (NSString *identifier in root == nil ? @[] : identifiers) {
      NSURL *directory = [root URLByAppendingPathComponent:identifier isDirectory:YES];
      struct stat metadata = {};
      if (lstat(directory.fileSystemRepresentation, &metadata) != 0) {
        if (errno == ENOENT) continue;
        error = LAError(5037, @"An attachment could not be inspected");
        break;
      }
      if (!S_ISDIR(metadata.st_mode) || S_ISLNK(metadata.st_mode)
        || ![[NSFileManager defaultManager] removeItemAtURL:directory error:&error]) break;
      discarded += 1;
    }
    if (error == nil && discarded > 0) {
      int rootDescriptor = open(root.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      if (rootDescriptor < 0 || fsync(rootDescriptor) != 0) {
        error = LAError(5037, @"Attachment removal could not be committed");
      }
      if (rootDescriptor >= 0) close(rootDescriptor);
    }
    if (error != nil) reject(@"attachments", error.localizedDescription, error);
    else resolve(@{@"schema_version": @1, @"discarded_count": @(discarded)});
    } @finally {
      [storeLock unlock];
    }
  });
}

RISH_NATIVE_METHOD(prune,
                 pruneReferencedIdentifiers:(id)identifiersValue
                 pruneResolver:(RishResolveBlock)resolve
                 pruneRejecter:(RishRejectBlock)reject) {
  NSArray *values = [identifiersValue isKindOfClass:NSArray.class] ? identifiersValue : nil;
  if (values == nil || values.count > 10000) {
    reject(@"validation", @"Referenced attachment identifiers are invalid", nil);
    return;
  }
  dispatch_async(self.attachmentQueue, ^{
    NSMutableSet<NSString *> *referenced = [NSMutableSet set];
    for (id value in values) {
      NSString *identifier = LACanonicalAttachmentID(value);
      if (identifier == nil) {
        reject(@"validation", @"Referenced attachment identifier is invalid", nil);
        return;
      }
      [referenced addObject:identifier];
    }
    NSRecursiveLock *storeLock = LAStoreLock();
    [storeLock lock];
    @try {
    NSError *error = nil;
    NSURL *root = LAAttachmentsRoot(YES, &error);
    NSArray<NSURL *> *children = root == nil ? nil
      : [[NSFileManager defaultManager] contentsOfDirectoryAtURL:root
          includingPropertiesForKeys:nil options:0 error:&error];
    NSUInteger removed = 0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (NSURL *child in children) {
      NSString *identifier = LACanonicalAttachmentID(child.lastPathComponent);
      if (identifier == nil || [referenced containsObject:identifier]) continue;
      struct stat metadata = {};
      if (lstat(child.fileSystemRepresentation, &metadata) != 0
        || !S_ISDIR(metadata.st_mode) || S_ISLNK(metadata.st_mode)) continue;
#if defined(__APPLE__)
      NSTimeInterval modified = (NSTimeInterval)metadata.st_mtimespec.tv_sec
        + ((NSTimeInterval)metadata.st_mtimespec.tv_nsec / 1000000000.0);
#else
      NSTimeInterval modified = (NSTimeInterval)metadata.st_mtime;
#endif
      if (now - modified <= LAOrphanGracePeriod) continue;
      if (![[NSFileManager defaultManager] removeItemAtURL:child error:&error]) break;
      removed += 1;
    }
    if (error == nil) {
      NSURL *stagingRoot = LAAttachmentStagingRoot(&error);
      NSArray<NSURL *> *stagedBatches = stagingRoot == nil ? nil
        : [[NSFileManager defaultManager] contentsOfDirectoryAtURL:stagingRoot
            includingPropertiesForKeys:nil options:0 error:&error];
      for (NSURL *batch in stagedBatches) {
        if (!LAValidBatchName(batch.lastPathComponent)) continue;
        struct stat metadata = {};
        if (lstat(batch.fileSystemRepresentation, &metadata) != 0
          || !S_ISDIR(metadata.st_mode) || S_ISLNK(metadata.st_mode)) continue;
#if defined(__APPLE__)
        NSTimeInterval modified = (NSTimeInterval)metadata.st_mtimespec.tv_sec
          + ((NSTimeInterval)metadata.st_mtimespec.tv_nsec / 1000000000.0);
#else
        NSTimeInterval modified = (NSTimeInterval)metadata.st_mtime;
#endif
        if (now - modified <= LAOrphanGracePeriod) continue;
        if (![[NSFileManager defaultManager] removeItemAtURL:batch error:&error]) break;
        removed += 1;
      }
    }
    if (error != nil) reject(@"attachments", error.localizedDescription, error);
    else resolve(@{@"schema_version": @1, @"removed_count": @(removed)});
    } @finally {
      [storeLock unlock];
    }
  });
}

RISH_NATIVE_METHOD(presentPreview,
                 presentPreviewIdentifier:(id)identifierValue
                 presentPreviewResolver:(RishResolveBlock)resolve
                 presentPreviewRejecter:(RishRejectBlock)reject) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![self beginSource:LAPickerSourcePreview resolve:resolve reject:reject]) return;
    dispatch_async(self.attachmentQueue, ^{
      NSError *error = nil;
      NSDictionary<NSString *, NSURL *> *prepared =
        [self preparePreviewForIdentifier:identifierValue error:&error];
      if (prepared == nil) {
        [self finishResult:nil error:error
          ?: LAError(5046, @"Attachment preview could not be prepared") code:@"preview"];
        return;
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pendingSource != LAPickerSourcePreview) {
          [[NSFileManager defaultManager] removeItemAtURL:prepared[@"root"] error:nil];
          return;
        }
        UIViewController *presenter = RishPresentedViewController();
        if (presenter == nil || [presenter isKindOfClass:UIAlertController.class]) {
          self.pendingPreviewRoot = prepared[@"root"];
          [self finishResult:nil
            error:LAError(5047, @"The attachment preview cannot be presented right now")
            code:@"presentation"];
          return;
        }
        self.pendingPreviewRoot = prepared[@"root"];
        self.pendingPreviewURL = prepared[@"file"];
        if (![QLPreviewController canPreviewItem:self.pendingPreviewURL]) {
          [self finishResult:nil
            error:LAError(5048, @"Quick Look cannot preview this attachment safely")
            code:@"preview"];
          return;
        }
        QLPreviewController *preview = [[QLPreviewController alloc] init];
        preview.dataSource = self;
        preview.delegate = self;
        preview.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
          initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                               target:self
                               action:@selector(closePreview)];
        UINavigationController *navigation = [[UINavigationController alloc]
          initWithRootViewController:preview];
        navigation.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentPicker:navigation fromPresenter:presenter];
      });
    });
  });
}

RISH_NATIVE_METHOD(preview,
                 previewIdentifier:(id)identifierValue
                 previewResolver:(RishResolveBlock)resolve
                 previewRejecter:(RishRejectBlock)reject) {
  dispatch_async(self.attachmentQueue, ^{
    NSRecursiveLock *storeLock = LAStoreLock();
    [storeLock lock];
    @try {
    NSString *identifier = LACanonicalAttachmentID(identifierValue);
    NSError *error = nil;
    NSDictionary *manifest = identifier == nil ? nil
      : RishLocalAttachmentLoadManifest(identifier, &error);
    if (manifest == nil) {
      error = error ?: LAError(5038, @"Attachment identifier is invalid");
      reject(@"attachments", error.localizedDescription, error);
      return;
    }
    NSURL *root = LAAttachmentsRoot(NO, &error);
    NSURL *thumbnailURL = [[root URLByAppendingPathComponent:identifier isDirectory:YES]
      URLByAppendingPathComponent:@"thumbnail.jpg"];
    struct stat metadata = {};
    NSString *dataURL = nil;
    if (lstat(thumbnailURL.fileSystemRepresentation, &metadata) == 0) {
      if (!S_ISREG(metadata.st_mode) || S_ISLNK(metadata.st_mode)
        || metadata.st_size <= 0 || metadata.st_size > LAMaxThumbnailBytes) {
        reject(@"attachments", @"Attachment thumbnail is invalid", nil);
        return;
      }
      NSData *thumbnail = [NSData dataWithContentsOfURL:thumbnailURL
                                                options:NSDataReadingMappedIfSafe
                                                  error:&error];
      dataURL = LADataURL(thumbnail);
      if (dataURL == nil) {
        reject(@"attachments", error.localizedDescription
          ?: @"Attachment thumbnail cannot be read", error);
        return;
      }
    } else if (errno != ENOENT) {
      reject(@"attachments", @"Attachment thumbnail is unavailable", nil);
      return;
    }
    resolve(@{
      @"schema_version": @1,
      @"id": identifier,
      @"thumbnail_data_url": dataURL ?: NSNull.null,
    });
    } @finally {
      [storeLock unlock];
    }
  });
}

@end
