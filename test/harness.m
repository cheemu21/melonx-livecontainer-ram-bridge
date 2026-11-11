// Runs MeloNX's real MLXRamDonor.m against the bridge on macOS.
//
// iOS extensions can't launch here, so NSExtension is faked: each "donor process" is a thread that
// loads the bridge the same way LiveProcess's main.m does. That checks the redirect, the payload
// keys and the XPC protocol. It can't check PlugInKit, jetsam, code signing or real iOS limits.

@import Foundation;
#import <dlfcn.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import "MLXRamDonor.h"

static int failures;

#define CHECK(cond, ...) do { \
    BOOL ok_ = (cond); \
    printf("%s  ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); fflush(stdout); \
    if (!ok_) failures++; \
} while (0)

static NSString *const kLiveProcessID = @"com.test.livecontainer.LiveProcess";
static NSMutableArray<NSString *> *gRequestedIDs;
static NSMutableArray<NSDictionary *> *gPayloadInfos;
static int gKillCount;

@interface LiveProcessHandler : NSObject
@end
@implementation LiveProcessHandler
+ (NSDictionary *)retrievedAppInfo { return NSThread.currentThread.threadDictionary[@"appInfo"]; }
@end

#pragma mark Fake NSExtension

static id fake_extensionWithIdentifier(id self, SEL _cmd, NSString *identifier, NSError **error)
{
    @synchronized (gRequestedIDs) { [gRequestedIDs addObject:identifier]; }

    // Like iOS: only extensions that are really installed can be found.
    if (![identifier isEqualToString:kLiveProcessID] && ![identifier isEqualToString:@"com.other.Installed"])
    {
        if (error) *error = [NSError errorWithDomain:@"fake" code:1 userInfo:nil];
        return nil;
    }

    return class_createInstance(self, 0);
}

static void fake_begin(id self, SEL _cmd, NSArray *items, void (^completion)(NSUUID *))
{
    NSDictionary *info = [items.firstObject userInfo];

    @synchronized (gPayloadInfos) { [gPayloadInfos addObject:info]; }

    // The same steps as LiveProcess/main.m.
    NSString *dylib = info[@"customPayloadDylib"];
    NSString *entry = info[@"customPayloadEntry"];

    if (!dylib || !entry) { completion(nil); return; }

    void *handle = dlopen(dylib.fileSystemRepresentation, RTLD_LAZY);
    int (*payload)(int, char **, char **, char **) = handle ? dlsym(handle, entry.UTF8String) : NULL;

    if (!payload) { completion(nil); return; }

    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        NSThread.currentThread.threadDictionary[@"appInfo"] = info;
        payload(0, NULL, NULL, NULL);
    }];
    [thread start];

    completion(NSUUID.UUID);
}

static int fake_pid(id self, SEL _cmd, NSUUID *uuid) { return getpid(); }
static void fake_kill(id self, SEL _cmd, int sig) { gKillCount++; }
static void fake_noop(id self, SEL _cmd, id value) {}

static void InstallFakes(void)
{
    Class cls = NSClassFromString(@"NSExtension");
    class_replaceMethod(object_getClass(cls), @selector(extensionWithIdentifier:error:), (IMP)fake_extensionWithIdentifier, "@@:@^@");
    class_replaceMethod(cls, @selector(beginExtensionRequestWithInputItems:completion:), (IMP)fake_begin, "v@:@@");
    class_replaceMethod(cls, @selector(pidForRequestIdentifier:), (IMP)fake_pid, "i@:@");
    class_replaceMethod(cls, @selector(_kill:), (IMP)fake_kill, "v@:i");
    class_replaceMethod(cls, @selector(setPreferredLanguages:), (IMP)fake_noop, "v@:@");
    class_replaceMethod(cls, @selector(setRequestCancellationBlock:), (IMP)fake_noop, "v@:@");
}

#pragma mark Tests

