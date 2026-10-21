#import <Foundation/Foundation.h>
#import "Core/SRStore.h"
#import "UI/SRPanel.h"
#import "Core/SRRuntimeLog.h"
#import "Core/SRVersion.h"

/* Startup restores storage/settings only. Every device checkpoint needs a manual start. */
static SRStore *SRRepository;

static void SRShowSettings(SRStore *store) {
    dispatch_async(dispatch_get_main_queue(), ^{ SRInstallPanelEntry(store); });
}

__attribute__((constructor)) static void SRInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.tencent.xin"]) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                NSError *error = nil;
                NSURL *library = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
                if (!library) { SRShowSettings(nil); return; }
                NSURL *directory = [library URLByAppendingPathComponent:@"Application Support/SyncRelay" isDirectory:YES];
                if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
                    NSLog(@"[SyncRelay] Storage unavailable; sender disabled.");
                    SRShowSettings(nil);
                    return;
                }
                [SRRuntimeLog.shared enablePersistenceAtPath:[[directory URLByAppendingPathComponent:@"runtime-log.json"] path]];
                SRRepository = [[SRStore alloc] initWithPath:[[directory URLByAppendingPathComponent:@"relay.sqlite3"] path] error:&error];
                if (!SRRepository || ![SRRepository recoverInterruptedRuns:&error]) {
                    NSLog(@"[SyncRelay] Recovery failed; sender disabled.");
                    SRShowSettings(nil);
                    return;
                }
                SRShowSettings(SRRepository);
                [SRRuntimeLog.shared record:@"boot" facts:@{@"storageReady": @YES}];
                NSLog(@"[SyncRelay] %@ initialized. Explicit 1-3-group checkpoint available; no automatic start or large batches.", SR_PLUGIN_VERSION);
            }
        });
    }
}
