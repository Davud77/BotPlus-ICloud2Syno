// Standalone Sparkle installation test. Targets only disposable bundles under /tmp.
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

@interface TestDriver : NSObject <SPUUserDriver>
@end
@implementation TestDriver
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply { exit(11); }
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation { puts("CHECK"); }
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply { puts("FOUND"); reply(SPUUserUpdateChoiceInstall); }
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))ack { NSLog(@"NO UPDATE: %@", error); exit(12); }
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))ack { NSLog(@"REJECTED: %@", error); exit(13); }
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation { puts("DOWNLOAD"); }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { puts("EXTRACT"); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { puts("READY"); reply(SPUUserUpdateChoiceInstall); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))ack { puts("INSTALLED"); ack(); exit(0); }
- (void)dismissUpdateInstallation {}
@end

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 2) return 10;
    NSString *path = [NSString stringWithUTF8String:argv[1]];
    NSString *resolved = path.stringByResolvingSymlinksInPath;
    if (![resolved hasPrefix:@"/private/tmp/aphotos-update-e2e/"] && ![resolved hasPrefix:@"/tmp/aphotos-update-e2e/"]) return 10;
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    if (![bundle.bundleIdentifier isEqualToString:@"com.synologyphotosync.update-test"]) return 10;
    [NSApplication sharedApplication];
    TestDriver *driver = [TestDriver new];
    SPUUpdater *updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:driver delegate:nil];
    NSError *error = nil;
    if (![updater startUpdater:&error]) { NSLog(@"START ERROR: %@", error); return 14; }
    [updater checkForUpdates];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(15); });
    [[NSRunLoop mainRunLoop] run];
  }
  return 15;
}