int main(int argc, char *argv[])
{
    @autoreleasepool {
        gRequestedIDs = [NSMutableArray array];
        gPayloadInfos = [NSMutableArray array];

        const uint64_t MiB = 1024ull * 1024ull;
        const uint64_t request = 3072 * MiB;

        // Each donor reports 1536 MB. MeloNX leaves 256 MB of that free, so 3 GB needs 3 donors.
        setenv("MLX_TEST_DONOR_BUDGET", [@(1536 * MiB) stringValue].UTF8String, 1);

        InstallFakes();

        void *bridge = dlopen(argv[1], RTLD_NOW);
        CHECK(bridge != NULL, "bridge dylib loads (%s)", bridge ? "ok" : dlerror());
        if (!bridge) return 1;

        void *(*firstRegion)(void) = dlsym(bridge, "MLXBridgeTestFirstRegion");

        // Other apps' extension lookups must not change.
        [gRequestedIDs removeAllObjects];
        id other = [NSClassFromString(@"NSExtension") performSelector:@selector(extensionWithIdentifier:error:)
                                                           withObject:@"com.other.Installed"
                                                           withObject:nil];
        CHECK(other && [gRequestedIDs.lastObject isEqualToString:@"com.other.Installed"],
              "unrelated extension lookups pass through unchanged");

        // This test binary has no PlugIns folder, like a guest whose PlugIns were removed.
        usleep(400000);
        CHECK(mlx_ram_donor_is_available(), "MeloNX sees a donor even with no PlugIns folder");

        [gRequestedIDs removeAllObjects];
        mlx_ram_donor_set_kill_after_mapping(true);

        uint64_t granted = 0;
        uint8_t *base = mlx_ram_donor_acquire_up_to(request, 256 * MiB, &granted);
        const char *lastError = mlx_ram_donor_last_error();

        CHECK(base != NULL, "real MLXRamDonor acquired memory (%s)", lastError ?: "no error");
        if (!base) return 1;

        CHECK(granted == request, "granted the full request: %llu of %llu MB", granted / MiB, request / MiB);
        CHECK(mlx_ram_donor_live_count() == 3, "3 donors connected: %u", mlx_ram_donor_live_count());

        BOOL allRedirected = gRequestedIDs.count == 3;
        for (NSString *identifier in gRequestedIDs) allRedirected &= [identifier isEqualToString:kLiveProcessID];
        CHECK(allRedirected, "every donor request was sent to LiveProcess (%lu requests, last %s)",
              (unsigned long)gRequestedIDs.count, gRequestedIDs.lastObject.UTF8String);

        NSDictionary *info = gPayloadInfos.lastObject;
        CHECK([info[@"customPayloadEntry"] isEqualToString:@"MLXDonorPayloadMain"], "payload entry is set");
        CHECK([info[@"customPayloadDylib"] hasSuffix:@"MeloNXDonorBridge.dylib"], "payload path is this dylib");
        CHECK([info[@"endpoint"] isKindOfClass:NSXPCListenerEndpoint.class], "MeloNX's endpoint is still in the request");

        CHECK(gKillCount == 3, "MeloNX's kill-after-mapping reached all 3 donors: %d", gKillCount);

        // Every chunk must be writable and readable, including across chunk boundaries.
        BOOL pattern = YES;
        for (uint64_t offset = 0; offset < granted; offset += 64 * MiB)
        {
            base[offset] = (uint8_t)(offset / (64 * MiB) + 1);
            base[offset + 64 * MiB - 1] = 0x5A;
        }
        for (uint64_t offset = 0; offset < granted; offset += 64 * MiB)
        {
            pattern &= base[offset] == (uint8_t)(offset / (64 * MiB) + 1);
            pattern &= base[offset + 64 * MiB - 1] == 0x5A;
        }
        CHECK(pattern, "the whole %llu MB block reads back correctly", granted / MiB);

        // Prove it's really the donor's memory rather than a private copy.
        uint8_t *donorSide = firstRegion ? firstRegion() : NULL;
        base[1] = 0xC3;
        CHECK(donorSide && donorSide[1] == 0xC3, "a write by MeloNX is visible on the donor's side");
        donorSide[2] = 0x7E;
        CHECK(base[2] == 0x7E, "a write by the donor is visible to MeloNX");

        mlx_ram_donor_release(base);
        CHECK(YES, "region released without crashing");
    }

    printf("\n%s (%d failed)\n", failures ? "TESTS FAILED" : "ALL TESTS PASSED", failures);
    fflush(stdout);
    _exit(failures ? 1 : 0);
}
