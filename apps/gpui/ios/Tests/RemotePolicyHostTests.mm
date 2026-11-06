#import <Foundation/Foundation.h>
#import "DSHGitPushSupport.h"
#import "DSHGitSSHSupport.h"
#import "RishGitFormValidation.h"

static NSUInteger checks;
static void Check(BOOL value, NSString *message) {
  checks++;
  NSCAssert(value, @"%@", message);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    Check(argc == 2, @"Shared policy fixture path is required");
    NSData *fixtureData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
    NSDictionary *fixture = [NSJSONSerialization JSONObjectWithData:fixtureData options:0 error:nil];
    Check([fixture[@"cases"] isKindOfClass:NSArray.class] && [fixture[@"cases"] count] > 0,
      @"The adapter must consume the shared Rust policy cases");
    for (NSDictionary *item in fixture[@"cases"]) {
      id expected = item[@"value"];
      BOOL httpsAdapter = [expected isKindOfClass:NSDictionary.class] &&
        [@[@"http", @"https"] containsObject:expected[@"scheme"]];
      NSError *error = nil;
      NSURL *url = DSHGitValidatedRemoteURL(item[@"url"], &error);
      Check(httpsAdapter ? (url != nil && error == nil && [url.absoluteString isEqual:expected[@"url"]]) :
        (url == nil && error.code == 3002), [NSString stringWithFormat:@"Shared fixture %@", item[@"id"]]);
      NSError *sshError = nil;
      NSDictionary *ssh = DSHGitSSHValidatedRemote(item[@"url"], &sshError);
      BOOL sshAdapter = [expected isKindOfClass:NSDictionary.class] && [expected[@"scheme"] isEqual:@"ssh"];
      if (sshAdapter) {
        NSMutableDictionary *nativeExpected = [expected mutableCopy];
        [nativeExpected removeObjectForKey:@"scheme"];
        Check([ssh isEqual:nativeExpected] && sshError == nil,
          [NSString stringWithFormat:@"Shared SSH credential identity %@", item[@"id"]]);
      } else {
        Check(ssh == nil && sshError.code == 4001,
          [NSString stringWithFormat:@"Shared SSH rejection %@", item[@"id"]]);
      }
    }
    for (NSString *input in @[@"https://github.com/org/repo.git", @"https://github.com:443/org/repo.git",
      @"http://localhost:9000/repo.git", @"http://127.0.0.1/repo.git", @"http://10.1.2.3/repo.git",
      @"http://172.16.0.1/repo.git", @"http://192.168.1.2/repo.git", @"http://169.254.1.2/repo.git",
      @"http://[::1]:9000/repo.git", @"http://[fd00::1]/repo.git", @"https://github.com/repo%20name.git"]) {
      NSError *error = nil;
      NSURL *url = DSHGitValidatedRemoteURL(input, &error);
      Check(url != nil && error == nil, @"Accepted Rust remote must produce a native URL");
      Check([url.absoluteString isEqual:input], @"Native adapter preserves the policy's URL bytes");
    }
    Check([DSHGitValidatedRemoteURL(@"HTTPS://GitHub.com/Org/Repo.git", nil).absoluteString
      isEqual:@"https://github.com/Org/Repo.git"], @"Rust canonicalizes only scheme and host");
    for (id input in @[NSNull.null, @42, @[], @{}, @"", @"git@github.com:org/repo.git",
      @"ssh://git@github.com/org/repo.git", @"file:///tmp/repo.git", @"ftp://github.com/repo.git",
      @"https://localhost/repo", @"https://127.0.0.1/repo", @"https://box.local/repo",
      @"https://box.internal/repo", @"https://github.com./repo", @"https://github.com:8443/repo",
      @"http://example.com/repo", @"http://8.8.8.8/repo", @"http://172.32.0.1/repo",
      @"http://10.0.0.1:0/repo", @"http://10.0.0.1:70000/repo", @"https://github.com/",
      @"https://user:password@github.com/repo", @"https://github.com/repo?token=value",
      @"https://github.com/repo#part", @"https://github.com/a/../repo", @"https://github.com/%2e/repo",
      @"https://github.com/repo%0a", @"https://github.com/repo%00", @"https://github.com/re po",
      @" https://github.com/repo", @"https://github.com/repo\n", @"https://github.com/a\\b"]) {
      NSError *error = nil;
      Check(DSHGitValidatedRemoteURL(input, &error) == nil && error.code == 3002,
        @"Native HTTPS adapter preserves Rust rejection and does not route SSH through HTTPS credentials");
    }
    unichar malformed[] = {'h', 't', 't', 'p', ':', '/', '/', 0xd800};
    NSError *error = nil;
    Check(DSHGitValidatedRemoteURL([NSString stringWithCharacters:malformed length:8], &error) == nil &&
      error.code == 3002, @"Lossy UTF-16 never crosses the Rust policy boundary");
    Check(DSHGitSSHValidatedRemote([NSString stringWithCharacters:malformed length:8], &error) == nil &&
      error.code == 4001, @"SSH also refuses lossy Unicode before the Rust policy boundary");
    Check(DSHGitRemoteURLIsPlaintext(DSHGitValidatedRemoteURL(@"http://localhost/repo", nil)),
      @"LAN URL remains plaintext for the transport UI");
    Check(!DSHGitRemoteURLIsPlaintext(DSHGitValidatedRemoteURL(@"https://github.com/repo", nil)),
      @"HTTPS URL remains encrypted for the transport UI");
    Check([RishGitFormValues(@"remote", @{@"url": @" \u0085HTTPS://GitHub.com:443/Org/repo%20name\u3000"})
      isEqual:@{@"url": @"https://github.com:443/Org/repo%20name"}],
      @"The form uses Rust whitespace normalization and the same canonical remote as the transport");
    NSString *prefix = @"https://github.com/";
    NSString *exact = [prefix stringByPaddingToLength:2048 withString:@"a" startingAtIndex:0];
    Check(RishGitFormValues(@"remote", @{@"url": exact}) != nil, @"Form accepts its exact byte boundary");
    Check(RishGitFormValues(@"remote", @{@"url": [exact stringByAppendingString:@"a"]}) == nil,
      @"Form limit is enforced by Rust before transport parsing");
    Check(RishGitFormValues(@"remote", @{@"url": @"ssh://git@github.com/org/repo"}) == nil,
      @"The HTTPS form cannot select the SSH transport");
    Check(RishGitFormValues(@"remote", @{@"url": @"https://github.com/repo", @"token": @"secret"}) == nil,
      @"Unexpected form fields do not cross the policy boundary");
    Check(RishGitFormValues(@"commit", @{@"message": @"  修复  ", @"author_name": @"  用户  ",
      @"author_email": @" user@example.com "}) != nil, @"Existing commit form remains available");
    for (NSArray *pair in @[@[@"[fd00::1]", @"fd00::1"], @[@"[FD00::1]", @"fd00::1"],
      @[@"[::1]", @"::1"], @[@"fd00::1", @"[fd00::1]"], @[@"GitHub.com", @"github.com"],
      @[@"192.168.1.1", @"192.168.1.1"]]) {
      Check(DSHGitSSHCredentialHostsMatch(pair[0], pair[1]),
        @"Read-only legacy IPv6 compatibility preserves the same credential host");
    }
    for (NSArray *pair in @[@[@"[fd00::1]", @"fd00::2"], @[@"[[fd00::1]]", @"fd00::1"],
      @[@"[fd00::1", @"fd00::1"], @[@"fd00::1]", @"fd00::1"],
      @[@"[github.com]", @"github.com"], @[@"[192.168.1.1]", @"192.168.1.1"],
      @[@"fd00::1", @"[[fd00::1]]"], @[@"[not:ipv6]", @"not:ipv6"],
      @[@"github.com", @"gitlab.com"], @[@"[fd00::1]", @"fd00:0::1"],
      @[NSNull.null, @"fd00::1"], @[@"fd00::1", NSNull.null]]) {
      Check(!DSHGitSSHCredentialHostsMatch(pair[0], pair[1]),
        @"Compatibility never broadens host authorization or repairs malformed endpoints");
    }
    printf("PASS: %lu native remote-policy checks using shared fixtures and the linked Rust implementation\n",
      (unsigned long)checks);
  }
  return 0;
}
