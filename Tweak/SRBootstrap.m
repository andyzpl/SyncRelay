#import <Foundation/Foundation.h>
#import "Core/SRStore.h"
#import "UI/SRPanel.h"

/* Manual receive candidate/settings entry. No private send API or automatic execution. */
static SRStore *SRRepository;

__attribute__((constructor)) static void SRInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.tencent.xin"]) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                NSError *error = nil;
                NSURL *library = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
                if (!library) return;
                NSURL *directory = [library URLByAppendingPathComponent:@"Application Support/SyncRelay" isDirectory:YES];
                if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
                    NSLog(@"[SyncRelay] Storage unavailable; sender disabled.");
                    return;
                }
                SRRepository = [[SRStore alloc] initWithPath:[[directory URLByAppendingPathComponent:@"relay.sqlite3"] path] error:&error];
                if (!SRRepository || ![SRRepository recoverInterruptedRuns:&error]) {
                    NSLog(@"[SyncRelay] Recovery failed; sender disabled.");
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{ SRInstallPanelEntry(SRRepository); });
                NSLog(@"[SyncRelay] 0.2.1 initialized. Native settings entry is guarded; floating entry is opt-in. Sending is disabled.");
            }
        });
    }
}
