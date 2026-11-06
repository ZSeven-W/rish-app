#import "ShellAssistantAvatarImage.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <TargetConditionals.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>

static const uint64_t AvatarMaxSourceBytes = 64ULL * 1024 * 1024;
static const NSUInteger AvatarMaxOutputBytes = 2 * 1024 * 1024;
static NSError *AvatarError(NSString *code) {
  return [NSError errorWithDomain:@"RishAssistantAvatar" code:1 userInfo:@{
    @"code":code, NSLocalizedDescriptionKey:@"This image cannot be used as an avatar."
  }];
}
static BOOL AvatarFail(NSError **error, NSString *code) {
  if (error) *error = AvatarError(code);
  return NO;
}
static NSData *AvatarReadSource(NSURL *url, NSError **error) {
  if (!url.isFileURL || !url.path.isAbsolutePath) {
    AvatarFail(error, @"E_ASSISTANT_AVATAR_INVALID"); return nil;
  }
  int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  struct stat metadata = {};
  if (fd < 0 || fstat(fd, &metadata) != 0 || !S_ISREG(metadata.st_mode)) {
    if (fd >= 0) close(fd);
    AvatarFail(error, @"E_ASSISTANT_AVATAR_INVALID"); return nil;
  }
  if (metadata.st_size <= 0 || (uint64_t)metadata.st_size > AvatarMaxSourceBytes) {
    close(fd); AvatarFail(error, @"E_ASSISTANT_AVATAR_TOO_LARGE"); return nil;
  }
  NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)metadata.st_size];
  uint8_t buffer[65536]; BOOL okay = YES;
  while (YES) {
    ssize_t count = read(fd, buffer, sizeof buffer);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) { okay = NO; break; }
    if (count == 0) break;
    if (data.length + (NSUInteger)count > AvatarMaxSourceBytes) { okay = NO; break; }
    [data appendBytes:buffer length:(NSUInteger)count];
  }
  close(fd);
  if (!okay) { AvatarFail(error, @"E_ASSISTANT_AVATAR_TOO_LARGE"); return nil; }
  return data;
}
static BOOL AvatarDimension(id value, uint64_t *dimension) {
  if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
  double number = [value doubleValue];
  if (!isfinite(number) || number != floor(number) || number < 1 || number > 32768) return NO;
  *dimension = (uint64_t)number; return YES;
}
static NSData *AvatarWithoutMetadata(NSData *png) {
  static const uint8_t signature[8] = {137,80,78,71,13,10,26,10};
  if (png.length < 8 || memcmp(png.bytes, signature, 8) != 0) return nil;
  NSMutableData *output = [NSMutableData dataWithBytes:signature length:8];
  const uint8_t *bytes = png.bytes; NSUInteger offset = 8; BOOL pixels = NO, ended = NO;
  while (offset + 12 <= png.length) {
    uint32_t length = ((uint32_t)bytes[offset] << 24) | ((uint32_t)bytes[offset + 1] << 16) |
        ((uint32_t)bytes[offset + 2] << 8) | bytes[offset + 3];
    if ((uint64_t)length + 12 > png.length - offset) return nil;
    const uint8_t *type = bytes + offset + 4;
    BOOL header = memcmp(type, "IHDR", 4) == 0;
    BOOL data = memcmp(type, "IDAT", 4) == 0;
    BOOL end = memcmp(type, "IEND", 4) == 0;
    // ImageIO synthesizes eXIf even when no source metadata is supplied. Keep
    // only pixel/palette/color chunks from its own completed PNG; copied chunks
    // retain their original CRC. EXIF, text, timestamps and XMP are omitted.
    BOOL keep = header || data || end || memcmp(type, "PLTE", 4) == 0 ||
        memcmp(type, "tRNS", 4) == 0 || memcmp(type, "sRGB", 4) == 0 ||
        memcmp(type, "gAMA", 4) == 0 || memcmp(type, "cHRM", 4) == 0 ||
        memcmp(type, "iCCP", 4) == 0 || memcmp(type, "sBIT", 4) == 0;
    if ((offset == 8 && (!header || length != 13)) || (header && offset != 8) ||
        (!keep && type[0] >= 'A' && type[0] <= 'Z')) return nil;
    if (data) pixels = YES;
    if (end && (length != 0 || offset + 12 != png.length)) return nil;
    if (keep) [output appendBytes:bytes + offset length:(NSUInteger)length + 12];
    offset += (NSUInteger)length + 12;
    if (end) { ended = YES; break; }
  }
  return pixels && ended && offset == png.length ? output : nil;
}
static NSData *AvatarPNG(NSData *source, NSUInteger *width, NSUInteger *height, NSError **error) {
  CGImageSourceRef image = CGImageSourceCreateWithData((__bridge CFDataRef)source,
      (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache:@NO});
  if (image == NULL || CGImageSourceGetCount(image) == 0) {
    if (image) CFRelease(image);
    AvatarFail(error, @"E_ASSISTANT_AVATAR_INVALID"); return nil;
  }
  NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(image, 0, NULL));
  uint64_t inputWidth = 0, inputHeight = 0;
  if (!AvatarDimension(properties[(__bridge NSString *)kCGImagePropertyPixelWidth], &inputWidth) ||
      !AvatarDimension(properties[(__bridge NSString *)kCGImagePropertyPixelHeight], &inputHeight) ||
      inputWidth * inputHeight > 100ULL * 1000 * 1000) {
    CFRelease(image); AvatarFail(error, @"E_ASSISTANT_AVATAR_TOO_LARGE"); return nil;
  }
  CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0,
      (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@(MIN(512ULL, MAX(inputWidth, inputHeight))),
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES});
  CFRelease(image);
  if (thumbnail == NULL) { AvatarFail(error, @"E_ASSISTANT_AVATAR_INVALID"); return nil; }
  *width = CGImageGetWidth(thumbnail); *height = CGImageGetHeight(thumbnail);
  if (*width == 0 || *height == 0 || *width > 512 || *height > 512) {
    CGImageRelease(thumbnail); AvatarFail(error, @"E_ASSISTANT_AVATAR_TOO_LARGE"); return nil;
  }
  NSMutableData *png = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,
      CFSTR("public.png"), 1, NULL);
  BOOL okay = NO;
  if (destination) {
    // Only decoded pixels are copied. Camera/EXIF/GPS and source filenames do
    // not become part of the app-private avatar or the profile metadata.
    CGImageDestinationAddImage(destination, thumbnail, NULL);
    okay = CGImageDestinationFinalize(destination);
    CFRelease(destination);
  }
  CGImageRelease(thumbnail);
  if (!okay || png.length == 0 || png.length > AvatarMaxOutputBytes) {
    AvatarFail(error, @"E_ASSISTANT_AVATAR_TOO_LARGE"); return nil;
  }
  NSData *sanitized = AvatarWithoutMetadata(png);
  if (!sanitized) AvatarFail(error, @"E_ASSISTANT_AVATAR_INVALID");
  return sanitized;
}
static BOOL AvatarDirectoryMatches(int fd, NSURL *url) {
  struct stat opened = {}, named = {};
  return fstat(fd, &opened) == 0 && lstat(url.fileSystemRepresentation, &named) == 0 &&
    S_ISDIR(named.st_mode) && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino;
}
static BOOL AvatarWrite(NSData *png, NSURL *directory, NSString *identifier, NSError **error) {
  if (!directory.isFileURL || !directory.path.isAbsolutePath ||
      ![directory.path isEqual:directory.URLByStandardizingPath.URLByResolvingSymlinksInPath.path])
    return AvatarFail(error, @"E_ASSISTANT_AVATAR_STORAGE");
  int root = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (root < 0) return AvatarFail(error, @"E_ASSISTANT_AVATAR_STORAGE");
  struct stat rootStat = {};
  if (fstat(root, &rootStat) != 0 || (rootStat.st_mode & 0777) != 0700 ||
      (mkdirat(root, "avatars", 0700) != 0 && errno != EEXIST)) {
    close(root); return AvatarFail(error, @"E_ASSISTANT_AVATAR_STORAGE");
  }
  int avatars = openat(root, "avatars", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (avatars < 0) { close(root); return AvatarFail(error, @"E_ASSISTANT_AVATAR_STORAGE"); }
  NSURL *avatarDirectory = [directory URLByAppendingPathComponent:@"avatars" isDirectory:YES];
  if (fchmod(avatars, 0700) != 0 || !AvatarDirectoryMatches(root, directory) ||
      !AvatarDirectoryMatches(avatars, avatarDirectory)) {
    close(avatars); close(root); return AvatarFail(error, @"E_ASSISTANT_AVATAR_STORAGE");
  }
  NSString *filename = [identifier stringByAppendingString:@".png"];
  NSString *temporary = [@".pending-" stringByAppendingString:identifier];
  int file = openat(avatars, temporary.fileSystemRepresentation,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (file < 0) { close(avatars); close(root); return AvatarFail(error, @"E_ASSISTANT_AVATAR_STORAGE"); }
  BOOL okay = fchmod(file, 0600) == 0;
  const uint8_t *bytes = png.bytes; NSUInteger offset = 0;
  while (okay && offset < png.length) {
    ssize_t written = write(file, bytes + offset, png.length - offset);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) { okay = NO; break; }
    offset += (NSUInteger)written;
  }
  okay = okay && fsync(file) == 0;
  close(file);
  BOOL published = NO;
  if (okay && AvatarDirectoryMatches(root, directory) && AvatarDirectoryMatches(avatars, avatarDirectory)) {
    // linkat publishes a complete unique file atomically and refuses an existing
    // destination. Old avatars are retained until profile ownership is known.
    published = linkat(avatars, temporary.fileSystemRepresentation, avatars, filename.fileSystemRepresentation, 0) == 0;
    okay = published;
  } else okay = NO;
  unlinkat(avatars, temporary.fileSystemRepresentation, 0);
  okay = okay && fsync(avatars) == 0 && fsync(root) == 0;
#if !TARGET_OS_SIMULATOR
  if (okay) {
    // New items inherit the protected Assistant directory. Verify rather than
    // mutating a path that could have changed after opening its descriptor.
    NSURL *fileURL = [avatarDirectory URLByAppendingPathComponent:filename];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:fileURL.path error:nil];
    okay = [attributes[NSFileProtectionKey] isEqual:NSFileProtectionCompleteUntilFirstUserAuthentication];
  }
#endif
  okay = okay && AvatarDirectoryMatches(root, directory) && AvatarDirectoryMatches(avatars, avatarDirectory);
  if (!okay && published) { unlinkat(avatars, filename.fileSystemRepresentation, 0); fsync(avatars); }
  close(avatars); close(root);
  return okay ?: AvatarFail(error, @"E_ASSISTANT_AVATAR_STORAGE");
}

@implementation ShellAssistantAvatarImage
+ (NSDictionary *)importImageAtURL:(NSURL *)source intoAssistantDirectory:(NSURL *)directory error:(NSError **)error {
  NSData *input = AvatarReadSource(source, error);
  if (!input) return nil;
  NSUInteger width = 0, height = 0;
  NSData *png = AvatarPNG(input, &width, &height, error);
  if (!png) return nil;
  NSString *identifier = NSUUID.UUID.UUIDString.lowercaseString;
  if (!AvatarWrite(png, directory, identifier, error)) return nil;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(png.bytes, (CC_LONG)png.length, digest);
  NSMutableString *hash = [NSMutableString stringWithCapacity:64];
  for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hash appendFormat:@"%02x", digest[i]];
  return @{@"id":identifier, @"sha256":hash, @"mime_type":@"image/png",
    @"width":@(width), @"height":@(height), @"byte_length":@(png.length)};
}
@end
